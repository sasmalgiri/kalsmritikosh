//
//  InvestigationContradictionGapService.swift
//  Kalsmritikosh
//
//  INV-12 — the case Contradiction & Gap desk. Orchestration only: it REUSES the shared
//  ContradictionsRepository + GapNodeRepository (the canonical detectors) and bounds them to the case's
//  authorized source versions, pairing each in-scope item with the case's human disposition recorded in the
//  thin InvestigationDeskReviewRepository. It forks neither authority and mutates neither's global status —
//  so a contradiction keeps BOTH sides (never averaged into one truth) and a gap keeps its reason (absence
//  is never proof). Confirm/dismiss here is the case's disposition, not a resolution of the underlying item.
//

import Foundation
import os

/// P3 — what the case contradiction check needs from the app (closures, so the desk stays a thin
/// orchestrator and the tests can supply fakes).
public nonisolated struct CaseContradictionPass: Sendable {
    /// The case's documents for exactly these authorized source versions (text, file name, date).
    public let documents: @Sendable (Set<UUID>) async throws -> [CaseContradictionFinder.Document]
    /// The cloud gate bound to the case's scope (nil: no protection labels — nothing may leave the Mac).
    public let gate: @Sendable (UUID) -> CloudSourceGate?
    /// The person's AI passage reader when Online document reading is on and AI is allowed (nil otherwise): "Look for
    /// conflicts with AI…" reads a case too large to read whole through it, under the case's stored permission.
    public let reader: @Sendable () -> CaseContradictionReader?
    /// Links each stored contradiction to the claims citing its documents, so the findings report's
    /// conflicts section (DisclosureSelectionService) shows it. Returns the links made.
    public let linkClaims: (@Sendable ([Contradiction]) async -> Int)?
    /// P5 — the person's AI reader for case drafts (chronology, gaps, interview questions) and the role
    /// reader for the cast, under the same conditions as `reader` (nil: rules only).
    public var draftReader: (@Sendable () -> CaseDraftReader?)? = nil
    public var roleReader: (@Sendable () -> VerifiedRoleReader?)? = nil
    /// Plan A — the whole-case reading (the same cached case prefix as questions) and the case's cloud
    /// scope. With both, an analysis whose case fits and whose permission is stored reads the whole case.
    public var caseReading: CaseWholeReading? = nil
    public var caseBinding: (@Sendable (UUID) -> CloudScopeBinding?)? = nil
    /// Ease fixes A — the case's structured money records (each real payment once), for the rule that compares what a
    /// document says about payments with them (nil: that rule does not run).
    public var moneyMovements: (@Sendable (UUID) async throws -> [CaseContradictionFinder.MoneyMovement])? = nil
    /// Owner request 2026-11-16 — where "Look for conflicts with AI…" keeps each conflict's detail (open kind, who found
    /// it, every side, the AI's labelled explanation). nil: that look does not store AI findings.
    public var conflictDetails: CaseConflictDetailsRepository? = nil
    /// Case plan 2026-11-16 (SEARCH-13) — how many documents the authorized versions hold before `documents` applies its
    /// per-run limit, so a run that compares fewer says how many it left out (nil: not known).
    public var documentCount: (@Sendable (Set<UUID>) async throws -> Int)? = nil
    /// SEARCH-13 — the documents from a position on, in the same stable order as `documents` (for a continuation past the
    /// per-run limit). nil: no continuation (only the first page is compared).
    public var documentsFrom: (@Sendable (Set<UUID>, Int) async throws -> [CaseContradictionFinder.Document])? = nil

    public init(documents: @escaping @Sendable (Set<UUID>) async throws -> [CaseContradictionFinder.Document],
                gate: @escaping @Sendable (UUID) -> CloudSourceGate?,
                reader: @escaping @Sendable () -> CaseContradictionReader?,
                linkClaims: (@Sendable ([Contradiction]) async -> Int)? = nil) {
        self.documents = documents; self.gate = gate; self.reader = reader; self.linkClaims = linkClaims
    }
}

/// What one run of the case contradiction check's rules did ("Find contradictions"). The AI's look is
/// `lookForConflictsWithAI` (AIConflictScanRun): owner request 2026-11-16, one AI conflict path.
public nonisolated struct CaseContradictionRun: Sendable {
    public var documents = 0
    public var ruleFindings: [CaseContradictionFinder.Finding] = []
    public var claimLinks = 0
    public var available = true
    /// Ease fixes A — how many payments of the case's money records the rules compared with the documents, and how many
    /// pairs that comparison raised (they are part of `ruleFindings`). nil: the money records could not be read.
    public var moneyMovementsCompared: Int? = 0
    public var moneyFindings = 0
    /// How many documents the case holds (nil: not known). More than `documents`: the rest were not compared.
    public var documentsInCase: Int?
    /// SEARCH-13 — where this run started in the case's stable document order (0: the first page).
    public var startingAt = 0
    /// Where a continuation would start, when documents remain after this run (nil: none remain, or not known).
    public var continuation: Int? {
        guard let total = documentsInCase, startingAt + documents < total, documents > 0 else { return nil }
        return startingAt + documents
    }
    /// SEARCH-14 — earlier documents carried into this page's comparison because they share a subject with it (a full
    /// name, a stated record identifier, a reference), and how many findings came from those cross-page pairs.
    public var carried = 0
    public var crossPageFindings = 0
    /// The source versions the rules compared (so an AI look right after can reuse these findings only while the case's
    /// documents are exactly these).
    public var versions: Set<UUID> = []
    public var findings: [CaseContradictionFinder.Finding] { ruleFindings }
    public init() {}
}

public actor InvestigationContradictionGapService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let evidence: EvidenceStore
    let contradictions: ContradictionsRepository
    private let gaps: GapNodeRepository
    private let reviews: InvestigationDeskReviewRepository
    /// P5 — read by the case drafts (InvestigationContradictionGapService+Drafts).
    let pass: CaseContradictionPass?

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver, evidence: EvidenceStore,
                contradictions: ContradictionsRepository, gaps: GapNodeRepository, reviews: InvestigationDeskReviewRepository,
                pass: CaseContradictionPass? = nil) {
        self.cases = cases; self.resolver = resolver; self.evidence = evidence
        self.contradictions = contradictions; self.gaps = gaps; self.reviews = reviews
        self.pass = pass
    }

    // MARK: - P3: find contradictions in the case (the rules)

    /// Compare the case's own documents with each other by the rules ("Find contradictions"), on this Mac, and store
    /// what they find with both sides; nothing outside the case is ever compared and nothing is sent. The AI's look is
    /// `lookForConflictsWithAI` — "Find contradictions" leads to it when AI is set up (owner request 2026-11-16: one AI
    /// conflict path; the older two-sided AI pass that ran here is removed). Read the result through `contradictions(caseID:)`.
    @discardableResult
    public func findContradictions(caseID: UUID, startingAt: Int = 0, at date: Date = Date()) async throws -> CaseContradictionRun {
        var run = CaseContradictionRun()
        guard let pass else { run.available = false; return run }
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        // Defence in depth: only documents whose version the case authorizes. A continuation (SEARCH-13) reads the next
        // page in the same stable order.
        let page: [CaseContradictionFinder.Document]
        if startingAt > 0, let from = pass.documentsFrom { page = try await from(authorized, startingAt) } else { page = try await pass.documents(authorized) }
        run.startingAt = startingAt > 0 && pass.documentsFrom != nil ? startingAt : 0
        let docs = page.filter { $0.sourceVersionID.map(authorized.contains) ?? false }
        run.documents = docs.count
        run.documentsInCase = await documentsInCase(authorized)
        run.versions = Set(docs.compactMap(\.sourceVersionID))
        run.ruleFindings = CaseContradictionFinder.ruleFindings(docs)
        // SEARCH-14: a continuation also compares the page with the earlier documents that share a subject with it.
        if run.startingAt > 0, let from = pass.documentsFrom {
            var carried: [CaseContradictionFinder.Document] = []
            var offset = 0
            while offset < run.startingAt, carried.count < CaseContradictionCarry.maxCarried {
                let earlier = try await from(authorized, offset).filter { $0.sourceVersionID.map(authorized.contains) ?? false }
                if earlier.isEmpty { break }
                let room = CaseContradictionCarry.maxCarried - carried.count
                carried += CaseContradictionCarry.carried(page: docs, earlier: Array(earlier.prefix(max(0, run.startingAt - offset))), limit: room)
                offset += earlier.count
            }
            let cross = CaseContradictionCarry.crossFindings(page: docs, carried: carried)
            run.carried = carried.count
            run.crossPageFindings = cross.count
            run.ruleFindings += cross
            run.versions.formUnion(carried.compactMap(\.sourceVersionID))
        }
        if let money = pass.moneyMovements {
            do {
                let movements = try await money(caseID)
                let found = CaseContradictionFinder.moneyRecordFindings(docs, movements: movements)
                run.moneyMovementsCompared = movements.count
                run.moneyFindings = found.count
                run.ruleFindings += found
            } catch {
                KalsmritikoshLog.knowledge.error("case contradiction check: money records unreadable: \(String(describing: error), privacy: .public)")
                run.moneyMovementsCompared = nil
            }
        }
        let stored = run.findings.map { $0.contradiction(at: date) }
        await contradictions.insertMany(stored)
        if let link = pass.linkClaims, !stored.isEmpty { run.claimLinks = await link(stored) }
        KalsmritikoshLog.knowledge.info("case contradiction check: \(run.ruleFindings.count, privacy: .public) by rules over \(docs.count, privacy: .public) document(s)")
        return run
    }

    // MARK: - Plan A: analysis on the whole-case path

    /// How this case's analysis reads with AI: the whole case (it fits and its permission is stored),
    /// or passages — under the stored permission when the case is too large, else as before.
    func analysisRoute(_ caseID: UUID) async -> CaseWholeReading.AnalysisRoute {
        guard let plan = pass?.caseReading, let binding = pass?.caseBinding?(caseID) else {
            return .passages(permitted: nil, why: "no whole-case reading set up")
        }
        do {
            return await plan.analysisRoute(caseID: caseID, versions: try await authorizedSet(caseID), binding: binding)
        } catch {
            KalsmritikoshLog.knowledge.error("case analysis: scope unreadable for the whole-case read: \(String(describing: error), privacy: .public)")
            return .passages(permitted: nil, why: "the case's scope could not be read")
        }
    }

    // MARK: - Read (in-scope items + case disposition)

    /// The contradictions whose evidence sits inside the case scope, each paired with the case's disposition.
    /// Both claim sides are preserved verbatim from the shared Contradiction.
    public func contradictions(caseID: UUID, limit: Int = 500) async throws -> [CaseContradictionItem] {
        let authorized = try await authorizedSet(caseID)
        let caseReviews = try await reviews.reviewsByItem(caseID: caseID, itemKind: .contradiction)
        // Scope before limit: walk every contradiction in a stable order and keep the case's own,
        // so other cases' items can never push this case's out of a global LIMIT (brief §7).
        var out: [CaseContradictionItem] = []
        var cursor: (Date, String)?
        while out.count < limit {
            let page = try await contradictions.page(after: cursor)
            guard let last = page.last else { break }
            for c in page where try await isContradictionInScope(c, authorized: authorized) {
                out.append(CaseContradictionItem(contradiction: c, review: caseReviews[c.id.uuidString]))
                if out.count == limit { break }
            }
            cursor = (last.detectedAt, last.id.uuidString)
        }
        return out
    }

    /// The gaps whose evidence sits inside the case scope, each paired with the case's disposition.
    public func gaps(caseID: UUID, limit: Int = 500) async throws -> [CaseGapItem] {
        let authorized = try await authorizedSet(caseID)
        let caseReviews = try await reviews.reviewsByItem(caseID: caseID, itemKind: .gap)
        var out: [CaseGapItem] = []
        var cursor: (Date, String)?
        while out.count < limit {
            let page = try await gaps.page(includeDismissed: true, after: cursor)
            guard let last = page.last else { break }
            for g in page where try await isGapInScope(g, authorized: authorized) {
                out.append(CaseGapItem(gap: g, review: caseReviews[g.id.uuidString]))
                if out.count == limit { break }
            }
            cursor = (last.detectedAt, last.id.uuidString)
        }
        return out
    }

    // MARK: - Human disposition (case-scoped; shared item status untouched)

    public func confirmContradiction(caseID: UUID, contradictionID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeContradiction(caseID: caseID, contradictionID: contradictionID, decision: .confirmed, note: note, actor: actor, at: date)
    }
    public func dismissContradiction(caseID: UUID, contradictionID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeContradiction(caseID: caseID, contradictionID: contradictionID, decision: .dismissed, note: note, actor: actor, at: date)
    }
    public func confirmGap(caseID: UUID, gapID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeGap(caseID: caseID, gapID: gapID, decision: .confirmed, note: note, actor: actor, at: date)
    }
    public func dismissGap(caseID: UUID, gapID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeGap(caseID: caseID, gapID: gapID, decision: .dismissed, note: note, actor: actor, at: date)
    }

    // MARK: - v170: review in place (confirm / dismiss / defer with a reason, kept against source versions)

    /// The case's contradictions with their review status: each decision is compared with the CURRENT
    /// version of both sides' documents, so a rerun over unchanged documents keeps it and a revised
    /// document reopens it. Nothing is written here.
    public func contradictionReviewItems(caseID: UUID, limit: Int = 500) async throws -> [CaseContradictionReviewItem] {
        let items = try await contradictions(caseID: caseID, limit: limit)
        let history = try await reviews.decisionHistory(caseID: caseID, itemKind: .contradiction)
        let details = try await sideDetails(caseID)
        var out: [CaseContradictionReviewItem] = []
        for item in items {
            let c = item.contradiction
            let extra = CaseContradictionReviewItem.extraSides(of: details[c.id], beside: c)
            var current: [UUID: UUID?] = [:]
            for ko in Self.sideObjects(c, extra: extra) { current[ko] = try await evidence.currentVersionID(forObject: ko) }
            let past = history[c.id.uuidString] ?? []
            // S5 (REASON-12) — a side whose document has a new version is checked for the words the decision was made on.
            var still = Set<UUID>()
            if let latest = past.last {
                for (ko, words) in latest.passages {
                    guard let now = current[ko] ?? nil, now != latest.sourceVersions[ko] else { continue }
                    if try await versionContains(now, words) { still.insert(ko) }
                }
            }
            let status = CaseItemReviewStatus.compute(history: past, currentVersions: current, stillContains: still)
            out.append(CaseContradictionReviewItem(contradiction: c, status: status, currentVersions: current, extraSides: extra))
        }
        return out
    }

    /// How many documents the authorized versions hold, before the per-run limit (nil: not known or unreadable).
    func documentsInCase(_ authorized: Set<UUID>) async -> Int? {
        guard let count = pass?.documentCount else { return nil }
        do { return try await count(authorized) } catch {
            KalsmritikoshLog.knowledge.error("case contradiction check: document count unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The case's conflict details for the sides beyond A and B (empty when none is stored or the store is not set up).
    private func sideDetails(_ caseID: UUID) async throws -> [UUID: CaseConflictDetail] {
        guard let repo = pass?.conflictDetails else { return [:] }
        return try await repo.details(caseID: caseID)
    }

    /// One conflict's detail (nil when none is stored or the store is not set up) — not the whole case's.
    private func sideDetail(_ caseID: UUID, _ contradictionID: UUID) async throws -> CaseConflictDetail? {
        guard let repo = pass?.conflictDetails else { return nil }
        return try await repo.detail(caseID: caseID, contradictionID: contradictionID)
    }

    /// Every document a conflict's sides rest on: A, B and the sides beyond them, each once, in order.
    nonisolated static func sideObjects(_ c: Contradiction, extra: [ConflictSide]) -> [UUID] {
        var out: [UUID] = []
        for ko in [c.evidenceA, c.evidenceB].compactMap({ $0 }) + extra.map(\.objectID) where !out.contains(ko) { out.append(ko) }
        return out
    }

    /// Record the person's decision on one in-scope contradiction, with the version of each side's
    /// document as it is now. A dismissal needs a reason; neither source and not the shared item change.
    @discardableResult
    public func reviewContradiction(caseID: UUID, contradictionID: UUID, decision: CaseReviewDecision, reason: CaseReviewReason?,
                                    note: String?, actor: String, at date: Date) async throws -> CaseReviewDecisionRecord {
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        guard let c = try await contradictions.findByIDs([contradictionID]).first else { throw InvestigationDeskError.contradictionNotFound(contradictionID) }
        guard try await isContradictionInScope(c, authorized: authorized) else { throw InvestigationDeskError.contradictionOutOfScope(contradictionID) }
        // Every side's document — A, B and, for a conflict of three or more, the sides beyond them — is recorded with the
        // version decided on and the words, so a change to any of them reopens the decision.
        let extra = CaseContradictionReviewItem.extraSides(of: try await sideDetail(caseID, c.id), beside: c)
        var versions: [UUID: UUID] = [:]
        for ko in Self.sideObjects(c, extra: extra) {
            if let v = try await evidence.currentVersionID(forObject: ko) { versions[ko] = v }
        }
        var passages: [UUID: String] = [:]
        if let a = c.evidenceA { passages[a] = c.claimA }
        if let b = c.evidenceB { passages[b] = passages[b].map { $0 + "\n" + c.claimB } ?? c.claimB }
        for s in extra { passages[s.objectID] = passages[s.objectID].map { $0 + "\n" + s.quote } ?? s.quote }
        let record = try await reviews.recordDecision(caseID: caseID, itemKind: .contradiction, itemID: contradictionID.uuidString,
                                                      decision: decision, reason: reason, note: note, sourceVersions: versions,
                                                      passages: passages, actor: actor, at: date)
        KalsmritikoshLog.knowledge.info("case contradiction \(decision.rawValue, privacy: .public) (reason: \(reason?.rawValue ?? "none", privacy: .public))")
        return record
    }

    // MARK: - S5 (REASON-03 / REASON-06): comparison and items no longer detected

    /// Whether a version's text holds `words` (each line of them), whitespace- and case-insensitively. A version with no
    /// readable text cannot show the words are still there, so it counts as changed.
    func versionContains(_ version: UUID, _ words: String) async throws -> Bool {
        let text = try await evidence.blocks(forVersion: version).map(\.rawText).joined(separator: " ")
        guard !text.isEmpty else { return false }
        let hay = CaseConflictComparer.normalized(text)
        return words.split(separator: "\n").allSatisfy { hay.contains(CaseConflictComparer.normalized(String($0))) }
    }

    /// Both accounts of an in-scope contradiction side by side: each quote in its passage (from the version it was read
    /// from when the case decided on it, else the current one), the values, dates and units it states, the version, and
    /// the cautions that may make it a difference rather than a contradiction. Nothing is written or decided.
    public func comparison(caseID: UUID, contradictionID: UUID) async throws -> CaseConflictComparison {
        let authorized = try await authorizedSet(caseID)
        guard let c = try await contradictions.findByIDs([contradictionID]).first else { throw InvestigationDeskError.contradictionNotFound(contradictionID) }
        guard try await isContradictionInScope(c, authorized: authorized) else { throw InvestigationDeskError.contradictionOutOfScope(contradictionID) }
        let decided = try await reviews.decisionHistory(caseID: caseID, itemKind: .contradiction)[c.id.uuidString]?.last?.sourceVersions ?? [:]
        func side(_ object: UUID?, _ quote: String) async throws -> CaseConflictSide {
            guard let object else { return CaseConflictComparer.side(quote: quote, objectID: nil, version: nil, current: nil, name: nil, text: nil) }
            let current = try await evidence.currentVersionID(forObject: object)
            let version = decided[object] ?? current
            var text: String?, name: String?
            if let v = version {
                text = try await evidence.blocks(forVersion: v).map(\.rawText).joined(separator: " ")
                name = try await evidence.sourceNames(forSourceVersionIDs: [v])[v]
            }
            return CaseConflictComparer.side(quote: quote, objectID: object, version: version, current: current, name: name, text: text)
        }
        // Every side beyond A and B too (owner request 2026-11-16), read the same way.
        var extra: [CaseConflictSide] = []
        for s in CaseContradictionReviewItem.extraSides(of: try await sideDetail(caseID, c.id), beside: c) {
            extra.append(try await side(s.objectID, s.quote))
        }
        return CaseConflictComparer.compare(c, a: try await side(c.evidenceA, c.claimA), b: try await side(c.evidenceB, c.claimB), extra: extra)
    }

    /// Items this case decided that the check no longer produces in the case: their decisions are kept and listed, and
    /// they are never treated as resolved because they are gone from the list.
    public func noLongerDetected(caseID: UUID) async throws -> [CaseVanishedReviewItem] {
        let history = try await reviews.decisionHistory(caseID: caseID, itemKind: .contradiction)
        let present = Set(try await contradictions(caseID: caseID).map { $0.contradiction.id.uuidString })
        let authorized = try await authorizedSet(caseID)
        var out: [CaseVanishedReviewItem] = []
        for (item, past) in history.sorted(by: { $0.key < $1.key }) where !present.contains(item) {
            var found: Contradiction?
            if let uid = UUID(uuidString: item) { found = try await contradictions.findByIDs([uid]).first }
            let why: String
            if let found { why = try await isContradictionInScope(found, authorized: authorized) ? "not listed by the check" : "its documents are no longer in the case's scope" }
            else { why = "the check no longer produces it" }
            out.append(CaseVanishedReviewItem(itemID: item, history: past, why: why))
        }
        return out
    }

    // MARK: - Internals

    private func disposeContradiction(caseID: UUID, contradictionID: UUID, decision: DeskDecision, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        guard let c = try await contradictions.findByIDs([contradictionID]).first else { throw InvestigationDeskError.contradictionNotFound(contradictionID) }
        guard try await isContradictionInScope(c, authorized: authorized) else { throw InvestigationDeskError.contradictionOutOfScope(contradictionID) }
        return try await reviews.record(caseID: caseID, itemKind: .contradiction, itemID: contradictionID.uuidString, decision: decision, note: note, actor: actor, at: date)
    }

    private func disposeGap(caseID: UUID, gapID: UUID, decision: DeskDecision, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        // The gap by its id, wherever it sits — not among the first 5,000 of every case's gaps.
        var found: GapNode?
        var cursor: (Date, String)?
        while found == nil {
            let page = try await gaps.page(includeDismissed: true, after: cursor)
            guard let last = page.last else { break }
            found = page.first { $0.id == gapID }
            cursor = (last.detectedAt, last.id.uuidString)
        }
        guard let g = found else { throw InvestigationDeskError.gapNotFound(gapID) }
        guard try await isGapInScope(g, authorized: authorized) else { throw InvestigationDeskError.gapOutOfScope(gapID) }
        return try await reviews.record(caseID: caseID, itemKind: .gap, itemID: gapID.uuidString, decision: decision, note: note, actor: actor, at: date)
    }

    /// A contradiction is in scope iff it has at least one evidence side and EVERY present side resolves to
    /// an authorized source version (fail-closed on an unresolved side).
    private func isContradictionInScope(_ c: Contradiction, authorized: Set<UUID>) async throws -> Bool {
        let sides = [c.evidenceA, c.evidenceB].compactMap { $0 }
        guard !sides.isEmpty else { return false }
        for ko in sides {
            guard let v = try await evidence.currentVersionID(forObject: ko), authorized.contains(v) else { return false }
        }
        return true
    }

    /// A gap is in scope iff it anchors to an evidence object that resolves to an authorized source version.
    private func isGapInScope(_ g: GapNode, authorized: Set<UUID>) async throws -> Bool {
        guard let ko = g.evidenceObjectID, let v = try await evidence.currentVersionID(forObject: ko) else { return false }
        return authorized.contains(v)
    }

    func authorizedSet(_ caseID: UUID) async throws -> Set<UUID> {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        return Set(try await resolver.scope(for: record).authorizedSourceVersionIDs)
    }

    func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw InvestigationDeskError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }
}
