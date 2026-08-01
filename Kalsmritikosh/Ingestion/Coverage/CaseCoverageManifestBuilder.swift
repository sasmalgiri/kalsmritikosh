//
//  CaseCoverageManifestBuilder.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-007 §19/§23/§25/§26) — assembles the deterministic CaseCoverageManifest from the existing
//  authorities. It performs NO writes, copies NO evidence, adds NO membership, and produces NO overall
//  percentage. Two identical database states yield an identical manifest apart from `generatedAt`. Reuses
//  SourceReadinessSnapshot / SourceCompletionState verbatim (no second readiness vocabulary). No LLM.
//

import Foundation

public struct CaseCoverageManifestBuilder: Sendable {

    private let repo: CaseCoverageRepository
    private let readiness: SourceReadinessRepository?
    private let container: ContainerInspectionRepository

    public init(repository: CaseCoverageRepository, readiness: SourceReadinessRepository?, container: ContainerInspectionRepository) {
        self.repo = repository
        self.readiness = readiness
        self.container = container
    }

    public func build(workspaceID: UUID, generatedAt: Date) async throws -> CaseCoverageManifest {
        guard let wsUpdated = try await repo.workspaceUpdatedAt(workspaceID) else {
            throw CaseCoverageError.workspaceNotFound(workspaceID)
        }
        var limitations: [String] = []
        var unavailable = 0

        // 1. Direct roots → current versions (aliases canonicalized).
        var rootVersions: [(version: UUID, path: String)] = []
        for fileID in try await repo.directRootFileIDs(workspaceID) {
            if let meta = try await repo.currentVersion(forFileID: fileID) {
                rootVersions.append((meta.sourceVersionID, "root:\(meta.sourceType.rawValue)"))
            } else {
                unavailable += 1
                limitations.append("Direct source \(fileID.uuidString.prefix(8)) has no resolvable current version.")
            }
        }

        // 2. Coverage closure through descendants (archiveMember / attachment / message / embedded).
        let reached = await CaseCoverageScopeResolver.resolve(roots: rootVersions) { v in
            (try? await repo.descendants(of: v, relations: CaseCoverageScopeResolver.coverageRelations)) ?? []
        }

        // 3. Items (deterministic order by version id).
        var items: [CaseCoverageItem] = []
        var unadmitted: [UnadmittedContainerMemberItem] = []
        var admittedMembers = 0, notAdmittedMembers = 0, discoveredMembers = 0, safetyBlocked = 0

        for vid in reached.order.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let meta = try await repo.versionMeta(sourceVersionID: vid) else {
                unavailable += 1
                limitations.append("Source version \(vid.uuidString.prefix(8)) is unavailable.")
                continue
            }
            let snap = try? await readiness?.snapshot(sourceVersionID: vid)
            items.append(CaseCoverageItem(
                logicalSourceID: meta.logicalSourceID, sourceVersionID: vid, sourceType: meta.sourceType,
                isDirectRoot: reached.directRoots.contains(vid), parentPaths: (reached.pathsByVersion[vid] ?? []).sorted(),
                completionState: snap?.completionState ?? .preservedOnly,
                isSearchReady: snap?.isSearchReady ?? false, isEvidenceReady: snap?.isEvidenceReady ?? false,
                isAnalyticallyReady: snap?.isAnalyticallyReady ?? false,
                limitations: (snap?.limitations ?? []).map { "\(String(describing: $0.dimension)): \(String(describing: $0.state))" }.sorted(),
                blockers: (snap?.blockers ?? []).map { "\(String(describing: $0.dimension)): \(String(describing: $0.condition))" }.sorted(),
                custodyMode: meta.custodyMode, preservationStatus: meta.preservationStatus))

            // Container coverage for an archive source version.
            if meta.sourceType.category == .archive {
                if let manifest = try await container.manifest(sourceVersionID: vid) {
                    admittedMembers += manifest.admittedMembers
                    let notAdmitted = manifest.blockedMembers + manifest.unsupportedMembers + manifest.failedMembers
                    notAdmittedMembers += notAdmitted
                    discoveredMembers += manifest.regularFileEntries
                    for m in try await container.members(parentSourceVersionID: vid)
                    where m.disposition != .admitted && m.disposition != .directory {
                        if m.disposition.isBlocked { safetyBlocked += 1 }
                        unadmitted.append(UnadmittedContainerMemberItem(
                            parentSourceVersionID: vid, memberID: m.id, memberPath: m.memberPath,
                            detectedType: m.detectedType, disposition: m.disposition, detail: m.detail))
                    }
                } else {
                    // §27 — an archive with no v87 manifest is NOT "0 members"; it is not-yet-inspected.
                    limitations.append("Container \(vid.uuidString.prefix(8)) has not been inspected (container inspection missing).")
                }
            }
        }

        // 4. Counts (no overall percentage — explicit states only).
        func count(_ predicate: (CaseCoverageItem) -> Bool) -> Int { items.filter(predicate).count }
        let summary = CaseCoverageSummary(
            directRoots: items.filter(\.isDirectRoot).count,
            canonicalSources: items.count,
            sourceOccurrences: reached.pathsByVersion.values.reduce(0) { $0 + $1.count },
            containerMembersDiscovered: discoveredMembers,
            containerMembersAdmitted: admittedMembers,
            containerMembersNotAdmitted: notAdmittedMembers,
            searchable: count { $0.isSearchReady },
            evidenceReady: count { $0.isEvidenceReady },
            analyticallyReady: count { $0.isAnalyticallyReady },
            preservedOnly: count { $0.completionState == .preservedOnly },
            deferred: count { $0.completionState == .deferred },
            encrypted: count { $0.completionState == .encrypted },
            corrupt: count { $0.completionState == .corrupt },
            unsupported: count { $0.completionState == .unsupported },
            failed: count { $0.completionState == .failed },
            safetyBlocked: safetyBlocked,
            unavailable: unavailable)

        let sortedUnadmitted = unadmitted.sorted {
            ($0.parentSourceVersionID.uuidString, $0.memberPath) < ($1.parentSourceVersionID.uuidString, $1.memberPath)
        }
        return CaseCoverageManifest(
            workspaceID: workspaceID, workspaceUpdatedAt: wsUpdated, generatedAt: generatedAt,
            directRoots: items.filter(\.isDirectRoot), canonicalSources: items,
            unadmittedContainerMembers: sortedUnadmitted, summary: summary,
            limitations: limitations.sorted(), blockers: [])
    }
}
