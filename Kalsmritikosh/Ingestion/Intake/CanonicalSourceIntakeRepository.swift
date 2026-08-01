//
//  CanonicalSourceIntakeRepository.swift
//  Kalsmritikosh
//
//  USF-001 / USF-001.1 — the ONE authoritative writer of intake custody. A single atomic
//  database operation resolves canonical identity (new logical source / unchanged / new
//  version / move / alias) INSIDE the savepoint — reads, decision, re-validation and writes
//  are one unit, so a concurrent intake cannot interleave a stale decision with the write.
//  Managed-copy bytes are streamed into the vault (single verified pass) BEFORE the
//  savepoint and accepted as managedCopyStored only when the vault address equals the
//  captured hash. source_versions remains the one version authority.
//

import Foundation

public struct CanonicalSourceIntakeRepository: Sendable {

    private let database: Database
    private let vault: EvidenceVault?

    public init(database: Database, vault: EvidenceVault? = nil) {
        self.database = database
        self.vault = vault
    }

    // MARK: - Public entry point

    /// Resolve and persist canonical custody for a captured accessible source, atomically.
    /// `snapshotURL` (USF-001.2) is the immutable per-intake snapshot whose bytes produced
    /// `captured.contentHash`; managed custody copies THOSE bytes into the vault (never the
    /// mutable original).
    public func intake(request: SourceIntakeRequest, captured: CapturedSource,
                       snapshotURL: URL? = nil) async throws -> SourceIntakeHandle {
        let now = request.recordedAt
        let canonicalURL = request.url.absoluteString

        // Managed custody: resolve a verified vault address BEFORE the identity savepoint.
        // USF-001.2 gap 4 — if the exact bytes are already vaulted under a stored address, REUSE
        // that address (verify the blob is present); otherwise copy the immutable snapshot in one
        // verified pass. The address is accepted only when it equals the captured hash. A managed
        // intake that cannot obtain a present address is `managedCopyFailed` — never a silent
        // `managedCopyStored` with a null address.
        var vaultAddress: String? = nil
        if request.custodyMode == .managed {
            if let known = try await existingManagedVaultAddress(forHash: captured.contentHash),
               let vault, await vault.contains(known) {
                vaultAddress = known
            } else if let vault {
                let copySource = snapshotURL ?? request.url
                if let stored = try? await vault.storeStreaming(contentsOf: copySource),
                   stored == captured.contentHash, await vault.contains(stored) {
                    vaultAddress = stored
                }
            }
        }

        let sp = "usf_intake_\(captured.contentHash.prefix(8))_\(UUID().uuidString.prefix(4))"
        let cap = captured, req = request, vAddr = vaultAddress
        let handle = try await database.withSavepoint(sp) { db -> SourceIntakeHandle in
            try Self.resolveAndWrite(db, request: req, captured: cap, canonicalURL: canonicalURL,
                                     now: now, vaultAddress: vAddr)
        }
        return handle.withProcessingSnapshot(snapshotURL)
    }

    /// A stored managed vault address for these exact bytes, if any version already holds one.
    private func existingManagedVaultAddress(forHash hash: String) async throws -> String? {
        try await database.query("""
            SELECT vault_address FROM source_versions
             WHERE content_hash = ? AND preservation_status = 'managedCopyStored'
               AND vault_address IS NOT NULL AND length(trim(vault_address)) > 0 LIMIT 1;
            """, [.text(hash)]).first?.string(0)
    }

    // MARK: - Atomic resolve + write (synchronous, inside the savepoint)

    private static func resolveAndWrite(_ db: isolated Database, request: SourceIntakeRequest,
                                        captured: CapturedSource, canonicalURL: String, now: Date,
                                        vaultAddress: String?) throws -> SourceIntakeHandle {
        // 1. Resolve any existing occurrence at this URL — INCLUDING aliases (USF-001.1 §9).
        let occurrence = try fileRow(db, url: canonicalURL)
        // 2/3. Resolve the canonical logical source + its current version.
        let sourceTypeRaw = captured.detectedType.rawValue

        var kind: Outcome
        var logical: UUID
        var occurrenceFileID: UUID
        var sourceVersionID: UUID
        var priorVersionID: UUID? = nil
        var reuseVersion: VersionRow? = nil
        // USF-001.2 gap 2 — an alias URL whose bytes changed resolves to exactly one of two
        // transitions, recorded here so the write step never creates a second file row for this URL.
        var aliasRetargetTo: UUID? = nil   // case (a): re-point this alias to another canonical
        var promoteAlias = false           // case (b): promote this occurrence to its own canonical

        if let occ = occurrence {
            let canonicalID = occ.aliasOf ?? occ.id
            let current = try currentVersion(db, logicalSourceID: canonicalID)
            if let current, current.contentHash == captured.contentHash {
                // Known URL (canonical or alias) with unchanged bytes → reuse the occurrence
                // and the canonical current version. An existing alias URL is NOT re-aliased.
                kind = occ.aliasOf == nil ? .unchanged : .aliased
                logical = canonicalID; occurrenceFileID = occ.id
                sourceVersionID = current.id; reuseVersion = current
            } else if occ.aliasOf == nil {
                // Canonical URL, changed bytes → a new immutable version of the same source.
                guard let current else { throw SourceIntakeError.sourceIdentityConflict("canonical \(canonicalID) has no current version") }
                kind = .newVersion; logical = canonicalID; occurrenceFileID = occ.id
                sourceVersionID = UUID(); priorVersionID = current.id
            } else {
                // Alias URL whose bytes changed — resolve the alias transition WITHOUT ever
                // creating a second file row for this URL (USF-001.2 §6).
                occurrenceFileID = occ.id
                if let target = try canonicalFileByHash(db, hash: captured.contentHash, excludingURL: canonicalURL),
                   let targetCurrent = try currentVersion(db, logicalSourceID: target.id),
                   targetCurrent.contentHash == captured.contentHash {
                    // (a) The new bytes match ANOTHER canonical source → re-point this alias at it
                    //     and refresh the occurrence's stored bytes; reuse the target's version.
                    kind = .aliased; logical = target.id; aliasRetargetTo = target.id
                    sourceVersionID = targetCurrent.id; reuseVersion = targetCurrent
                } else {
                    // (b) Entirely new bytes → promote this occurrence to its own canonical
                    //     logical source (alias_of := NULL) and create its first version.
                    kind = .newLogicalSource; logical = occ.id; promoteAlias = true
                    sourceVersionID = UUID()
                }
            }
        } else {
            let resolved = try resolveByHash(db, captured: captured, canonicalURL: canonicalURL, now: now)
            kind = resolved.kind; logical = resolved.logical; occurrenceFileID = resolved.occurrenceFileID
            sourceVersionID = resolved.sourceVersionID; reuseVersion = resolved.reuseVersion
        }

        // Preservation for new outcomes; carried from the reused version otherwise. USF-001.2 gap 4 —
        // managedCopyStored is derived from an ACTUAL present vault address, never from the absence
        // of a failure flag; no address ⇒ managedCopyFailed.
        let preservation: SourcePreservationStatus
        switch kind {
        case .newLogicalSource, .newVersion:
            preservation = request.custodyMode == .managed
                ? (vaultAddress != nil ? .managedCopyStored : .managedCopyFailed)
                : .referenceRecorded
        case .unchanged, .moved, .aliased:
            preservation = reuseVersion?.preservation ?? .referenceRecorded
        }
        let effectiveVault = (kind == .newLogicalSource || kind == .newVersion) ? vaultAddress : reuseVersion?.vaultAddress

        // Writes.
        switch kind {
        case .newLogicalSource:
            if promoteAlias {
                // Promote the existing alias occurrence in place — no second row for this URL.
                try db.exec("""
                    UPDATE files SET alias_of = NULL, content_hash = ?, size_bytes = ?, modified_at = ?, source_type = ?, ingested_at = ?, availability = 'available' WHERE id = ?;
                    """, [.text(captured.contentHash), .integer(captured.sizeBytes),
                          captured.modifiedAt.map(SQLValue.date) ?? .real(0), .text(sourceTypeRaw), .date(now), .uuid(logical)])
            } else {
                try insertFile(db, id: logical, url: canonicalURL, type: sourceTypeRaw, captured: captured, now: now, aliasOf: nil)
            }
            try insertVersion(db, id: sourceVersionID, logical: logical, captured: captured, now: now,
                              supersedes: nil, custody: request.custodyMode, preservation: preservation, vault: effectiveVault, url: canonicalURL)
        case .newVersion:
            guard let prior = priorVersionID,
                  try db.query("SELECT is_current FROM source_versions WHERE id = ?;", [.uuid(prior)]).first?.int(0) == 1 else {
                throw SourceIntakeError.sourceIdentityConflict("prior current version changed for \(logical)")
            }
            try db.exec("UPDATE source_versions SET is_current = 0, valid_to = ? WHERE id = ?;", [.date(now), .uuid(prior)])
            try insertVersion(db, id: sourceVersionID, logical: logical, captured: captured, now: now,
                              supersedes: prior, custody: request.custodyMode, preservation: preservation, vault: effectiveVault, url: canonicalURL)
            try db.exec("""
                UPDATE files SET content_hash = ?, size_bytes = ?, modified_at = ?, source_type = ?, ingested_at = ? WHERE id = ?;
                """, [.text(captured.contentHash), .integer(captured.sizeBytes),
                      captured.modifiedAt.map(SQLValue.date) ?? .real(0), .text(sourceTypeRaw), .date(now), .uuid(logical)])
        case .unchanged:
            break
        case .moved:
            try db.exec("UPDATE files SET url = ?, availability = 'available' WHERE id = ?;", [.text(canonicalURL), .uuid(logical)])
        case .aliased:
            if let retarget = aliasRetargetTo {
                // Re-point an existing alias URL to a different canonical + refresh its stored
                // bytes (the occurrence row already exists — never insert a second row).
                try db.exec("""
                    UPDATE files SET alias_of = ?, content_hash = ?, size_bytes = ?, modified_at = ?, source_type = ?, availability = 'available' WHERE id = ?;
                    """, [.uuid(retarget), .text(captured.contentHash), .integer(captured.sizeBytes),
                          captured.modifiedAt.map(SQLValue.date) ?? .real(0), .text(sourceTypeRaw), .uuid(occurrenceFileID)])
            } else if try fileRow(db, url: canonicalURL) == nil {
                try insertFile(db, id: occurrenceFileID, url: canonicalURL, type: sourceTypeRaw, captured: captured, now: now, aliasOf: logical)
            }
        }

        // USF-002 — a NEW source version is born with its ten readiness dimensions in the SAME
        // savepoint. No successfully-created version ever exists without them; unchanged/moved/
        // aliased/retargeted occurrences reuse the canonical version's readiness (no new aggregate).
        if kind == .newLogicalSource || kind == .newVersion {
            let readinessRecords = SourceReadinessBootstrap.initialDimensions(
                sourceVersionID: sourceVersionID, detectedType: captured.detectedType,
                preservationStatus: preservation, at: now)
            try SourceReadinessRepository.initialize(db, sourceVersionID: sourceVersionID, records: readinessRecords, now: now)
        }

        // Optional version-level parent relation (survives child parse failure). Idempotent
        // for re-intake, but never silently OR-IGNOREd: a genuine duplicate races to a typed error.
        if let parent = request.parent {
            guard try db.query("SELECT 1 FROM source_versions WHERE id = ?;", [.uuid(parent.parentSourceVersionID)]).first != nil else {
                throw SourceIntakeError.invalidParentReference("parent version \(parent.parentSourceVersionID) not found")
            }
            guard parent.parentSourceVersionID != sourceVersionID else {
                throw SourceIntakeError.invalidRelation("a source version cannot be its own parent")
            }
            let exists = try db.query("""
                SELECT 1 FROM source_version_relations WHERE parent_source_version_id = ? AND child_source_version_id = ? AND relation = ?;
                """, [.uuid(parent.parentSourceVersionID), .uuid(sourceVersionID), .text(parent.relation.rawValue)]).first != nil
            if !exists {
                do {
                    try db.exec("""
                        INSERT INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, ordinal, created_at)
                        VALUES (?,?,?,?,?,?);
                        """, [.uuid(UUID()), .uuid(parent.parentSourceVersionID), .uuid(sourceVersionID),
                              .text(parent.relation.rawValue), parent.ordinal.map { SQLValue.integer(Int64($0)) } ?? .null, .date(now)])
                } catch {
                    throw SourceIntakeError.invalidRelation("duplicate version relation")
                }
            }
        }

        // One intake receipt per successful capture — its content hash is pinned to the
        // version's hash by composite FK (v83).
        try db.exec("""
            INSERT INTO source_intake_receipts (id, occurrence_file_id, logical_source_id, source_version_id, outcome, original_url, content_hash, custody_mode, preservation_status, detail, recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(occurrenceFileID), .uuid(logical), .uuid(sourceVersionID),
                  .text(kind.rawValue), .text(canonicalURL), .text(captured.contentHash),
                  .text(request.custodyMode.rawValue), .text(preservation.rawValue), .null, .date(now)])

        // Return the exact resolved values.
        let handleDetected = reuseVersion.flatMap { SourceType(rawValue: $0.detectedType) } ?? captured.detectedType
        let handleBasis = reuseVersion.flatMap { SourceDetectionBasis(rawValue: $0.detectionBasis) } ?? captured.detectionBasis
        return SourceIntakeHandle(
            occurrenceFileID: occurrenceFileID, logicalSourceID: logical, sourceVersionID: sourceVersionID,
            outcome: kind, filename: reuseVersion?.filename ?? captured.filename,
            declaredExtension: reuseVersion?.declaredExtension ?? captured.declaredExtension,
            detectedType: handleDetected, mimeType: reuseVersion?.mimeType ?? captured.mimeType,
            detectionBasis: handleBasis, contentHash: captured.contentHash,
            sizeBytes: reuseVersion?.sizeBytes ?? captured.sizeBytes,
            custodyMode: reuseVersion?.custody ?? request.custodyMode,
            preservationStatus: preservation, vaultAddress: effectiveVault)
    }

    private struct HashResolution {
        let kind: Outcome; let logical: UUID; let occurrenceFileID: UUID
        let sourceVersionID: UUID; let reuseVersion: VersionRow?
    }

    /// Resolve an occurrence not found by URL: move (old location gone), alias (old present),
    /// or a brand-new logical source.
    private static func resolveByHash(_ db: isolated Database, captured: CapturedSource,
                                      canonicalURL: String, now: Date) throws -> HashResolution {
        if let canonical = try canonicalFileByHash(db, hash: captured.contentHash, excludingURL: canonicalURL),
           let current = try currentVersion(db, logicalSourceID: canonical.id) {
            let oldExists = FileManager.default.fileExists(atPath: URL(string: canonical.url)?.path ?? canonical.url)
            if oldExists {
                return HashResolution(kind: .aliased, logical: canonical.id, occurrenceFileID: UUID(),
                                      sourceVersionID: current.id, reuseVersion: current)
            }
            return HashResolution(kind: .moved, logical: canonical.id, occurrenceFileID: canonical.id,
                                  sourceVersionID: current.id, reuseVersion: current)
        }
        let newID = UUID()
        return HashResolution(kind: .newLogicalSource, logical: newID, occurrenceFileID: newID,
                              sourceVersionID: UUID(), reuseVersion: nil)
    }

    // MARK: - Writes

    private static func insertFile(_ db: isolated Database, id: UUID, url: String, type: String,
                                   captured: CapturedSource, now: Date, aliasOf: UUID?) throws {
        try db.exec("""
            INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash, alias_of, availability, privileged)
            VALUES (?,?,?,?,?,?,?,?,?,0);
            """, [.uuid(id), .text(url), .text(type), .integer(captured.sizeBytes),
                  captured.modifiedAt.map(SQLValue.date) ?? .real(0), .date(now), .text(captured.contentHash),
                  aliasOf.map(SQLValue.uuid) ?? .null, .text("available")])
    }

    private static func insertVersion(_ db: isolated Database, id: UUID, logical: UUID, captured: CapturedSource,
                                      now: Date, supersedes: UUID?, custody: SourceCustodyMode,
                                      preservation: SourcePreservationStatus, vault: String?, url: String) throws {
        try db.exec("""
            INSERT INTO source_versions
                (id, logical_source_id, document_id, content_hash, supersedes, valid_from, valid_to, is_current,
                 original_url, created_at, filename, declared_extension, detected_type, mime_type, detection_basis,
                 size_bytes, modified_at, custody_mode, preservation_status, vault_address, intake_recorded_at)
            VALUES (?,?,NULL,?,?,?,NULL,1,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), .text(captured.contentHash), supersedes.map(SQLValue.uuid) ?? .null,
                  .date(now), .text(url), .date(now), .text(captured.filename), .text(captured.declaredExtension),
                  .text(captured.detectedType.rawValue), captured.mimeType.map(SQLValue.text) ?? .null,
                  .text(captured.detectionBasis.rawValue), .integer(captured.sizeBytes),
                  captured.modifiedAt.map(SQLValue.date) ?? .null, .text(custody.rawValue),
                  .text(preservation.rawValue), vault.map(SQLValue.text) ?? .null, .date(now)])
    }

    // MARK: - Reads (synchronous, inside the savepoint)

    private struct FileRow: Sendable { let id: UUID; let url: String; let aliasOf: UUID? }
    private struct VersionRow: Sendable {
        let id: UUID; let contentHash: String; let preservation: SourcePreservationStatus
        let custody: SourceCustodyMode; let vaultAddress: String?; let filename: String
        let detectedType: String; let declaredExtension: String; let mimeType: String?
        let detectionBasis: String; let sizeBytes: Int64
    }

    private static func fileRow(_ db: isolated Database, url: String) throws -> FileRow? {
        guard let r = try db.query("SELECT id, url, alias_of FROM files WHERE url = ? LIMIT 1;", [.text(url)]).first,
              let id = r.uuid(0), let u = r.string(1) else { return nil }
        return FileRow(id: id, url: u, aliasOf: r.uuid(2))
    }

    private static func canonicalFileByHash(_ db: isolated Database, hash: String, excludingURL: String) throws -> FileRow? {
        guard let r = try db.query("""
            SELECT id, url, alias_of FROM files WHERE content_hash = ? AND alias_of IS NULL AND url <> ? LIMIT 1;
            """, [.text(hash), .text(excludingURL)]).first, let id = r.uuid(0), let u = r.string(1) else { return nil }
        return FileRow(id: id, url: u, aliasOf: nil)
    }

    private static func currentVersion(_ db: isolated Database, logicalSourceID: UUID) throws -> VersionRow? {
        guard let r = try db.query("""
            SELECT id, content_hash, preservation_status, custody_mode, vault_address, filename,
                   detected_type, declared_extension, mime_type, detection_basis, size_bytes
              FROM source_versions WHERE logical_source_id = ? AND is_current = 1 LIMIT 1;
            """, [.uuid(logicalSourceID)]).first, let id = r.uuid(0) else { return nil }
        return VersionRow(
            id: id, contentHash: r.string(1) ?? "",
            preservation: SourcePreservationStatus(rawValue: r.string(2) ?? "") ?? .referenceRecorded,
            custody: SourceCustodyMode(rawValue: r.string(3) ?? "") ?? .referenced,
            vaultAddress: r.string(4), filename: r.string(5) ?? "",
            detectedType: r.string(6) ?? "unknown", declaredExtension: r.string(7) ?? "",
            mimeType: r.string(8), detectionBasis: r.string(9) ?? "unknown", sizeBytes: r.int(10) ?? 0)
    }
}

private typealias Outcome = SourceIntakeOutcome
