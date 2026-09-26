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

    /// The single-document subject: the title block, else — L3 — the PERSON the
    /// document is about when its head is a name ("RESUME" / "Curriculum Vitae"
    /// followed by "Shirshendu Sasmal."), else the file-name stem. Structural,
    /// not statistical: on the owner's archive every résumé's person was the
    /// first name-shaped block after a generic heading, while "most-mentioned
    /// organisation" returned "API" and "APTECH".
    public static func documentLabel(blocks: [EvidenceBlock], fileURL: URL) -> String {
        if let title = blocks.first(where: { $0.kind == .documentTitle }) {
            let t = title.normalizedText.isEmpty ? title.rawText : title.normalizedText
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isGenericHeading(trimmed) { return String(trimmed.prefix(120)) }
        }
        if let name = headlineName(blocks: blocks) { return name }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    /// Headings that name the KIND of document, not its subject.
    static let genericHeadings: Set<String> = [
        "resume", "résumé", "cv", "curriculum vitae", "curriculam vitae", "curriculam-vitae",
        "curriculum-vitae", "bio-data", "biodata", "bio data", "profile", "personal details",
        "personal information", "personal profile", "professional profile", "objective",
        "career objective", "career summary", "summary", "cover letter", "application",
        // Section headings a document's head may carry before or instead of a name —
        // each is two Title-case words and would otherwise pass as a name.
        "work experience", "professional experience", "employment history", "experience",
        "education", "educational qualifications", "academic qualifications", "qualifications",
        "skills", "technical skills", "key skills", "core competencies", "strengths",
        "achievements", "certifications", "projects", "training", "languages", "hobbies",
        "interests", "declaration", "references", "contact", "contact details", "address",
        "table of contents", "contents", "introduction", "abstract", "annexure", "appendix",
    ]

    static func isGenericHeading(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return genericHeadings.contains(t)
    }

    /// The first name-shaped block among the document's opening blocks: 2–4
    /// words, each capitalised or all-caps, letters (plus . ' -) only, no digits,
    /// ≤ 40 characters, not a label ("Name: …") and not a generic heading.
    static func headlineName(blocks: [EvidenceBlock]) -> String? {
        let head = blocks.sorted { $0.ordinal < $1.ordinal }
            .filter { $0.kind == .paragraph || $0.kind == .documentTitle || $0.kind == .documentHeader
                   || $0.kind == .sectionHeading || $0.kind == .pageHeader }
            .prefix(4)
        for b in head {
            let raw = (b.normalizedText.isEmpty ? b.rawText : b.normalizedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isGenericHeading(raw) { continue }
            if let name = nameShaped(raw) { return name }
        }
        return nil
    }

    static func nameShaped(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: \t"))
        guard text.count <= 40, !text.contains(":"), !text.contains(where: \.isNumber) else { return nil }
        let words = text.split(whereSeparator: { $0 == " " }).map(String.init)
        guard (2...4).contains(words.count) else { return nil }
        for w in words {
            guard let first = w.first, first.isLetter, first.isUppercase else { return nil }
            guard w.allSatisfy({ $0.isLetter || $0 == "." || $0 == "'" || $0 == "-" }) else { return nil }
            if w.count == 1 { return nil }
        }
        return words.joined(separator: " ")
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
