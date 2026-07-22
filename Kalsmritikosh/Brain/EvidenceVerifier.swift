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

    /// Question text matches an aggregation shape ("all X", "how many",
    /// "list all", "across the…"). Drives both the generous global
    /// citation cap AND the G2-1.5 reranker bypass — aggregation needs
    /// breadth of coverage, but the reranker scores relevance, so it
    /// systematically drops the long tail of legitimate evidence.
    private static func isAggregationShape(_ intent: UserIntent) -> Bool {
        let q = " " + intent.rawQuestion.lowercased() + " "
        return aggregationShapeKeywords.contains(where: { q.contains($0) })
    }

    /// G2-MMR — Maximal Marginal Relevance lambda. 0.7 = 70% weight on
    /// relevance, 30% on diversity. chatmind-pipeline's validated value.
    /// Lower → more diversity / less relevance pull; higher → vice-versa.
    private static let mmrLambda = 0.7

    /// MMR pass over reranked citation survivors.
    ///
    /// Greedy selection: at each step, pick the candidate that
    /// maximizes  λ * relevance − (1 − λ) * maxSimilarityToAlreadyPicked.
    /// Relevance combines reranker + retrieval scores. Similarity is
    /// token-Jaccard on snippets — cheap, deterministic, no embedder
    /// needed. Stops when `limit` citations are picked.
    ///
    /// Fixes the aggregation pile-up pattern (UPDATE_18 §2): without
    /// MMR, a thread of 4 near-identical supplier emails monopolizes
    /// the citation cap and crowds out the contract/amendment that
    /// completes the answer.
    private static func applyMMR(
        citations: [VerifiedAnswer.Citation],
        rerankByObject: [KnowledgeObject.ID: Double],
        scoreByObject: [KnowledgeObject.ID: Double],
        lambda: Double,
        limit: Int
    ) -> [VerifiedAnswer.Citation] {
        guard citations.count > limit else { return citations }

        // Pre-tokenize each snippet once. Short tokens (<3 chars) are
        // dropped to suppress stop-word noise; lowercasing makes the
        // Jaccard case-insensitive.
        let tokensByID: [KnowledgeObject.ID: Set<String>] = Dictionary(
            uniqueKeysWithValues: citations.map { c in
                let toks = c.snippet
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 3 }
                return (c.objectID, Set(toks))
            }
        )

        func relevance(_ c: VerifiedAnswer.Citation) -> Double {
            let r = rerankByObject[c.objectID] ?? 0.5
            let s = scoreByObject[c.objectID] ?? 0.5
            return (r + s) / 2
        }

        func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
            if a.isEmpty && b.isEmpty { return 0 }
            let inter = a.intersection(b).count
            let union = a.union(b).count
            return union == 0 ? 0 : Double(inter) / Double(union)
        }

        var pool = citations
        var picked: [VerifiedAnswer.Citation] = []
        picked.reserveCapacity(limit)

        while !pool.isEmpty && picked.count < limit {
            var bestIdx = 0
            var bestScore = -Double.infinity
            for (i, c) in pool.enumerated() {
                let rel = relevance(c)
                let cToks = tokensByID[c.objectID] ?? []
                var maxSim = 0.0
                for p in picked {
                    let sim = jaccard(cToks, tokensByID[p.objectID] ?? [])
                    if sim > maxSim { maxSim = sim }
                }
                let score = lambda * rel - (1 - lambda) * maxSim
                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }
            picked.append(pool.remove(at: bestIdx))
        }
        return picked
    }

    /// Choose the per-answer global cap by intent kind + question shape.
    private static func intentCitationCap(_ intent: UserIntent) -> Int {
        if isAggregationShape(intent) {
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
    /// Answerability gate (inspired by chatmind-pipeline's ANSWERABILITY_MIN_SCORE).
    /// When the BEST retrieval score across all chunks is below this floor,
    /// the verifier refuses before running the LLM reranker — saves wasted
    /// latency AND prevents weak evidence from producing a confidently-
    /// worded answer the user shouldn't trust.
    ///
    /// The fixture's typical max score is ~0.86. A real-archive query that
    /// finds nothing relevant typically tops out under 0.20. Default sits
    /// well below the fixture floor so eval behavior is unchanged.
    public let answerabilityMinRetrievalScore: Double
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
    /// G2-1.5 — optional. When present, the verifier reads the session
    /// snapshot at verify() time and hands it to the reranker so the
    /// model can resolve pronouns / topic returns against recent turns.
    /// Nil → reranker prompt falls back to the G2-1 question-only form.
    private let sessionProfile: SessionProfile?

    public init(
        minimumConfidence: Confidence = Confidence(0.2),
        minimumCitations: Int = 1,
        engine: any ConfidenceEngine = DefaultConfidenceEngine(),
        ingestCoverageProvider: (@Sendable () async -> Double)? = nil,
        entityQualityGate: EntityQualityGate? = nil,
        reranker: Reranker? = nil,
        sessionProfile: SessionProfile? = nil,
        answerabilityMinRetrievalScore: Double = 0.20
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumCitations = minimumCitations
        self.engine = engine
        self.ingestCoverageProvider = ingestCoverageProvider
        self.entityQualityGate = entityQualityGate
        self.reranker = reranker
        self.sessionProfile = sessionProfile
        self.answerabilityMinRetrievalScore = answerabilityMinRetrievalScore
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
        // Answerability gate (chatmind-inspired). When retrieval clearly
        // didn't find anything similar to the question, refuse early
        // BEFORE running the LLM reranker. This both saves an Ollama
        // round-trip on hopeless queries AND prevents the model from
        // ranking noise into a confident-sounding answer.
        let maxRetrievalScore: Double = scoreByObject.values.max() ?? 0
        if maxRetrievalScore < answerabilityMinRetrievalScore {
            let intentKindRaw = intent.kind.rawValue
            return VerifiedAnswer(
                body: "Kalsmritikosh can't ground an answer to that yet.",
                answerText: nil,
                intentKind: intentKindRaw,
                citations: [],
                confidence: report.combined,
                contradictions: report.contradictions,
                refused: true,
                refusalReason: "Retrieval scores too low (max=\(String(format: "%.3f", maxRetrievalScore)) < \(String(format: "%.2f", answerabilityMinRetrievalScore))) — no confident match in archive.",
                report: report
            )
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
        // Runtime A/B/C toggle (KALSMRITIKOSH_RERANKER):
        //   off    → skip reranker entirely (sort by scoreByObject only)
        //   embed  → Apple NLEmbedding bi-encoder (deterministic, sandbox-safe)
        //   <else> → default Ollama prompted scoring (current path)
        // The Ollama path is non-deterministic and not App-Store-shippable;
        // `embed` and `off` are the diagnostic baselines while UPDATE_17B's
        // Core ML cross-encoder is being built.
        // Mode source priority (highest to lowest):
        //   1. KALSMRITIKOSH_RERANKER process env (Xcode scheme arg)
        //   2. UserDefaults key "KALSMRITIKOSH_RERANKER"
        //   3. Default: "ladder" (post-Fast-Eval-#3 decision).
        //
        // FAST-EVAL-FIX (run #3): the Ollama prompted-scoring path
        // produced ±33% multihop recall swings across identical runs
        // (UPDATE_18 §1 documented this; Fast Eval #2 → #3 confirmed
        // it on M1: 1.00 → 0.67 with no code change). The Core ML
        // cross-encoder cascade ("ladder") is deterministic; ship it
        // as the new default. Explicit env / defaults can still flip
        // back to off / embed / ollama for diagnostic runs.
        let envMode = ProcessInfo.processInfo
            .environment["KALSMRITIKOSH_RERANKER"]?
            .lowercased()
        let defaultsMode = UserDefaults.standard
            .string(forKey: "KALSMRITIKOSH_RERANKER")?
            .lowercased()
        let rerankerMode = envMode ?? defaultsMode ?? "ladder"
        let rerankerDisabled = (rerankerMode == "off")
        let useEmbeddingReranker = (rerankerMode == "embed")
        let useLadder = (rerankerMode == "ladder")
        // G2-1.5 — bypass the reranker for aggregation-shape questions
        // ("list all", "how many", "across the…"). The reranker scores
        // relevance and would drop the long tail of legitimate evidence
        // that aggregation answers need for coverage. Leaving
        // rerankByObject empty makes the survivor sort fall back to
        // `scoreByObject`, which is what aggregation wants.
        let bypassRerank = Self.isAggregationShape(intent) || rerankerDisabled
        if !citations.isEmpty, !bypassRerank {
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
            let scores: [Double]
            if useLadder {
                // G2-RERANK-LADDER — composable cascade. Cheap tiers
                // run first; the Core ML cross-encoder tier (Tier 3,
                // costClass 50) returns nil when the .mlpackage isn't
                // bundled yet, so the cascade gracefully falls back to
                // the heuristic tier alone. When BGEReranker.mlpackage
                // lands in Resources/ (UPDATE_17B), Tier 3 activates
                // automatically — no code change here.
                let ladder = RerankerLadder(tiers: [
                    HeuristicKeywordTier(),
                    CoreMLCrossEncoderTier()
                ])
                scores = await ladder.score(
                    question: intent.rawQuestion,
                    candidates: snippets
                )
            } else if useEmbeddingReranker {
                // Apple-native bi-encoder. Deterministic. No external
                // dep, no Ollama, no LLM noise. Lower ceiling than a
                // cross-encoder but a strict improvement over the
                // current Ollama prompted-scoring path for evals.
                let embedRanker = EmbeddingReranker()
                scores = await embedRanker.score(
                    question: intent.rawQuestion,
                    candidates: snippets
                )
            } else if let reranker {
                // Default: Ollama LLM prompted scoring with intent context.
                let snapshot = await sessionProfile?.snapshot()
                let recentTurns: [String] = snapshot
                    .map { $0.recentTurns.reversed().map(\.rawQuestion) }
                    ?? []
                let mentioned: [String] = snapshot?.mentionedEntities ?? []
                let context = Reranker.Context(
                    intentKind: intent.kind.rawValue,
                    questionShape: Reranker.questionShape(intent.rawQuestion),
                    keyEntities: intent.entityHints,
                    recentTurns: recentTurns,
                    mentionedEntities: mentioned
                )
                scores = await reranker.score(
                    question: intent.rawQuestion,
                    context: context,
                    candidates: snippets
                )
            } else {
                // No reranker available; leave rerankByObject empty
                // so the sort falls back to scoreByObject.
                scores = []
            }
            for (i, citation) in citations.enumerated() where i < scores.count {
                rerankByObject[citation.objectID] = scores[i]
            }
        }

        // UPDATE_14 + G2-MMR — apply the intent-aware global cap on
        // distinct documents. The pre-MMR rule was a pure lexicographic
        // sort on (rerankScore desc, scoreByObject desc). MMR adds a
        // diversity term so aggregation/multihop answers stop piling
        // up many duplicates of the same email thread — the
        // pile-up pattern noted in UPDATE_18 §2 (Revision D).
        //
        // FAST-EVAL-FIX (run #3): factualLookup questions stuck at
        // precision 0.33 for 3 runs because L1 was citing 3 documents
        // when only 1 was expected. When the top retrieval hit is
        // BOTH confident (>=0.85 score) AND clearly ahead of the runner-up
        // (margin >=0.04), the answer almost certainly comes from that
        // single chunk. Tighten the cap to 1 in that case. The same
        // rule benefits semanticSearch and unknown-kind questions.
        let lookupKinds: Set<UserIntent.Kind> = [.factualLookup, .semanticSearch, .unknown]
        var globalCap = Self.intentCitationCap(intent)
        if lookupKinds.contains(intent.kind), !Self.isAggregationShape(intent) {
            let sortedScores = scoreByObject.values.sorted(by: >)
            if let top = sortedScores.first, top >= 0.85,
               (sortedScores.dropFirst().first ?? 0) <= top - 0.04 {
                globalCap = 1
            }
        }
        if citations.count > globalCap {
            citations = Self.applyMMR(
                citations: citations,
                rerankByObject: rerankByObject,
                scoreByObject: scoreByObject,
                lambda: Self.mmrLambda,
                limit: globalCap
            )
        }

        let intentKindRaw = intent.kind.rawValue

        guard !claims.isEmpty,
              report.combined >= minimumConfidence,
              citations.count >= minimumCitations
        else {
            return VerifiedAnswer(
                body: "Kalsmritikosh can't ground an answer to that yet.",
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
            report: report,
            walkSteps: retrieval.walkSteps
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
            // G2-RENDER-FIX (Fast Eval #2 follow-up) — rank doc-claims
            // by the maximum retrieval score across the KOs they cite,
            // not by expert-iteration order. With synthetic-questions
            // + QA-pairs + Tier 3 in the cascade, many experts now
            // produce many doc-grounded claims; the original `.prefix(5)`
            // truncation was dropping the claim that cited the #1-ranked
            // chunk (e.g. contract.md on T3 question 3) in favour of
            // whichever expert finished first. Surfacing the
            // best-evidenced claims first keeps the rendered answer
            // text aligned with the citation list.
            var scoreByObject: [KnowledgeObject.ID: Double] = [:]
            for rc in retrieval.chunks {
                let id = rc.chunk.objectID
                if let prior = scoreByObject[id], prior >= rc.score { continue }
                scoreByObject[id] = rc.score
            }
            let rankedDocClaims = docClaims.sorted { a, b in
                let aScore = a.supportingObjectIDs
                    .compactMap { scoreByObject[$0] }.max() ?? 0
                let bScore = b.supportingObjectIDs
                    .compactMap { scoreByObject[$0] }.max() ?? 0
                return aScore > bScore
            }
            answerText = rankedDocClaims
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
        // RET-006 — honest sufficiency disclosure: if the question asked for specific
        // fields the retrieved evidence does not contain, say so neutrally rather than
        // leaving a vague gap. Absence is disclosed, never presented as proof.
        let plan = QueryPlanCompiler().compile(intent: intent, category: .fact, queryClass: .ordinary)
        let sufficiency = EvidenceSufficiencyAssessor()
            .assess(plan: plan, evidenceTexts: retrieval.chunks.map(\.chunk.text))
        let disclosure = sufficiency.disclosure()
        if !disclosure.isEmpty {
            footerParts.append(disclosure)
        }
        // CLM-002 — flag any causal over-claim: if the answer asserts a cause but the
        // evidence shows only sequence, say so (adjacency is not causation).
        let causalCaution = CausalLanguageGuard()
            .assess(claims: [answerText], evidenceTexts: retrieval.chunks.map(\.chunk.text))
        if !causalCaution.isEmpty {
            footerParts.append(causalCaution)
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
