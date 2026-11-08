//
//  CaseCoverageReadout.swift
//  Kalsmritikosh
//
//  Package B (plan P0-A, display only, 2026-11-06) — what the person is shown about a case's reading
//  coverage: which of its documents were read, partly read or not read, each unread one with its reason
//  (password-protected, unsupported type, too large, text recognition failed …). It is a pure projection
//  of the existing CaseCoverageManifest (USF-M2) and the ledger's knowledge objects — no new extraction,
//  no writes, no overall percentage. Shown on the case overview, on the case-read permission sheet and in
//  the case file report and its export notice.
//

import Foundation

public nonisolated struct CaseCoverageReadout: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable { case read, partlyRead, notRead }

    public struct Entry: Sendable, Equatable, Hashable {
        public let name: String
        public let status: Status
        /// Why it was partly or not read (nil for a read document).
        public let reason: String?
        public init(name: String, status: Status, reason: String?) { self.name = name; self.status = status; self.reason = reason }
    }

    public let read: Int
    /// Partly and not read documents, each with its reason (sorted: not read first, then by name).
    public let entries: [Entry]
    /// Coverage facts that are not one document ("an archive not yet inspected").
    public let notes: [String]

    /// Smart-map IN-12 — the case's intake inventory this coverage rests on (what was taken in, decided, could not be taken
    /// in, and the batch receipts its documents trace to). Nil where it was not loaded (e.g. the search receipt).
    public var intake: CaseIntakeReconciliation? = nil

    public init(read: Int, entries: [Entry], notes: [String]) { self.read = read; self.entries = entries; self.notes = notes }

    public var partlyRead: [Entry] { entries.filter { $0.status == .partlyRead } }
    public var notRead: [Entry] { entries.filter { $0.status == .notRead } }
    public var total: Int { read + entries.count }
    /// Nothing partly or not read and nothing to note.
    public var isComplete: Bool { entries.isEmpty && notes.isEmpty }

    /// "Read: 6 · Partly read: 1 · Not read: 2 (1 password-protected, 1 unsupported file type)".
    public var summaryLine: String {
        var s = "Read: \(read) · Partly read: \(partlyRead.count) · Not read: \(notRead.count)"
        let reasons = Dictionary(grouping: notRead.compactMap(\.reason), by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        if !reasons.isEmpty { s += " (" + reasons.map { "\($0.1) \($0.0)" }.joined(separator: ", ") + ")" }
        return s
    }

    /// One line per partly or not read document: "statement.pdf — not read: password-protected".
    public var entryLines: [String] {
        entries.map { "\($0.name) — \($0.status == .notRead ? "not read" : "partly read")" + ($0.reason.map { ": \($0)" } ?? "") }
    }

    /// The report section (Markdown), stated within its limits.
    public var reportSection: String {
        var o = "\n## What the app could read\n"
        o += "_From the case's documents as ingested on this Mac. A document not read here was not searched, quoted or sent to an AI; nothing in this report rests on it._\n"
        o += "- \(summaryLine)\n"
        for line in entryLines { o += "- \(line)\n" }
        for n in notes { o += "- \(n)\n" }
        for line in intake?.lines ?? [] { o += "- \(line)\n" }
        return o
    }

    // MARK: - From the manifest

    /// The readout for the case's documents: `manifest` is the case workspace's coverage snapshot,
    /// `scope` the case's authorised source versions (nil: every source of the workspace), `labels` a
    /// file name per source version, `hasLedgerText` the versions that produced a knowledge object (read
    /// on this Mac) — used where the readiness record does not say (a source ingested before it existed).
    /// Every version in `scope` is counted once, also one the manifest does not list (`total` is the
    /// number of documents in the case plus the archive members that were not taken out).
    /// `logicalSources` (version → logical source) keeps an older version of a listed document from being
    /// counted as another document.
    public static func make(manifest: CaseCoverageManifest, scope: Set<UUID>?, labels: [UUID: String],
                            hasLedgerText: Set<UUID>, logicalSources: [UUID: UUID] = [:]) -> CaseCoverageReadout {
        let items = manifest.canonicalSources.filter { scope?.contains($0.sourceVersionID) ?? true }
        var read = 0
        var entries: [Entry] = []
        for item in items {
            let name = labels[item.sourceVersionID] ?? "Source \(item.sourceVersionID.uuidString.prefix(8))"
            switch classify(item, hasLedgerText: hasLedgerText.contains(item.sourceVersionID)) {
            case (.read, _): read += 1
            case (let status, let reason): entries.append(Entry(name: name, status: status, reason: reason))
            }
        }
        // LS14 — a document in the case that the coverage record does not list is still counted: read when
        // the ledger holds its text, otherwise not read, saying there is no reading record for it.
        if let scope {
            let listed = Set(items.map(\.sourceVersionID))
            var counted = Set(items.map(\.logicalSourceID))
            for v in scope.subtracting(listed).sorted(by: { $0.uuidString < $1.uuidString }) {
                // Another version of a document already counted is not another document.
                if let logical = logicalSources[v] { guard counted.insert(logical).inserted else { continue } }
                if hasLedgerText.contains(v) { read += 1; continue }
                let name = labels[v] ?? "Source \(v.uuidString.prefix(8))"
                entries.append(Entry(name: name, status: .notRead, reason: noReadingRecord))
            }
        }
        let parents = Set(items.map(\.sourceVersionID))
        for m in manifest.unadmittedContainerMembers where scope == nil || parents.contains(m.parentSourceVersionID) {
            let container = labels[m.parentSourceVersionID].map { " (in \($0))" } ?? ""
            entries.append(Entry(name: (m.memberPath as NSString).lastPathComponent + container, status: .notRead,
                                 reason: reason(for: m.disposition)))
        }
        let notes = manifest.limitations.filter { $0.hasPrefix("Container ") }.map { line -> String in
            // "Container 1a2b3c4d has not been inspected (…)" → the file's name where known.
            for item in items where line.contains(item.sourceVersionID.uuidString.prefix(8)) {
                if let n = labels[item.sourceVersionID] { return "The archive \(n) has not been opened yet, so what it holds is not counted." }
            }
            return "An archive in this case has not been opened yet, so what it holds is not counted."
        }
        entries.sort { ($0.status == .notRead ? 0 : 1, $0.name) < ($1.status == .notRead ? 0 : 1, $1.name) }
        return CaseCoverageReadout(read: read, entries: entries, notes: notes)
    }

    /// The reason given for a case document the coverage record does not list (LS14).
    static let noReadingRecord = "no reading record"

    static func classify(_ item: CaseCoverageItem, hasLedgerText: Bool) -> (Status, String?) {
        switch item.completionState {
        case .evidenceReady:
            return (.read, nil)
        case .searchablePartial:
            return (.partlyRead, partialReason(item))
        case .preservedOnly:
            // No readiness record (older ingestion) but the ledger holds its text: it was read.
            return hasLedgerText ? (.read, nil) : (.notRead, "kept, but no text could be read from it")
        case .deferred:   return (.notRead, "waiting to be read")
        case .encrypted:  return (.notRead, "password-protected")
        case .corrupt:    return (.notRead, "the file is damaged")
        case .unsupported: return (.notRead, "unsupported file type")
        case .failed:     return (.notRead, failedReason(item))
        }
    }

    private static func partialReason(_ item: CaseCoverageItem) -> String {
        let text = (item.limitations + item.blockers).joined(separator: " ")
        if text.contains("ocr") { return "some pages could not be read (text recognition failed)" }
        if text.contains("transcription") { return "part of the recording was not transcribed" }
        if text.contains("resourceLimit") { return "too large to read in full" }
        if text.contains("textExtraction") { return "part of the text could not be extracted" }
        return "only part of it could be read"
    }

    private static func failedReason(_ item: CaseCoverageItem) -> String {
        let text = (item.limitations + item.blockers).joined(separator: " ")
        if text.contains("ocr") { return "text recognition (OCR) failed" }
        if text.contains("transcription") { return "the recording could not be transcribed" }
        if text.contains("encrypted") { return "password-protected" }
        if text.contains("resourceLimit") { return "too large" }
        return "reading failed"
    }

    static func reason(for d: ContainerMemberDisposition) -> String {
        switch d {
        case .encrypted: return "password-protected"
        case .unsupported: return "unsupported file type"
        case .failedExtraction: return "could not be taken out of the archive"
        case .blockedSizeLimit, .blockedRootBudget, .blockedCompressionRatio: return "too large"
        case .blockedDepth, .blockedEntryLimit: return "beyond the archive limits"
        case .blockedUnsafePath, .blockedCycle: return "skipped for safety"
        case .admitted, .directory: return "not read"
        }
    }
}
