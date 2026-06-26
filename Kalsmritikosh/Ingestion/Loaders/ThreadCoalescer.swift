//
//  ThreadCoalescer.swift
//  Kalsmritikosh
//
//  Group parsed mbox / PST / NSF messages into email threads. Each
//  thread becomes one KnowledgeObject downstream — see EmailLoader's
//  `ingestMBOXAsMessages` for the call site. Per-message offsets are
//  preserved in the structured `messages` array so the Evidence gate
//  can still cite a specific message inside a thread.
//
//  Threading algorithm (RFC 5256-inspired, simplified):
//
//  1. Primary keys: every message's Message-ID, In-Reply-To, and
//     References headers. Two messages are in the same thread if any
//     ID in one's chain appears anywhere in the other's chain.
//  2. Fallback for messages that strip threading headers: normalized
//     Subject ("Re:" / "Fwd:" prefixes removed, whitespace folded)
//     plus a 180-day date proximity window. This catches threads
//     that lost threading metadata via copy-paste forwarding.
//  3. Singletons (messages with no threading partner) stay as their
//     own 1-message "thread" so the per-message path still applies.
//

import Foundation

public nonisolated enum ThreadCoalescer {

    /// One parsed message as it enters the coalescer. EmailLoader
    /// builds these from the byte-scanned mbox; ports for PST/NSF
    /// produce the same shape.
    public struct ParsedMessage: Sendable {
        public let index: Int
        public let headers: [String: String]
        public let body: String
        public let date: Date?

        public init(index: Int, headers: [String: String], body: String, date: Date?) {
            self.index = index
            self.headers = headers
            self.body = body
            self.date = date
        }

        public var messageID: String? { extractID(headers["message-id"]) }
        public var inReplyTo: String? { extractID(headers["in-reply-to"]) }
        public var references: [String] {
            (headers["references"] ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .compactMap { extractID(String($0)) }
        }
        public var normalizedSubject: String {
            Self.normalize(headers["subject"] ?? "")
        }

        /// Strip the angle-brackets and lowercase the body of an
        /// `<id@host>`-style Message-ID. Returns nil for empty or
        /// obviously malformed values so they don't merge unrelated
        /// threads under the same junk key.
        private func extractID(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let stripped = trimmed
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .lowercased()
            // Require at least one '@' so a stray noise word doesn't
            // pretend to be an ID and collapse unrelated threads.
            guard stripped.contains("@") else { return nil }
            return stripped
        }

        nonisolated static func normalize(_ subject: String) -> String {
            var s = subject.lowercased()
            // Drop common reply / forward prefixes — repeat because
            // some threads chain "Re: Re: Fwd: Re: ..." indefinitely.
            for _ in 0..<8 {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("re:") { s = String(trimmed.dropFirst(3)); continue }
                if trimmed.hasPrefix("fwd:") { s = String(trimmed.dropFirst(4)); continue }
                if trimmed.hasPrefix("fw:") { s = String(trimmed.dropFirst(3)); continue }
                if trimmed.hasPrefix("aw:") { s = String(trimmed.dropFirst(3)); continue }
                break
            }
            // Collapse internal whitespace so trailing-space wobble
            // doesn't fragment a thread.
            return s
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// One coalesced thread, ordered by the original parse index so
    /// the caller can preserve a stable byte layout when concatenating.
    public struct Thread: Sendable {
        public let messages: [ParsedMessage]
        public let canonicalSubject: String

        public init(messages: [ParsedMessage], canonicalSubject: String) {
            self.messages = messages
            self.canonicalSubject = canonicalSubject
        }

        public var earliestDate: Date? {
            messages.compactMap(\.date).min()
        }
    }

    /// Run the union-find on the given parsed messages. Returns
    /// threads ordered by earliest message date; within each thread
    /// messages are chronologically sorted (date-stable; falls back
    /// to original `index` when dates are missing or equal).
    public static func coalesce(_ messages: [ParsedMessage]) -> [Thread] {
        guard !messages.isEmpty else { return [] }

        // Union-Find sized to message count.
        var parent = Array(0..<messages.count)
        func find(_ x: Int) -> Int {
            var i = x
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a); let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // First pass: index every Message-ID so we can wire replies.
        var messageIDToIndex: [String: Int] = [:]
        for (i, m) in messages.enumerated() {
            if let mid = m.messageID, messageIDToIndex[mid] == nil {
                messageIDToIndex[mid] = i
            }
        }

        // Second pass: union via In-Reply-To and References. Both
        // edges are bidirectional in thread space.
        for (i, m) in messages.enumerated() {
            let parents = (m.references + [m.inReplyTo].compactMap { $0 })
            for pid in parents {
                if let j = messageIDToIndex[pid] {
                    union(i, j)
                }
            }
        }

        // Third pass: subject-based fallback. STRICT version — the
        // earlier 180-day window over-merged real archives (Sent.mbox
        // of 526 messages collapsed to 2 threads because every "Re:"
        // chain over years got lumped). Tighter rules:
        //
        // - Skip when normalized subject is short (<10 chars after
        //   "Re:"/"Fwd:" stripping) — generic subjects like "thanks"
        //   are not thread signal.
        // - Skip when subject reduces to a single common word
        //   (single-token + ≤5 chars).
        // - Require BOTH dates to be present AND within 14 days for
        //   the merge. Anchor-day jumps (subject reused for a new
        //   topic a year later) should NOT thread.
        // - Cap the size of subject-fallback threads at 30 messages
        //   so a recurring weekly subject doesn't form a 200-message
        //   monster.
        let dayWindow: TimeInterval = 14 * 86_400
        var bySubject: [String: [(Int, Date?)]] = [:]
        for (i, m) in messages.enumerated() {
            let subj = m.normalizedSubject
            guard !subj.isEmpty else { continue }
            // Reject too-short / single-tokenish subjects.
            let tokens = subj.split(separator: " ", omittingEmptySubsequences: true)
            if subj.count < 10 { continue }
            if tokens.count < 2 && subj.count < 12 { continue }
            bySubject[subj, default: []].append((i, m.date))
        }
        for (_, group) in bySubject {
            guard group.count > 1 else { continue }
            let sorted = group.sorted { (lhs, rhs) in
                (lhs.1 ?? .distantPast) < (rhs.1 ?? .distantPast)
            }
            // Sliding window: merge consecutive pairs only when both
            // sides have a date AND the gap fits the window. Stop a
            // chain when a gap is too large or when the resulting
            // component already exceeds the size cap.
            let maxSubjectThreadSize = 30
            for k in 1..<sorted.count {
                let (i, dateI) = sorted[k]
                let (j, dateJ) = sorted[k - 1]
                guard let dI = dateI, let dJ = dateJ,
                      abs(dI.timeIntervalSince(dJ)) <= dayWindow else { continue }
                // Cap on component size — count current root's reach.
                let rootI = find(i)
                let componentSize = (0..<messages.count).filter { find($0) == rootI }.count
                if componentSize >= maxSubjectThreadSize { break }
                union(i, j)
            }
        }

        // Bucket messages by root.
        var buckets: [Int: [Int]] = [:]
        for i in 0..<messages.count {
            buckets[find(i), default: []].append(i)
        }

        // Build threads — sort messages by date (then by index).
        var threads: [Thread] = []
        for (_, indices) in buckets {
            let msgs = indices.map { messages[$0] }.sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (l?, r?) where l != r: return l < r
                default: return lhs.index < rhs.index
                }
            }
            // Canonical subject: the longest normalized subject in
            // the thread (re-prefix-stripping makes shorter forms
            // common; the longest is most likely the original).
            let canonical = msgs.map { $0.headers["subject"] ?? "" }
                .max(by: { $0.count < $1.count }) ?? ""
            threads.append(Thread(messages: msgs, canonicalSubject: canonical))
        }
        return threads.sorted { (lhs, rhs) in
            (lhs.earliestDate ?? .distantPast) < (rhs.earliestDate ?? .distantPast)
        }
    }
}
