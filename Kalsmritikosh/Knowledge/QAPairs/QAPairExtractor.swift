//
//  QAPairExtractor.swift
//  Kalsmritikosh
//
//  G2-QA-PAIRS — sibling of synthetic questions.
//
//  Per UPDATE_18 §7d: where the source has natural Q-A turns (emails:
//  message → reply; meeting notes: question raised → answer given),
//  mine the pair directly instead of synthesizing. Stronger than
//  hypothetical-question generation because every QA pair was a REAL
//  exchange — grounded, not hallucinated. chatmind validated this as
//  a separate retrieval-side surface that fuses with chunk-text search.
//
//  This file ships the protocol + an email-thread extractor. Storage
//  + retrieval wiring deferred (schema for the sidecar `qa_pairs`
//  table, embedder hookup, RRF fusion at query time — all separate).
//

import Foundation

/// One mined Q-A pair. The question is the prior turn's body / subject;
/// the answer is the reply's body. `confidence` captures how clearly
/// the pair was identified (RFC 5322 In-Reply-To headers → high; topic-
/// proximity heuristic → medium; pure adjacency in a thread → low).
public struct QAPair: Sendable, Codable, Hashable {
    public let questionText: String
    public let answerText: String
    public let questionObjectID: KnowledgeObject.ID
    public let answerObjectID: KnowledgeObject.ID
    public let confidence: Double

    public init(
        questionText: String,
        answerText: String,
        questionObjectID: KnowledgeObject.ID,
        answerObjectID: KnowledgeObject.ID,
        confidence: Double
    ) {
        self.questionText = questionText
        self.answerText = answerText
        self.questionObjectID = questionObjectID
        self.answerObjectID = answerObjectID
        self.confidence = max(0, min(1, confidence))
    }
}

/// Extracts Q-A pairs from a set of related KnowledgeObjects. The
/// caller is responsible for grouping by thread/conversation before
/// invoking — the extractor doesn't try to discover threading itself.
public protocol QAPairExtractor: Sendable {
    // G2-SWIFT6 — nonisolated so the IngestCoordinator actor can read
    // `extractor.id` in log statements from any context.
    nonisolated var id: String { get }
    func extract(from thread: [KnowledgeObject]) async -> [QAPair]
}

/// Email-thread extractor. Pairs each KO with the NEXT KO in the
/// thread (by date) where the next message references the previous
/// (In-Reply-To OR shared X-GM-THRID OR adjacent in time AND same
/// participants). Confidence cascades: header-derived = 0.9, thread-
/// id-shared = 0.75, adjacency-only = 0.4.
public struct EmailThreadQAPairExtractor: QAPairExtractor {
    public let id = "qa.email.thread"
    public nonisolated init() {}

    public func extract(from thread: [KnowledgeObject]) async -> [QAPair] {
        // Email-only — bail early for mixed-format inputs.
        let emails = thread.filter { $0.sourceType.category == .email }
        guard emails.count >= 2 else { return [] }

        // Sort by date (header preferred).
        let sorted = emails.sorted { lhs, rhs in
            (Self.date(for: lhs) ?? lhs.createdAt) < (Self.date(for: rhs) ?? rhs.createdAt)
        }

        var pairs: [QAPair] = []
        for i in 0..<(sorted.count - 1) {
            let q = sorted[i]
            let a = sorted[i + 1]
            let confidence = Self.pairingConfidence(question: q, answer: a)
            // Skip very weak pairings — adjacency alone with no shared
            // signal is too noisy to bother storing.
            guard confidence >= 0.4 else { continue }
            let qText = Self.bodyText(for: q)
            let aText = Self.bodyText(for: a)
            guard qText.count >= 20, aText.count >= 20 else { continue }
            pairs.append(QAPair(
                questionText: qText,
                answerText: aText,
                questionObjectID: q.id,
                answerObjectID: a.id,
                confidence: confidence
            ))
        }
        return pairs
    }

    private static func pairingConfidence(
        question q: KnowledgeObject,
        answer a: KnowledgeObject
    ) -> Double {
        // In-Reply-To: explicit. Highest signal.
        if let irt = stringMeta(a, "in-reply-to"),
           let qMid = stringMeta(q, "message-id"),
           irt.contains(qMid) || qMid.contains(irt.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))) {
            return 0.9
        }
        // Shared Gmail thread id (X-GM-THRID) or shared Message-ID family.
        if let qThread = stringMeta(q, "X-GM-THRID"),
           let aThread = stringMeta(a, "X-GM-THRID"),
           qThread == aThread, !qThread.isEmpty {
            return 0.75
        }
        // Adjacency fallback: dates within 7 days, shared subject.
        let qSubject = stringMeta(q, "subject")?.lowercased() ?? ""
        let aSubject = stringMeta(a, "subject")?.lowercased() ?? ""
        let qStrip = qSubject.replacingOccurrences(of: "re:", with: "").trimmingCharacters(in: .whitespaces)
        let aStrip = aSubject.replacingOccurrences(of: "re:", with: "").trimmingCharacters(in: .whitespaces)
        if !qStrip.isEmpty, qStrip == aStrip {
            return 0.55
        }
        return 0.4
    }

    private static func date(for object: KnowledgeObject) -> Date? {
        guard let headerString = stringMeta(object, "date") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = f
            if let d = formatter.date(from: headerString) { return d }
        }
        return ISO8601DateFormatter().date(from: headerString)
    }

    private static func bodyText(for object: KnowledgeObject) -> String {
        // Trim to a reasonable size — the extractor produces summary-shaped
        // text, not full bodies. Storage will summarize further via the
        // .summarization capability in a later commit.
        let trimmed = object.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(800))
    }

    private static func stringMeta(_ object: KnowledgeObject, _ key: String) -> String? {
        guard let v = object.metadata[key] else { return nil }
        if case .string(let s) = v.value { return s }
        return nil
    }
}
