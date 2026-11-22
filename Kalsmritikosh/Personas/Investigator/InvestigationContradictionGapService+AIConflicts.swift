//
//  InvestigationContradictionGapService+AIConflicts.swift
//  Kalsmritikosh
//
//  Owner request 2026-11-16: "Look for conflicts with AI…" — the gating and the run around the person's AI, reusing what
//  the case check already has: the rules (they always run, and never depend on the AI), the whole-case reading with its
//  once-per-case permission and document fingerprint (CaseWholeReading), the cloud gate (privileged and withheld
//  documents are never sent; the AI is told nothing about them), the provider's own meter and its refusals, the case's
//  review decisions and the claim links that carry a confirmed conflict into the report. New here: the structured output
//  contract and its verification (AIConflictContract), the store-time re-check, the merge with the rules (one item for a
//  pair found by both), and the ARCH-09 apply-time check inside the one write that stores the result.
//
//  Gating, in order: AI off or not set up → nothing is sent, the rules run, and the screen says what they checked. The
//  estimate is shown before anything runs, for exactly the documents that would be sent; a run whose documents changed
//  since then sends nothing. The case's permission is asked once (CaseWholeReading.permitted). The case is read whole when
//  it fits; otherwise passages are read under the stored permission. A failure, a refusal or a cancel changes nothing.
//

import Foundation
import os

/// What "Look for conflicts with AI…" would do now, shown before it runs.
public nonisolated struct AIConflictScanPreview: Sendable, Equatable {
    public enum Route: String, Sendable { case wholeCase, passages, off }
    public let caseID: UUID
    /// Whether the person's AI may read this case's documents now.
    public var aiAvailable: Bool
    /// AI is off or not set up (nothing is sent; the rules run).
    public var aiOff = true
    /// Why it may not (AI is off, not set up, or nothing of the case may be sent), in plain words.
    public var offReason: String?
    public var route: Route
    public var documentsInCase: Int
    /// The documents that would be sent.
    public var toSend: [String] = []
    /// The documents that would not be sent, each with why (privileged, restricted …).
    public var withheld: [CaseReadConsentRequest.Item] = []
    /// The case's documents this Mac could not read (never sent).
    public var notReadable: [CaseReadConsentRequest.Item] = []
    public var tokens = 0
    public var limit = 0
    /// The cost estimate (credits on a plan, dollars on your own key), shown before anything runs.
    public var estimate: String?
    public var balance: String?
    /// Whether the case's permission already covers these documents (no permission sheet will be shown).
    public var permissionStored = false
    /// The document set the estimate is for.
    public var fingerprint: String?

    /// What would be checked: documents sent, withheld and too large, in plain words.
    public var coverageLine: String {
        if aiOff { return "AI is off; rules checked: " + CaseContradictionFinder.ruleCoverage }
        guard aiAvailable else { return (offReason ?? "Nothing of this case may be sent to the AI.") + " The rules still run." }
        var s = "Documents to send: \(toSend.count) of \(documentsInCase)"
        if !withheld.isEmpty { s += " · withheld: \(withheld.count) (never sent: " + withheld.map { "\($0.name) — \($0.reason ?? "withheld")" }.joined(separator: "; ") + ")" }
        if !notReadable.isEmpty { s += " · not readable on this Mac: \(notReadable.count)" }
        if route == .passages {
            s += " · too large to read whole (about \(tokens.formatted()) tokens, the limit is \(limit.formatted())): passages naming people and events are sent instead"
        }
        return s + "."
    }
}

/// What one "Look for conflicts with AI…" did.
public nonisolated struct AIConflictScanRun: Sendable {
    public enum Outcome: String, Sendable { case aiOff, notSent, declined, done, failed, refused, cancelled }
    public var outcome: Outcome = .aiOff
    /// The result in plain words (shown on the screen).
    public var message = ""
    public var documents = 0
    public var ruleFindings = 0
    /// AI findings stored that the rules did not find.
    public var aiFindings = 0
    /// Rule findings the AI also found (one item, labelled found by rule and AI).
    public var foundByBoth = 0
    /// AI findings that did not verify (or failed the store-time re-check), each with why.
    public var dropped: [String] = []
    public var calls = 0
    /// Calls that did not come back, and why each failed in the provider's words ("conflict call (events): …").
    public var failedCalls = 0
    public var failures: [String] = []
    public var readWholeCase = false
    public var documentsSent = 0
    public var withheld = 0
    /// Cleared documents not sent because the case is too large to read whole (only its passages were).
    public var tooLarge = 0
    /// Reading passages (a case too large to read whole): the subjects named in two or more documents that the per-look
    /// limit left out, and the passages left out (case plan 2026-11-16, SEARCH-14).
    public var subjectsLeftOut: [String] = []
    public var passagesLeftOut = 0
    /// SEARCH-14 — parts of the look over passages: how many there were, how many were done by an earlier look that was
    /// stopped (not sent again), and whether this look was stopped (what came back is kept; the next look continues).
    public var parts = 0
    public var partsResumed = 0
    public var stopped = false
    /// What was checked (documents sent / withheld / too large / left out by the limits).
    public var coverage = ""
    /// The stored items of this run (AI-only and found-by-both).
    public var storedIDs: [UUID] = []
    public init() {}
}

extension InvestigationContradictionGapService {

    static let aiConflictPurpose = "case.analysis.conflicts"
    static let aiConflictRequest = "Look for conflicts with AI"

    // MARK: Preview (shown before anything runs)

    public func aiConflictPreview(caseID: UUID) async throws -> AIConflictScanPreview {
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        var p = AIConflictScanPreview(caseID: caseID, aiAvailable: false, route: .off, documentsInCase: authorized.count)
        guard let plan = pass?.caseReading, let binding = pass?.caseBinding?(caseID) else {
            p.offReason = "AI case reading is not set up. Set up AI in Settings ▸ Online (a plan or your own key), then allow it for this case."
            return p
        }
        guard await plan.reader() != nil else {
            p.offReason = "AI is off or not set up: " + (await plan.offlineReason() ?? "set up AI in Settings ▸ Online.")
            return p
        }
        p.aiOff = false
        let (prepared, excluded) = await plan.prepare(caseID: caseID, versions: authorized, binding: binding)
        p.withheld = excluded
        p.notReadable = await plan.notReadable(caseID)
        guard let prepared else {
            p.offReason = "No document of this case may be sent to the AI" + (excluded.isEmpty ? "." : " (" + excluded.map { "\($0.name): \($0.reason ?? "withheld")" }.joined(separator: "; ") + ").")
            return p
        }
        p.aiAvailable = true
        p.documentsInCase = prepared.caseDocuments
        // Unified path AI-23 (owner 2026-11-22) — not tested yet: every case is read whole, in parts when large.
        p.route = .wholeCase
        p.toSend = prepared.documents.map { $0.fileName ?? "a document" }
        p.tokens = prepared.tokens
        p.limit = prepared.limit
        p.fingerprint = prepared.fingerprint
        p.permissionStored = plan.permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint)
        let sent = prepared.tokens   // AI-23: every part is sent (the briefing once per part)
        p.estimate = plan.estimate(sent, CaseReader.estimatedTokens([AIConflictContract.wholeCaseTask()]) * max(1, prepared.parts.count))
        p.balance = await plan.balanceLine()
        return p
    }

    // MARK: The run

    /// Run the rules and, when AI is on and the person allowed it, the AI's look for conflicts of any kind. `preview` is
    /// the estimate the person saw: a run whose documents changed since then sends nothing. `rulesRun`: the rules' run of
    /// "Find contradictions" just before, reused (not run, stored or linked again) when it compared exactly the case's
    /// documents as they are now; otherwise the rules run here.
    @discardableResult
    public func lookForConflictsWithAI(caseID: UUID, preview: AIConflictScanPreview, rulesRun: CaseContradictionRun? = nil,
                                       at date: Date = Date()) async throws -> AIConflictScanRun {
        var run = AIConflictScanRun()
        guard let pass else { run.outcome = .notSent; run.message = "The case check is not available."; return run }
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        let docs = try await pass.documents(authorized).filter { $0.sourceVersionID.map(authorized.contains) ?? false }
        run.documents = docs.count
        let inCase = await documentsInCase(authorized) ?? docs.count
        // SEARCH-14: the AI looks across every page of the case, not only the rules' first page (read a page at a time).
        var aiDocs = docs
        if inCase > docs.count, let from = pass.documentsFrom {
            var offset = docs.count
            while offset < inCase {
                let page = try await from(authorized, offset).filter { $0.sourceVersionID.map(authorized.contains) ?? false }
                if page.isEmpty { break }
                aiDocs += page
                offset += page.count
            }
        }

        // 1. The rules — always, on this Mac, whatever happens to the AI. Reused from "Find contradictions" just before
        //    when it compared these very documents (already stored and linked there).
        var rules: [CaseContradictionFinder.Finding]
        if let rulesRun, rulesRun.available, rulesRun.versions == Set(docs.compactMap(\.sourceVersionID)) {
            rules = rulesRun.ruleFindings
        } else {
            rules = CaseContradictionFinder.ruleFindings(docs)
            if let money = pass.moneyMovements {
                do { rules += CaseContradictionFinder.moneyRecordFindings(docs, movements: try await money(caseID)) } catch {
                    KalsmritikoshLog.knowledge.error("AI conflict look: money records unreadable: \(String(describing: error), privacy: .public)")
                }
            }
            let ruleRows = rules.map { $0.contradiction(at: date) }
            await contradictions.insertMany(ruleRows)
            if let link = pass.linkClaims, !ruleRows.isEmpty { _ = await link(ruleRows) }
        }
        run.ruleFindings = rules.count
        let rulesLine = "\(rules.count) found by the rules."

        // 2. Gating: AI on and set up, something may be sent, the estimate shown was for these documents.
        guard let plan = pass.caseReading, let binding = pass.caseBinding?(caseID), let reader = await plan.reader() else {
            run.outcome = .aiOff
            run.coverage = "AI is off; rules checked: " + CaseContradictionFinder.ruleCoverage
            run.message = "AI is off — nothing was sent. " + rulesLine
            return run
        }
        let (preparedOrNil, excluded) = await plan.prepare(caseID: caseID, versions: authorized, binding: binding)
        run.withheld = excluded.count
        guard let prepared = preparedOrNil else {
            run.outcome = .notSent
            run.message = "Nothing was sent: no document of this case may be sent to the AI. " + rulesLine
            return run
        }
        guard preview.aiAvailable, preview.fingerprint == prepared.fingerprint else {
            run.outcome = .notSent
            run.message = "Nothing was sent: the case's documents changed since the estimate was shown. Choose “Look for conflicts with AI…” again to see the new estimate. " + rulesLine
            return run
        }
        // 3. The case's permission (asked once per case and document set).
        guard await plan.permitted(caseID: caseID, prepared: prepared, question: Self.aiConflictRequest) else {
            run.outcome = .declined
            run.message = "Nothing was sent: you did not allow the AI to read this case's documents. " + rulesLine
            return run
        }

        // 4. The read: the whole case in one call when it fits, else passages under the stored permission.
        var replies: [(reply: String, batch: CaseContradictionFinder.Batch)] = []
        var sentObjects = Set<UUID>()
        do {
            // Unified path AI-23 (owner 2026-11-22) — not tested yet: the briefing + every part on the one path;
            // the passage branch below is kept only for a prepared case with no parts (never produced).
            if !prepared.parts.isEmpty {
                run.readWholeCase = true
                let reply = try await plan.readForAnalysis(reader, prepared, caseID: caseID, task: AIConflictContract.wholeCaseTask(),
                                                           replyTokens: AIConflictContract.wholeCaseReplyTokens, purpose: Self.aiConflictPurpose,
                                                           background: true)   // Unified path AI-24 (owner 2026-11-22): batch
                run.calls += 1
                replies.append((reply.text, CaseContradictionFinder.wholeCaseBatch(prepared.documents)))
                sentObjects = Set(prepared.documents.map(\.objectID))
            } else {
                guard let passageReader = pass.reader() else {
                    run.outcome = .notSent
                    run.message = "Nothing was sent: the case is too large to read whole and reading passages is not set up. " + rulesLine
                    return run
                }
                let cleared = aiDocs.filter { prepared.clearance.clearedObjectIDs.contains($0.objectID) }
                let permitted = CaseReadPermittedSet(caseID: caseID, versions: prepared.clearance.versions)
                // Case plan 2026-11-16 (SEARCH-14): the limits' omissions are recorded, never dropped silently.
                let batchPlan = CaseContradictionFinder.batchPlan(cleared, allDocuments: aiDocs)
                run.subjectsLeftOut = batchPlan.subjectsLeftOut
                run.passagesLeftOut = batchPlan.passagesLeftOut
                let batches = batchPlan.batches
                    .filter { $0.passages.allSatisfy { prepared.clearance.clearedObjectIDs.contains($0.objectID) } }
                // SEARCH-14: parts a stopped look already kept for these documents are not sent again.
                let done = (try? await pass.conflictDetails?.doneUnits(caseID: caseID, fingerprint: prepared.fingerprint)) ?? []
                run.parts = batches.count
                for batch in batches {
                    if done.contains(Self.unitKey(batch)) { run.partsResumed += 1; continue }
                    let text: String
                    do {
                        text = try await CaseReadPermittedSet.$current.withValue(permitted) {
                            try await passageReader.read(AIConflictContract.prompt(batch), clearance: prepared.clearance)
                        }
                    } catch is CancellationError where !replies.isEmpty {
                        // Stopped: what came back is kept below; the next look continues with the rest.
                        run.stopped = true
                        break
                    } catch {
                        // Not sent, a refusal or a stop ends the look; any other failure is this call's own: recorded with
                        // the provider's words, and the other batches still run.
                        if Self.endsTheLook(error) { throw error }
                        KalsmritikoshLog.knowledge.error("AI conflict look: a passage call failed: \(String(describing: error), privacy: .public)")
                        run.failedCalls += 1
                        run.failures.append("conflict call (\(batch.subject ?? "events")): " + VerifiedRoleReader.reason(error))
                        continue
                    }
                    run.calls += 1
                    replies.append((text, batch))
                    sentObjects.formUnion(batch.passages.map(\.objectID))
                }
                run.tooLarge = cleared.filter { !sentObjects.contains($0.objectID) }.count
                if replies.isEmpty, run.partsResumed > 0, run.failures.isEmpty {
                    run.outcome = .done
                    run.message = "Every part of this look was done by the earlier look, which was stopped; its findings are already kept. " + rulesLine
                    try? await pass.conflictDetails?.clearUnits(caseID: caseID, fingerprint: prepared.fingerprint)
                    return run
                }
                if replies.isEmpty, let first = run.failures.first {
                    run.outcome = .failed
                    run.message = "The AI did not answer (\(run.failedCalls) call(s) failed — \(first)). Nothing from the AI was stored; the case is unchanged. " + rulesLine
                    run.coverage = Self.coverage(sent: 0, of: inCase, withheld: excluded.count, tooLarge: 0, rulesChecked: docs.count)
                    return run
                }
            }
        } catch {
            let (outcome, why) = Self.aiFailure(error)
            if outcome == .failed {
                run.failedCalls += 1
                run.failures.append("conflict call (\(run.readWholeCase ? "whole case" : "passages")): " + VerifiedRoleReader.reason(error))
            }
            KalsmritikoshLog.knowledge.info("AI conflict look did not come back: \(outcome.rawValue, privacy: .public)")
            run.outcome = outcome
            run.message = why + " Nothing from the AI was stored; the case is unchanged. " + rulesLine
            run.coverage = Self.coverage(sent: 0, of: inCase, withheld: excluded.count, tooLarge: 0, rulesChecked: docs.count)
            return run
        }
        run.documentsSent = sentObjects.count
        run.coverage = Self.coverage(sent: sentObjects.count, of: inCase, withheld: excluded.count, tooLarge: run.tooLarge, rulesChecked: docs.count)
            + Self.leftOutLine(subjects: run.subjectsLeftOut, passages: run.passagesLeftOut)
        let kept: AIConflictScanRun
        if run.stopped {
            // The person stopped the look: the parts that came back are checked and kept in work that is not itself
            // cancelled, so they are not lost; the next look over the same documents sends only the rest.
            let input = (run, replies, sentObjects, docs, aiDocs, rules, rulesLine, prepared, plan, binding, caseID, date)
            kept = await Task { await self.keep(input.0, replies: input.1, sentObjects: input.2, docs: input.3, aiDocs: input.4, rules: input.5,
                                                rulesLine: input.6, prepared: input.7, plan: input.8, binding: input.9, caseID: input.10, date: input.11) }.value
        } else {
            kept = await keep(run, replies: replies, sentObjects: sentObjects, docs: docs, aiDocs: aiDocs, rules: rules, rulesLine: rulesLine,
                              prepared: prepared, plan: plan, binding: binding, caseID: caseID, date: date)
        }
        var out = kept
        if !out.readWholeCase, out.outcome == .done, let repo = pass.conflictDetails {
            let keys = replies.map { Self.unitKey($0.batch) }
            if out.stopped {
                do { try await Task { try await repo.markUnitsDone(caseID: caseID, fingerprint: prepared.fingerprint, units: keys) }.value } catch {
                    KalsmritikoshLog.knowledge.error("AI conflict look: finished parts not recorded: \(String(describing: error), privacy: .public)")
                }
                let left = out.parts - out.partsResumed - keys.count
                out.outcome = .cancelled
                let continueHint: String = left > 0 ? "Choose “Look for conflicts with AI…” again to continue with the other \(left) part(s) — the kept ones are not sent again. " : ""
                out.message = "Stopped after \(keys.count) of \(out.parts - out.partsResumed) part(s); the parts that came back were checked and kept. \(continueHint)"
                    + out.message
            } else {
                do { try await repo.clearUnits(caseID: caseID, fingerprint: prepared.fingerprint) } catch {
                    KalsmritikoshLog.knowledge.error("AI conflict look: parts not cleared: \(String(describing: error), privacy: .public)")
                }
                if out.partsResumed > 0 { out.message = "Continued from the stopped look: \(out.partsResumed) part(s) already done were not sent again. " + out.message }
            }
        }
        return out
    }

    /// One part (batch) of a look over passages, identified by its subject and its documents (stable across looks).
    nonisolated static func unitKey(_ b: CaseContradictionFinder.Batch) -> String {
        CaseFileHash.sha256((b.subject ?? "events") + "|" + b.passages.map { $0.objectID.uuidString.lowercased() }.sorted().joined(separator: ","))
    }

    /// Steps 5–7: verify every reply against what was sent, re-check at store time and store with the rules merged.
    private func keep(_ runIn: AIConflictScanRun, replies: [(reply: String, batch: CaseContradictionFinder.Batch)], sentObjects: Set<UUID>,
                      docs: [CaseContradictionFinder.Document], aiDocs: [CaseContradictionFinder.Document], rules: [CaseContradictionFinder.Finding],
                      rulesLine: String, prepared: CaseWholeReading.Prepared, plan: CaseWholeReading, binding: CloudScopeBinding,
                      caseID: UUID, date: Date) async -> AIConflictScanRun {
        var run = runIn
        guard let pass else { run.outcome = .notSent; run.message = "The case check is not available."; return run }

        // 5. Verify every finding against exactly what was sent.
        var verified: [AIConflictContract.Verified] = []
        for r in replies {
            let check = AIConflictContract.verify(reply: r.reply, batch: r.batch, allDocuments: aiDocs)
            if let why = check.unreadable { run.dropped.append(why); continue }
            run.dropped += check.dropped
            for v in check.verified where !verified.contains(where: { $0.stableID == v.stableID }) { verified.append(v) }
        }

        // 6. Again at store time: the permission still covers the documents, every side's document is still in the case,
        //    and the cloud gate still clears it (one made privileged or restricted meanwhile drops the finding).
        guard plan.permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint) else {
            run.outcome = .refused
            run.message = "Not stored: the AI permission for this case no longer covers these documents. " + rulesLine
            return run
        }
        let nowAuthorized: Set<UUID>
        do { nowAuthorized = try await authorizedSet(caseID) } catch {
            KalsmritikoshLog.knowledge.notice("AI conflict look: the case could not be read after the AI replied: \(String(describing: type(of: error)), privacy: .public)")
            run.outcome = .refused
            run.message = "Not stored: the case changed while the AI was working (it was erased or could not be read). " + rulesLine
            return run
        }
        let inScope = Set(aiDocs.filter { $0.sourceVersionID.map(nowAuthorized.contains) ?? false }.map(\.objectID))
        var stillCleared = sentObjects
        if let gate = plan.gate()?.bound(to: binding) {
            let (again, _) = await gate.clear(Array(sentObjects), purpose: Self.aiConflictPurpose + ".store")
            stillCleared = sentObjects.intersection(again.clearedObjectIDs)
        }
        let rechecked = AIConflictContract.recheck(verified, sent: stillCleared, inScope: inScope)
        run.dropped += rechecked.dropped

        // 7. Merge with the rules and store in one write, with the apply-time check (ARCH-09) inside it.
        let merged = AIConflictContract.merge(rules: rules, ai: rechecked.kept)
        guard let repo = pass.conflictDetails else {
            run.outcome = .notSent
            run.message = "The AI's findings could not be kept (no store for them is set up). " + rulesLine
            return run
        }
        var conflicts: [Contradiction] = []
        var details: [CaseConflictDetail] = []
        var versions = Set<UUID>()
        for v in merged.aiOnly {
            conflicts.append(v.contradiction(at: date))
            details.append(v.detail(caseID: caseID, foundBy: .ai, fingerprint: prepared.fingerprint, at: date))
            versions.formUnion(v.sides.compactMap(\.sourceVersionID))
        }
        for pair in merged.both {
            details.append(AIConflictContract.detail(rule: pair.rule, ai: pair.ai, caseID: caseID, fingerprint: prepared.fingerprint, at: date))
            versions.formUnion(pair.ai.sides.compactMap(\.sourceVersionID))
        }
        if !details.isEmpty {
            do {
                try await repo.store(caseID: caseID, conflicts: conflicts, details: details,
                                     recheck: CaseApplyRecheck.inputsCurrent(versions.sorted { $0.uuidString < $1.uuidString }))
            } catch {
                KalsmritikoshLog.knowledge.notice("AI conflict look: not stored: \(String(describing: type(of: error)), privacy: .public)")
                run.outcome = .refused
                run.message = (error as? LocalizedError)?.errorDescription ?? "Not stored: the case changed while the AI was working."
                run.message += " " + rulesLine
                return run
            }
            if let link = pass.linkClaims, !conflicts.isEmpty { _ = await link(conflicts) }
        }
        run.aiFindings = merged.aiOnly.count
        run.foundByBoth = merged.both.count
        run.storedIDs = details.map(\.contradictionID)
        run.outcome = .done
        var m = "\(rules.count) found by the rules; the AI proposed \(merged.aiOnly.count) more"
        if !merged.both.isEmpty { m += " and also found \(merged.both.count) of the rules' items" }
        m += ". Every quote was checked word for word against its document"
        if !run.dropped.isEmpty { m += "; \(run.dropped.count) proposal(s) did not check out and are not shown" }
        if !run.failures.isEmpty { m += "; \(run.failedCalls) call(s) failed — " + run.failures.prefix(3).joined(separator: "; ") }
        run.message = m + ". The AI's items are proposals until you confirm them."
        KalsmritikoshLog.knowledge.info("AI conflict look: \(rules.count, privacy: .public) rules, \(merged.aiOnly.count, privacy: .public) AI, \(merged.both.count, privacy: .public) both, \(run.dropped.count, privacy: .public) dropped, \(run.calls, privacy: .public) call(s)")
        return run
    }

    /// The case's conflict details (open kind, who found it, every side, the AI's explanation), by conflict id.
    public func conflictDetails(caseID: UUID) async throws -> [UUID: CaseConflictDetail] {
        guard let repo = pass?.conflictDetails else { return [:] }
        return try await repo.details(caseID: caseID)
    }

    // MARK: Helpers

    /// `total`: the case's documents; `rulesChecked`: how many of them the rules compared (fewer when the per-run limit
    /// applied — then the line says so, never "every document").
    static func coverage(sent: Int, of total: Int, withheld: Int, tooLarge: Int, rulesChecked: Int? = nil) -> String {
        var s = "Checked by the AI: \(sent) of \(total) document\(total == 1 ? "" : "s") sent"
        if withheld > 0 { s += "; \(withheld) withheld (privileged or restricted — never sent)" }
        if tooLarge > 0 { s += "; \(tooLarge) not sent because the case is too large to read whole (only passages were)" }
        if let rulesChecked, rulesChecked < total {
            return s + ". The rules checked \(rulesChecked) of the \(total) documents; the other \(total - rulesChecked) were not compared in this run."
        }
        return s + ". The rules checked every document."
    }

    /// The passages a look over passages did not send because of its limits ("" when nothing was left out).
    static func leftOutLine(subjects: [String], passages: Int) -> String {
        var parts: [String] = []
        if !subjects.isEmpty {
            let named = subjects.prefix(5).joined(separator: ", ") + (subjects.count > 5 ? " and \(subjects.count - 5) more" : "")
            parts.append("\(subjects.count) subject(s) named in two or more documents were not sent (\(named))")
        }
        if passages > 0 { parts.append("\(passages) passage(s) beyond the per-subject limit were not sent") }
        return parts.isEmpty ? "" : " Not compared by the AI in this look: " + parts.joined(separator: "; ") + "."
    }

    /// A failure that ends the whole look (nothing was sent, the meter or the relay refused, or the person stopped it),
    /// rather than one passage call's own.
    static func endsTheLook(_ error: Error) -> Bool {
        if case .failed = aiFailure(error).0 { return false }
        return true
    }

    /// The outcome and honest words for a read that did not come back.
    static func aiFailure(_ error: Error) -> (AIConflictScanRun.Outcome, String) {
        if error is CancellationError { return (.cancelled, "Stopped.") }
        if let notSent = error as? VerifiedAnswerComposer.NotSent { return (.notSent, "Nothing was sent: \(notSent.reason).") }
        if let refusal = error as? AIPlanRefusal { return (.refused, refusal.message) }
        if let limit = error as? OwnKeyBudget.LimitReached { return (.refused, limit.reason) }
        if case AIIncludedRelay.RelayError.refused(let why)? = error as? AIIncludedRelay.RelayError { return (.refused, why) }
        return (.failed, "The AI did not answer: " + VerifiedRoleReader.reason(error) + ".")
    }

    /// Who found a stored conflict (nil: the archive-wide scan, not this case's check).
    public nonisolated static func foundBy(_ c: Contradiction, detail: CaseConflictDetail?) -> ConflictFoundBy? {
        if let detail { return detail.foundBy }
        switch CaseContradictionFinder.provenance(of: c) {
        case .rules?: return .rule
        case .aiRead?: return .ai
        case nil: return nil
        }
    }
}
