//
//  FactSubjectPartitioner.swift
//  Kalsmritikosh
//
//  WHICH SUBJECT a fact is about, decided before extraction — shared by the
//  ingest path and the ledger drain so the two cannot drift.
//
//  A single-document file keeps the historical rule: the title block, else the
//  file-name stem. A MAILBOX is not one document. Deriving its facts once over
//  the whole file filed every fact in 526 messages under the mailbox's file
//  name — on the owner's archive, 252 facts under "Sent", with "status" holding
//  rejected, amendment, filed, draft and granted at once and no way back to the
//  email that said each. So a multi-message file is partitioned by the
//  `messageIndex` its parser stamps on every block, and each message's facts
//  take that message's normalized Subject line. Replies share their thread's
//  subject, so one thread's facts land together; the subject spine later
//  resolves a subject naming a matter ("…Patent Application-202331019665") to
//  that matter.
//
//  Partitioning also keeps the cross-block label pass (C-4) inside one message:
//  a label at the foot of one email can no longer pair with a value at the head
//  of the next.
//

import Foundation

public nonisolated enum FactSubjectPartitioner {

    public struct Partition: Sendable {
        public let subjectLabel: String
        public let blocks: [EvidenceBlock]
    }

    /// The single-document subject: the title block, else the file-name stem.
    public static func documentLabel(blocks: [EvidenceBlock], fileURL: URL) -> String {
        if let title = blocks.first(where: { $0.kind == .documentTitle }) {
            let t = title.normalizedText.isEmpty ? title.rawText : title.normalizedText
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    /// Split blocks into subject partitions. Blocks without a `messageIndex`
    /// stay under `fallbackLabel`; a file with none is one partition, exactly
    /// the historical behaviour.
    public static func partitions(blocks: [EvidenceBlock], fallbackLabel: String) -> [Partition] {
        var byMessage: [Int: [EvidenceBlock]] = [:]
        var unindexed: [EvidenceBlock] = []
        for b in blocks where !isMachineHeader(b) {
            if let idx = messageIndex(of: b) { byMessage[idx, default: []].append(b) }
            else { unindexed.append(b) }
        }
        guard !byMessage.isEmpty else {
            return [Partition(subjectLabel: fallbackLabel, blocks: blocks)]
        }
        var out: [Partition] = []
        if !unindexed.isEmpty { out.append(Partition(subjectLabel: fallbackLabel, blocks: unindexed)) }
        for idx in byMessage.keys.sorted() {
            let msgBlocks = byMessage[idx] ?? []
            let subject = msgBlocks
                .first { $0.kind == .emailHeader && $0.locator.emailHeaderField?.lowercased() == "subject" }
                .flatMap { normalizedSubject($0.rawText) }
            out.append(Partition(subjectLabel: subject ?? fallbackLabel, blocks: msgBlocks))
        }
        return out
    }

    /// Headers a person wrote or reads. The rest (ARC-Seal, Authentication-
    /// Results, Received, X-…) are transport plumbing: read as `Label: value`
    /// they became facts like "Arcseal: i=1; a=rsa-sha256". Their blocks stay
    /// in the evidence store; only fact extraction skips them.
    static let humanHeaders: Set<String> = ["subject", "from", "to", "cc", "bcc", "date", "reply-to", "sender"]

    static func isMachineHeader(_ block: EvidenceBlock) -> Bool {
        guard block.kind == .emailHeader, let field = block.locator.emailHeaderField?.lowercased() else { return false }
        return !humanHeaders.contains(field)
    }

    static func messageIndex(of block: EvidenceBlock) -> Int? {
        switch block.attributes["messageIndex"]?.value {
        case .int(let n)?: return Int(n)
        case .double(let d)?: return Int(d)
        default: return nil
        }
    }

    /// "RE: Fwd: [Our Ref: X] Hearing Notice…" → "[Our Ref: X] Hearing Notice…".
    /// Strips a leading "Subject:" and any run of reply/forward prefixes; nil
    /// when nothing is left.
    static func normalizedSubject(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("subject:") { s = String(s.dropFirst("subject:".count)) }
        let prefix = try? NSRegularExpression(pattern: #"^\s*((re|fw|fwd|aw|sv|tr)\s*(\[\d+\])?\s*[:：]\s*)+"#,
                                              options: [.caseInsensitive])
        if let prefix {
            s = prefix.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : String(s.prefix(120))
    }
}
