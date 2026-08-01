//
//  ZIPContainerInspector.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §15) — enumerates a ZIP's central directory and applies the CHEAP, per-container
//  safety checks (path safety, encryption, unsupported compression, per-member size cap, compression
//  ratio, per-container entry ceiling) WITHOUT extracting or touching the database. Extraction of the
//  surviving candidates + the root-wide depth/cycle/budget decisions are driven by the coordinator,
//  which streams each candidate only after reserving the shared root budget. Every regular member
//  becomes exactly one disposition — none silently disappears.
//

import Foundation

/// A per-member inspection result. `disposition == .admitted` here means "passed the cheap checks —
/// a candidate the coordinator may stream-extract"; the coordinator finalizes it to admitted (after
/// intake) or blockedRootBudget / blockedCycle / blockedDepth / failedExtraction.
public nonisolated struct ContainerMemberInspection: Sendable {
    public let ordinal: Int
    public let memberPath: String
    public let normalizedMemberPath: String
    public let entryKind: ContainerEntryKind
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let detectedType: SourceType?
    public let disposition: ContainerMemberDisposition
    public let detail: String?
    /// Present only for candidates (disposition == .admitted) so the coordinator can stream-extract.
    public let entry: ZIPEntry?
}

/// The enumeration of one container: its members' cheap classifications + the reader for streaming.
public nonisolated struct ZIPContainerEnumeration: Sendable {
    public let containerType: SourceType
    public let members: [ContainerMemberInspection]
    public let unreadable: Bool
    public let reader: ZIPReader?
}

public enum ZIPContainerInspector {

    public nonisolated static let inspectorID = "zip.container.inspector"
    public nonisolated static let inspectorVersion = "1"

    /// Enumerate + cheaply classify. Never throws — an unreadable ZIP yields `unreadable == true` and
    /// no members (the coordinator records a failed/blocked manifest, keeping custody).
    public nonisolated static func inspect(url: URL, containerType: SourceType,
                                           policy: ContainerSafetyPolicy) -> ZIPContainerEnumeration {
        guard let reader = try? ZIPReader(url: url), let entries = try? reader.entries() else {
            return ZIPContainerEnumeration(containerType: containerType, members: [], unreadable: true, reader: nil)
        }
        var members: [ContainerMemberInspection] = []
        for (i, entry) in entries.enumerated() {
            members.append(classify(entry: entry, ordinal: i, overLimit: i >= policy.maxEntriesPerContainer, policy: policy))
        }
        return ZIPContainerEnumeration(containerType: containerType, members: members, unreadable: false, reader: reader)
    }

    private nonisolated static func classify(entry: ZIPEntry, ordinal: Int, overLimit: Bool,
                                             policy: ContainerSafetyPolicy) -> ContainerMemberInspection {
        let compressed = Int64(max(0, entry.compressedSize))
        let uncompressed = Int64(max(0, entry.uncompressedSize))
        func make(_ kind: ContainerEntryKind, _ normalized: String, _ disp: ContainerMemberDisposition,
                  detail: String? = nil, candidate: Bool = false) -> ContainerMemberInspection {
            ContainerMemberInspection(
                ordinal: ordinal, memberPath: entry.name, normalizedMemberPath: normalized, entryKind: kind,
                compressedSize: compressed, uncompressedSize: uncompressed,
                detectedType: kind == .file ? SourceType.detect(from: URL(fileURLWithPath: normalized)) : nil,
                disposition: disp, detail: detail, entry: candidate ? entry : nil)
        }

        switch ZIPContainerExtractor.classifyPath(entry.name) {
        case .directory:
            return make(.directory, entry.name, .directory)
        case .unsafe(let reason):
            return make(.file, entry.name, .blockedUnsafePath, detail: reason)
        case .file(let normalized):
            // The per-container entry ceiling drops members beyond the limit — visibly, never silently.
            if overLimit { return make(.file, normalized, .blockedEntryLimit, detail: "beyond per-container entry limit") }
            if entry.isEncrypted { return make(.file, normalized, .encrypted, detail: "encrypted member") }
            if entry.compressionMethod != 0 && entry.compressionMethod != 8 {
                return make(.file, normalized, .unsupported, detail: "unsupported compression method \(entry.compressionMethod)")
            }
            if uncompressed > policy.maxSingleMemberBytes {
                return make(.file, normalized, .blockedSizeLimit, detail: "declared size exceeds per-member cap")
            }
            if compressed > 0 && uncompressed / compressed > Int64(policy.maxCompressionRatio) {
                return make(.file, normalized, .blockedCompressionRatio, detail: "compression ratio exceeds cap")
            }
            return make(.file, normalized, .admitted, candidate: true)
        }
    }
}
