//
//  CanonicalSourceIntakeRepository.swift
//  Kalsmritikosh
//
//  USF-001 — the ONE authoritative writer of intake custody. It owns a single atomic
//  database operation that resolves canonical identity (new logical source / new version /
//  unchanged / move / alias) and writes the file row, source-version row, intake receipt
//  and optional version-level parent relation together. A failure writes none of them.
//  It never creates a second source or version authority; source_versions remains the one
//  version authority. Managed-copy bytes are streamed into the vault BEFORE the atomic
//  write (an orphaned blob on a later rollback is reclaimable under USF-010).
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
    public func intake(request: SourceIntakeRequest, captured: CapturedSource) async throws -> SourceIntakeHandle {
        let now = request.recordedAt
        let canonicalURL = request.url.absoluteString

        // 1. Read current identity (async, before the atomic write).
        let byURL = try await canonicalFile(url: canonicalURL)
        let currentForURL = byURL?.currentVersion
        let byHash = try await canonicalFile(hash: captured.contentHash, excludingURL: canonicalURL)

        // 2. Decide the outcome.
        let decision = decide(byURL: byURL, currentForURL: currentForURL, byHash: byHash, captured: captured)

        // 3. Managed-copy bytes into the vault for outcomes that introduce a new version.
        var vaultAddress: String? = nil
        var preservation: SourcePreservationStatus
        switch decision.kind {
        case .newLogicalSource, .newVersion:
            if request.custodyMode == .managed {
                if let vault, let stored = try? await vault.storeStreaming(contentsOf: request.url),
                   stored == captured.contentHash {
                    vaultAddress = stored
                    preservation = .managedCopyStored
                } else {
                    preservation = .managedCopyFailed          // visible, never a silent downgrade
                }
            } else {
                preservation = .referenceRecorded
            }
        case .unchanged, .moved, .aliased:
            preservation = decision.existingPreservation ?? .referenceRecorded
        }

        // 4. Atomic write.
        let sp = "usf_intake_\(captured.contentHash.prefix(8))"
        let plan = decision
        let mode = request.custodyMode
        let parent = request.parent
        let vaultAddr = vaultAddress
        let preservationStatus = preservation
        return try await database.withSavepoint(sp) { db -> SourceIntakeHandle in
            try Self.write(db, plan: plan, captured: captured, canonicalURL: canonicalURL, now: now,
                           custodyMode: mode, preservation: preservationStatus, vaultAddress: vaultAddr, parent: parent)
        }
    }

    // MARK: - Decision

    private struct Decision {
        enum Kind {
            case newLogicalSource, newVersion, unchanged, moved, aliased
            var outcome: SourceIntakeOutcome {
                switch self {
                case .newLogicalSource: return .newLogicalSource
                case .newVersion:       return .newVersion
                case .unchanged:        return .unchanged
                case .moved:            return .moved
                case .aliased:          return .aliased
                }
            }
            var isReuse: Bool {
                switch self {
                case .unchanged, .moved, .aliased:   return true
                case .newLogicalSource, .newVersion: return false
                }
            }
        }
        let kind: Kind
        let logicalSourceID: UUID          // canonical file id
        let occurrenceFileID: UUID         // the file row this occurrence is (alias id for aliased)
        let sourceVersionID: UUID          // resulting current version
        let priorVersionID: UUID?          // retired on newVersion
        let newURLForMove: String?
        let existingPreservation: SourcePreservationStatus?
        let existingCustody: SourceCustodyMode?
        let existingVaultAddress: String?
        let existingFilename: String?
        let existingDetectedType: SourceType?
        let existingDeclaredExtension: String?
        let existingMimeType: String?
        let existingDetectionBasis: SourceDetectionBasis?
        let existingSizeBytes: Int64?
    }

    private func decide(byURL: FileRow?, currentForURL: VersionRow?, byHash: FileRow?, captured: CapturedSource) -> Decision {
        if let file = byURL, let current = currentForURL {
            if current.contentHash == captured.contentHash {
                return existing(.unchanged, file: file, version: current)
            }
            // Same URL, changed bytes → new immutable version of the same logical source.
            return Decision(kind: .newVersion, logicalSourceID: file.id, occurrenceFileID: file.id,
                            sourceVersionID: UUID(), priorVersionID: current.id, newURLForMove: nil,
                            existingPreservation: nil, existingCustody: nil, existingVaultAddress: nil,
                            existingFilename: nil, existingDetectedType: nil, existingDeclaredExtension: nil,
                            existingMimeType: nil, existingDetectionBasis: nil, existingSizeBytes: nil)
        }
        if let canonical = byHash, let current = canonicalVersion(canonical) {
            // Same bytes already known at another URL: move if the old location is gone,
            // otherwise a physical alias (not independent evidence).
            let oldExists = FileManager.default.fileExists(atPath: URL(string: canonical.url)?.path ?? canonical.url)
            if oldExists {
                return existing(.aliased, file: canonical, version: current, occurrenceFileID: UUID())
            }
            return existing(.moved, file: canonical, version: current, newURL: captured.filename.isEmpty ? nil : nil)
        }
        // Brand new URL + brand new bytes.
        let newID = UUID()
        return Decision(kind: .newLogicalSource, logicalSourceID: newID, occurrenceFileID: newID,
                        sourceVersionID: UUID(), priorVersionID: nil, newURLForMove: nil,
                        existingPreservation: nil, existingCustody: nil, existingVaultAddress: nil,
                        existingFilename: nil, existingDetectedType: nil, existingDeclaredExtension: nil,
                        existingMimeType: nil, existingDetectionBasis: nil, existingSizeBytes: nil)
    }

    private func existing(_ kind: Decision.Kind, file: FileRow, version: VersionRow,
                          occurrenceFileID: UUID? = nil, newURL: String? = nil) -> Decision {
        Decision(kind: kind, logicalSourceID: file.id, occurrenceFileID: occurrenceFileID ?? file.id,
                 sourceVersionID: version.id, priorVersionID: nil,
                 newURLForMove: kind == .moved ? file.id.uuidString : nil,
                 existingPreservation: version.preservation, existingCustody: version.custody,
                 existingVaultAddress: version.vaultAddress, existingFilename: version.filename,
                 existingDetectedType: SourceType(rawValue: version.detectedType) ?? .unknown,
                 existingDeclaredExtension: version.declaredExtension,
                 existingMimeType: version.mimeType,
                 existingDetectionBasis: SourceDetectionBasis(rawValue: version.detectionBasis) ?? .unknown,
                 existingSizeBytes: version.sizeBytes)
    }

    // The canonical current version helper used at decision time (loaded eagerly is avoided;
    // here we re-fetch synchronously is not possible in the async path, so callers pass it).
    private func canonicalVersion(_ file: FileRow) -> VersionRow? { file.currentVersion }

    // MARK: - Atomic write (synchronous inside the savepoint)

    private static func write(_ db: isolated Database, plan: Decision, captured: CapturedSource,
                              canonicalURL: String, now: Date, custodyMode: SourceCustodyMode,
                              preservation: SourcePreservationStatus, vaultAddress: String?,
                              parent: SourceParentReference?) throws -> SourceIntakeHandle {
        let logical = plan.logicalSourceID
        var occurrenceFileID = plan.occurrenceFileID
        var sourceVersionID = plan.sourceVersionID
        let sourceTypeRaw = captured.detectedType.rawValue

        switch plan.kind {
        case .newLogicalSource:
            try insertFile(db, id: logical, url: canonicalURL, type: sourceTypeRaw, captured: captured, now: now, aliasOf: nil)
            try insertVersion(db, id: sourceVersionID, logical: logical, captured: captured, now: now,
                              supersedes: nil, custody: custodyMode, preservation: preservation, vault: vaultAddress, url: canonicalURL)

        case .newVersion:
            // Re-verify the prior current version is still current (race guard).
            guard let prior = plan.priorVersionID,
                  try db.query("SELECT is_current FROM source_versions WHERE id = ?;", [.uuid(prior)]).first?.int(0) == 1 else {
                throw SourceIntakeError.sourceIdentityConflict("prior current version changed for \(logical)")
            }
            try db.exec("UPDATE source_versions SET is_current = 0, valid_to = ? WHERE id = ?;",
                        [.date(now), .uuid(prior)])
            try insertVersion(db, id: sourceVersionID, logical: logical, captured: captured, now: now,
                              supersedes: prior, custody: custodyMode, preservation: preservation, vault: vaultAddress, url: canonicalURL)
            try db.exec("""
                UPDATE files SET content_hash = ?, size_bytes = ?, modified_at = ?, source_type = ?, ingested_at = ?
                  WHERE id = ?;
                """, [.text(captured.contentHash), .integer(captured.sizeBytes),
                      captured.modifiedAt.map(SQLValue.date) ?? .real(0), .text(sourceTypeRaw), .date(now), .uuid(logical)])

        case .unchanged:
            // No writes to identity; the current version is reused.
            break

        case .moved:
            try db.exec("UPDATE files SET url = ?, availability = 'available' WHERE id = ?;",
                        [.text(canonicalURL), .uuid(logical)])

        case .aliased:
            try insertFile(db, id: occurrenceFileID, url: canonicalURL, type: sourceTypeRaw, captured: captured, now: now, aliasOf: logical)
        }

        // Optional version-level parent relation (survives child parse failure).
        if let parent {
            guard try db.query("SELECT 1 FROM source_versions WHERE id = ?;", [.uuid(parent.parentSourceVersionID)]).first != nil else {
                throw SourceIntakeError.invalidParentReference("parent version \(parent.parentSourceVersionID) not found")
            }
            guard parent.parentSourceVersionID != sourceVersionID else {
                throw SourceIntakeError.invalidRelation("a source version cannot be its own parent")
            }
            try db.exec("""
                INSERT OR IGNORE INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, ordinal, created_at)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(parent.parentSourceVersionID), .uuid(sourceVersionID),
                      .text(parent.relation.rawValue), parent.ordinal.map { SQLValue.integer(Int64($0)) } ?? .null, .date(now)])
        }

        // One intake receipt for every successful capture (append-only audit).
        let outcome = plan.kind.outcome
        try db.exec("""
            INSERT INTO source_intake_receipts (id, occurrence_file_id, logical_source_id, source_version_id, outcome, original_url, content_hash, custody_mode, preservation_status, detail, recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(occurrenceFileID), .uuid(logical), .uuid(sourceVersionID),
                  .text(outcome.rawValue), .text(canonicalURL), .text(captured.contentHash),
                  .text(custodyMode.rawValue), .text(preservation.rawValue), .null, .date(now)])

        // Resolve the exact values to return (existing custody carried for reuse outcomes).
        let handleDetected = plan.existingDetectedType ?? captured.detectedType
        let handleBasis = plan.existingDetectionBasis ?? captured.detectionBasis
        let handleFilename = plan.existingFilename ?? captured.filename
        let handleExt = plan.existingDeclaredExtension ?? captured.declaredExtension
        let handleMime = plan.kind.isReuse ? plan.existingMimeType : captured.mimeType
        let handleSize = plan.existingSizeBytes ?? captured.sizeBytes
        let handleCustody = plan.existingCustody ?? custodyMode
        let handlePreservation = plan.existingPreservation ?? preservation
        let handleVault = plan.kind.isReuse ? plan.existingVaultAddress : vaultAddress
        return SourceIntakeHandle(
            occurrenceFileID: occurrenceFileID, logicalSourceID: logical, sourceVersionID: sourceVersionID,
            outcome: outcome, filename: handleFilename, declaredExtension: handleExt,
            detectedType: handleDetected, mimeType: handleMime, detectionBasis: handleBasis,
            contentHash: captured.contentHash, sizeBytes: handleSize, custodyMode: handleCustody,
            preservationStatus: handlePreservation, vaultAddress: handleVault)
    }

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

    // MARK: - Reads

    private struct FileRow: Sendable { let id: UUID; let url: String; var currentVersion: VersionRow? }
    private struct VersionRow: Sendable {
        let id: UUID; let contentHash: String; let preservation: SourcePreservationStatus
        let custody: SourceCustodyMode; let vaultAddress: String?; let filename: String
        let detectedType: String; let declaredExtension: String; let mimeType: String?
        let detectionBasis: String; let sizeBytes: Int64
    }

    private func canonicalFile(url: String) async throws -> FileRow? {
        guard let row = try await database.query(
            "SELECT id FROM files WHERE url = ? AND alias_of IS NULL LIMIT 1;", [.text(url)]).first,
            let id = row.uuid(0) else { return nil }
        var file = FileRow(id: id, url: url, currentVersion: nil)
        file.currentVersion = try await currentVersion(logicalSourceID: id)
        return file
    }

    private func canonicalFile(hash: String, excludingURL: String) async throws -> FileRow? {
        guard let row = try await database.query("""
            SELECT id, url FROM files WHERE content_hash = ? AND alias_of IS NULL AND url <> ? LIMIT 1;
            """, [.text(hash), .text(excludingURL)]).first,
            let id = row.uuid(0), let url = row.string(1) else { return nil }
        var file = FileRow(id: id, url: url, currentVersion: nil)
        file.currentVersion = try await currentVersion(logicalSourceID: id)
        return file
    }

    private func currentVersion(logicalSourceID: UUID) async throws -> VersionRow? {
        guard let r = try await database.query("""
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
