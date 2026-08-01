//
//  ContainerInspectionRepository.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §28) — the SOLE writer of the v87 container tables. One savepoint per inspection:
//  verify the exact container SourceVersion exists + is container-compatible, assign the next manifest
//  revision (CAS-style), atomically REPLACE the manifest + its member rows, and validate the admitted-
//  child invariants + count consistency. A partial inspection never leaves a manifest whose declared
//  counts disagree with its member rows. This is a PROCESSING PROJECTION — it admits no sources and
//  confirms no claims; source_versions / source_version_relations / source_readiness_* stay authoritative.
//

import Foundation

public struct ContainerInspectionRepository: Sendable {

    private let database: Database
    public init(database: Database) { self.database = database }

    /// Record (upsert) the inspection of one container SourceVersion atomically. Manifest counts are
    /// DERIVED from `members` (never caller-set); the caller supplies only the judged `status`.
    @discardableResult
    public func record(sourceVersionID: UUID, containerType: SourceType, status: ContainerManifestStatus,
                       members: [ContainerMember], inspectorID: String = ZIPContainerInspector.inspectorID,
                       inspectorVersion: String = ZIPContainerInspector.inspectorVersion,
                       policyVersion: String = ContainerSafetyPolicy.standard.version,
                       at now: Date) async throws -> ContainerManifest {
        // Validate the admitted/non-admitted child invariants up front (cheap + deterministic).
        for m in members {
            if m.disposition == .admitted {
                guard m.childSourceVersionID != nil, m.contentHash != nil else {
                    throw ContainerError.admittedMemberMissingChild(ordinal: m.ordinal)
                }
            } else if m.childSourceVersionID != nil {
                throw ContainerError.nonAdmittedMemberHasChild(ordinal: m.ordinal)
            }
        }
        let tally = ContainerInspectionResult.tally(members: members)
        let sp = "usf_container_\(sourceVersionID.uuidString.prefix(8))_\(UUID().uuidString.prefix(4))"
        let membersCopy = members, ct = containerType, st = status
        let iID = inspectorID, iVer = inspectorVersion, pVer = policyVersion
        return try await database.withSavepoint(sp) { db -> ContainerManifest in
            guard let detected = try db.query(
                "SELECT detected_type FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(sourceVersionID)]).first?.string(0) else {
                throw ContainerError.sourceVersionMissing(sourceVersionID)
            }
            guard SourceType(rawValue: detected)?.category == .archive else {
                throw ContainerError.notContainerCompatible(sourceVersionID, ct)
            }
            let existing = try db.query(
                "SELECT revision FROM container_manifests WHERE source_version_id = ? LIMIT 1;", [.uuid(sourceVersionID)]).first?.int(0)
            let newRevision = Int((existing ?? 0) + 1)

            try db.exec("DELETE FROM container_members WHERE parent_source_version_id = ?;", [.uuid(sourceVersionID)])
            try db.exec("DELETE FROM container_manifests WHERE source_version_id = ?;", [.uuid(sourceVersionID)])

            let manifest = ContainerManifest(
                sourceVersionID: sourceVersionID, revision: newRevision, containerType: ct,
                inspectorID: iID, inspectorVersion: iVer, policyVersion: pVer, status: st,
                totalEntries: tally.total, regularFileEntries: tally.regular, admittedMembers: tally.admitted,
                blockedMembers: tally.blocked, unsupportedMembers: tally.unsupported, failedMembers: tally.failed,
                declaredUncompressedBytes: tally.declaredBytes)
            try Self.insertManifest(db, manifest, at: now)
            for m in membersCopy { try Self.insertMember(db, m, at: now) }

            // Prove the persisted member rows match the manifest's total (belt-and-suspenders).
            let count = try db.query(
                "SELECT COUNT(*) FROM container_members WHERE parent_source_version_id = ?;", [.uuid(sourceVersionID)]).first?.int(0) ?? 0
            guard Int(count) == manifest.totalEntries else {
                throw ContainerError.memberCountMismatch(expected: manifest.totalEntries, actual: Int(count))
            }
            return manifest
        }
    }

    // MARK: - Reads

    public func manifest(sourceVersionID: UUID) async throws -> ContainerManifest? {
        try await database.query("""
            SELECT source_version_id, revision, container_type, inspector_id, inspector_version, policy_version,
                   status, total_entries, regular_file_entries, admitted_members, blocked_members,
                   unsupported_members, failed_members, declared_uncompressed_bytes
              FROM container_manifests WHERE source_version_id = ? LIMIT 1;
            """, [.uuid(sourceVersionID)]).first.flatMap(Self.decodeManifest)
    }

    public func members(parentSourceVersionID: UUID) async throws -> [ContainerMember] {
        try await database.query("""
            SELECT id, parent_source_version_id, ordinal, member_path, normalized_member_path, entry_kind,
                   compressed_size, uncompressed_size, detected_type, disposition, child_source_version_id,
                   content_hash, detail
              FROM container_members WHERE parent_source_version_id = ? ORDER BY ordinal ASC;
            """, [.uuid(parentSourceVersionID)]).compactMap(Self.decodeMember)
    }

    // MARK: - Writers (synchronous, inside the savepoint)

    private static func insertManifest(_ db: isolated Database, _ m: ContainerManifest, at now: Date) throws {
        try db.exec("""
            INSERT INTO container_manifests (source_version_id, revision, container_type, inspector_id,
                inspector_version, policy_version, status, total_entries, regular_file_entries, admitted_members,
                blocked_members, unsupported_members, failed_members, declared_uncompressed_bytes, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(m.sourceVersionID), .integer(Int64(m.revision)), .text(m.containerType.rawValue),
                  .text(m.inspectorID), .text(m.inspectorVersion), .text(m.policyVersion), .text(m.status.rawValue),
                  .integer(Int64(m.totalEntries)), .integer(Int64(m.regularFileEntries)), .integer(Int64(m.admittedMembers)),
                  .integer(Int64(m.blockedMembers)), .integer(Int64(m.unsupportedMembers)), .integer(Int64(m.failedMembers)),
                  .integer(m.declaredUncompressedBytes), .date(now), .date(now)])
    }

    private static func insertMember(_ db: isolated Database, _ m: ContainerMember, at now: Date) throws {
        try db.exec("""
            INSERT INTO container_members (id, parent_source_version_id, ordinal, member_path, normalized_member_path,
                entry_kind, compressed_size, uncompressed_size, detected_type, disposition, child_source_version_id,
                content_hash, detail, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(m.id), .uuid(m.parentSourceVersionID), .integer(Int64(m.ordinal)), .text(m.memberPath),
                  .text(m.normalizedMemberPath), .text(m.entryKind.rawValue), .integer(m.compressedSize),
                  .integer(m.uncompressedSize), m.detectedType.map { SQLValue.text($0.rawValue) } ?? .null,
                  .text(m.disposition.rawValue), m.childSourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                  m.contentHash.map { SQLValue.text($0) } ?? .null, m.detail.map { SQLValue.text($0) } ?? .null,
                  .date(now), .date(now)])
    }

    // MARK: - Decoders

    private static func decodeManifest(_ r: SQLRow) -> ContainerManifest? {
        guard let sv = r.uuid(0), let status = ContainerManifestStatus(rawValue: r.string(6) ?? ""),
              let type = SourceType(rawValue: r.string(2) ?? "") else { return nil }
        return ContainerManifest(
            sourceVersionID: sv, revision: Int(r.int(1) ?? 1), containerType: type,
            inspectorID: r.string(3) ?? "", inspectorVersion: r.string(4) ?? "", policyVersion: r.string(5) ?? "",
            status: status, totalEntries: Int(r.int(7) ?? 0), regularFileEntries: Int(r.int(8) ?? 0),
            admittedMembers: Int(r.int(9) ?? 0), blockedMembers: Int(r.int(10) ?? 0),
            unsupportedMembers: Int(r.int(11) ?? 0), failedMembers: Int(r.int(12) ?? 0),
            declaredUncompressedBytes: r.int(13) ?? 0)
    }

    private static func decodeMember(_ r: SQLRow) -> ContainerMember? {
        guard let id = r.uuid(0), let parent = r.uuid(1),
              let kind = ContainerEntryKind(rawValue: r.string(5) ?? ""),
              let disp = ContainerMemberDisposition(rawValue: r.string(9) ?? "") else { return nil }
        return ContainerMember(
            id: id, parentSourceVersionID: parent, ordinal: Int(r.int(2) ?? 0),
            memberPath: r.string(3) ?? "", normalizedMemberPath: r.string(4) ?? "", entryKind: kind,
            compressedSize: r.int(6) ?? 0, uncompressedSize: r.int(7) ?? 0,
            detectedType: r.string(8).flatMap { SourceType(rawValue: $0) }, disposition: disp,
            childSourceVersionID: r.uuid(10), contentHash: r.string(11), detail: r.string(12))
    }
}
