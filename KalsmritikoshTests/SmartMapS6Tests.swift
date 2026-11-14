//
//  SmartMapS6Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S6 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: CHANGE and PEOPLE of milestone M2; schema v182).
//  Throwaway ledgers and synthetic projections; expected results written by hand. AI off: nothing here calls a model or the
//  network — a "generated" brief is plain text handed to the fence, as a job would hand it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

/// A new current version of the document behind `object` (its own text), included in the case.
private func s6Revise(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID, text: String) async throws -> UUID {
    let fileID = try #require(try await db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(object)]).first?.uuid(0))
    try await db.exec("UPDATE source_versions SET is_current = 0 WHERE logical_source_id = ?;", [.uuid(fileID)])
    let version = UUID(), doc = UUID(), t = Date().timeIntervalSince1970
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
            filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(version), .uuid(fileID), .uuid(doc), .text(hex + hex), .real(t), .integer(1), .real(t),
              .text("revised.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(t)])
    try await db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(doc), .uuid(version), .integer(0), .text("paragraph"), .text(text), .text(text.lowercased()), .text("native"), .real(1.0)])
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
    return version
}

private func s6Count(_ db: Database, _ sql: String, _ binds: [SQLValue]) async throws -> Int {
    Int(try await db.query(sql, binds).first?.int(0) ?? -1)
}

/// A case with a document, an allegation supported by a passage of it, and the map/feed services.
@MainActor
private struct S6Rig {
    let f: CaseFileTests.Fixture
    let doc: (version: UUID, object: UUID, blocks: [UUID])
    let allegation: UUID
    let feeds: CaseChangeFeedService
    static func make() async throws -> S6Rig {
        let f = try await CaseFileTests.fixture(title: "Supplier payments")
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "bank-statement.txt",
                                                            text: "Transfer to Dalmia Traders on 5 March 2026 for ₹10,000. A second transfer of ₹10,000 followed on 9 March 2026.")
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "The supplier was paid twice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: doc.version.uuidString, label: "Bank statement", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: doc.version, quote: "A second transfer of ₹10,000 followed on 9 March 2026."),
                                         actor: "Ada")
        return S6Rig(f: f, doc: doc, allegation: a, feeds: CaseChangeFeedService(database: f.db))
    }
    func projection() async throws -> CaseMapProjection { try #require(await caseMapLoad(f).projection) }
    func docNode() async throws -> CaseMapNodeID {
        let logical = try #require(try await f.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(doc.version)]).first?.uuid(0))
        return CaseMapNodeID(caseID: f.caseID, kind: .document, id: logical)
    }
    var allegationNode: CaseMapNodeID { CaseMapNodeID(caseID: f.caseID, kind: .allegation, id: allegation) }
    func revise() async throws { _ = try await s6Revise(f.db, object: doc.object, cases: f.cases, caseID: f.caseID, text: "Only one transfer of ₹10,000 was made.") }
}

// MARK: - CHANGE

@MainActor
@Suite("Smart map S6 — change and impact (CHANGE)", .serialized)
struct SmartMapS6ChangeTests {

    @Test("CHANGE-03: a change travels along typed dependency links to any depth, cycle-safe and cancellable; social and mention adjacency is not followed")
    func typedTransitiveTraversal() {
        let c = UUID()
        let d = S3Synth.node(c, .document, "d", .evidence, "Bank statement")
        let a = S3Synth.node(c, .allegation, "a", .question, "Supplier paid twice", review: .confirmed)
        let r = S3Synth.node(c, .reportItem, "r", .finding, "Finding: paid twice", review: .accepted)
        let t = S3Synth.node(c, .task, "t", .action, "Recover the overpayment", workOpen: true)
        let p = S3Synth.node(c, .person, "p", .person, "Ravi Kumar")
        let p2 = S3Synth.node(c, .person, "p2", .person, "Ravi Kumar")
        let s2 = S3Synth.node(c, .interview, "s2", .statement, "Ravi's other statement")
        let a2 = S3Synth.node(c, .allegation, "a2", .question, "Unrelated: late deliveries", review: .confirmed)
        let links = [S3Synth.link(c, .supports, d.id, a.id), S3Synth.link(c, .selectedForReport, r.id, a.id), S3Synth.link(c, .dependsOn, t.id, r.id),
                     S3Synth.link(c, .challenges, t.id, a.id),                         // a cycle a → r → t → a
                     S3Synth.link(c, .mentions, d.id, p.id), S3Synth.link(c, .attributedTo, s2.id, p.id),
                     S3Synth.link(c, .possibleSamePerson, p.id, p2.id), S3Synth.link(c, .supports, s2.id, a2.id)]
        let proj = S3Synth.projection(c, [d, a, r, t, p, p2, s2, a2], links)
        let trace = CaseDependencyTraversal.trace(from: d.id, in: proj)
        #expect(trace.isComplete)
        #expect(trace.entries.map(\.node) == [a.id, r.id, t.id], "allegation (1), the finding selected under it (2), the task depending on the finding (3)")
        #expect(trace.entries.map(\.depth) == [1, 2, 3])
        #expect(trace.entries.last?.explanation == "“Bank statement” supports “Supplier paid twice” → “Finding: paid twice” selected for report “Supplier paid twice” → “Recover the overpayment” depends on “Finding: paid twice”")
        // Social adjacency is not dependency: the person, their other statement and the unrelated question are not reached.
        for unrelated in [p.id, p2.id, s2.id, a2.id] { #expect(!trace.nodes.contains(unrelated), "\(unrelated)") }
        #expect(trace.notFollowed[.mentions] == 1 && trace.notFollowedLine?.contains("adjacency is not dependency") == true)
        // Recorded decisions stay as they were; the walk only flags them.
        #expect(trace.entries.first { $0.node == r.id }?.keepsDecision == true && trace.entries.first { $0.node == r.id }?.review == .accepted)
        // The feed's impact uses the same walk: direct, then further along the path.
        let impact = CaseChangeImpactAnalysis.impact(of: d.id, in: proj)
        #expect(impact.direct.map(\.node) == [a.id] && impact.mayNeedReview.map(\.node) == [r.id, t.id] && impact.notFollowed != nil)
        // The earlier walk (any link, two hops) reached the person; the typed walk does not.
        #expect(!impact.direct.contains { $0.node == p.id } && !impact.mayNeedReview.contains { $0.node == p.id })
        // Cancellation and the budget stop the walk visibly.
        #expect(CaseDependencyTraversal.trace(from: d.id, in: proj, isCancelled: { true }).state == .cancelled)
        #expect(CaseDependencyTraversal.trace(from: d.id, in: proj, budget: 1).state == .budgetReached(1))
        // A 2,000-deep chain terminates and reaches the end.
        var nodes = [d], chain: [CaseMapLink] = []
        var prev = d.id
        for i in 0..<2000 {
            let n = S3Synth.node(c, .task, String(format: "k%04d", i), .action, "Step \(i)")
            nodes.append(n); chain.append(S3Synth.link(c, .derivedFrom, n.id, prev)); prev = n.id
        }
        let long = CaseDependencyTraversal.trace(from: d.id, in: S3Synth.projection(c, nodes, chain))
        #expect(long.isComplete && long.entries.count == 2000 && long.deepest == 2000)
    }

    @Test("CHANGE-02 / CHANGE-03: a summary and an output bound to their inputs say exactly why they went stale after a source amendment; the walk reaches them through the binding")
    func derivationInputsExplainStaleness() async throws {
        let rig = try await S6Rig.make()
        let f = rig.f, c = f.caseID
        let p1 = try await rig.projection()
        let docKey = try await rig.docNode().key
        let brief = UUID()
        _ = try await f.file.bindDerivation(caseID: c, derived: .summary, derivedID: brief.uuidString, label: "Case summary",
                                            inputs: [docKey, rig.allegationNode.key], projection: p1, actor: "Ada")
        let output = UUID()
        _ = try await f.file.bindDerivation(caseID: c, derived: .output, derivedID: output.uuidString, label: "Interim report",
                                            inputs: ["summary:" + brief.uuidString.lowercased()], projection: p1, actor: "Ada")
        await #expect(throws: CaseChangeWorkError.self) {
            _ = try await f.file.bindDerivation(caseID: c, derived: .output, derivedID: "x", label: "Bad", inputs: ["allegation:" + UUID().uuidString], projection: p1, actor: "Ada")
        }
        var bindings = try await f.file.derivationBindings(caseID: c)
        #expect(bindings.count == 2 && bindings[0].inputs.count == 2)
        #expect(CaseDerivation.staleness(of: "summary:" + brief.uuidString.lowercased(), bindings: bindings, in: p1)?.isStale == false)

        try await rig.revise()
        let p2 = try await rig.projection()
        bindings = try await f.file.derivationBindings(caseID: c)
        let s = try #require(CaseDerivation.staleness(of: "summary:" + brief.uuidString.lowercased(), bindings: bindings, in: p2))
        #expect(s.isStale && s.reasons.contains { $0.contains("bank-statement") || $0.contains("source version changed") }, "\(s.reasons)")
        #expect(s.reasons.allSatisfy { !$0.contains("Supplier was paid twice") } || s.unchangedInputs >= 0)
        let o = try #require(CaseDerivation.staleness(of: "output:" + output.uuidString.lowercased(), bindings: bindings, in: p2))
        #expect(o.isStale && o.reasons.first?.contains("rests on inputs that changed") == true, "\(o.reasons)")
        // The walk from the amended document reaches the summary and then the output, through the recorded bindings.
        let trace = CaseDependencyTraversal.trace(from: try await rig.docNode(), in: p2, derivations: bindings)
        let keys = trace.entries.map(\.key)
        #expect(keys.contains(rig.allegationNode.key) && keys.contains("summary:" + brief.uuidString.lowercased()) && keys.contains("output:" + output.uuidString.lowercased()))
        #expect((trace.entries.first { $0.key.hasPrefix("output:") }?.depth ?? 0) >= 2)
        // The binding rows are append-only.
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_derivation_inputs SET derived_label = 'x';", []) }
        // Nothing was decided again.
        #expect(try await f.file.allegations(caseID: c).first { $0.id == rig.allegation }?.disposition == .pending)
    }

    @Test("CHANGE-04 / CHANGE-08 / PEOPLE-09: a generated brief is a proposal beside the accepted one, applied only if no newer edit, unchanged inputs, unchanged policy, an active requester and an open case; every attempt is recorded")
    func refreshIsNotApprovalAndLateResultsAreFenced() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let anchor = CaseMapNodeID(caseID: c, kind: .caseFile, id: c)
        let v1 = try await f.file.writeBrief(caseID: c, anchor: anchor, text: CaseBriefText(position: "Two payments were made; one may be a duplicate."), expectedVersion: 0, actor: "Ada")
        try await f.file.acceptBrief(caseID: c, id: v1, actor: "Ada")
        let policy = "ai:on|permission:granted"
        let gen = CaseBriefText(position: "Generated: two payments; the second matches the first.")

        let f1 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ada")
        let first = try await f.file.applyGeneratedBrief(f1, text: gen, generatedBy: "rule: brief drafter v1", policyNow: policy)
        #expect(first.isApplied)
        var view = CaseBriefRefreshView.resolve(try await f.file.briefLedger(caseID: c), anchor: anchor)
        #expect(view.accepted?.id == v1 && view.accepted?.position == "Two payments were made; one may be a duplicate.")
        #expect(view.proposal?.origin == .generated && view.proposal?.isAccepted == false && view.proposal?.version == 2)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_briefs SET position = 'silently amended' WHERE id = ?;", [.uuid(v1)]) }

        // A person writes while a job runs: the late result is refused.
        let f2 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ada")
        let v3 = try await f.file.writeBrief(caseID: c, anchor: anchor, text: CaseBriefText(position: "Ada's own revision"), expectedVersion: 2, actor: "Ada")
        #expect(try await f.file.resultFenceIsCurrent(f2, policyNow: policy) == false)
        guard case .refusedNewerEdit = try await f.file.applyGeneratedBrief(f2, text: gen, generatedBy: "rule: brief drafter v1", policyNow: policy) else {
            Issue.record("a newer edit must refuse the late result"); return
        }
        // A person's unaccepted draft is not covered by a generated one.
        let f3 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ada")
        guard case .refusedNewerEdit = try await f.file.applyGeneratedBrief(f3, text: gen, generatedBy: "rule: brief drafter v1", policyNow: policy) else {
            Issue.record("a person's draft must not be covered"); return
        }
        try await f.file.acceptBrief(caseID: c, id: v3, actor: "Ada")
        // The inputs change while the job runs.
        let f4 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ada")
        _ = try await f.file.addAllegation(caseID: c, text: "A new question arrived", actor: "Ada")
        guard case .refusedInputsChanged = try await f.file.applyGeneratedBrief(f4, text: gen, generatedBy: "rule: brief drafter v1", policyNow: policy) else {
            Issue.record("changed inputs must refuse"); return
        }
        view = CaseBriefRefreshView.resolve(try await f.file.briefLedger(caseID: c), anchor: anchor)
        #expect(view.accepted?.id == v3 && view.acceptedIsStale, "the accepted brief stays as written and says it predates the change")
        // The policy changes.
        let f5 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ada")
        guard case .refusedPolicyChanged = try await f.file.applyGeneratedBrief(f5, text: gen, generatedBy: "rule: brief drafter v1", policyNow: "ai:off") else {
            Issue.record("a changed policy must refuse"); return
        }
        // The requester left the team (PEOPLE-09): their queued job cannot act.
        _ = try await f.file.addTeamMember(caseID: c, member: "Ada", role: .lead, actor: "Ada")
        let ben = try await f.file.addTeamMember(caseID: c, member: "Ben", role: .investigator, actor: "Ada")
        let f6 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ben")
        try await f.file.endTeamMembership(caseID: c, membershipID: ben, reason: "Moved to another unit", transferTo: nil, actor: "Ada")
        guard case .refusedPolicyChanged(let why) = try await f.file.applyGeneratedBrief(f6, text: gen, generatedBy: "rule: brief drafter v1", policyNow: policy),
              why.contains("can no longer act") else { Issue.record("an ended member's job must be refused"); return }
        // The case closes: the result is queued, not applied and not dropped.
        let f7 = try await f.file.resultFence(caseID: c, anchor: anchor, policy: policy, requestedBy: "Ada")
        try await f.file.markClosed(caseID: c, reopened: false, actor: "Ada")
        guard case .refusedClosed(let late) = try await f.file.applyGeneratedBrief(f7, text: gen, generatedBy: "rule: brief drafter v1", policyNow: policy) else {
            Issue.record("a closed case must queue the result"); return
        }
        #expect(try await f.file.lateContributions(caseID: c).contains { $0.id == late && $0.kind == .result && $0.state == .queued })
        let attempts = try await f.file.resultApplications(caseID: c).map(\.outcome)
        #expect(attempts == ["applied", "refusedNewerEdit", "refusedNewerEdit", "refusedInputsChanged", "refusedPolicyChanged", "refusedPolicyChanged", "refusedClosed"])
        #expect(try await s6Count(f.db, "SELECT COUNT(*) FROM case_briefs WHERE case_id = ?;", [.uuid(c)]) == 3, "only the one fenced result was written")
    }

    @Test("CHANGE-05: each person has a seen position; marking seen clears no obligation and changes no review; an acknowledgement with a note does, without deciding anything")
    func personalReview() async throws {
        let rig = try await S6Rig.make()
        let f = rig.f, c = f.caseID
        let p0 = try await rig.projection()
        let seed = await rig.feeds.load(caseID: c, projection: p0, viewer: "Ada")
        try await rig.feeds.markSeen(seed, actor: "Ada")
        try await rig.feeds.markSeen(await rig.feeds.load(caseID: c, projection: p0, viewer: "Ben"), actor: "Ben")
        try await Task.sleep(nanoseconds: 5_000_000)
        try await rig.revise()
        let p = try await rig.projection()
        let ada = await rig.feeds.load(caseID: c, projection: p, viewer: "Ada")
        let revised = try #require(ada.newChanges.first { $0.kind == .documentRevised })
        try await rig.feeds.markSeen(ada, actor: "Ada", projection: p)
        let adaAgain = await rig.feeds.load(caseID: c, projection: p, viewer: "Ada")
        let ben = await rig.feeds.load(caseID: c, projection: p, viewer: "Ben")
        #expect(!adaAgain.newChanges.contains { $0.id == revised.id }, "Ada has seen it")
        #expect(ben.newChanges.contains { $0.id == revised.id }, "Ben has not: seen positions are per person")
        #expect(try await rig.feeds.seenPosition(caseID: c, viewer: "Cara") == nil, "someone else's position never stands in for Cara's")
        // Scrolling past it cleared no obligation.
        let reviewsBefore = try await s6Count(f.db, "SELECT COUNT(*) FROM investigation_review_decisions WHERE case_id = ?;", [.uuid(c)])
        #expect(!adaAgain.changes.contains { $0.id == revised.id }, "the change has left Ada's feed window")
        var obligations = CaseChangeObligations.list(adaAgain, projection: p, acknowledgements: try await rig.feeds.acknowledgements(caseID: c),
                                                     notifications: try await rig.feeds.impactNotifications(caseID: c))
        let ob = try #require(obligations.first { $0.change.id == revised.id })
        #expect(ob.isOpen && ob.dependents.contains { $0.node == rig.allegationNode })
        await #expect(throws: CaseChangeWorkError.blankNote) { _ = try await rig.feeds.acknowledge(ob.change, caseID: c, note: "  ", actor: "Ada") }
        _ = try await rig.feeds.acknowledge(ob.change, caseID: c, note: "Checked the new version: the second transfer is no longer listed; the question needs review.", actor: "Ada")
        obligations = CaseChangeObligations.list(adaAgain, projection: p, acknowledgements: try await rig.feeds.acknowledgements(caseID: c),
                                                 notifications: try await rig.feeds.impactNotifications(caseID: c))
        #expect(obligations.first { $0.id == ob.id }?.acknowledgedBy == ["Ada"])
        #expect(try await s6Count(f.db, "SELECT COUNT(*) FROM investigation_review_decisions WHERE case_id = ?;", [.uuid(c)]) == reviewsBefore)
        #expect(try await f.file.allegations(caseID: c).first { $0.id == rig.allegation }?.disposition == .pending)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_change_acknowledgements SET note = 'x';", []) }
    }

    @Test("CHANGE-01 / CHANGE-06: typed events for identity, roles, assignment, access and amendments reach the feed, layout does not; groups keep every member, their impact and what is unresolved")
    func typedEventsAndAggregation() async throws {
        let rig = try await S6Rig.make()
        let f = rig.f, c = f.caseID
        let p0 = try await rig.projection()
        try await rig.feeds.markSeen(await rig.feeds.load(caseID: c, projection: p0, viewer: "Ada"), actor: "Ada")
        try await Task.sleep(nanoseconds: 5_000_000)
        // Cosmetic: layout positions and a saved view write no feed entry.
        try await CaseMapRepository(database: f.db).savePlacements(caseID: c, [rig.allegationNode: CaseMapPlacement(point: CaseMapPoint(x: 10, y: 20))])
        #expect(await rig.feeds.load(caseID: c, projection: try await rig.projection(), viewer: "Ada").newChanges.isEmpty)
        #expect(CaseChangeClassifier.classify(action: "mapViewSaved") == .cosmetic && CaseChangeClassifier.classify(action: "briefWritten") == .cosmetic)
        #expect(CaseChangeClassifier.classify(action: "identityDecided") == .semantic(.identity))
        #expect(CaseChangeClassifier.classify(action: "workAssigned") == .semantic(.assignment))
        #expect(CaseChangeClassifier.classify(action: "profileRestricted") == .semantic(.access))
        #expect(CaseChangeClassifier.classify(action: "statementCorrected") == .semantic(.amendment))
        #expect(CaseChangeClassifier.classify(action: "sourceIncluded") == .semantic(.scope))
        #expect(CaseChangeClassifier.classify(action: "lateContributionQueued") == .semantic(.newMaterial))
        // Semantic changes of every kind.
        let ravi = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let ravi2 = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .other, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await f.file.recordIdentityDecision(caseID: c, personA: ravi, personB: ravi2, decision: .differentPeople, rationale: "Different dates of birth", actor: "Ada")
        _ = try await f.file.addPersonRole(caseID: c, personID: ravi, role: .accountHolder, context: "account ending 4471", actor: "Ada")
        _ = try await f.file.assignWork(caseID: c, kind: .allegation, workID: rig.allegation.uuidString, to: "Ben", actor: "Ada")
        _ = try await f.file.restrictProfile(caseID: c, personID: ravi2, reason: "Protected witness", actor: "Ada")
        let iv = try await f.file.addInterview(caseID: c, personID: ravi, questions: nil, actor: "Ada")
        var interview = try #require(try await f.file.interview(id: iv))
        interview.statementText = "I made one transfer."; interview.status = .held
        try await f.file.updateInterview(interview, actor: "Ada")
        try await f.file.attest(interviewID: iv, caseID: c, attestedBy: "Ravi Kumar", actor: "Ada")
        _ = try await f.file.addStatementAddendum(caseID: c, interviewID: iv, text: "I made two transfers.", reason: "Remembered the second", actor: "Ada")
        try await rig.revise()
        let p = try await rig.projection()
        let feed = await rig.feeds.load(caseID: c, projection: p, viewer: "Ada")
        #expect(feed.state == .loaded)
        let kinds = Set(feed.newChanges.map(\.kind))
        for k in [CaseChangeKind.identityChanged, .roleChanged, .assignmentChanged, .accessChanged, .statementAmended, .documentRevised] {
            #expect(kinds.contains(k), "\(k)")
        }
        #expect(feed.newChanges.first { $0.kind == .assignmentChanged }?.record == rig.allegationNode)
        #expect(feed.newChanges.allSatisfy { $0.kind.category != .output || $0.kind == .stageChanged })
        // Aggregation conceals nothing: more than six kinds, every member kept, impact and unresolved per group.
        let groups = CaseChangeDigest.groups(feed, projection: p)
        #expect(groups.count == kinds.count && groups.count > 6)
        #expect(groups.reduce(0) { $0 + $1.count } == feed.newChanges.count)
        let revisedGroup = try #require(groups.first { $0.kind == .documentRevised })
        #expect(revisedGroup.impact >= 1 && revisedGroup.unresolved >= 1 && revisedGroup.line.contains("rest on it"))
        let acked = Set(revisedGroup.members.map(\.id))
        #expect(CaseChangeDigest.groups(feed, projection: p, acknowledged: acked).first { $0.kind == .documentRevised }?.unresolved == 0)
        // A part that fails is named; the feed is partial, never "nothing changed".
        await rig.feeds.setFaults(.init(parts: [.people]))
        #expect(await rig.feeds.load(caseID: c, projection: p, viewer: "Ada").state == .partial([.people]))
        await rig.feeds.setFaults(.init())
    }

    @Test("CHANGE-07: a closed case queues late material from background work, refuses to admit it until reopened, and never drops it")
    func closedCaseQueuesLateContributions() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        await #expect(throws: CaseChangeWorkError.caseNotClosed) {
            _ = try await f.file.queueLateContribution(caseID: c, kind: .note, sourceRef: nil, description: "x", contributedBy: "Ada")
        }
        try await f.file.markClosed(caseID: c, reopened: false, actor: "Ada")
        let file = f.file
        let outcome = try await f.file.contributeOrQueue(caseID: c, kind: .result, sourceRef: nil, description: "Bank reply to the evidence request",
                                                         contributedBy: "Ada", softwareActor: "evidence request import") {
            _ = try await file.addAllegation(caseID: c, text: "From the bank reply", actor: "Ada")
        }
        guard case .queued(let id) = outcome else { Issue.record("expected the contribution to be queued"); return }
        #expect(try await f.file.allegations(caseID: c).isEmpty, "the closed case was not changed")
        let other = try await f.file.queueLateContribution(caseID: c, kind: .document, sourceRef: nil, description: "A scanned letter", contributedBy: "Ben")
        await #expect(throws: CaseChangeWorkError.reopenFirst) {
            try await f.file.decideLateContribution(caseID: c, id: id, decision: .admit, reason: "Relevant", actor: "Ada")
        }
        try await f.file.decideLateContribution(caseID: c, id: id, decision: .requestReopen, reason: "The reply answers question 2", actor: "Ada")
        try await f.file.decideLateContribution(caseID: c, id: other, decision: .decline, reason: "Duplicate of exhibit 4", actor: "Ada")
        #expect(try await f.file.profile(caseID: c).stage == .closed, "asking to reopen does not reopen")
        try await f.file.markClosed(caseID: c, reopened: true, actor: "Ada")
        try await f.file.decideLateContribution(caseID: c, id: id, decision: .admit, reason: "Reopened to examine the reply", actor: "Ada")
        let list = try await f.file.lateContributions(caseID: c)
        #expect(list.map(\.state) == [.admitted, .declined] && list.allSatisfy { $0.decisionReason != nil })
        #expect(list.first?.softwareActor == "evidence request import")
        await #expect(throws: CaseChangeWorkError.alreadyDecided) {
            try await f.file.decideLateContribution(caseID: c, id: other, decision: .admit, reason: "Changed mind", actor: "Ada")
        }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_late_contributions SET description = 'x' WHERE id = ?;", [.uuid(other)]) }
    }

    @Test("CHANGE-09: impact notifications are reconciled idempotently from canonical state — a crash part-way writes nothing, a rerun adds each once, another adds none")
    func reconciliationIsIdempotent() async throws {
        let rig = try await S6Rig.make()
        let f = rig.f, c = f.caseID
        try await rig.revise()
        let p = try await rig.projection()
        let feed = await rig.feeds.load(caseID: c, projection: p, viewer: "Ada")
        await #expect(throws: (any Error).self) { _ = try await rig.feeds.reconcileImpacts(feed, projection: p, failAfter: 0) }
        #expect(try await rig.feeds.impactNotifications(caseID: c).isEmpty, "the interrupted run left nothing half-written")
        let first = try await rig.feeds.reconcileImpacts(feed, projection: p)
        #expect(first.inserted >= 1 && first.alreadyKnown == 0 && first.runs == 1)
        // Reconnect / missed events: the feed is read again from the ledger and reconciled again.
        let again = await rig.feeds.load(caseID: c, projection: try await rig.projection(), viewer: "Ada")
        let second = try await rig.feeds.reconcileImpacts(again, projection: p)
        #expect(second.inserted == 0 && second.alreadyKnown == first.inserted && second.runs == 2)
        let notes = try await rig.feeds.impactNotifications(caseID: c)
        #expect(notes.count == first.inserted && notes.contains { $0.dependent == rig.allegationNode.key && $0.path.contains("supports") })
        try await rig.feeds.acknowledgeNotification(caseID: c, id: notes[0].id, actor: "Ada")
        await #expect(throws: CaseChangeWorkError.alreadyDecided) { try await rig.feeds.acknowledgeNotification(caseID: c, id: notes[0].id, actor: "Ben") }
        #expect(try await rig.feeds.reconcileImpacts(again, projection: p).inserted == 0, "an acknowledged notification is not recreated")
    }

    @Test("CHANGE-10: after a source change, warnings appear on the affected branch while unaffected positions, labels, folds and completed work stay exactly as they were")
    func stablePresentation() {
        let c = UUID()
        func build(revised: Bool) -> CaseMapProjection {
            var d = S3Synth.node(c, .document, "d", .evidence, "Bank statement")
            if revised { d = CaseMapNode(id: d.id, revision: "r2", kind: d.kind, title: d.title, wording: d.wording, status: d.status, review: d.review, sources: d.sources,
                                         author: nil, recordedAt: nil, eventDate: nil, history: [], changedSourceWarning: "A newer version was recorded", isDocumentary: false) }
            let a = S3Synth.node(c, .allegation, "a", .question, "Supplier paid twice")
            let r = S3Synth.node(c, .reportPoint, "r", .statement, "Point: two debits", review: .accepted)
            let q2 = S3Synth.node(c, .allegation, "q2", .question, "Late deliveries")
            let t2 = S3Synth.node(c, .task, "t2", .action, "Ask the depot", review: .completed, workOpen: false)
            let x2 = S3Synth.node(c, .journal, "x2", .event, "Depot log entry")
            return S3Synth.projection(c, [d, a, r, q2, t2, x2],
                                      [S3Synth.link(c, .supports, d.id, a.id), S3Synth.link(c, .derivedFrom, r.id, a.id),
                                       S3Synth.link(c, .requestsEvidenceFor, t2.id, q2.id), S3Synth.link(c, .derivedFrom, x2.id, q2.id)])
        }
        let before = build(revised: false), after = build(revised: true)
        let d = CaseMapNodeID(caseID: c, kind: .document, recordID: "d"), a = CaseMapNodeID(caseID: c, kind: .allegation, recordID: "a")
        let q2 = CaseMapNodeID(caseID: c, kind: .allegation, recordID: "q2"), t2 = CaseMapNodeID(caseID: c, kind: .task, recordID: "t2")
        let changed = Set([d] + CaseDependencyTraversal.trace(from: d, in: after).nodes)
        #expect(changed.contains(a) && changed.contains(CaseMapNodeID(caseID: c, kind: .reportPoint, recordID: "r")))
        #expect(!changed.contains(q2) && !changed.contains(t2))
        // Positions: placements made before are kept for every item.
        let placed = CaseMapLayout.placeNew(before, existing: [:])
        let replaced = CaseMapLayout.placeNew(after, existing: placed)
        for (id, pl) in placed { #expect(replaced[id]?.point == pl.point, "\(id) moved") }
        // Labels and card lines of unaffected items, and every link label, are unchanged.
        for n in before.nodes where !changed.contains(n.id) {
            let m = after.node(n.id)
            #expect(m?.title == n.title && m?.status == n.status && m?.review == n.review)
            #expect(m.map { CaseMapZoomDetail.cardLines($0, at: .rich) } == CaseMapZoomDetail.cardLines(n, at: .rich))
        }
        #expect(before.links.map { "\($0.id)|\($0.type.label)" } == after.links.map { "\($0.id)|\($0.type.label)" })
        // Folds: the unaffected branch's summary is identical; the affected one says what is new.
        let foldsBefore = CaseMapFolds.apply([q2, a], in: before, changed: [])
        let foldsAfter = CaseMapFolds.apply([q2, a], in: after, changed: changed)
        #expect(foldsAfter.summaries[q2] == foldsBefore.summaries[q2] && foldsAfter.summaries[q2]?.new == 0)
        #expect((foldsAfter.summaries[a]?.new ?? 0) >= 1 && foldsAfter.held == foldsBefore.held)
        // Completed work stays completed.
        #expect(after.node(t2)?.review == .completed && after.node(CaseMapNodeID(caseID: c, kind: .reportPoint, recordID: "r"))?.review == .accepted)
    }
}

// MARK: - PEOPLE

@MainActor
@Suite("Smart map S6 — people (PEOPLE)", .serialized)
struct SmartMapS6PeopleTests {

    @Test("PEOPLE-01: one person, many roles in context; adding the same documents' person adds a role, not a row; no role implies wrongdoing")
    func identitySeparateFromRole() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let entity = UUID()
        let ravi = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .witness, entityID: entity, contact: nil, notes: nil, actor: "Ada")
        let out = try await f.file.addPersonOrRole(caseID: c, name: "R. Kumar", role: .accountHolder, context: "account ending 4471", entityID: entity, actor: "Ada")
        guard case .roleAdded(let person, _) = out, person == ravi else { Issue.record("expected a role on the existing row, got \(out)"); return }
        #expect(try await f.file.people(caseID: c).count == 1, "the same person is not duplicated")
        _ = try await f.file.addPersonRole(caseID: c, personID: ravi, role: .investigator, context: "internal audit 2025", actor: "Ada")
        await #expect(throws: CasePeopleError.duplicateRole) {
            _ = try await f.file.addPersonRole(caseID: c, personID: ravi, role: .accountHolder, context: "account ending 4471", actor: "Ada")
        }
        let view = try #require(try await f.file.identityViews(caseID: c).first)
        #expect(view.roles.count == 3 && view.roles[1].contains("Account holder — account ending 4471"))
        let node = try #require(await caseMapLoad(f).projection?.node(CaseMapNodeID(caseID: c, kind: .person, id: ravi)))
        #expect(node.status.text.contains("Witness") && node.status.text.contains("Account holder") && node.status.text.contains("Investigator"))
        #expect(CasePersonRole.subject.label.contains("no wrongdoing implied") && CasePersonRoleKind.subject.label.contains("no wrongdoing implied"))
        let subject = try await f.file.addPersonOrRole(caseID: c, name: "Meena Shah", role: .subject, context: nil, entityID: UUID(), actor: "Ada")
        guard case .added = subject else { Issue.record("a different person is a new row"); return }
        let roles = try await f.file.personRoles(caseID: c)
        try await f.file.endPersonRole(caseID: c, id: roles[0].id, reason: "Account closed in 2024", actor: "Ada")
        await #expect(throws: CasePeopleError.alreadyEnded) { try await f.file.endPersonRole(caseID: c, id: roles[0].id, reason: "again", actor: "Ada") }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_person_roles SET role = 'subject' WHERE id = ?;", [.uuid(roles[1].id)]) }
    }

    @Test("PEOPLE-02 / PEOPLE-03: every profile line states its origin and period; card notes are unsourced; a location is always a past observation with its age")
    func sourcedProfileAndWhereabouts() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "register.txt", text: "Ravi Kumar, director of Dalmia Traders since 2019.")
        let ravi = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .witness, entityID: nil, contact: "ravi@example.com", notes: "Seemed nervous", actor: "Ada")
        _ = try await f.file.addPersonAttribute(caseID: c, personID: ravi, kind: .organisation, value: "Dalmia Traders (director)", origin: .source, sourceVersionID: doc.version,
                                                quote: "director of Dalmia Traders since 2019", validFrom: Date(timeIntervalSince1970: 1_546_300_800), actor: "Ada")
        _ = try await f.file.addPersonAttribute(caseID: c, personID: ravi, kind: .background, value: "Previously employed at the depot", origin: .supplied, suppliedBy: "HR file", actor: "Ada")
        let note = try await f.file.addPersonAttribute(caseID: c, personID: ravi, kind: .relationship, value: "Brother-in-law of the clerk", origin: .unsourced, actor: "Ada")
        await #expect(throws: CaseWorkError.sourceNotInCase) {
            _ = try await f.file.addPersonAttribute(caseID: c, personID: ravi, kind: .alias, value: "RK", origin: .source, actor: "Ada")
        }
        await #expect(throws: CaseWorkError.sourceNotInCase) {
            _ = try await f.file.addPersonAttribute(caseID: c, personID: ravi, kind: .alias, value: "RK", origin: .source, sourceVersionID: UUID(), actor: "Ada")
        }
        await #expect(throws: CaseFileError.self) {
            _ = try await f.file.addPersonAttribute(caseID: c, personID: ravi, kind: .alias, value: "RK", origin: .supplied, actor: "Ada")
        }
        let now = Date()
        _ = try await f.file.recordLocationObservation(caseID: c, personID: ravi, place: "Depot 4, Pune", observedFrom: now.addingTimeInterval(-10 * 86_400),
                                                       timePrecision: .day, placePrecision: .street, basis: .source, sourceVersionID: doc.version,
                                                       uncertainty: "CCTV time stamp not verified", actor: "Ada", at: now)
        await #expect(throws: CasePeopleError.futureObservation) {
            _ = try await f.file.recordLocationObservation(caseID: c, personID: ravi, place: "Airport", observedFrom: now.addingTimeInterval(86_400), timePrecision: .day,
                                                           placePrecision: .city, basis: .supplied, actor: "Ada", at: now)
        }
        await #expect(throws: CaseFileError.self) {
            _ = try await f.file.recordLocationObservation(caseID: c, personID: ravi, place: "Home", observedFrom: nil, timePrecision: .unknown,
                                                           placePrecision: .area, basis: .authorisedRecord, actor: "Ada", at: now)
        }
        let profile = try await f.file.personProfile(caseID: c, personID: ravi)
        let lines = profile.lines
        #expect(lines.contains { $0.contains("Dalmia Traders (director)") && $0.contains("From a source") && $0.contains("director of Dalmia Traders since 2019") })
        #expect(lines.contains { $0.contains("Previously employed") && $0.contains("Supplied by HR file") })
        #expect(lines.contains { $0.contains("Brother-in-law") && $0.contains("Unsourced") })
        #expect(lines.contains { $0.contains("Seemed nervous") && $0.contains("unsourced") } && lines.contains { $0.contains("ravi@example.com") && $0.contains("unsourced") })
        let loc = try #require(lines.first { $0.contains("Depot 4") })
        #expect(loc.contains("A past observation, not the person's current location") && loc.contains("10 day(s) ago") && loc.contains("CCTV time stamp not verified"))
        try await f.file.withdrawPersonAttribute(caseID: c, id: note, reason: "Hearsay", actor: "Ada")
        #expect(!(try await f.file.personProfile(caseID: c, personID: ravi).lines.contains { $0.contains("Brother-in-law") }))
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_person_attributes SET value = 'x' WHERE id = ?;", [.uuid(note)]) }
    }

    @Test("PEOPLE-04: questions and responses are linked items; after confirmation an item changes only by a recorded correction with an addendum; the witness's statement history keeps both")
    func interviewItemsAndStatementHistory() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let rec = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "interview-audio.txt", text: "Transcript of the interview.")
        let ravi = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let iv = try await f.file.addInterview(caseID: c, personID: ravi, questions: nil, actor: "Ada")
        let q1 = try await f.file.addInterviewItem(caseID: c, interviewID: iv, question: "How many transfers did you make?", response: "One.",
                                                   recordingRef: rec.version.uuidString, recordingOffset: 312.5, actor: "Ada")
        _ = try await f.file.addInterviewItem(caseID: c, interviewID: iv, question: "Who approved it?", response: "The finance manager.", transcriptLocator: "page 2, line 14", actor: "Ada")
        await #expect(throws: CaseFileError.self) {
            _ = try await f.file.addInterviewItem(caseID: c, interviewID: iv, question: "Bad ref", response: nil, recordingRef: UUID().uuidString, actor: "Ada")
        }
        try await f.file.updateInterviewItem(caseID: c, id: q1, question: "How many transfers did you make in March?", response: "One.", actor: "Ada")
        var interview = try #require(try await f.file.interview(id: iv))
        interview.statementText = "I made one transfer in March, approved by the finance manager."; interview.status = .held
        try await f.file.updateInterview(interview, actor: "Ada")
        try await f.file.attest(interviewID: iv, caseID: c, attestedBy: "Ravi Kumar", actor: "Ada")
        await #expect(throws: CasePeopleError.statementConfirmed) {
            try await f.file.updateInterviewItem(caseID: c, id: q1, question: "How many transfers did you make in March?", response: "Two.", actor: "Ada")
        }
        await #expect(throws: CasePeopleError.statementConfirmed) {
            _ = try await f.file.addInterviewItem(caseID: c, interviewID: iv, question: "Late question", response: nil, actor: "Ada")
        }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_interview_items SET response = 'Two.' WHERE id = ?;", [.uuid(q1)]) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_interview_items WHERE id = ?;", [.uuid(q1)]) }
        let (fixed, addendum) = try await f.file.correctInterviewItem(caseID: c, id: q1, question: nil, response: "Two — I forgot the second one.",
                                                                      reason: "Witness recalled the second transfer", actor: "Ada")
        await #expect(throws: CasePeopleError.itemSuperseded) {
            _ = try await f.file.correctInterviewItem(caseID: c, id: q1, question: nil, response: "Three", reason: "x", actor: "Ada")
        }
        let items = try await f.file.interviewItems(caseID: c)
        let old = try #require(items.first { $0.id == q1 }), new = try #require(items.first { $0.id == fixed })
        #expect(old.response == "One." && old.supersededBy == fixed && old.recordingOffset == 312.5)
        #expect(new.correctsID == q1 && new.addendumID == addendum && new.ordinal == old.ordinal && new.recordingRef == old.recordingRef)
        #expect(try await f.file.addenda(caseID: c).contains { $0.id == addendum && $0.reason == "Witness recalled the second transfer" })
        let history = try await f.file.statementHistory(caseID: c, personID: ravi)
        let kinds = history.map(\.kind)
        #expect(kinds.first == .interview && kinds.contains(.confirmed) && kinds.filter { $0 == .correction }.count == 2 && kinds.filter { $0 == .item }.count == 2)
        #expect(history.contains { $0.text.contains("One.") && $0.text.contains("corrected later; kept as confirmed") })
        #expect(try #require(try await f.file.interview(id: iv)).statementIntact, "the confirmed statement is untouched")
    }

    @Test("PEOPLE-05 (local part): who recorded an action and who was reported as performing it stay distinct; none is an authenticated account")
    func participantsStayDistinct() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        _ = try await f.file.addPerson(caseID: c, name: "Meena Shah", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let file = f.file
        try await CaseActionContext.$current.withValue(CaseActionContext(performedBy: "External Auditor")) {
            _ = try await file.addAllegation(caseID: c, text: "Audit found a duplicate payment", actor: "Ada")
        }
        let list = try await f.file.participants(caseID: c)
        let auditor = try #require(list.first { $0.name == "External Auditor" })
        #expect(auditor.appearances == [.reportedPerformer] && auditor.actionsRecorded == 0 && auditor.actionsReported == 1)
        let ada = try #require(list.first { $0.name == "Ada" })
        #expect(ada.appearances.contains(.recordingUser) && !ada.appearances.contains(.reportedPerformer) && !ada.sessionAccounts.isEmpty)
        #expect(list.first { $0.name == "Meena Shah" }?.appearances == [.casePerson])
        #expect(list.allSatisfy { !$0.authenticated })
    }

    @Test("PEOPLE-06 / PEOPLE-08 / PEOPLE-09: assignment honours declared capability, availability and conflicts; reassignment and departure transfer work and keep attribution; histories open their records")
    func workHistoriesCapabilitiesAndDepartures() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let a = try await f.file.addAllegation(caseID: c, text: "The supplier was paid twice", actor: "Ada")
        let ada = try await f.file.addTeamMember(caseID: c, member: "Ada", role: .lead, actor: "Ada")
        _ = try await f.file.addTeamMember(caseID: c, member: "Ben", role: .investigator, actor: "Ada")
        _ = try await f.file.addTeamMember(caseID: c, member: "Cara", role: .investigator, actor: "Ada")
        _ = try await f.file.declareCapability(investigator: "Ben", capability: "Forensic accounting", basis: "CFE certificate supplied", actor: "Ada")
        try await f.db.exec("INSERT INTO case_conflict_checks (id, case_id, investigator, result, matched, note, checked_by, checked_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(c), .text("Cara"), .text("conflict"), .text("Ravi Kumar"), .null, .text("Ada"), .date(Date())])
        var candidates = try await f.file.routingCandidates(caseID: c, capability: "forensic accounting")
        #expect(candidates.map(\.name) == ["Ada", "Ben", "Cara"], "alphabetical, never ranked")
        #expect(candidates.first { $0.name == "Ben" }?.eligible == true)
        #expect(candidates.first { $0.name == "Cara" }.map { !$0.eligible && $0.reasons.contains("Conflict recorded in this case") } == true)
        #expect(candidates.first { $0.name == "Ada" }.map { !$0.eligible && $0.reasons.contains { $0.contains("Has not declared") } } == true)
        let task = UUID().uuidString
        await #expect(throws: CasePeopleError.conflictRecorded("Cara")) { _ = try await f.file.assignWork(caseID: c, kind: .task, workID: task, to: "Cara", actor: "Ada") }
        await #expect(throws: CasePeopleError.self) {
            _ = try await f.file.assignWork(caseID: c, kind: .task, workID: task, to: "Ada", capability: "Forensic accounting", actor: "Ada")
        }
        let first = try await f.file.assignWork(caseID: c, kind: .task, workID: task, to: "Ben", capability: "Forensic accounting", actor: "Ada")
        await #expect(throws: CasePeopleError.alreadyAssigned("Ben")) { _ = try await f.file.assignWork(caseID: c, kind: .task, workID: task, to: "Ada", actor: "Ada") }
        _ = try await f.file.declareUnavailable(investigator: "Ben", from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(86_400), note: "Leave", actor: "Ada")
        candidates = try await f.file.routingCandidates(caseID: c, capability: "forensic accounting")
        #expect(candidates.first { $0.name == "Ben" }.map { !$0.eligible && $0.reasons.contains { $0.contains("unavailable") } } == true)
        try await f.db.exec("DELETE FROM investigator_availability;", [])
        await #expect(throws: CasePeopleError.self, "reassignment keeps the work's required capability") {
            _ = try await f.file.reassignWork(caseID: c, assignmentID: first, to: "Ada", reason: "Ben on leave", actor: "Ada")
        }
        #expect(try await f.file.assignments(caseID: c).first { $0.id == first }?.isOpen == true, "a refused reassignment leaves the assignment as it was")
        _ = try await f.file.declareCapability(investigator: "Ada", capability: "Forensic accounting", basis: "Chartered accountant", actor: "Ada")
        _ = try await f.file.reassignWork(caseID: c, assignmentID: first, to: "Ada", reason: "Ben on leave", actor: "Ada")
        _ = try await f.file.assignWork(caseID: c, kind: .allegation, workID: a.uuidString, to: "Ada", actor: "Ada")
        // Ada leaves: pending work must be transferred; attribution stays.
        let adaActions = try await s6Count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND actor = 'Ada';", [.uuid(c)])
        await #expect(throws: CasePeopleError.pendingWorkNeedsTransfer(2)) {
            try await f.file.endTeamMembership(caseID: c, membershipID: ada, reason: "Left the organisation", transferTo: nil, actor: "Ben")
        }
        try await f.file.endTeamMembership(caseID: c, membershipID: ada, reason: "Left the organisation", transferTo: "Ben", actor: "Ben")
        #expect(try await s6Count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND actor = 'Ada';", [.uuid(c)]) == adaActions)
        let open = try await f.file.assignments(caseID: c).filter(\.isOpen)
        #expect(open.count == 2 && open.allSatisfy { $0.assignee == "Ben" })
        await #expect(throws: CasePeopleError.self) { _ = try await f.file.assignWork(caseID: c, kind: .report, workID: UUID().uuidString, to: "Ben", actor: "Ada") }
        await #expect(throws: CasePeopleError.self) { _ = try await f.file.assignWork(caseID: c, kind: .report, workID: UUID().uuidString, to: "Ada", actor: "Ben") }
        // Histories: each entry opens its record (or says why it cannot).
        let ben = try await f.file.workHistory(caseID: c, person: "Ben")
        #expect(ben.entries.contains { $0.kind == .assigned && $0.target == CaseMapNodeID(caseID: c, kind: .task, recordID: task) })
        #expect(ben.entries.contains { $0.kind == .reassignedAway } && ben.openAssignments == 2)
        let adaH = try await f.file.workHistory(caseID: c, person: "Ada")
        #expect(adaH.entries.contains { $0.kind == .receivedByReassignment } && adaH.entries.contains { $0.kind == .transferredAway })
        #expect(adaH.entries.contains { $0.kind == .performed && $0.target == CaseMapNodeID(caseID: c, kind: .allegation, id: a) })
        #expect(adaH.entries.allSatisfy { $0.target != nil || $0.unavailable != nil })
        #expect(adaH.periods.first?.contains("Left the organisation") == true && adaH.firstInvolved != nil)
        let removed = try await f.file.removeInvestigatorProfile(investigator: "Ben")
        let leftCaps = try await f.file.capabilities(investigator: "Ben")
        #expect(removed == 1 && leftCaps.isEmpty)
    }

    @Test("PEOPLE-07: a versioned rule explains why records match or stay separate; a same name is never more than a weak candidate; nothing is merged without a decision")
    func samePersonCandidates() async throws {
        let same = CasePersonMatcher.assess(CasePersonEvidence(name: "Ravi Kumar"), CasePersonEvidence(name: "ravi  KUMAR"))
        #expect(same.0 == .weakCandidate && same.1.contains { $0.kind == .nameExact && $0.counts.contains("never") })
        let conflict = CasePersonMatcher.assess(CasePersonEvidence(name: "Ravi Kumar", identifiers: ["email:ravi@a.com"]),
                                                CasePersonEvidence(name: "Ravi Kumar", identifiers: ["email:rk@b.com"]))
        #expect(conflict.0 == .keepSeparate && conflict.1.contains { $0.kind == .identifierConflict })
        let strong = CasePersonMatcher.assess(CasePersonEvidence(name: "R. Kumar", identifiers: ["phone:9876543210"]),
                                              CasePersonEvidence(name: "Ravi Kumar", identifiers: ["phone:9876543210"]))
        #expect(strong.0 == .strongCandidate && strong.1.contains { $0.kind == .identifierMatch } && strong.1.contains { $0.kind == .nameVariant })
        #expect(CasePersonMatcher.assess(CasePersonEvidence(name: "Ravi Kumar", entityID: UUID()), CasePersonEvidence(name: "Ravi Kumar", entityID: UUID())).0 == .keepSeparate)
        #expect(CasePersonMatcher.identifiers(in: "Call +91 98765 43210 or mail Ravi.K@Example.com") == ["phone:9876543210", "email:ravi.k@example.com"])

        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let a = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .witness, entityID: nil, contact: "ravi@a.com", notes: nil, actor: "Ada")
        let b = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .subject, entityID: nil, contact: "rk@b.com", notes: nil, actor: "Ada")
        let assessment = try await f.file.assessSamePerson(caseID: c, personA: a, personB: b, actor: "Ada")
        #expect(assessment.verdict == .keepSeparate && assessment.ruleVersion == CasePersonMatcher.ruleVersion)
        let stored = try #require(try await f.file.matchAssessments(caseID: c).first)
        #expect(stored.reasons == assessment.reasons && stored.reasons.contains { $0.detail.contains("ravi@a.com") })
        #expect(try await s6Count(f.db, "SELECT COUNT(*) FROM case_person_identity_decisions WHERE case_id = ?;", [.uuid(c)]) == 0, "an assessment decides nothing")
        #expect(try await f.file.people(caseID: c).count == 2)
        let p = try #require(await caseMapLoad(f).projection)
        #expect(p.count(.person) == 2 && !p.links.contains { $0.type == .samePersonDecided })
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_person_match_assessments SET verdict = 'strongCandidate';", []) }
    }

    @Test("PEOPLE-10 (local part): a restricted profile withholds its content from the profile and statement history and says how much; person erasure removes the v182 person records")
    func restrictionAndErasure() async throws {
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "note.txt", text: "Asha Rao lives near the depot.")
        let entity = UUID()
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("Asha Rao"), .text("asha rao"), .uuid(doc.object)])
        let asha = try await f.file.addPerson(caseID: c, name: "Asha Rao", role: .witness, entityID: entity, contact: nil, notes: nil, actor: "Ada")
        _ = try await f.file.addPersonAttribute(caseID: c, personID: asha, kind: .contact, value: "asha@example.com", origin: .supplied, suppliedBy: "HR", actor: "Ada")
        _ = try await f.file.recordLocationObservation(caseID: c, personID: asha, place: "Near the depot", observedFrom: Date().addingTimeInterval(-86_400), timePrecision: .day,
                                                       placePrecision: .area, basis: .source, sourceVersionID: doc.version, actor: "Ada")
        _ = try await f.file.addPersonRole(caseID: c, personID: asha, role: .source, context: "tip-off", actor: "Ada")
        _ = try await f.file.addInterview(caseID: c, personID: asha, questions: nil, actor: "Ada")
        let r = try await f.file.restrictProfile(caseID: c, personID: asha, reason: "Protected witness", actor: "Ada")
        await #expect(throws: CasePeopleError.alreadyRestricted) { _ = try await f.file.restrictProfile(caseID: c, personID: asha, reason: "again", actor: "Ada") }
        let restricted = try await f.file.personProfile(caseID: c, personID: asha)
        #expect(restricted.isRestricted && restricted.withheld == 3 && restricted.attributes.isEmpty && restricted.locations.isEmpty)
        #expect(restricted.lines.allSatisfy { !$0.contains("asha@example.com") && !$0.contains("Near the depot") })
        #expect(restricted.lines.contains { $0.contains("3 item(s) withheld") && $0.contains("Protected witness") })
        let history = try await f.file.statementHistory(caseID: c, personID: asha)
        #expect(history.count == 1 && history[0].kind == .restricted && history[0].text.contains("1 statement record(s) withheld"))
        try await f.file.liftProfileRestriction(caseID: c, id: r, reason: "Witness consented", actor: "Ada")
        #expect(try await f.file.personProfile(caseID: c, personID: asha).lines.contains { $0.contains("asha@example.com") })
        let report = try await CaseEraser(database: f.db).erasePerson(entityID: entity, reason: "Erasure request", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        for t in ["case_person_roles", "case_person_attributes", "case_person_locations", "case_person_restrictions"] {
            #expect(try await s6Count(f.db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(c)]) == 0, "\(t)")
        }
    }
}
