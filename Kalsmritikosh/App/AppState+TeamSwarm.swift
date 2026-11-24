//
//  AppState+TeamSwarm.swift
//  Kalsmritikosh
//
//  Speed PERF-40 torrent (owner 2026-11-23, approved; per-case opt-in, shown to every member) — not tested yet.
//  The steps of a team swarm that touch both the team folder (App/Team/TeamSwarm.swift) and this Mac's ledger
//  (CaseTeamSwarmLedger): turn sharing on or off, start a shared import of files already in the team folder, and one
//  pass of the swarm (announce, claim a piece, read it into a partial ledger, publish it encrypted and signed, fetch and
//  merge every published piece once). A background loop runs a pass every two minutes for each case that shares.
//
//  Privacy: nothing leaves the team folder — the files read are the folder's own (checked against the manifest's
//  fingerprints), and what is written goes only into the folder, encrypted for the folder's members.
//

import Foundation
import CryptoKit
import os

/// Everything one swarm pass needs, gathered on the main actor once.
nonisolated struct TeamSwarmContext: Sendable {
    let caseID: UUID
    let link: CaseTeamLink
    let actor: String
    let file: CaseFileRepository
    let main: Database
    let ledgerURL: URL
    let vault: EvidenceVault?
    let chunker: Chunker
    let embedding: ShardEmbeddingSetup?
    let intake: InvestigationWorkspaceIntake?
    let control: IngestControl
}

/// What one pass did (shown in the Team folder tool).
nonisolated struct TeamSwarmPassResult: Sendable {
    var reachable = true
    var published = 0
    var merged = 0
    var problems: [String] = []
    var summary: String {
        guard reachable else { return "The team folder can't be reached now; the shared import continues when it is back." }
        var parts: [String] = []
        if published > 0 { parts.append("this Mac read and shared \(published) piece(s)") }
        if merged > 0 { parts.append("\(merged) piece(s) joined into this Mac's ledger") }
        if !problems.isEmpty { parts.append("\(problems.count) problem(s): \(problems.prefix(3).joined(separator: " "))") }
        return parts.isEmpty ? "Shared import: nothing new to do right now." : "Shared import: " + parts.joined(separator: "; ") + "."
    }
}

extension AppState {

    /// The context for one pass, or a plain reason why there is none.
    func teamSwarmContext(caseID: UUID, linkID: UUID, actor: String) async -> (TeamSwarmContext?, String?) {
        guard let file = caseFiles?.file, let main = database, let ingest else { return (nil, "The ledger isn't open.") }
        let link: CaseTeamLink
        do {
            guard let l = try await file.teamLinks(caseID: caseID).first(where: { $0.id == linkID }) else { return (nil, CaseTeamError.notLinked.localizedDescription) }
            link = l
        } catch {
            KalsmritikoshLog.app.error("Team swarm: links unreadable: \(error.localizedDescription, privacy: .public)")
            return (nil, error.localizedDescription)
        }
        let chunker = await ingest.chunkerConfiguration()
        let setup = await ingest.embeddingSetup()
        let setupDimension = await ingest.embeddingDimension()
        let embedding: ShardEmbeddingSetup? = {
            guard let e = setup.embedder, let id = setup.modelID else { return nil }
            return ShardEmbeddingSetup(embedder: e, modelID: id, modelVersion: setup.modelVersion ?? "1", dimension: setupDimension)
        }()
        return (TeamSwarmContext(caseID: caseID, link: link, actor: actor, file: file, main: main, ledgerURL: main.url, vault: evidenceVault,
                                 chunker: chunker, embedding: embedding, intake: investigationWorkspaceIntake, control: ingestControl), nil)
    }

    /// Turn "Share the work of this import with the team" on or off for a case's team folder, and say so in the folder.
    func setTeamSwarm(caseID: UUID, linkID: UUID, enabled: Bool, actor: String) async -> String {
        guard let file = caseFiles?.file else { return "The ledger isn't open." }
        do {
            try await file.setSwarmOptIn(caseID: caseID, linkID: linkID, enabled: enabled, actor: actor)
        } catch {
            KalsmritikoshLog.app.error("Team swarm: opt-in not saved: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
        let (ctx, why) = await teamSwarmContext(caseID: caseID, linkID: linkID, actor: actor)
        guard let ctx else { return why ?? "Saved." }
        let announced = await Task.detached(priority: .utility) { await Self.announceOptInIfNeeded(ctx) }.value
        if !announced { return enabled ? "Sharing is on for this case. The team folder can't be reached now; the team sees it once it is back." : "Sharing is off for this case." }
        return enabled
            ? "Sharing is on: big imports of files in the team folder are split among the team's Macs that have it on too. Every member sees that this case shares."
            : "Sharing is off: this Mac no longer takes pieces of shared imports for this case."
    }

    /// Open the link's folder as this Mac's member (security scope held until `release`).
    nonisolated static func openSwarmFolder(_ link: CaseTeamLink) -> (folder: TeamCase, key: Curve25519.Signing.PrivateKey, release: @Sendable () -> Void)? {
        guard let key = TeamIdentity.key(), TeamIdentity.memberID(key.publicKey) == link.memberID,
              let (url, scoped) = CaseTeamService.resolve(link.bookmark) else { return nil }
        let release: @Sendable () -> Void = { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let folder = TeamCase.open(url), folder.reachable() else { release(); return nil }
        return (folder, key, release)
    }

    /// Publish this Mac's key and say in the folder whether this case shares; true once the folder has it.
    nonisolated static func announceOptInIfNeeded(_ ctx: TeamSwarmContext) async -> Bool {
        guard let (folder, key, release) = openSwarmFolder(ctx.link) else { return false }
        defer { release() }
        do {
            if let agreement = TeamSwarmIdentity.agreementKey() {
                try folder.publishAgreementKey(member: ctx.link.memberID, signing: key, agreement: agreement)
            }
            guard let o = try await ctx.file.swarmOptIn(caseID: ctx.caseID, linkID: ctx.link.id) else { return true }
            if !o.announced {
                try folder.announceOptIn(caseLabel: ctx.link.folderLabel, on: o.enabled, member: ctx.link.memberID, key: key)
                try await ctx.file.markSwarmOptInAnnounced(caseID: ctx.caseID, linkID: ctx.link.id)
            }
            return true
        } catch {
            KalsmritikoshLog.app.error("Team swarm: sharing not announced: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// Start a shared import: the files under `root` (a folder or files INSIDE the team folder) are planned into pieces
    /// that fit one Mac's memory share and announced; this Mac then starts on them like any other member.
    func startTeamSwarmImport(caseID: UUID, linkID: UUID, roots: [URL], title: String, actor: String) async -> String {
        guard PurchaseCenter.shared.allowPaidAction("share an import with the team", importing: true) else { return "Adding documents needs Workbench." }
        let (ctxOpt, why) = await teamSwarmContext(caseID: caseID, linkID: linkID, actor: actor)
        guard let ctx = ctxOpt else { return why ?? "The ledger isn't open." }
        do {
            guard try await ctx.file.swarmOptIn(caseID: caseID, linkID: linkID)?.enabled == true else {
                return "Turn on “Share the work of this import with the team” first."
            }
        } catch {
            KalsmritikoshLog.app.error("Team swarm: opt-in unreadable: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
        let pressure = await memoryPressure?.latestReportedLevel() ?? .normal
        let started: Result<TeamSwarmAnnouncement, Error> = await Task.detached(priority: .utility) {
            guard let (folder, key, release) = Self.openSwarmFolder(ctx.link) else {
                return .failure(TeamFolderError.unreachable("it is not available now"))
            }
            defer { release() }
            for r in roots where folder.relativePath(of: r) == nil { return .failure(TeamSwarmError.notInFolder(r.lastPathComponent)) }
            let files = IngestBatchPlanner.enumerate(roots).filter { folder.relativePath(of: $0.url).flatMap(folder.sharedFile) != nil }
            let budget = WorkerBudget.current(pressure: pressure)
            let share = max(IngestBatchPlanner.minimumBytesPerBatch, budget.bytesPerWorker(count: budget.workers(perWorkerBytes: IngestWorkerPool.defaultPerWorkerBytes)))
            let batches = IngestBatchPlanner.pack(files, bytesPerBatch: share)
            do {
                if let agreement = TeamSwarmIdentity.agreementKey() {
                    try folder.publishAgreementKey(member: ctx.link.memberID, signing: key, agreement: agreement)
                }
                let note = try folder.publishSwarm(id: UUID().uuidString, title: title, pieces: batches.map { $0.files.map(\.url) },
                                                   member: ctx.link.memberID, key: key)
                return .success(note)
            } catch {
                return .failure(error)
            }
        }.value
        switch started {
        case .failure(let error):
            KalsmritikoshLog.app.error("Team swarm: shared import not started: \(error.localizedDescription, privacy: .private)")
            return error.localizedDescription
        case .success(let note):
            do {
                try await ctx.file.noteSwarm(caseID: caseID, linkID: linkID, id: note.id, title: note.title, authoredHere: true,
                                             authorMember: ctx.link.memberID, pieces: note.pieces, files: note.files, manifestSHA256: note.manifestSHA256)
            } catch {
                KalsmritikoshLog.app.error("Team swarm: shared import not recorded: \(error.localizedDescription, privacy: .public)")
            }
            Task { [weak self] in _ = await self?.runTeamSwarmPass(caseID: caseID, linkID: linkID, actor: actor) }
            return "Shared import “\(note.title)” started: \(note.files) file(s) in \(note.pieces) piece(s). Each Mac of the team that shares takes pieces; progress shows here."
        }
    }

    /// One pass for a case's folder (see the file header). Safe to run again at any time.
    @discardableResult
    func runTeamSwarmPass(caseID: UUID, linkID: UUID, actor: String) async -> TeamSwarmPassResult {
        var result = TeamSwarmPassResult()
        let (ctxOpt, why) = await teamSwarmContext(caseID: caseID, linkID: linkID, actor: actor)
        guard let ctx = ctxOpt else { result.problems.append(why ?? "not ready"); return result }
        do {
            guard try await ctx.file.swarmOptIn(caseID: caseID, linkID: linkID)?.enabled == true else { return result }
        } catch {
            KalsmritikoshLog.app.error("Team swarm: opt-in unreadable: \(error.localizedDescription, privacy: .public)")
            result.problems.append(error.localizedDescription)
            return result
        }
        let mayAdd = PaidUse.refusal("add documents", importing: true) == nil
        result = await Self.swarmPass(ctx, mayProcess: mayAdd)
        if result.merged > 0 {
            await afterShardMerges()
            await refreshRetrievalCaches()
        }
        return result
    }

    /// Every two minutes: a pass for each case that shares (nothing runs while no case has it on).
    nonisolated static let teamSwarmLoopStarted = OSAllocatedUnfairLock(initialState: false)

    func startTeamSwarmLoop() {
        guard Self.teamSwarmLoopStarted.withLock({ started in let first = !started; started = true; return first }) else { return }
        // Fix (AI-50 hard eval, 2026-11-24): the loop is this state's, so shutdown() cancels it and frees the slot.
        let loop = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, !self.isShutDown else { return }
                guard let file = self.caseFiles?.file else { continue }
                let on: [CaseTeamSwarmOptIn]
                do { on = try await file.swarmOptInsEnabled() } catch {
                    KalsmritikoshLog.app.error("Team swarm: opt-ins unreadable: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                for o in on where !(await self.ingestControl.isStopped) {
                    let r = await self.runTeamSwarmPass(caseID: o.caseID, linkID: o.linkID, actor: o.changedBy)
                    if r.published + r.merged > 0 { KalsmritikoshLog.app.info("Team swarm pass: \(r.published, privacy: .public) published, \(r.merged, privacy: .public) merged") }
                }
            }
        }
        onShutdown { [loop] in
            loop.cancel()
            Self.teamSwarmLoopStarted.withLock { $0 = false }
        }
    }

    // MARK: The pass (off the main actor)

    nonisolated static func swarmPass(_ ctx: TeamSwarmContext, mayProcess: Bool) async -> TeamSwarmPassResult {
        var out = TeamSwarmPassResult()
        guard let (folder, key, release) = openSwarmFolder(ctx.link) else { out.reachable = false; return out }
        defer { release() }
        let me = ctx.link.memberID
        let agreement = TeamSwarmIdentity.agreementKey()
        if let agreement {
            do { try folder.publishAgreementKey(member: me, signing: key, agreement: agreement) } catch {
                KalsmritikoshLog.app.error("Team swarm: key not published: \(error.localizedDescription, privacy: .private)")
            }
        }
        // Say in the folder whether this case shares (once per change).
        if !(await announceOptInIfNeeded(ctx)) { out.problems.append("sharing could not be announced in the folder") }
        let teamCaseID = folder.teamCaseID ?? ctx.link.teamCaseID
        var entries = folder.verifiedEntries().entries
        for s in folder.swarms(in: entries) {
            do {
                try await ctx.file.noteSwarm(caseID: ctx.caseID, linkID: ctx.link.id, id: s.note.id, title: s.note.title,
                                             authoredHere: s.author == me, authorMember: s.author, pieces: s.note.pieces,
                                             files: s.note.files, manifestSHA256: s.note.manifestSHA256)
            } catch {
                KalsmritikoshLog.app.error("Team swarm: swarm not recorded: \(error.localizedDescription, privacy: .public)")
                continue
            }
            // 1. Work: claim and read pieces while there are open ones (one piece at a time on this Mac).
            if mayProcess {
                while !(await ctx.control.isStopped) {
                    let notes = folder.shardNotes(swarmID: s.note.id, in: entries)
                    let published = (try? await ctx.file.publishedSwarmPieces(swarmID: s.note.id)) ?? []
                    guard let (piece, duplicate) = nextPiece(s.manifest, notes: notes, published: published, folder: folder, me: me) else { break }
                    guard folder.claim(swarmID: s.note.id, piece: piece.index, member: me, key: key, duplicate: duplicate) else { continue }
                    do {
                        try await ctx.file.setSwarmPiece(caseID: ctx.caseID, swarmID: s.note.id, piece: piece.index, state: "claimed",
                                                         byMember: nil, byMe: false, claimedHere: true)
                    } catch {
                        KalsmritikoshLog.app.error("Team swarm: claim not recorded: \(error.localizedDescription, privacy: .public)")
                    }
                    do {
                        _ = try await processPiece(ctx, folder: folder, key: key, teamCaseID: teamCaseID, swarmID: s.note.id, piece: piece)
                        out.published += 1
                        try await ctx.file.setSwarmPiece(caseID: ctx.caseID, swarmID: s.note.id, piece: piece.index, state: "published",
                                                         byMember: nil, byMe: false, publishedHere: true)
                    } catch {
                        KalsmritikoshLog.app.error("Team swarm: piece \(piece.index, privacy: .public) not shared: \(error.localizedDescription, privacy: .private)")
                        out.problems.append("piece \(piece.index + 1): \(error.localizedDescription)")
                        do {
                            try await ctx.file.setSwarmPiece(caseID: ctx.caseID, swarmID: s.note.id, piece: piece.index, state: "failed",
                                                             byMember: nil, byMe: false, publishedHere: true, detail: String(error.localizedDescription.prefix(300)))
                        } catch {
                            KalsmritikoshLog.app.error("Team swarm: failure not recorded: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    entries = folder.verifiedEntries().entries
                }
            }
            // 2. Merge: every published piece once, the first published copy of each.
            if mayProcess, let agreement {
                out.merged += await mergePublished(ctx, folder: folder, swarm: s.manifest, title: s.note.title,
                                                   notes: folder.shardNotes(swarmID: s.note.id, in: entries),
                                                   teamCaseID: teamCaseID, agreement: agreement, problems: &out.problems)
            }
            let notes = folder.shardNotes(swarmID: s.note.id, in: entries)
            let state = notes.count >= s.manifest.pieces.count ? "done" : "running"
            do { try await ctx.file.setSwarmState(caseID: ctx.caseID, id: s.note.id, state: state, error: out.problems.last) } catch {
                KalsmritikoshLog.app.error("Team swarm: state not recorded: \(error.localizedDescription, privacy: .public)")
            }
        }
        return out
    }

    /// The next piece for this Mac: an open, unclaimed piece (starting at a place that differs per member, so Macs rarely
    /// race for the same one); in the endgame (every piece claimed, at most two left), a duplicate of the piece claimed
    /// longest ago by someone else, once.
    nonisolated static func nextPiece(_ m: TeamSwarmManifest, notes: [Int: [TeamSigned<TeamSwarmShardNote>]], published: Set<Int>,
                                      folder: TeamCase, me: String) -> (TeamSwarmPiece, Bool)? {
        let open = m.pieces.filter { notes[$0.index] == nil && !published.contains($0.index) }
        guard !open.isEmpty else { return nil }
        let start = Int(TeamSwarmIDs.uuid(from: me).uuid.0) % open.count
        let rotated = Array(open[start...] + open[..<start])
        var claimedByOthers: [(TeamSwarmPiece, Double)] = []
        for p in rotated {
            let claims = folder.validClaims(swarmID: m.id, piece: p.index).filter { !$0.duplicate }
            if claims.isEmpty { return (p, false) }
            if claims.contains(where: { $0.member == me }) { continue }
            claimedByOthers.append((p, claims[0].claimedAt))
        }
        guard open.count <= 2, let oldest = claimedByOthers.min(by: { $0.1 < $1.1 }) else { return nil }
        let mine = folder.validClaims(swarmID: m.id, piece: oldest.0.index).contains { $0.member == me }
        return mine ? nil : (oldest.0, true)
    }

    /// Read one piece into a partial ledger under a fresh piece key and publish it.
    nonisolated static func processPiece(_ ctx: TeamSwarmContext, folder: TeamCase, key: Curve25519.Signing.PrivateKey,
                                         teamCaseID: String, swarmID: String, piece: TeamSwarmPiece) async throws -> TeamSwarmShardNote {
        // Only the folder's own files, exactly as the manifest lists them.
        var urls: [URL] = []
        for f in piece.files {
            guard let u = folder.sharedFile(f.path) else { throw TeamSwarmError.notShared(f.path) }
            let digest: String = try await VolumeReadLanes.withRead(u) {
                try await Task.detached(priority: .utility) { try StreamingFileCopy.hash(u).sha256 }.value
            }
            guard digest == f.sha256 else { throw TeamSwarmError.changed((f.path as NSString).lastPathComponent) }
            urls.append(u)
        }
        let pieceKey = LedgerKey.random()
        let outRun = TeamSwarmIDs.uuid(from: "out|" + swarmID)
        let shard = try await ShardLedger.open(runID: outRun, index: piece.index, besideLedgerAt: ctx.ledgerURL, key: pieceKey)
        var written = 0
        do {
            let coordinator = try await IngestStackBuilder.makeConfiguredCoordinator(database: shard.database, vault: ctx.vault,
                                                                                    chunker: ctx.chunker, embedding: ctx.embedding)
            for u in urls {
                guard await ctx.control.checkpoint() else { break }
                folder.renewClaim(swarmID: swarmID, piece: piece.index, member: ctx.link.memberID, key: key)
                let ext = u.pathExtension.lowercased()
                let budget: Double = ["mbox", "pst", "nsf", "zip", "mbx"].contains(ext) ? 3600 : 180
                do {
                    _ = try await VolumeReadLanes.withRead(u) { try await AppState.withFileTimeout(budget) { try await coordinator.ingest(fileAt: u) } }
                    written += 1
                } catch {
                    KalsmritikoshLog.ingestion.error("Team swarm: \(u.lastPathComponent, privacy: .private) not read: \(String(describing: error), privacy: .private)")
                }
            }
            if ctx.embedding != nil { await coordinator.drainEmbeddingsNow() }
            await coordinator.shutdown()
        } catch {
            await shard.close()
            ShardLedger.removeFiles(at: shard.url)
            throw error
        }
        await shard.close()
        defer { ShardLedger.removeFiles(at: shard.url) }
        guard written == urls.count else { throw TeamFolderError.missingInput(name: "\(urls.count - written) file(s) of piece \(piece.index + 1)") }
        let marks = ShardLedger.loadSeedMarks(for: shard.url)
        return try folder.publishShard(swarmID: swarmID, piece: piece.index, shardURL: shard.url, pieceKey: pieceKey, seedMarks: marks,
                                       files: written, teamCaseID: teamCaseID, member: ctx.link.memberID, key: key)
    }

    /// Fetch, re-key and merge every published piece this Mac has not merged yet; the merged files join the case.
    nonisolated static func mergePublished(_ ctx: TeamSwarmContext, folder: TeamCase, swarm: TeamSwarmManifest, title: String,
                                           notes: [Int: [TeamSigned<TeamSwarmShardNote>]], teamCaseID: String,
                                           agreement: Curve25519.KeyAgreement.PrivateKey, problems: inout [String]) async -> Int {
        let me = ctx.link.memberID
        let done = (try? await ctx.file.mergedSwarmPieces(swarmID: swarm.id)) ?? []
        let mergeRun = TeamSwarmIDs.uuid(from: "in|" + swarm.id)
        let merger = ShardMerger(main: ctx.main)
        var merged = 0
        for piece in swarm.pieces {
            guard let winner = notes[piece.index]?.first, !done.contains(piece.index) else { continue }
            if await ctx.control.isStopped { break }
            let target = ShardLedger.fileURL(runID: mergeRun, index: piece.index, besideLedgerAt: ctx.ledgerURL)
            let incoming = target.deletingLastPathComponent().appendingPathComponent("incoming", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
                let (encrypted, pieceKey) = try folder.fetchShard(winner.value, teamCaseID: teamCaseID, member: me, agreement: agreement, into: incoming)
                defer {
                    do { try FileManager.default.removeItem(at: incoming) } catch {
                        KalsmritikoshLog.storage.debug("Team swarm: incoming copy not removed: \(error.localizedDescription, privacy: .private)")
                    }
                }
                try LedgerCipher.rekeyedCopy(from: encrypted, key: pieceKey, to: target, newKey: ctx.main.key)
                try JSONEncoder().encode(winner.value.seedMarks).write(to: ShardLedger.seedURL(for: target), options: .atomic)
                try await ctx.main.recordShard(runID: mergeRun, index: piece.index, path: target.path, state: "written", files: winner.value.files)
            } catch {
                KalsmritikoshLog.storage.error("Team swarm: piece \(piece.index, privacy: .public) not fetched: \(error.localizedDescription, privacy: .private)")
                problems.append("piece \(piece.index + 1) not fetched: \(error.localizedDescription)")
                continue
            }
            switch await merger.merge(runID: mergeRun, index: piece.index, shardURL: target) {
            case .merged:
                merged += 1
                do {
                    try await ctx.file.setSwarmPiece(caseID: ctx.caseID, swarmID: swarm.id, piece: piece.index, state: "merged",
                                                     byMember: winner.member, byMe: winner.member == me)
                } catch {
                    KalsmritikoshLog.app.error("Team swarm: merged piece not recorded: \(error.localizedDescription, privacy: .public)")
                }
                await admitToCase(ctx, piece: piece, by: winner.memberName, title: title)
            case .failed(let why):
                problems.append("piece \(piece.index + 1) not joined: \(why.prefix(160))")
            }
        }
        return merged
    }

    /// The merged files join the case as team-folder documents (found by their fingerprints, so a file this Mac already
    /// held stays one document).
    nonisolated static func admitToCase(_ ctx: TeamSwarmContext, piece: TeamSwarmPiece, by name: String, title: String) async {
        guard let intake = ctx.intake else { return }
        for f in piece.files {
            do {
                guard let version = try await ctx.main.query(
                    "SELECT id FROM source_versions WHERE lower(content_hash) = ? ORDER BY is_current DESC LIMIT 1;", [.text(f.sha256.lowercased())]
                ).first?.uuid(0) else { continue }
                let provenance = "Read by \(name)'s Mac in the shared import “\(title)” through the team folder “\(ctx.link.folderLabel)”"
                _ = try await intake.admitTeamSubmission(caseID: ctx.caseID, version: version, label: (f.path as NSString).lastPathComponent,
                                                         provenance: provenance, suppliedBy: name, receivedAt: Date(), include: true,
                                                         byPolicy: false, note: nil, actor: ctx.actor, at: Date())
            } catch {
                KalsmritikoshLog.app.error("Team swarm: a merged file did not join the case: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Erasure

    /// Before a case erasure: the swarm files this Mac wrote for the case (read now; the rows go with the erasure).
    func teamSwarmFootprint(caseID: UUID) async -> [(link: CaseTeamLink, swarms: [String], authored: Set<String>)] {
        guard let file = caseFiles?.file else { return [] }
        do { return try await file.swarmFootprint(caseID: caseID) } catch {
            KalsmritikoshLog.app.error("Team swarm: erasure footprint unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// After the erasure committed: remove those files from the team folders. Returns what is left behind (residue).
    nonisolated static func eraseTeamSwarmFiles(_ footprint: [(link: CaseTeamLink, swarms: [String], authored: Set<String>)]) -> [String] {
        var residue: [String] = []
        for f in footprint {
            guard let (folder, key, release) = openSwarmFolder(f.link) else {
                residue.append("team folder “\(f.link.folderLabel)” could not be reached: its shared-import files from this Mac are still there")
                continue
            }
            residue += folder.eraseSwarmFiles(swarmIDs: f.swarms, authored: f.authored, member: f.link.memberID, key: key)
            release()
        }
        return residue
    }
}
