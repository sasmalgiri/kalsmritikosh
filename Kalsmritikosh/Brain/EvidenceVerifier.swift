//
//  EvidenceVerifier.swift
//  Kalsmritikosh
//
//  Last gate before any answer ships. Delegates confidence + contradiction
//  scoring to ConfidenceEngine and uses the report to decide whether to
//  ship, refuse, or downgrade. Without citations, no answer.
//

import Foundation

public struct EvidenceVerifier: Verifier {
    /// Per-claim citation cap (Item 1 of UPDATE_08). The previous
    /// `claims.flatMap { ... supportingObjectIDs.map { ... } }` emitted
    /// one citation per (claim × supportingObject) pair with no dedupe
    /// and no ranking — so a 16-claim answer with 4 supporting objects
    /// per claim shipped 64 raw citations, drowning the real source in
    /// noise (Gate 1: lookup precision 0.02). The cap is per-claim and
    /// NOT global so aggregation answers can still cite many sources.
    public static let maxCitationsPerClaim = 3

    /// UPDATE_14 — intent-aware global cap on distinct doc citations.
    /// After the per-claim cap + cross-claim dedupe, the survivor list
    /// still ran 6–8 docs deep because 5+ experts each contributed top
    /// chunks. Lookup answers should cite 1–3 docs; reconstruction and
    /// aggregation legitimately need more. These caps are intent-keyed,
    /// with an aggregation-shape override for question text that asks
    /// for breadth ("all", "total", "how many", "list", …).
    public static let lookupCitationCap = 3
    public static let reconstructCitationCap = 6
    public static let executiveCitationCap = 8
    public static let aggregationCitationCap = 8

    /// Question-shape hints that always get the generous cap even if
    /// the intent detector classified the question as factualLookup.
    /// Without this guard a "How many emails reference Supplier ABC?"
    /// question would lose recall on aggregation-class questions.
    private static let aggregationShapeKeywords: [String] = [
        "all ", " total", "how many", "how much", "count of",
        "each ", "list ", "list all", "sum of", "summarize all",
        "across the", "across all"
    ]

    /// Choose the per-answer global cap by intent kind + question shape.
    private static func intentCitationCap(_ intent: UserIntent) -> Int {
        let q = " " + intent.rawQuestion.lowercased() + " "
        if aggregationShapeKeywords.contains(where: { q.contains($0) }) {
            return aggregationCitationCap
        }
        switch intent.kind {
        case .factualLookup, .semanticSearch, .unknown:
            return lookupCitationCap
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            return reconstructCitationCap
        case .executiveBriefing, .riskDetection, .missingInformation:
            return executiveCitationCap
        }
    }

    public let minimumConfidence: Confidence
    public let minimumCitations: Int
    private let engine: any ConfidenceEngine
    /// Returns the fraction of the user's archive past Tier-1 ingest
    /// (chunks + entities + events present). The Engine multiplies
    /// final confidence by max(coverage, 0.5) while < 1.0, so the
    /// Quality Strip can honestly say "Answered from X% of your
    /// archive". `nil` → engine treats it as 1.0 (no-op multiplier).
    /// T11 close-out.
    private let ingestCoverageProvider: (@Sendable () async -> Double)?
    /// Defensive — filters hostname-shape, stoplist, and weekday
    /// strings out of the rendered "Subjects in scope" line even if
    /// they somehow survived ingestion. nil = no filtering, behaviour
    /// identical to pre-fix.
    private let entityQualityGate: EntityQualityGate?
    /// G2-1 — optional. When present, citation survivors are reordered
    /// by claim-relevance (reranker score) before the intent-aware
    /// global cap truncates. When nil, the cap orders by
    /// `scoreByObject` alone (pre-G2-1 behavior). The reranker itself
    /// degrades gracefully to identity scoring when no provider
    /// supports `.reranking` — so plumbing this through doesn't risk
    /// regression on a heuristic-floor run.
    private let reranker: Reranker?

    public init(
        minimumConfidence: Confidence = Confidence(0.2),
        minimumCitations: Int = 1,
        engine: any ConfidenceEngine = DefaultConfidenceEngine(),
        ingestCoverageProvider: (@Sendable () async -> Double)? = nil,
        entityQualityGate: EntityQualityGate? = nil,
        reranker: Reranker? = nil
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumCitations = minimumCitations
        self.engine = engine
        self.ingestCoverageProvider = ingestCoverageProvider
        self.entityQualityGate = entityQualityGate
        self.reranker = reranker
    }

    public func verify(
        intent: UserIntent,
        findings: [ExpertFindings],
        retrieval: RetrievalResult
    ) async throws -> VerifiedAnswer {
        let claims = findings.flatMap(\.claims)
        let droppedUnverifiable = findings.map(\.droppedUnverifiable).reduce(0, +)
        let intentWindow: DateInterval? = {
            guard let tf = intent.timeframe,
                  let s = tf.start, let e = tf.end, e > s else { return nil }
            return DateInterval(start: s, end: e)
        }()
        let ingestCoverage: Double = await ingestCoverageProvider?() ?? 1.0
        let report = await engine.evaluate(
            claims: claims,
            droppedUnverifiable: droppedUnverifiable,
            events: retrieval.events,
            intentKind: intent.kind,
            intentWindow: intentWindow,
            ingestCoverage: ingestCoverage,
            now: Date()
        )
        // Per-object ranking signal: best (max) hybrid retrieval score
        // across the chunks in `retrieval.chunks` that belong to a given
        // KnowledgeObject. Objects with no retrieval hit (came in via
        // memory / entity / event layer) sort to the back via -infinity.
        var scoreByObject: [KnowledgeObject.ID: Double] = [:]
        for rc in retrieval.chunks {
            let id = rc.chunk.objectID
            if let existing = scoreByObject[id] {
                if rc.score > existing { scoreByObject[id] = rc.score }
            } else {
                scoreByObject[id] = rc.score
            }
        }
        // Build citations with: per-claim cap (top-N by score), dedupe
        // across the whole answer by objectID (first claim that wins
        // a given object owns its snippet), and an intent-aware global
        // distinct-document cap applied last.
        var seenObjects = Set<KnowledgeObject.ID>()
        var citations: [VerifiedAnswer.Citation] = []
        for claim in claims {
            let ranked = claim.supportingObjectIDs.sorted { lhs, rhs in
                let ls = scoreByObject[lhs] ?? -.infinity
                let rs = scoreByObject[rhs] ?? -.infinity
                return ls > rs
            }
            for objectID in ranked.prefix(Self.maxCitationsPerClaim) {
                guard !seenObjects.contains(objectID) else { continue }
                seenObjects.insert(objectID)
                citations.append(VerifiedAnswer.Citation(
                    objectID: objectID,
                    eventID: claim.supportingEventIDs.first,
                    snippet: String(claim.statement.prefix(180))
                ))
            }
        }
        // G2-1 — pairwise relevance scoring of (question, candidate
        // citation snippet) via the reranker. Lifts citation precision
        // by reordering survivors against the actual question text
        // instead of retrieval similarity alone. Returns identity (0.5
        // for every candidate) when no reranker is wired OR when the
        // resolved provider isn't available — preserving the
        // `scoreByObject` ordering and ensuring no regression on the
        // heuristic floor.
        var rerankByObject: [KnowledgeObject.ID: Double] = [:]
        if let reranker, !citations.isEmpty {
            let snippets = citations.map { citation -> String in
                // Prefer a chunk text snippet for the candidate. The
                // citation's own `snippet` (a claim statement) is a
                // weak signal because the claim is what we're scoring
                // AGAINST. Fall back to it only when we have nothing
                // better — typically when the citation came from an
                // event-only claim with no chunk evidence.
                let chunkText = retrieval.chunks
                    .first { $0.chunk.objectID == citation.objectID }?
                    .chunk.text
                return String((chunkText ?? citation.snippet).prefix(400))
            }
            let scores = await reranker.score(question: intent.rawQuestion, candidates: snippets)
            for (i, citation) in citations.enumerated() where i < scores.count {
                rerankByObject[citation.objectID] = scores[i]
            }
        }

        // UPDATE_14 — apply the intent-aware global cap on distinct
        // documents. Survivor ranking is now lexicographic on
        // (rerankScore desc, scoreByObject desc) so the reranker takes
        // first say but never erases retrieval-score tiebreaks. The
        // answer-bearing top chunk (e.g. contract.md @ 0.863) keeps
        // winning when the reranker has no opinion (identity = 0.5
        // across the board → falls back to scoreByObject).
        let globalCap = Self.intentCitationCap(intent)
        if citations.count > globalCap {
            citations = Array(citations.sorted { lhs, rhs in
                let lr = rerankByObject[lhs.objectID] ?? 0.5
                let rr = rerankByObject[rhs.objectID] ?? 0.5
                if lr != rr { return lr > rr }
                let ls = scoreByObject[lhs.objectID] ?? -.infinity
                let rs = scoreByObject[rhs.objectID] ?? -.infinity
                return ls > rs
            }.prefix(globalCap))
        }

        let intentKindRaw = intent.kind.rawValue

        guard !claims.isEmpty,
              report.combined >= minimumConfidence,
              citations.count >= minimumCitations
        else {
            return VerifiedAnswer(
                body: "Atlas can't ground an answer to that yet.",
                answerText: nil,
                intentKind: intentKindRaw,
                citations: [],
                confidence: report.combined,
                contradictions: report.contradictions,
                refused: true,
                refusalReason: claims.isEmpty
                    ? "No expert produced any claim."
                    : "Evidence below confidence threshold (\(minimumConfidence.value)).",
                report: report
            )
        }

        let rendered = renderAnswer(intent: intent, findings: findings, retrieval: retrieval, report: report)
        return VerifiedAnswer(
            body: rendered.body,
            answerText: rendered.answerText,
            intentKind: intentKindRaw,
            citations: citations,
            confidence: report.combined,
            contradictions: report.contradictions,
            refused: false,
            refusalReason: nil,
            report: report
        )
    }

    /// Rendered answer split into the synthesized response (`answerText`)
    /// and the full UI body (`body`, which appends a small retrieval
    /// footer). Splitting these out is what UPDATE_13 Item 3/4 needs:
    /// eval metrics score against `answerText` so an expected name in
    /// the footer can no longer satisfy keyword-hit by coincidence.
    private struct RenderedAnswer {
        let body: String
        let answerText: String
    }

    private func renderAnswer(
        intent: UserIntent,
        findings: [ExpertFindings],
        retrieval: RetrievalResult,
        report: ConfidenceReport
    ) -> RenderedAnswer {
        // 1) Prefer claims that cite document chunks (KOs) — those are
        //    the synthesized answer for factual questions. When the LLM
        //    ran, these are real sentences answering the question. When
        //    the heuristic fallback ran, these are the top retrieval
        //    snippets — still better than event-title bullets because
        //    they contain the actual document text.
        let docClaims = findings.flatMap(\.claims).filter { !$0.supportingObjectIDs.isEmpty }
        let answerText: String
        if !docClaims.isEmpty {
            answerText = docClaims
                .prefix(5)
                .map(\.statement)
                .joined(separator: " ")
        } else {
            // 2) No document-grounded claims. Fall back to whatever
            //    claims any expert produced — typically event bullets.
            //    Still better than an entity dump.
            let anyClaims = findings.flatMap(\.claims)
            if anyClaims.isEmpty {
                answerText = "No expert produced findings for that question."
            } else {
                answerText = anyClaims
                    .prefix(5)
                    .map { "\u{2022} \($0.statement)" }
                    .joined(separator: "\n")
            }
        }

        // 3) Optional retrieval footer: subjects + an agreement note.
        //    This is for the user's situational awareness; it does NOT
        //    contribute to keyword-hit scoring.
        var footerParts: [String] = []
        let subjectLine = subjectHeading(intent: intent, retrieval: retrieval)
        if !subjectLine.isEmpty {
            footerParts.append(subjectLine)
        }
        if report.agreementScore <= 0.6 {
            footerParts.append("Note: experts disagreed across some of these claims.")
        }
        let body: String
        if footerParts.isEmpty {
            body = answerText
        } else {
            body = answerText + "\n\n---\n" + footerParts.joined(separator: "\n")
        }
        return RenderedAnswer(body: body, answerText: answerText)
    }

    private func subjectHeading(intent: UserIntent, retrieval: RetrievalResult) -> String {
        var subjects: [String] = []
        switch intent.scope {
        case .project(let name): subjects.append("Project \(name)")
        case .person(let name): subjects.append(name)
        case .organization(let name): subjects.append(name)
        case .folder(let path): subjects.append(path)
        case .global: break
        }
        for hint in intent.entityHints.prefix(6) where hint.count > 2 {
            if !subjects.contains(where: { $0.localizedCaseInsensitiveContains(hint) }) {
                subjects.append(hint)
            }
        }
        // Pull strong organization / project / person entities from
        // retrieved evidence to ground the answer body in named subjects.
        // Defensively re-filter through EntityQualityGate so the rendered
        // line never surfaces hostname-shape / stoplist / weekday strings
        // even if a pre-T13.4 row survived in the canonical table.
        let strong = retrieval.entities
            .filter { $0.kind == .organization || $0.kind == .person || $0.kind == .project || $0.kind == .vendor || $0.kind == .client }
            .filter { entityQualityGate?.shouldKeep($0) ?? true }
            .sorted { $0.confidence > $1.confidence }
            .prefix(6)
            .map(\.value)
        for value in strong where value.count > 2 {
            if !subjects.contains(where: { $0.localizedCaseInsensitiveContains(value) }) {
                subjects.append(value)
            }
        }
        // Domain mining: walk emails encountered in retrieved evidence and
        // surface the organizational domains they came from (e.g.
        // "supplier-abc.com" → "Supplier ABC").
        let emails = retrieval.entities
            .filter { $0.kind == .emailAddress }
            .compactMap { $0.normalizedValue ?? $0.value }
        var domains = Set<String>()
        for email in emails {
            if let at = email.firstIndex(of: "@") {
                let domain = String(email[email.index(after: at)...])
                guard let head = domain.split(separator: ".").first.map(String.init)
                else { continue }
                let label = head
                    .split(separator: "-")
                    .map { token -> String in
                        let s = String(token)
                        // Preserve obvious acronyms (<= 4 chars, alphabetic).
                        if s.count <= 4 && s.allSatisfy(\.isLetter) {
                            return s.uppercased()
                        }
                        return s.prefix(1).uppercased() + s.dropFirst().lowercased()
                    }
                    .joined(separator: " ")
                if !label.isEmpty { domains.insert(label) }
            }
        }
        for label in domains where label.count > 2 {
            // Same gate check via a synthesized organization entity so
            // hostname-shape domain stems (Tyzpr01mb4530, Seqmbx01) get
            // filtered before they ever reach the rendered line.
            if let gate = entityQualityGate {
                let probe = Entity(
                    kind: .organization,
                    value: label,
                    sourceObjectID: UUID(),
                    confidence: .medium
                )
                if !gate.shouldKeep(probe) { continue }
            }
            if !subjects.contains(where: { $0.localizedCaseInsensitiveContains(label) }) {
                subjects.append(label)
            }
        }
        return subjects.isEmpty ? "" : "Subjects in scope: \(subjects.joined(separator: ", "))."
    }
}
