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

import Foundation

/// A file offered to (or already in) a workspace's source set, with just the fields the picker and
/// the Sources list render.
public struct WorkspaceSourceCandidate: Sendable, Hashable, Identifiable {
    public let fileID: UUID
    public let filename: String
    public let parentPath: String
    public let sourceType: SourceType
    public let availability: FileAvailability
    public let ingestedAt: Date?
    public var id: UUID { fileID }

    public nonisolated init(fileID: UUID, filename: String, parentPath: String, sourceType: SourceType,
                availability: FileAvailability, ingestedAt: Date?) {
        self.fileID = fileID; self.filename = filename; self.parentPath = parentPath
        self.sourceType = sourceType; self.availability = availability; self.ingestedAt = ingestedAt
    }
}

public enum WorkspaceSourceError: Error, Equatable {
    /// None of the requested files were eligible (canonical + ingested) to add.
    case noEligibleSources
}

public actor WorkspaceSourceCoordinator {
    private let files: FilesRepository
    private let objects: KnowledgeObjectRepository
    private let workspaces: WorkspaceRepository
    private let membership: WorkspaceMembershipDeriver
    private let projection: ClaimProjectionBackfill

    public init(files: FilesRepository, objects: KnowledgeObjectRepository,
                workspaces: WorkspaceRepository, membership: WorkspaceMembershipDeriver,
                projection: ClaimProjectionBackfill) {
        self.files = files; self.objects = objects; self.workspaces = workspaces
        self.membership = membership; self.projection = projection
    }

    // MARK: - Reads

    /// Files eligible to ADD to a workspace: canonical (`aliasOf == nil`), genuinely ingested
    /// (owns ≥1 KnowledgeObject), and not already in this workspace. Deterministically ordered.
    public func candidates(for workspaceID: Workspace.ID) async throws -> [WorkspaceSourceCandidate] {
        let already = Set(try await workspaces.sourceIDs(in: workspaceID))
        let ingested = try await objects.fileIDsWithObjects()
        return (try await files.all())
            .filter { $0.aliasOf == nil && ingested.contains($0.id) && !already.contains($0.id) }
            .map(Self.candidate(from:))
            .sorted(by: Self.order)
    }

    /// The workspace's current sources, most-recently-added first (mirrors `sourceIDs` order).
    public func currentSources(in workspaceID: Workspace.ID) async throws -> [WorkspaceSourceCandidate] {
        let ids = try await workspaces.sourceIDs(in: workspaceID)     // added_at DESC
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary((try await files.all()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }.map(Self.candidate(from:))
    }

    // MARK: - Writes

    /// Add the eligible files among `fileIDs` to the workspace, then project each source's subjects
    /// and reconcile derived membership so the workspace immediately has members + producible
    /// Claims. Deduplicated + deterministic. Throws `.noEligibleSources` if nothing valid remains.
    public func addSources(_ fileIDs: Set<UUID>, to workspaceID: Workspace.ID, at now: Date) async throws {
        let ingested = try await objects.fileIDsWithObjects()
        let byID = Dictionary((try await files.all()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let valid = fileIDs.filter { id in
            guard let f = byID[id] else { return false }
            return f.aliasOf == nil && ingested.contains(id)
        }
        guard !valid.isEmpty else { throw WorkspaceSourceError.noEligibleSources }
        let ordered = valid.sorted { $0.uuidString < $1.uuidString }   // deterministic
        try await workspaces.addSources(ordered, to: workspaceID, at: now)   // atomic + touches updated_at
        for fileID in ordered {
            try await projection.projectSourceForUserAction(fileID: fileID, at: now)
        }
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
