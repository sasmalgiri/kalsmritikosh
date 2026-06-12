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

    public init(
        minimumConfidence: Confidence = Confidence(0.2),
        minimumCitations: Int = 1,
        engine: any ConfidenceEngine = DefaultConfidenceEngine(),
        ingestCoverageProvider: (@Sendable () async -> Double)? = nil,
        entityQualityGate: EntityQualityGate? = nil
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumCitations = minimumCitations
        self.engine = engine
        self.ingestCoverageProvider = ingestCoverageProvider
        self.entityQualityGate = entityQualityGate
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
        _ = retrieval  // available for richer rendering below
        let citations = claims.flatMap { claim -> [VerifiedAnswer.Citation] in
            claim.supportingObjectIDs.map { objectID in
                VerifiedAnswer.Citation(
                    objectID: objectID,
                    eventID: claim.supportingEventIDs.first,
                    snippet: String(claim.statement.prefix(180))
                )
            }
        }

        guard !claims.isEmpty,
              report.combined >= minimumConfidence,
              citations.count >= minimumCitations
        else {
            return VerifiedAnswer(
                body: "Atlas can't ground an answer to that yet.",
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

        let body = renderAnswer(intent: intent, findings: findings, retrieval: retrieval, report: report)
        return VerifiedAnswer(
            body: body,
            citations: citations,
            confidence: report.combined,
            contradictions: report.contradictions,
            refused: false,
            refusalReason: nil,
            report: report
        )
    }

    private func renderAnswer(
        intent: UserIntent,
        findings: [ExpertFindings],
        retrieval: RetrievalResult,
        report: ConfidenceReport
    ) -> String {
        var sections: [String] = []

        // Lead with the subject + named entities from intent + retrieval
        // so the body surfaces who/what the answer is about even when
        // individual claim strings only contain event titles.
        let subjectLine = subjectHeading(intent: intent, retrieval: retrieval)
        if !subjectLine.isEmpty {
            sections.append(subjectLine)
        }

        for finding in findings where !finding.claims.isEmpty {
            let body = finding.claims.map { "\u{2022} \($0.statement)" }.joined(separator: "\n")
            let label = finding.expertID.replacingOccurrences(of: "expert.", with: "").capitalized
            sections.append("\(label) findings:\n\(body)")
        }
        if sections.isEmpty {
            return "No expert produced findings for that question."
        }
        let agreementNote = report.agreementScore > 0.6
            ? ""
            : "\n\nNote: experts disagreed across some of these claims."
        return sections.joined(separator: "\n\n") + agreementNote
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
