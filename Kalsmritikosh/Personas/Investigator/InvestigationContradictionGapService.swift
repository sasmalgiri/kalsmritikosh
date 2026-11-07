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
    /// The person's AI reader when Online document reading is on and AI is allowed (nil otherwise).
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

    public init(documents: @escaping @Sendable (Set<UUID>) async throws -> [CaseContradictionFinder.Document],
                gate: @escaping @Sendable (UUID) -> CloudSourceGate?,
                reader: @escaping @Sendable () -> CaseContradictionReader?,
                linkClaims: (@Sendable ([Contradiction]) async -> Int)? = nil) {
        self.documents = documents; self.gate = gate; self.reader = reader; self.linkClaims = linkClaims
    }
}

/// What one run of the case contradiction check did.
public nonisolated struct CaseContradictionRun: Sendable {
    public var documents = 0
    public var ruleFindings: [CaseContradictionFinder.Finding] = []
    public var aiFindings: [CaseContradictionFinder.Finding] = []
    /// Reader pairs that did not verify, with why.
    public var aiDropped: [String] = []
    /// Reader pairs the rules had already found.
    public var aiAgreedWithRules = 0
    public var calls = 0
    public var failedCalls = 0
    /// Why each failed call failed (the provider's words).
    public var failures: [String] = []
    public var passagesSent = 0
    public var deniedForCloud = 0
    /// Why the AI reading did not run or stopped (nil: it ran, or no reader is set up).
    public var notSentReason: String?
    public var readerAvailable = false
    /// Plan A — the AI read the whole case in one call (false: passages, `passagePathReason` says why).
    public var readWholeCase = false
    public var passagePathReason: String?
    public var claimLinks = 0
    public var available = true
    public var findings: [CaseContradictionFinder.Finding] { ruleFindings + aiFindings }
    public init() {}
}

public actor InvestigationContradictionGapService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let evidence: EvidenceStore
    private let contradictions: ContradictionsRepository
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

    // MARK: - P3: find contradictions in the case

    /// Compare the case's own documents with each other ("Find contradictions"): the rules always; the
    /// person's AI reader too when it is available, over the documents CloudSourceGate clears for the
    /// case's scope (privileged and above-confidential material never), every pair it proposes verified.
    /// Verified pairs are stored with both sides; nothing outside the case is ever compared. Read the
    /// result through `contradictions(caseID:)`.
    @discardableResult
    public func findContradictions(caseID: UUID, at date: Date = Date()) async throws -> CaseContradictionRun {
        var run = CaseContradictionRun()
        guard let pass else { run.available = false; return run }
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        // Defence in depth: only documents whose version the case authorizes.
        let docs = try await pass.documents(authorized).filter { $0.sourceVersionID.map(authorized.contains) ?? false }
        run.documents = docs.count
        run.ruleFindings = CaseContradictionFinder.ruleFindings(docs)
        if let reader = pass.reader() {
            run.readerAvailable = true
            switch await analysisRoute(caseID) {
            case .wholeCase(let caseReader, let prepared):
                run.readWholeCase = true
                await readWholeCase(caseReader, prepared, caseID: caseID, docs: docs, into: &run)
            case .passages(let permitted, let why):
                run.passagePathReason = why
                var r = run
                await CaseReadPermittedSet.$current.withValue(permitted) {
                    await readWithAI(reader, caseID: caseID, docs: docs, into: &r)
                }
                run = r
            }
        }
        let stored = run.findings.map { $0.contradiction(at: date) }
        await contradictions.insertMany(stored)
        if let link = pass.linkClaims, !stored.isEmpty { run.claimLinks = await link(stored) }
        KalsmritikoshLog.knowledge.info("case contradiction check: \(run.ruleFindings.count, privacy: .public) by rules, \(run.aiFindings.count, privacy: .public) by the AI reading (\(run.aiDropped.count, privacy: .public) dropped, \(run.calls, privacy: .public) call(s), \(run.passagesSent, privacy: .public) passage(s)) over \(docs.count, privacy: .public) document(s)")
        return run
    }

    private func readWithAI(_ reader: CaseContradictionReader, caseID: UUID, docs: [CaseContradictionFinder.Document],
                            into run: inout CaseContradictionRun) async {
        guard let gate = pass?.gate(caseID) else {
            run.notSentReason = "documents cannot be cleared for the cloud (no protection labels)"; return
        }
        let (clearance, denied) = await gate.clear(docs.map(\.objectID), purpose: "case.contradictions")
        run.deniedForCloud = denied.count
        let cleared = docs.filter { clearance.clearedObjectIDs.contains($0.objectID) }
        guard cleared.count >= 2 else {
            run.notSentReason = "fewer than two of the case's documents may leave the Mac"; return
        }
        for batch in CaseContradictionFinder.batches(cleared, allDocuments: docs) {
            guard batch.passages.allSatisfy({ clearance.clearedObjectIDs.contains($0.objectID) }) else { continue }
            let reply: String
            do {
                reply = try await reader.read(CaseContradictionFinder.prompt(batch), clearance: clearance)
            } catch let notSent as VerifiedAnswerComposer.NotSent {
                KalsmritikoshLog.knowledge.info("case contradiction reading not sent: \(notSent.reason, privacy: .public)")
                run.notSentReason = notSent.reason; return
            } catch is CancellationError {
                KalsmritikoshLog.knowledge.info("case contradiction reading cancelled")
                run.notSentReason = "cancelled"; return
            } catch {
                KalsmritikoshLog.knowledge.error("case contradiction reading failed: \(String(describing: error), privacy: .public)")
                run.failedCalls += 1
                run.failures.append("contradiction call (\(batch.subject ?? "events")): " + VerifiedRoleReader.reason(error))
                continue
            }
            run.calls += 1
            run.passagesSent += batch.passages.count
            absorb(CaseContradictionFinder.verify(reply: reply, batch: batch, allDocuments: docs), into: &run)
        }
    }

    /// The verified pairs of one reading into the run (the rules' own pairs counted, never twice).
    private func absorb(_ check: CaseContradictionFinder.Verification, into run: inout CaseContradictionRun) {
        if check.unreadable { run.aiDropped.append("the reply could not be read"); return }
        run.aiDropped += check.dropped
        for f in check.verified {
            if CaseContradictionFinder.sameAsRule(f, run.ruleFindings) { run.aiAgreedWithRules += 1; continue }
            if !run.aiFindings.contains(where: { $0.contradiction().id == f.contradiction().id }) { run.aiFindings.append(f) }
        }
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

    /// One whole-case read: the case's cached prefix, the contradiction task after it; every pair verified
    /// exactly as on the passage path (passage N = document N as sent).
    private func readWholeCase(_ reader: CaseReader, _ prepared: CaseWholeReading.Prepared, caseID: UUID,
                               docs: [CaseContradictionFinder.Document], into run: inout CaseContradictionRun) async {
        guard let plan = pass?.caseReading else { return }
        guard prepared.documents.count >= 2 else {
            run.notSentReason = "fewer than two of the case's documents may leave the Mac"; return
        }
        let reply: String
        do {
            reply = try await plan.readForAnalysis(reader, prepared, caseID: caseID, task: CaseContradictionFinder.wholeCaseTask(),
                                                   replyTokens: CaseContradictionFinder.wholeCaseReplyTokens,
                                                   purpose: "case.analysis.contradictions").text
        } catch let notSent as VerifiedAnswerComposer.NotSent {
            KalsmritikoshLog.knowledge.info("case contradiction whole-case reading not sent: \(notSent.reason, privacy: .public)")
            run.notSentReason = notSent.reason; return
        } catch is CancellationError {
            KalsmritikoshLog.knowledge.info("case contradiction whole-case reading cancelled")
            run.notSentReason = "cancelled"; return
        } catch {
            KalsmritikoshLog.knowledge.error("case contradiction whole-case reading failed: \(String(describing: error), privacy: .public)")
            run.failedCalls += 1
            run.failures.append("contradiction call (whole case): " + VerifiedRoleReader.reason(error))
            return
        }
        run.calls += 1
        run.passagesSent += prepared.documents.count
        absorb(CaseContradictionFinder.verify(reply: reply, batch: CaseContradictionFinder.wholeCaseBatch(prepared.documents), allDocuments: docs),
               into: &run)
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
        var out: [CaseContradictionReviewItem] = []
        for item in items {
            let c = item.contradiction
            var current: [UUID: UUID?] = [:]
            for ko in [c.evidenceA, c.evidenceB].compactMap({ $0 }) { current[ko] = try await evidence.currentVersionID(forObject: ko) }
            let status = CaseItemReviewStatus.compute(history: history[c.id.uuidString] ?? [], currentVersions: current)
            out.append(CaseContradictionReviewItem(contradiction: c, status: status, currentVersions: current))
        }
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
        var versions: [UUID: UUID] = [:]
        for ko in [c.evidenceA, c.evidenceB].compactMap({ $0 }) {
            if let v = try await evidence.currentVersionID(forObject: ko) { versions[ko] = v }
        }
        let record = try await reviews.recordDecision(caseID: caseID, itemKind: .contradiction, itemID: contradictionID.uuidString,
                                                      decision: decision, reason: reason, note: note, sourceVersions: versions,
                                                      actor: actor, at: date)
        KalsmritikoshLog.knowledge.info("case contradiction \(decision.rawValue, privacy: .public) (reason: \(reason?.rawValue ?? "none", privacy: .public))")
        return record
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

    private func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw InvestigationDeskError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }
}
