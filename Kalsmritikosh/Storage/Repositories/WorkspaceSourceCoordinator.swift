//
//  WorkspaceSourceCoordinator.swift
//  Kalsmritikosh
//
//  PA-UI-001 — the testable service behind the workspace source-management UI. Orchestration and
//  DB access live here, NOT in WorkspacesView. Sources are chosen from files ALREADY ingested into
//  the archive (no second ingestion path); adding one immediately projects its subjects' Claims and
//  reconciles derived membership so a report can be produced; removing one drops only the
//  membership row — the file, its KnowledgeObjects, EvidenceBlocks, Claims, reviews and prior
//  exports are never touched.
//
//  Smart-map S14 (QA-15, 2026-11-12) — omissions are visible. A file the app holds but could not read (a failed scan,
//  an unsupported or damaged file: canonical custody registered, no readable content) is offered and admitted too, in
//  a "not read" state with its reason (`readState`). It is never projected (it has nothing to project), never counted
//  as read or searched; the case that takes it in lists it as not read in its coverage, search receipt, brief and map.
//  A file with no custody record at all (refused before intake) still cannot be added: there is nothing to account for.
//

import Foundation

/// A file offered to (or already in) a workspace's source set, with just the fields the picker and
/// the Sources list render.
public struct WorkspaceSourceCandidate: Sendable, Hashable, Identifiable {
    /// S14 (QA-15) — whether the app could read the file. A not-read file can still be added (so the case accounts for
    /// it); it never counts as read or searched.
    public enum ReadState: Sendable, Hashable {
        case read
        case notRead(reason: String)
        public var isRead: Bool { if case .read = self { return true }; return false }
        public var label: String? { if case .notRead(let why) = self { return "Not read — \(why)" }; return nil }
    }
    public let fileID: UUID
    public let filename: String
    public let parentPath: String
    public let sourceType: SourceType
    public let availability: FileAvailability
    public let ingestedAt: Date?
    public var readState: ReadState = .read
    public var id: UUID { fileID }

    public nonisolated init(fileID: UUID, filename: String, parentPath: String, sourceType: SourceType,
                availability: FileAvailability, ingestedAt: Date?, readState: ReadState = .read) {
        self.fileID = fileID; self.filename = filename; self.parentPath = parentPath
        self.sourceType = sourceType; self.availability = availability; self.ingestedAt = ingestedAt
        self.readState = readState
    }
}

public enum WorkspaceSourceError: Error, Equatable {
    /// None of the requested files were eligible (canonical + ingested) to add.
    case noEligibleSources
}

/// S14 (QA-15) — the outcome of an add: what was admitted, and which of those were admitted as not read (with reasons).
public struct WorkspaceSourceAddResult: Sendable, Equatable {
    public let added: [UUID]
    /// Admitted in the "not read" state: file id → reason. Never projected, never counted as read or searched.
    public let notRead: [UUID: String]
}

public actor WorkspaceSourceCoordinator {
    private let files: FilesRepository
    private let objects: KnowledgeObjectRepository
    private let workspaces: WorkspaceRepository
    private let membership: WorkspaceMembershipDeriver
    private let projection: ClaimProjectionBackfill
    /// S14 (QA-15) — the ledger, to find files held in custody without readable content. Nil: only read files are
    /// eligible (the pre-S14 rule; rigs that do not pass it).
    private let database: Database?

    public init(files: FilesRepository, objects: KnowledgeObjectRepository,
                workspaces: WorkspaceRepository, membership: WorkspaceMembershipDeriver,
                projection: ClaimProjectionBackfill, database: Database? = nil) {
        self.files = files; self.objects = objects; self.workspaces = workspaces
        self.membership = membership; self.projection = projection; self.database = database
    }

    // MARK: - Reads

    /// Files eligible to ADD to a workspace: canonical (`aliasOf == nil`), genuinely ingested
    /// (owns ≥1 KnowledgeObject) — or (S14) held in custody without readable content, offered as not read with the
    /// reason — and not already in this workspace. Deterministically ordered.
    public func candidates(for workspaceID: Workspace.ID) async throws -> [WorkspaceSourceCandidate] {
        let already = Set(try await workspaces.sourceIDs(in: workspaceID))
        let ingested = try await objects.fileIDsWithObjects()
        let all = try await files.all()
        let unread = try await unreadHeld(all.filter { $0.aliasOf == nil && !ingested.contains($0.id) && !already.contains($0.id) })
        return all
            .filter { $0.aliasOf == nil && (ingested.contains($0.id) || unread[$0.id] != nil) && !already.contains($0.id) }
            .map { f in
                var c = Self.candidate(from: f)
                if let why = unread[f.id] { c.readState = .notRead(reason: why) }
                return c
            }
            .sorted(by: Self.order)
    }

    /// The workspace's current sources, most-recently-added first (mirrors `sourceIDs` order).
    public func currentSources(in workspaceID: Workspace.ID) async throws -> [WorkspaceSourceCandidate] {
        let ids = try await workspaces.sourceIDs(in: workspaceID)     // added_at DESC
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary((try await files.all()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ingested = try await objects.fileIDsWithObjects()
        let unread = try await unreadHeld(ids.compactMap { byID[$0] }.filter { !ingested.contains($0.id) })
        return ids.compactMap { byID[$0] }.map { f in
            var c = Self.candidate(from: f)
            if let why = unread[f.id] { c.readState = .notRead(reason: why) }
            return c
        }
    }

    // MARK: - Writes

    /// Add the eligible files among `fileIDs` to the workspace, then project each source's subjects
    /// and reconcile derived membership so the workspace immediately has members + producible
    /// Claims. Deduplicated + deterministic. Throws `.noEligibleSources` if nothing valid remains.
    /// S14 (QA-15): a file held in custody without readable content is admitted as not read (never projected); the
    /// result names it with its reason.
    @discardableResult
    public func addSources(_ fileIDs: Set<UUID>, to workspaceID: Workspace.ID, at now: Date) async throws -> WorkspaceSourceAddResult {
        let ingested = try await objects.fileIDsWithObjects()
        let byID = Dictionary((try await files.all()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let canonical = fileIDs.compactMap { byID[$0] }.filter { $0.aliasOf == nil }
        let unread = try await unreadHeld(canonical.filter { !ingested.contains($0.id) })
        let valid = canonical.map(\.id).filter { ingested.contains($0) || unread[$0] != nil }
        guard !valid.isEmpty else { throw WorkspaceSourceError.noEligibleSources }
        let ordered = valid.sorted { $0.uuidString < $1.uuidString }   // deterministic
        try await workspaces.addSources(ordered, to: workspaceID, at: now)   // atomic + touches updated_at
        for fileID in ordered where ingested.contains(fileID) {
            try await projection.projectSourceForUserAction(fileID: fileID, at: now)
        }
        return WorkspaceSourceAddResult(added: ordered, notRead: unread.filter { ordered.contains($0.key) })
    }

    /// S14 (QA-15) — of `files` (canonical, without readable content), those the app holds in custody (a current source
    /// version of the same bytes), each with why it was not read. Empty without a ledger handle.
    private func unreadHeld(_ candidates: [FileRecord]) async throws -> [UUID: String] {
        guard let database, !candidates.isEmpty else { return [:] }
        var versionByFile: [UUID: UUID] = [:]
        let byHash = Dictionary(grouping: candidates.filter { !($0.contentHash ?? "").isEmpty }, by: { ($0.contentHash ?? "").lowercased() })
        let hashes = Array(byHash.keys).sorted()
        for start in stride(from: 0, to: hashes.count, by: 400) {
            let chunk = Array(hashes[start..<min(start + 400, hashes.count)])
            let rows = try await database.query(
                "SELECT lower(content_hash), id FROM source_versions WHERE is_current = 1 AND lower(content_hash) IN (\(chunk.map { _ in "?" }.joined(separator: ",")));",
                chunk.map { SQLValue.text($0) })
            for r in rows {
                guard let h = r.string(0), let v = r.uuid(1) else { continue }
                for f in byHash[h] ?? [] where versionByFile[f.id] == nil { versionByFile[f.id] = v }
            }
        }
        guard !versionByFile.isEmpty else { return [:] }
        let reasons = await UnreadSourceReason.reasons(for: Set(versionByFile.values), database: database)
        return versionByFile.mapValues { reasons[$0] ?? UnreadSourceReason.noRecord }
    }

    /// Remove a source: drop the membership row, reconcile the workspace's derived subjects (so
    /// entities no longer sourced fall away while manually-added ones survive), bump `updated_at`.
    /// Never deletes the file or any extracted evidence.
    public func removeSource(_ fileID: UUID, from workspaceID: Workspace.ID, at now: Date) async throws {
        try await workspaces.removeSource(fileID, from: workspaceID)
        _ = try await membership.deriveMembership(for: workspaceID, at: now)
        try await workspaces.touch(workspaceID, at: now)
    }

    // MARK: - Helpers

    private static func candidate(from f: FileRecord) -> WorkspaceSourceCandidate {
        let name = f.url.lastPathComponent
        return WorkspaceSourceCandidate(
            fileID: f.id,
            filename: name.isEmpty ? f.url.absoluteString : name,
            parentPath: f.url.deletingLastPathComponent().path,
            sourceType: f.sourceType,
            availability: f.availability,
            ingestedAt: f.ingestedAt)
    }

    /// available before offline/missing; then newest ingestion first (undated last); then
    /// filename; then file id.
    private static func order(_ a: WorkspaceSourceCandidate, _ b: WorkspaceSourceCandidate) -> Bool {
        let aAvail = a.availability == .available ? 0 : 1
        let bAvail = b.availability == .available ? 0 : 1
        if aAvail != bAvail { return aAvail < bAvail }
        switch (a.ingestedAt, b.ingestedAt) {
        case let (x?, y?) where x != y: return x > y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        if a.filename != b.filename { return a.filename < b.filename }
        return a.fileID.uuidString < b.fileID.uuidString
    }
}
