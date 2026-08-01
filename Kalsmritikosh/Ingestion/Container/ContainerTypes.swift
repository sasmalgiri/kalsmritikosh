//
//  ContainerTypes.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006) — the closed vocabulary + value models for safe, finite, VISIBLE container
//  handling. A container manifest + its members are a PROCESSING PROJECTION over an exact container
//  SourceVersion: they record what the archive claims to contain and how each member was disposed.
//  They are NOT source/evidence/readiness authorities. A discovered member is not a source; only an
//  ADMITTED member becomes a canonical child SourceVersion. Blocked / encrypted / unsupported / failed
//  members stay visible here rather than silently dropped.
//

import Foundation

/// How completely a container was INSPECTED (describes the inspection operation, not readiness).
public nonisolated enum ContainerManifestStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case complete      // every regular member enumerated + dispositioned
    case partial       // some members enumerated, others blocked by policy / budget
    case blocked       // the container itself could not be safely opened (e.g. encrypted root)
    case unsupported   // recognized container type with no decoder yet (RAR/7z)
    case failed        // inspection attempt failed
}

/// A container member's kind. Directories are recorded but never counted as sources.
public nonisolated enum ContainerEntryKind: String, Sendable, Codable, CaseIterable, Hashable {
    case file
    case directory
}

/// The disposition of one container member. Closed set (mirrors the v87 CHECK). Only `admitted`
/// produces a canonical child SourceVersion; everything else remains visible without a child.
public nonisolated enum ContainerMemberDisposition: String, Sendable, Codable, CaseIterable, Hashable {
    case admitted
    case directory
    case blockedUnsafePath
    case blockedDepth
    case blockedEntryLimit
    case blockedSizeLimit
    case blockedCompressionRatio
    case blockedRootBudget
    case blockedCycle
    case encrypted
    case unsupported
    case failedExtraction

    /// Whether this disposition admits a canonical child SourceVersion.
    public var isAdmitted: Bool { self == .admitted }
    /// Whether this disposition counts toward the manifest's `blocked_members` tally.
    public var isBlocked: Bool {
        switch self {
        case .blockedUnsafePath, .blockedDepth, .blockedEntryLimit, .blockedSizeLimit,
             .blockedCompressionRatio, .blockedRootBudget, .blockedCycle, .encrypted:
            return true
        default:
            return false
        }
    }
}

/// One recovered member disposition. `childSourceVersionID`/`contentHash` are non-nil ONLY when
/// `disposition == .admitted` (a non-admitted member never fabricates a SourceVersion).
public nonisolated struct ContainerMember: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let parentSourceVersionID: UUID
    public let ordinal: Int
    public let memberPath: String
    public let normalizedMemberPath: String
    public let entryKind: ContainerEntryKind
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let detectedType: SourceType?
    public let disposition: ContainerMemberDisposition
    public let childSourceVersionID: UUID?
    public let contentHash: String?
    public let detail: String?

    public nonisolated init(id: UUID = UUID(), parentSourceVersionID: UUID, ordinal: Int,
                            memberPath: String, normalizedMemberPath: String, entryKind: ContainerEntryKind,
                            compressedSize: Int64, uncompressedSize: Int64, detectedType: SourceType?,
                            disposition: ContainerMemberDisposition, childSourceVersionID: UUID? = nil,
                            contentHash: String? = nil, detail: String? = nil) {
        self.id = id
        self.parentSourceVersionID = parentSourceVersionID
        self.ordinal = ordinal
        self.memberPath = memberPath
        self.normalizedMemberPath = normalizedMemberPath
        self.entryKind = entryKind
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.detectedType = detectedType
        self.disposition = disposition
        self.childSourceVersionID = childSourceVersionID
        self.contentHash = contentHash
        self.detail = detail
    }
}

/// One current inspection manifest for an exact container SourceVersion. The disposition counts are
/// DERIVED from the members and validated (admitted+blocked+unsupported+failed <= regular files).
public nonisolated struct ContainerManifest: Sendable, Hashable {
    public let sourceVersionID: UUID
    public let revision: Int
    public let containerType: SourceType
    public let inspectorID: String
    public let inspectorVersion: String
    public let policyVersion: String
    public let status: ContainerManifestStatus
    public let totalEntries: Int
    public let regularFileEntries: Int
    public let admittedMembers: Int
    public let blockedMembers: Int
    public let unsupportedMembers: Int
    public let failedMembers: Int
    public let declaredUncompressedBytes: Int64

    public nonisolated init(sourceVersionID: UUID, revision: Int, containerType: SourceType,
                            inspectorID: String, inspectorVersion: String, policyVersion: String,
                            status: ContainerManifestStatus, totalEntries: Int, regularFileEntries: Int,
                            admittedMembers: Int, blockedMembers: Int, unsupportedMembers: Int,
                            failedMembers: Int, declaredUncompressedBytes: Int64) {
        self.sourceVersionID = sourceVersionID
        self.revision = revision
        self.containerType = containerType
        self.inspectorID = inspectorID
        self.inspectorVersion = inspectorVersion
        self.policyVersion = policyVersion
        self.status = status
        self.totalEntries = totalEntries
        self.regularFileEntries = regularFileEntries
        self.admittedMembers = admittedMembers
        self.blockedMembers = blockedMembers
        self.unsupportedMembers = unsupportedMembers
        self.failedMembers = failedMembers
        self.declaredUncompressedBytes = declaredUncompressedBytes
    }
}

/// The full result of inspecting one container: the manifest + its ordered members. Persisted
/// atomically by ContainerInspectionRepository (the sole v87 writer).
public nonisolated struct ContainerInspectionResult: Sendable, Hashable {
    public let manifest: ContainerManifest
    public let members: [ContainerMember]

    public nonisolated init(manifest: ContainerManifest, members: [ContainerMember]) {
        self.manifest = manifest
        self.members = members
    }

    /// Recompute the manifest disposition tallies from the member list so a caller can build a
    /// COUNT-CONSISTENT manifest without hand-maintaining the numbers.
    public nonisolated static func tally(members: [ContainerMember])
    -> (total: Int, regular: Int, admitted: Int, blocked: Int, unsupported: Int, failed: Int, declaredBytes: Int64) {
        var regular = 0, admitted = 0, blocked = 0, unsupported = 0, failed = 0
        var declared: Int64 = 0
        for m in members {
            if m.entryKind == .file { regular += 1; declared += max(0, m.uncompressedSize) }
            switch m.disposition {
            case .admitted: admitted += 1
            case .unsupported: unsupported += 1
            case .failedExtraction: failed += 1
            case .directory: break
            default: if m.disposition.isBlocked { blocked += 1 }
            }
        }
        return (members.count, regular, admitted, blocked, unsupported, failed, declared)
    }
}
