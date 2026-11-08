//
//  InvestigationWorkspaceIntake.swift
//  Kalsmritikosh
//
//  A case opened over a workspace takes in that workspace's documents — and the attachments and
//  archive members inside them — as in-scope sources, each inclusion recorded in the case's audit.
//
//  FOUND BY THE CASE BENCH, 2026-10-20 (AI-1000, investigation workflow). The case engine only
//  answers from sources included in the case, but nothing in the app ever included one: a case
//  created from the persona job screen had zero authorized sources, so its questions had nothing
//  to answer from and its findings report was empty. And an included email or ZIP authorized only
//  the container itself, never the PDF attached to it.
//
//  Inclusion stays explicit and auditable: this runs when a case is opened over a workspace, and
//  later through the person's explicit "Review new documents" (investigator workflow review
//  2026-10-30, I1): `preview` shows what is new — each version, what it is inside, and what stays
//  excluded — and `include` authorises only what they approve. Reopening a matter never includes
//  anything. Every source authorised is a recorded `includeSource` with a note saying why; a
//  deliberately excluded source is never re-included; an inclusion bumps the case revision, so every
//  approval bound to the earlier scope fingerprint (findings) is stale from then on.
//
//  Smart map S2 (2026-11-08, IN-01 / IN-05 / IN-07 / IN-12):
//  • Every inclusion or exclusion here first writes the case-intake contract record (CaseIntakeLedger): channel,
//    provenance, who entered it, when it was actually received, and who decided — a person, or a NAMED policy.
//  • Opening a case is a named trusted-source policy ("Documents in the case's workspace when the case was opened") that
//    covers only what the workspace held at that moment; a document added or revised later always goes to the review.
//  • A person's channel-arrival policy (e.g. "items shared to the app") includes later arrivals of that channel
//    automatically, each naming the policy; it never re-includes an exclusion and never reaches back before it was made.
//  • Items shared to the app (Share menu), captured, or imported from a device after the case was opened are offered in
//    the case's review; approving one adds it to the case's workspace and the case. Exclusions persist.
//  • `intakeList` is the per-item case intake list: inclusion state (pending review / included / excluded), processing
//    stage from the readiness ledger, and the remedy for anything not available; `reconciliation` ties the case's
//    coverage back to the batch receipts that took its documents in.
//

import Foundation
import os

/// One source version the case's workspace holds that the case has not decided on yet.
public nonisolated struct PendingCaseSource: Sendable, Hashable, Identifiable {
    public var id: UUID { sourceVersionID }
    public let sourceVersionID: UUID
    /// The file name it was read from.
    public let label: String
    /// Added to the workspace directly (true) or found inside a workspace document (false).
    public let isRoot: Bool
    /// The containing version when `isRoot` is false.
    public let parentVersionID: UUID?
    public let parentLabel: String?
    /// IN-01 — the channel the document (or the document holding it) arrived through; nil when not recorded.
    public var channel: IntakeChannel? = nil
    /// IN-05 — sent to the app (Share menu, capture, device import) and not yet in the case's workspace: approving it adds
    /// it to the workspace and the case.
    public var offeredFromChannel: Bool = false
}

/// A source the case has deliberately excluded; it stays excluded through any inclusion.
public nonisolated struct ExcludedCaseSource: Sendable, Hashable, Identifiable {
    public var id: String { sourceRef }
    public let sourceRef: String
    public let label: String
    public let note: String?
}

/// What approving an inclusion would do — shown before anything is authorised.
public nonisolated struct CaseInclusionPreview: Sendable, Equatable, Identifiable {
    /// One preview per case revision (a sheet shown for it is for that state).
    public var id: String { "\(caseID.uuidString)@\(caseRevision)" }
    public let caseID: UUID
    public let caseRevision: Int
    /// Sources already in scope.
    public let inScope: Int
    /// New in the workspace, not yet decided — what approval would include.
    public let pending: [PendingCaseSource]
    /// Deliberately excluded; they stay excluded.
    public let excluded: [ExcludedCaseSource]
    /// IN-05 — the case's active trusted-source policies (what is included without this review, by name).
    public var activePolicies: [CaseIntakePolicy] = []
    public var hasChanges: Bool { !pending.isEmpty }
}

/// One node of the walk over a workspace's documents and what is inside them.
nonisolated struct WorkspaceWalkNode: Sendable, Hashable {
    let version: UUID
    let root: Bool
    let parent: UUID?
    /// The workspace document this one is (or is inside).
    let rootVersion: UUID
    let rootFile: UUID?
}

public struct InvestigationWorkspaceIntake: Sendable {
    private let cases: InvestigationCaseRepository
    private let workspaces: WorkspaceRepository
    private let coverage: CaseCoverageRepository
    /// IN-01 / IN-05 — the contract record of every inclusion, and the case's trusted-source policies.
    public let ledger: CaseIntakeLedger
    /// IN-12 — the batch receipts (how and when each version arrived).
    public let receipts: IntakeReceiptRepository

    public init(cases: InvestigationCaseRepository, workspaces: WorkspaceRepository, coverage: CaseCoverageRepository) {
        self.cases = cases; self.workspaces = workspaces; self.coverage = coverage
        self.ledger = CaseIntakeLedger(database: cases.intakeDatabase)
        self.receipts = IntakeReceiptRepository(database: cases.intakeDatabase)
    }

    /// What the case's workspace holds that the case has not yet decided on, with what stays excluded.
    /// Reads only; authorises nothing.
    public func preview(caseID: UUID) async throws -> CaseInclusionPreview {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        let decided = Set(record.sources.map(\.sourceRef))
        let walk = try await walkWorkspace(record.caseHeader.workspaceID)
        let undecided = walk.filter { !decided.contains($0.version.uuidString) }
        let offered = try await offeredArrivals(since: record.caseHeader.createdAt, inWorkspace: Set(walk.map(\.version)), decided: decided)
        let excludedRefs = record.sources.filter { !$0.inScope }
        let arrivals = try await receipts.arrivals(of: Set(undecided.map(\.rootVersion)))
        let labels = try await coverage.labels(for: undecided.flatMap { [$0.version] + ($0.parent.map { [$0] } ?? []) }
                                               + offered.map(\.sourceVersionID)
                                               + excludedRefs.compactMap { UUID(uuidString: $0.sourceRef) })
        var pending = undecided.map { item in
            PendingCaseSource(sourceVersionID: item.version, label: labels[item.version] ?? "Source \(item.version.uuidString.prefix(8))",
                              isRoot: item.root, parentVersionID: item.parent,
                              parentLabel: item.parent.flatMap { labels[$0] }, channel: arrivals[item.rootVersion]?.channel)
        }
        pending += offered.map { a in
            PendingCaseSource(sourceVersionID: a.sourceVersionID, label: labels[a.sourceVersionID] ?? "Source \(a.sourceVersionID.uuidString.prefix(8))",
                              isRoot: true, parentVersionID: nil, parentLabel: nil, channel: a.channel, offeredFromChannel: true)
        }
        let excluded = excludedRefs.map { s in
            ExcludedCaseSource(sourceRef: s.sourceRef, label: UUID(uuidString: s.sourceRef).flatMap { labels[$0] } ?? s.sourceRef, note: s.note)
        }
        let policies = try await ledger.policies(caseID: caseID).filter(\.isActive)
        return CaseInclusionPreview(caseID: caseID, caseRevision: record.caseHeader.revision,
                                    inScope: record.sources.filter(\.inScope).count, pending: pending, excluded: excluded,
                                    activePolicies: policies)
    }

    /// Include the documents the case's workspace holds now — the files added to it and, through the source-version graph,
    /// everything inside them (archive members, attachments, mailbox messages, embedded files; the same closure the case
    /// coverage manifest uses) — under the case's opening policy. IN-05: the policy is created the first time, covers only
    /// what the workspace held at that moment (a document added, or a version read, later is left for the review), and each
    /// inclusion names it. A withdrawn opening policy includes nothing. Returns the updated case and the count included.
    @discardableResult
    public func includeWorkspaceSources(caseID: UUID, actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var current = record.caseHeader
        guard let opening = try await ledger.openingPolicyRecord(caseID: caseID, actor: actor, at: date) else {
            return (current, 0)
        }
        let policy = opening.policy, createdNow = opening.createdNow
        let decided = Set(record.sources.map(\.sourceRef))
        let walk = try await walkWorkspace(current.workspaceID)
        // What the policy covers is fixed by the ledger's own order, not by comparing clocks: when the policy is first
        // recorded, every document the workspace holds then (in its current version) is covered; afterwards, only the
        // workspace documents it already included — so their contents read later still come in, while a document added
        // later, or a new version of one, goes to the review.
        let coveredRoots: Set<UUID>
        if createdNow {
            coveredRoots = Set(walk.filter(\.root).map(\.rootVersion))
        } else {
            coveredRoots = try await ledger.versionsIncluded(byPolicy: policy.id).intersection(Set(walk.filter(\.root).map(\.rootVersion)))
        }
        let received = try await ledger.receivedAt(walk.map(\.version))
        let arrivals = try await receipts.arrivals(of: coveredRoots)
        let todo = walk.filter { coveredRoots.contains($0.rootVersion) && !decided.contains($0.version.uuidString) }
        let labels = try await coverage.labels(for: todo.flatMap { [$0.version] + ($0.parent.map { [$0] } ?? []) })
        var included = 0
        for item in todo {
            let where_ = item.root ? "in the case's workspace" : "inside a workspace document (attachment, archive member or message)"
            current = try await admit(caseID: caseID, expectedRevision: current.revision, version: item.version,
                                      label: labels[item.version] ?? "", channel: arrivals[item.rootVersion]?.channel ?? .workspace,
                                      provenance: item.root ? "In the case's workspace when the case was opened"
                                                            : "Inside \(item.parent.flatMap { labels[$0] } ?? "a workspace document")",
                                      runID: arrivals[item.rootVersion]?.runID, receivedAt: received[item.version] ?? date,
                                      note: "Included automatically under the policy “\(policy.name)” (\(where_))",
                                      decision: .included, via: .policy, policyID: policy.id, actor: actor, at: date)
            included += 1
        }
        return (current, included)
    }

    /// Include what the person approved: the pending versions in `approved` (nil = every pending one).
    /// A version already decided — included or excluded — is left exactly as it is; a version not
    /// in the workspace's current closure (or offered from a channel) is ignored. An approved item offered from a channel
    /// is first added to the case's workspace. Returns the updated case and the count included.
    @discardableResult
    public func include(caseID: UUID, approved: Set<UUID>?, actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        try await decide(caseID: caseID, chosen: approved, decision: .included, note: nil, actor: actor, at: date)
    }

    /// IN-05 — exclude what the person chose from the pending documents (or offered items), with the reason. The exclusion
    /// is recorded in the case and in the intake record, and it persists: no review or policy includes it again (only the
    /// person, through the case's own scope controls).
    @discardableResult
    public func exclude(caseID: UUID, versions: Set<UUID>, note: String, actor: String, at date: Date) async throws -> (case: InvestigationCase, excluded: Int) {
        let reason = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw CaseIntakeError.blankReason }
        guard !versions.isEmpty else {
            guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
            return (record.caseHeader, 0)
        }
        let (updated, count) = try await decide(caseID: caseID, chosen: versions, decision: .excluded, note: reason, actor: actor, at: date)
        return (updated, count)
    }

    /// The person's decision on pending documents (`chosen` nil = all of them).
    private func decide(caseID: UUID, chosen: Set<UUID>?, decision: CaseIntakeDecision, note: String?,
                        actor: String, at date: Date) async throws -> (case: InvestigationCase, included: Int) {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var current = record.caseHeader
        // Already decided either way (included, or deliberately excluded): left as it is.
        let decided = Set(record.sources.map(\.sourceRef))
        let walk = try await walkWorkspace(current.workspaceID)
        let todo = walk.filter { !decided.contains($0.version.uuidString) && (chosen?.contains($0.version) ?? true) }
        let offered = try await offeredArrivals(since: current.createdAt, inWorkspace: Set(walk.map(\.version)), decided: decided)
            .filter { chosen?.contains($0.sourceVersionID) ?? true }
        guard !todo.isEmpty || !offered.isEmpty else { return (current, 0) }
        let arrivals = try await receipts.arrivals(of: Set(todo.map(\.rootVersion)))
        let received = try await ledger.receivedAt(todo.map(\.version) + offered.map(\.sourceVersionID))
        let labels = try await coverage.labels(for: todo.flatMap { [$0.version] + ($0.parent.map { [$0] } ?? []) } + offered.map(\.sourceVersionID))
        var count = 0
        for item in todo {
            current = try await admit(caseID: caseID, expectedRevision: current.revision, version: item.version,
                                      label: labels[item.version] ?? "", channel: arrivals[item.rootVersion]?.channel ?? .workspace,
                                      provenance: item.root ? "In the case's workspace"
                                                            : "Inside \(item.parent.flatMap { labels[$0] } ?? "a workspace document")",
                                      runID: arrivals[item.rootVersion]?.runID, receivedAt: received[item.version] ?? date,
                                      note: note ?? (item.root ? "In the case's workspace" : "Inside a workspace document (attachment, archive member or message)"),
                                      decision: decision, via: .person, policyID: nil, actor: actor, at: date)
            count += 1
        }
        if !offered.isEmpty {
            // An included offered item joins the case's workspace (the person chose it for this case); an excluded one does not.
            var logical: [UUID: UUID] = [:]
            if decision == .included { logical = try await coverage.logicalSources(for: offered.map(\.sourceVersionID)) }
            for a in offered {
                if decision == .included, let file = logical[a.sourceVersionID] {
                    try await workspaces.addSource(file, to: current.workspaceID, at: date)
                }
                current = try await admit(caseID: caseID, expectedRevision: current.revision, version: a.sourceVersionID,
                                          label: labels[a.sourceVersionID] ?? "", channel: a.channel,
                                          provenance: "\(a.channel.label), received \(ISO8601DateFormatter().string(from: a.at))",
                                          runID: a.runID, receivedAt: received[a.sourceVersionID] ?? a.at,
                                          note: note ?? "\(a.channel.label); approved for this case", decision: decision, via: .person,
                                          policyID: nil, actor: actor, at: date)
                count += 1
            }
        }
        return (current, count)
    }

    /// IN-05 — apply every active channel-arrival policy: a document that arrived through the policy's channel after the
    /// policy was made, and that its case has not decided on, is included (added to the case's workspace if it is not there
    /// yet), together with what is inside it, each inclusion naming the policy. Never re-includes an exclusion; one case's
    /// failure does not stop the others. Returns how many sources were included.
    @discardableResult
    public func applyArrivalPolicies(at date: Date) async -> Int {
        var total = 0
        let policies: [CaseIntakePolicy]
        do { policies = try await ledger.activeArrivalPolicies() } catch {
            KalsmritikoshLog.app.error("Trusted-source policies unreadable: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        for policy in policies {
            do {
                total += try await applyArrivalPolicy(policy, at: date)
            } catch {
                KalsmritikoshLog.app.error("Trusted-source policy not applied: \(error.localizedDescription, privacy: .public)")
            }
        }
        return total
    }

    private func applyArrivalPolicy(_ policy: CaseIntakePolicy, at date: Date) async throws -> Int {
        guard let record = try await cases.fetch(caseID: policy.caseID) else { return 0 }
        var current = record.caseHeader
        let decided = Set(record.sources.map(\.sourceRef))
        let arrivals = try await receipts.channelArrivals(channels: [policy.channel], since: policy.createdAt)
            .filter { !decided.contains($0.sourceVersionID.uuidString) }
        guard !arrivals.isEmpty else { return 0 }
        let inWorkspace = Set(try await walkWorkspace(current.workspaceID).map(\.version))
        let logical = try await coverage.logicalSources(for: arrivals.map(\.sourceVersionID))
        var count = 0
        for a in arrivals {
            if !inWorkspace.contains(a.sourceVersionID), let file = logical[a.sourceVersionID] {
                try await workspaces.addSource(file, to: current.workspaceID, at: date)
            }
            // The document and what is inside it, each once, each not yet decided.
            var nodes: [(version: UUID, parent: UUID?)] = [(a.sourceVersionID, nil)]
            var seen = Set<UUID>(), i = 0
            while i < nodes.count {
                let n = nodes[i]; i += 1
                guard seen.insert(n.version).inserted else { continue }
                for child in try await coverage.descendants(of: n.version, relations: CaseCoverageScopeResolver.coverageRelations) {
                    nodes.append((child.child, n.version))
                }
            }
            let nodeVersions = nodes.map { $0.version }
            let labels = try await coverage.labels(for: nodeVersions)
            let received = try await ledger.receivedAt(nodeVersions)
            var done = Set<UUID>()
            for n in nodes {
                guard !decided.contains(n.version.uuidString), done.insert(n.version).inserted else { continue }
                current = try await admit(caseID: policy.caseID, expectedRevision: current.revision, version: n.version,
                                          label: labels[n.version] ?? "", channel: a.channel,
                                          provenance: n.parent == nil ? a.channel.label : "Inside \(n.parent.flatMap { labels[$0] } ?? "a document") (\(a.channel.label))",
                                          runID: a.runID, receivedAt: received[n.version] ?? a.at,
                                          note: "Included automatically under the policy “\(policy.name)” (arrived through: \(a.channel.label))",
                                          decision: .included, via: .policy, policyID: policy.id, actor: policy.createdBy, at: date)
                count += 1
            }
        }
        return count
    }

    /// One decision through the contract: the intake record first (if it cannot be written, nothing enters or leaves the
    /// scope), then the scope, then the first decision on the record.
    private func admit(caseID: UUID, expectedRevision: Int, version: UUID, label: String, channel: IntakeChannel, provenance: String,
                       runID: UUID?, receivedAt: Date, note: String, decision: CaseIntakeDecision, via: CaseIntakeDecider,
                       policyID: UUID?, actor: String, at date: Date) async throws -> InvestigationCase {
        let item = try await ledger.recordSourceArrival(caseID: caseID, sourceVersionID: version, channel: channel, label: label,
                                                        provenance: provenance, ingestRunID: runID,
                                                        attribution: CaseIntakeAttribution(enteredBy: actor, receivedAt: receivedAt), at: date)
        let updated: InvestigationCase
        if decision == .included {
            updated = try await cases.includeSource(caseID: caseID, expectedRevision: expectedRevision, sourceRef: version.uuidString,
                                                    sourceKind: .sourceVersion, note: note, actor: actor, at: date)
        } else {
            updated = try await cases.excludeSource(caseID: caseID, expectedRevision: expectedRevision, sourceRef: version.uuidString,
                                                    sourceKind: .sourceVersion, note: note, actor: actor, at: date)
        }
        try await ledger.recordDecision(itemID: item.id, decision: decision, via: via, policyID: policyID, actor: actor, note: note, at: date)
        return updated
    }

    /// Items sent to the app (Share menu, capture, device import) since the case was opened that are not in its workspace
    /// and not decided for it — what the Share inbox routes into the case's review.
    private func offeredArrivals(since: Date, inWorkspace: Set<UUID>, decided: Set<String>) async throws -> [IntakeArrival] {
        try await receipts.channelArrivals(channels: IntakeReceiptRepository.capturedChannels, since: since)
            .filter { !inWorkspace.contains($0.sourceVersionID) && !decided.contains($0.sourceVersionID.uuidString) }
    }

    /// The workspace's current source versions and everything inside them, in deterministic order,
    /// each once.
    private func walkWorkspace(_ workspaceID: UUID) async throws -> [WorkspaceWalkNode] {
        var queue: [WorkspaceWalkNode] = []
        for file in try await workspaces.sourceIDs(in: workspaceID) {
            if let meta = try await coverage.currentVersion(forFileID: file) {
                queue.append(WorkspaceWalkNode(version: meta.sourceVersionID, root: true, parent: nil, rootVersion: meta.sourceVersionID, rootFile: file))
            }
        }
        var seen = Set<UUID>()
        var out: [WorkspaceWalkNode] = []
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard seen.insert(item.version).inserted else { continue }
            out.append(item)
            for child in try await coverage.descendants(of: item.version, relations: CaseCoverageScopeResolver.coverageRelations) {
                queue.append(WorkspaceWalkNode(version: child.child, root: false, parent: item.version,
                                               rootVersion: item.rootVersion, rootFile: item.rootFile))
            }
        }
        return out
    }

    // MARK: - IN-07: the per-item case intake list

    /// Every item of the case's intake, one entry each: the workspace's documents (and what is inside them), the documents
    /// decided for the case, items offered from a channel, typed entries, and the latest batch's files that could not be
    /// taken in at all. Each shows its inclusion state, its processing stage (from the readiness ledger) and, for anything
    /// not available, the remedy. Reads only.
    public func intakeList(caseID: UUID) async throws -> [CaseIntakeListEntry] {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationCaseError.caseNotFound(caseID) }
        var inScope: [String: Bool] = [:]
        for s in record.sources { inScope[s.sourceRef] = s.inScope }
        let walk = try await walkWorkspace(record.caseHeader.workspaceID)
        var nodes: [UUID: WorkspaceWalkNode] = [:]
        for n in walk where nodes[n.version] == nil { nodes[n.version] = n }
        let offered = try await offeredArrivals(since: record.caseHeader.createdAt, inWorkspace: Set(walk.map(\.version)), decided: Set(inScope.keys))
        var versions: [UUID] = []
        var listed = Set<UUID>()
        let candidates: [UUID] = walk.map(\.version) + record.sources.compactMap { UUID(uuidString: $0.sourceRef) } + offered.map(\.sourceVersionID)
        for v in candidates {
            if listed.insert(v).inserted { versions.append(v) }
        }
        let items = try await ledger.items(caseID: caseID)
        var itemByVersion: [UUID: CaseIntakeItem] = [:]
        for i in items { if let v = i.sourceVersionID, itemByVersion[v] == nil { itemByVersion[v] = i } }
        var offeredChannel: [UUID: IntakeChannel] = [:]
        for a in offered where offeredChannel[a.sourceVersionID] == nil { offeredChannel[a.sourceVersionID] = a.channel }
        let arrivals = try await receipts.arrivals(of: Set(versions.map { nodes[$0]?.rootVersion ?? $0 }))
        let labels = try await coverage.labels(for: versions + walk.compactMap(\.parent))
        let withText = Set(try await KnowledgeObjectRepository(database: cases.intakeDatabase)
            .sourceVersionsByObject(inSourceVersionIDs: Set(versions)).values.flatMap { $0 })
        let readiness = SourceReadinessRepository(database: cases.intakeDatabase)

        var out: [CaseIntakeListEntry] = []
        for v in versions {
            let node = nodes[v]
            let root = node?.rootVersion ?? v
            let inclusion: CaseIntakeInclusion = inScope[v.uuidString].map { $0 ? .included : .excluded } ?? .pendingReview
            let readinessNow = await readinessSnapshot(readiness, v)
            let (stage, detail) = CaseIntakeStages.stage(snapshot: readinessNow, hasLedgerText: withText.contains(v))
            out.append(CaseIntakeListEntry(
                id: v.uuidString, label: labels[v] ?? "Source \(v.uuidString.prefix(8))", parentLabel: node?.parent.flatMap { labels[$0] },
                sourceVersionID: v, rootVersionID: root,
                channel: itemByVersion[v]?.channel ?? offeredChannel[v] ?? arrivals[root]?.channel,
                inclusion: inclusion, stage: stage, stageDetail: detail,
                remedies: CaseIntakeStages.remedies(inclusion: inclusion, stage: stage),
                item: itemByVersion[v], ingestRunID: itemByVersion[v]?.ingestRunID ?? arrivals[root]?.runID,
                offeredFromChannel: offeredChannel[v] != nil))
        }
        for i in items where i.form == .typedEntry {
            out.append(CaseIntakeListEntry(id: i.id.uuidString, label: i.label, parentLabel: nil, sourceVersionID: nil, rootVersionID: nil,
                                           channel: i.channel, inclusion: .included, stage: .typedEntry, stageDetail: nil,
                                           remedies: [], item: i, ingestRunID: nil, offeredFromChannel: false))
        }
        // The latest batch's files that never became a document (read error, time limit): visible with their remedy.
        if let latest = try await receipts.recentRuns(limit: 1).first, let receipt = try await receipts.receipt(run: latest) {
            for line in receipt.lines where line.sourceVersionID == nil
                && (line.outcome == .failed || line.outcome == .timedOut || (line.outcome == nil && line.state == "failed")) {
                out.append(CaseIntakeListEntry(id: "batch:\(latest.uuidString):\(line.path)", label: line.name, parentLabel: nil,
                                               sourceVersionID: nil, rootVersionID: nil, channel: line.channel, inclusion: .notReceived,
                                               stage: .notReceived,
                                               stageDetail: line.outcome == .timedOut ? "took longer than the time allowed" : (line.error ?? "could not be read"),
                                               remedies: [.addFileAgain], item: nil, ingestRunID: latest, offeredFromChannel: false))
            }
        }
        return out
    }

    /// IN-12 — the case's coverage traced back to the intake inventory: what it took in, decided and could not take in, and
    /// the batches its documents came from (a document inside another is traced through the one holding it).
    public func reconciliation(caseID: UUID) async throws -> CaseIntakeReconciliation {
        let list = try await intakeList(caseID: caseID)
        let included = list.filter { $0.inclusion == .included && $0.sourceVersionID != nil }
        let roots = Set(included.compactMap(\.rootVersionID))
        let settled = try await receipts.runs(settling: roots)
        let traced = included.filter { e in e.rootVersionID.map { !(settled[$0] ?? []).isEmpty } ?? false }.count
        var batchIDs: [UUID] = []
        for runs in settled.values { for r in runs where !batchIDs.contains(r) { batchIDs.append(r) } }
        let latest: IntakeBatchReceipt?
        if let id = try await receipts.recentRuns(limit: 1).first { latest = try await receipts.receipt(run: id) } else { latest = nil }
        return CaseIntakeReconciliation(
            included: included.count,
            excluded: list.filter { $0.inclusion == .excluded }.count,
            pendingReview: list.filter { $0.inclusion == .pendingReview }.count,
            typedEntries: list.filter { $0.stage == .typedEntry }.count,
            includedNotAvailable: included.filter { $0.stage != .available && $0.stage != .partial }.count,
            tracedToBatches: traced, batchIDs: batchIDs.sorted { $0.uuidString < $1.uuidString },
            latestBatch: latest, notReceived: list.filter { $0.inclusion == .notReceived }.map(\.label))
    }

    private func readinessSnapshot(_ repo: SourceReadinessRepository, _ version: UUID) async -> SourceReadinessSnapshot? {
        do {
            return try await repo.snapshot(sourceVersionID: version)
        } catch let e as SourceReadinessError {
            // A version read before readiness records existed has none; that is a state, not a fault.
            if case .aggregateNotFound(_) = e { return nil }
            KalsmritikoshLog.app.error("Intake list: readiness unreadable: \(String(describing: e), privacy: .public)")
            return nil
        } catch {
            KalsmritikoshLog.app.error("Intake list: readiness unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - IN-07 vocabulary

/// Whether the case has taken an item in.
public nonisolated enum CaseIntakeInclusion: String, Sendable, Codable, Hashable, CaseIterable {
    case pendingReview, included, excluded
    /// The file never became a document (it could not be read at all), so no case can take it in yet.
    case notReceived

    public var label: String {
        switch self {
        case .pendingReview: return "Waiting for your review"
        case .included: return "In the case"
        case .excluded: return "Excluded"
        case .notReceived: return "Not taken in"
        }
    }
}

/// Where an item is in processing.
public nonisolated enum CaseIntakeStage: String, Sendable, Codable, Hashable, CaseIterable {
    case notReceived, received, processing, available, partial, keptWithoutText, passwordNeeded, damaged, unsupported, failed
    /// A typed entry: no file to read.
    case typedEntry

    public var label: String {
        switch self {
        case .notReceived: return "Could not be taken in"
        case .received: return "Received, no reading record yet"
        case .processing: return "Being read"
        case .available: return "Read"
        case .partial: return "Partly read"
        case .keptWithoutText: return "Kept, no text read"
        case .passwordNeeded: return "Needs a password"
        case .damaged: return "Damaged"
        case .unsupported: return "Unsupported file type"
        case .failed: return "Reading failed"
        case .typedEntry: return "Typed entry"
        }
    }
}

/// What the person can do about an item.
public nonisolated enum CaseIntakeRemedy: String, Sendable, Codable, Hashable, CaseIterable {
    case reviewInclusion, wait, readAgain, providePassword, replaceFile, supplyReadableCopy, addFileAgain

    public var instruction: String {
        switch self {
        case .reviewInclusion: return "Review new documents: include it in the case or exclude it with a reason."
        case .wait: return "It is being read; it becomes searchable when reading finishes."
        case .readAgain: return "Read it again from Sources (Read again, or Read with AI for scans)."
        case .providePassword: return "Open it with its password, or ask whoever supplied it for an unprotected copy."
        case .replaceFile: return "The file is damaged; ask for a fresh copy and add it again. The damaged original is kept."
        case .supplyReadableCopy: return "This type is kept but not read; add a PDF or text copy beside it."
        case .addFileAgain: return "Check the file can be opened, then add it again; it was not kept."
        }
    }
}

/// One row of the case intake list.
public nonisolated struct CaseIntakeListEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let parentLabel: String?
    public let sourceVersionID: UUID?
    /// The workspace (or channel) document this one is, or is inside.
    public let rootVersionID: UUID?
    public let channel: IntakeChannel?
    public let inclusion: CaseIntakeInclusion
    public let stage: CaseIntakeStage
    public let stageDetail: String?
    public let remedies: [CaseIntakeRemedy]
    /// The case-intake contract record, once the item was decided (or typed).
    public let item: CaseIntakeItem?
    /// The batch that took it in, when recorded.
    public let ingestRunID: UUID?
    public let offeredFromChannel: Bool
}

public nonisolated enum CaseIntakeStages {
    /// The processing stage of a version from its readiness snapshot (nil: no readiness record) and whether the ledger holds
    /// text read from it.
    public static func stage(snapshot: SourceReadinessSnapshot?, hasLedgerText: Bool) -> (CaseIntakeStage, String?) {
        guard let s = snapshot else {
            return hasLedgerText ? (.available, "read before reading records were kept") : (.received, nil)
        }
        let reading: [SourceReadinessDimension] = [.textExtraction, .structuralExtraction, .ocr, .transcription, .indexing]
        switch s.completionState {
        case .evidenceReady: return (.available, nil)
        case .searchablePartial:
            let what = s.limitations.map { "\(activity($0.dimension)) \($0.state.rawValue)" }
            return (.partial, what.isEmpty ? nil : what.joined(separator: ", "))
        case .encrypted: return (.passwordNeeded, nil)
        case .corrupt: return (.damaged, nil)
        case .unsupported: return (.unsupported, nil)
        case .failed: return (.failed, s.limitations.first.map { "\(activity($0.dimension)) failed" })
        case .deferred: return (.processing, "waiting to be read")
        case .preservedOnly:
            if let running = s.dimensions.first(where: { $0.state == .running && reading.contains($0.dimension) }) {
                return (.processing, activity(running.dimension))
            }
            if hasLedgerText { return (.available, nil) }
            if s.dimensions.contains(where: { $0.isApplicable && $0.state == .notStarted && ($0.dimension == .textExtraction || $0.dimension == .indexing) }) {
                return (.processing, "waiting to be read")
            }
            return (.keptWithoutText, "kept, but no text could be read from it")
        }
    }

    static func activity(_ d: SourceReadinessDimension) -> String {
        switch d {
        case .textExtraction, .structuralExtraction: return "parsing"
        case .ocr: return "text recognition (OCR)"
        case .transcription: return "transcription"
        case .indexing: return "indexing"
        default: return d.rawValue
        }
    }

    /// The remedies for an item: a pending one needs a decision; an excluded one needs nothing; anything not read says how.
    public static func remedies(inclusion: CaseIntakeInclusion, stage: CaseIntakeStage) -> [CaseIntakeRemedy] {
        var out: [CaseIntakeRemedy] = []
        if inclusion == .pendingReview { out.append(.reviewInclusion) }
        if inclusion == .excluded { return out }
        switch stage {
        case .notReceived: out.append(.addFileAgain)
        case .received, .keptWithoutText, .failed, .partial: out.append(.readAgain)
        case .processing: out.append(.wait)
        case .passwordNeeded: out.append(.providePassword)
        case .damaged: out.append(.replaceFile)
        case .unsupported: out.append(.supplyReadableCopy)
        case .available, .typedEntry: break
        }
        return out
    }
}

// MARK: - IN-12: coverage traced to the intake inventory

/// What the case took in, reconciled: shown with the case's reading coverage so coverage rests on the intake inventory,
/// not only on what was read.
public nonisolated struct CaseIntakeReconciliation: Sendable, Equatable {
    /// Documents in the case.
    public let included: Int
    public let excluded: Int
    public let pendingReview: Int
    public let typedEntries: Int
    /// Documents in the case not (yet) read: being read, failed, protected, damaged, unsupported or kept without text.
    public let includedNotAvailable: Int
    /// Documents in the case traced to an intake batch line (their own, or the one of the document holding them).
    public let tracedToBatches: Int
    /// The batches the case's documents came from.
    public let batchIDs: [UUID]
    /// The most recent batch (selected / received / duplicates / failed / not finished).
    public let latestBatch: IntakeBatchReceipt?
    /// Files of the latest batch that could not be taken in at all.
    public let notReceived: [String]

    /// Documents in the case taken in before batch receipts were kept (no batch line to trace to).
    public var untraced: Int { max(0, included - tracedToBatches) }

    public var lines: [String] {
        var out = ["Intake: \(included) document\(included == 1 ? "" : "s") in the case" + (typedEntries > 0 ? ", \(typedEntries) typed entr\(typedEntries == 1 ? "y" : "ies")" : "")
                   + (pendingReview > 0 ? ", \(pendingReview) waiting for review" : "") + (excluded > 0 ? ", \(excluded) excluded" : "")]
        if included > 0 {
            var t = "Traced to intake receipts: \(tracedToBatches) of \(included) (from \(batchIDs.count) batch\(batchIDs.count == 1 ? "" : "es"))"
            if untraced > 0 { t += "; \(untraced) taken in before receipts were kept" }
            out.append(t)
        }
        if includedNotAvailable > 0 { out.append("In the case but not read yet or not readable: \(includedNotAvailable)") }
        if let b = latestBatch { out.append("Latest intake batch — \(b.summaryLine)") }
        if !notReceived.isEmpty { out.append("Could not be taken in (latest batch): " + notReceived.prefix(10).joined(separator: ", ") + (notReceived.count > 10 ? " …" : "")) }
        return out
    }
}
