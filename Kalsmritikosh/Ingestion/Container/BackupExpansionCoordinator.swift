//
//  BackupExpansionCoordinator.swift
//  Kalsmritikosh
//
//  HOST-8c — walks an iOS backup's virtual tree, so every file inside it is
//  ingested under the path it had ON THE DEVICE rather than under its SHA-1 name.
//  HOST-8b recorded the mapping; this makes it operative.
//
//  Written as a SEPARATE coordinator, deliberately. ContainerProcessingCoordinator
//  is hardwired to ZIPContainerInspector, and its member shape is an archive
//  reader plus an entry to extract — a backup member needs no extraction at all,
//  because its bytes are already a file on disk. Branching inside that coordinator
//  would have meant editing the file that owns ZIP budgets, depth and cycle limits,
//  which is load-bearing today. Nothing in the ZIP path changes.
//
//  What it does NOT duplicate is the safety layer. Every guard here is the same
//  primitive the ZIP lane uses:
//    • ZIPContainerExtractor.isContained — a malicious `relativePath` of
//      `../../../etc/passwd` must not place a member outside the backup root.
//    • ContainerRootBudget — one shared pool, so a backup cannot exhaust
//      resources any more than a nested archive chain can.
//    • ContainerInspectionRepository — the SAME manifest + per-member disposition
//      record, so every member stays VISIBLE: admitted, blocked or failed. A
//      backup member is never silently dropped.
//

import Foundation
import OSLog

public actor BackupExpansionCoordinator {

    /// Same closure shape the container lane uses: give it the real bytes and the
    /// logical origin, get back the child's identity.
    public typealias IngestMember = ContainerProcessingCoordinator.IngestMember
    public typealias MemberIngestOutcome = ContainerProcessingCoordinator.MemberIngestOutcome

    private let repository: ContainerInspectionRepository?
    private let policy: ContainerSafetyPolicy

    public init(repository: ContainerInspectionRepository?,
                policy: ContainerSafetyPolicy = .standard) {
        self.repository = repository
        self.policy = policy
    }

    /// Expands one backup whose `Manifest.db` bytes are at `manifestURL` and whose
    /// content files live under `bundleRoot`. Every readable file entry is handed
    /// to `ingestMember` with its DEVICE path as the origin.
    ///
    /// `bundleRoot` is the folder holding the two-hex subdirectories. When it is
    /// nil — the manifest was supplied on its own — nothing is expanded and the
    /// manifest says so, rather than reporting an empty backup.
    public func expand(manifestVersionID: UUID, manifestURL: URL, bundleRoot: URL?,
                       context: ContainerTraversalContext, now: Date,
                       ingestMember: IngestMember) async {
        guard let bundleRoot else {
            do {
                _ = try await repository?.record(
                sourceVersionID: manifestVersionID, containerType: .extractionManifest,
                status: .unsupported, members: [], at: now)
            } catch {
                KalsmritikoshLog.ingestion.error("BackupExpansionCoordinator: manifest record failed — \(String(describing: error), privacy: .public)")
            }
            return
        }

        let manifest: IOSBackupManifest
        do {
            manifest = try IOSBackupManifest(
                manifestData: try Data(contentsOf: manifestURL), bundleRoot: bundleRoot)
        } catch {
            // Custody is already preserved by intake; the backup's CONTENTS could
            // not be enumerated, and "unenumerable" is not "empty".
            do {
                _ = try await repository?.record(
                sourceVersionID: manifestVersionID, containerType: .extractionManifest,
                status: .failed, members: [], at: now)
            } catch {
                KalsmritikoshLog.ingestion.error("BackupExpansionCoordinator: manifest record failed — \(String(describing: error), privacy: .public)")
            }
            return
        }

        var members: [ContainerMember] = []
        var sawProblem = false
        var ordinal = 0

        for entry in manifest.entries {
            defer { ordinal += 1 }

            func finalize(_ disposition: ContainerMemberDisposition,
                          childID: UUID? = nil, hash: String? = nil,
                          detail: String? = nil) -> ContainerMember {
                ContainerMember(
                    parentSourceVersionID: manifestVersionID, ordinal: ordinal,
                    memberPath: entry.virtualPath, normalizedMemberPath: entry.virtualPath,
                    entryKind: entry.kind == .directory ? .directory : .file,
                    // A backup stores files uncompressed, so the two sizes are one
                    // number; reporting a fake compressed size would be invented data.
                    compressedSize: entry.size ?? 0, uncompressedSize: entry.size ?? 0,
                    detectedType: SourceType.detect(from: URL(fileURLWithPath: entry.virtualPath)),
                    disposition: disposition, childSourceVersionID: childID,
                    contentHash: hash, detail: detail)
            }

            // Directories and symlinks carry no bytes. Recorded, not ingested, so
            // the manifest still shows the tree's shape.
            guard entry.kind == .file else {
                members.append(finalize(entry.kind == .directory ? .directory : .unsupported,
                                        detail: entry.kind == .symlink ? "symlink" : nil))
                continue
            }
            guard let stored = entry.storedRelativePath else {
                sawProblem = true
                members.append(finalize(.failedExtraction, detail: "no stored path for file entry"))
                continue
            }

            // The SAME path-escape guard the ZIP lane uses. A crafted domain or
            // relativePath must not resolve outside the backup root.
            let byteURL = bundleRoot.appendingPathComponent(stored)
            guard ZIPContainerExtractor.isContained(byteURL, inRoot: bundleRoot) else {
                sawProblem = true
                members.append(finalize(.blockedUnsafePath, detail: "escapes backup root"))
                continue
            }
            guard FileManager.default.fileExists(atPath: byteURL.path) else {
                // Listed in the manifest but absent on disk: a truncated or
                // partial extraction. A real finding, so it is recorded as failed
                // rather than skipped.
                sawProblem = true
                members.append(finalize(.failedExtraction,
                                        detail: "listed in manifest but missing from backup"))
                continue
            }

            // Same per-member ceiling the ZIP lane applies, so one enormous file
            // inside a backup is blocked identically rather than admitted because
            // it happened to arrive by a different route.
            if let size = entry.size, size > policy.maxSingleMemberBytes {
                sawProblem = true
                members.append(finalize(.blockedSizeLimit,
                                        detail: "exceeds per-member ceiling of "
                                              + "\(policy.maxSingleMemberBytes) bytes"))
                continue
            }

            // One shared root budget, so a backup draws from the same pool as any
            // other container traversal.
            let verdict = context.budget.reserveMember(uncompressedBytes: entry.size ?? 0)
            guard verdict == .ok else {
                sawProblem = true
                members.append(finalize(.blockedRootBudget, detail: "\(verdict)"))
                continue
            }

            // The origin is the DEVICE path — the whole point of HOST-8c. Detection,
            // citations and answers all see `HomeDomain/Library/SMS/sms.db` instead
            // of `3d0d7e5f…`.
            let origin = URL(fileURLWithPath: "/" + entry.virtualPath)
            // `.archiveMember` is the honest relation: the manifest IS the parent
            // and each device file is a member of it, exactly as a zip member is.
            let parent = SourceParentReference(parentSourceVersionID: manifestVersionID,
                                               relation: .archiveMember, ordinal: ordinal)
            let outcome = await ingestMember(byteURL, origin, parent)
            guard let childID = outcome.childSourceVersionID else {
                sawProblem = true
                members.append(finalize(.failedExtraction, detail: "member ingest failed"))
                continue
            }
            members.append(finalize(.admitted, childID: childID, hash: outcome.contentHash))
        }

        let status: ContainerManifestStatus = members.isEmpty
            ? .unsupported
            : (sawProblem ? .partial : .complete)
        do {
            _ = try await repository?.record(
            sourceVersionID: manifestVersionID, containerType: .extractionManifest,
            status: status, members: members, at: now)
        } catch {
            KalsmritikoshLog.ingestion.error("BackupExpansionCoordinator: manifest record failed — \(String(describing: error), privacy: .public)")
        }
    }
}
