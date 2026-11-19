//
//  SmartMapS3Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S3 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: GRAPH, MAP and BRIEF of milestone M1; schema
//  v179). Deterministic: synthetic projections for the pure rules, throwaway ledgers for persistence. AI off; nothing here
//  calls a model or the network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

// MARK: - Synthetic projections

enum S3Synth {
    static func node(_ c: UUID, _ kind: CaseMapRecordKind, _ id: String, _ nk: CaseMapNodeKind, _ title: String,
                     status: CaseMapStatus = .recorded("Recorded"), review: CaseMapReviewState = .notApplicable, date: Date? = nil,
                     precision: DatePrecision? = nil, money: CaseMapMoney? = nil, workOpen: Bool? = nil, blocked: Bool = false,
                     wording: String? = nil, sources: Int = 0) -> CaseMapNode {
        var n = CaseMapNode(id: CaseMapNodeID(caseID: c, kind: kind, recordID: id), revision: "r1", kind: nk, title: title, wording: wording,
                            status: status, review: review,
                            sources: (0..<sources).map { _ in CaseMapSourceRef(sourceVersionID: UUID(), objectID: UUID(), documentName: "d", quote: nil) },
                            author: nil, recordedAt: nil, eventDate: date, history: [], changedSourceWarning: nil, isDocumentary: false)
        n.datePrecision = precision; n.money = money; n.workOpen = workOpen; n.workBlocked = blocked
        return n
    }
    static func link(_ c: UUID, _ type: CaseMapLinkType, _ from: CaseMapNodeID, _ to: CaseMapNodeID, certainty: CaseMapCertainty = .notStated,
                     review: CaseMapReviewState = .notApplicable, status: CaseMapStatus = .recorded("x")) -> CaseMapLink {
        var l = CaseMapLink(id: CaseMapLink.makeID(type: type, from: from, to: to, origins: [CaseMapOrigin(.rule, "\(from.key)>\(to.key)")]), caseID: c,
                            from: from, to: to, type: type, origins: [CaseMapOrigin(.rule, "\(from.key)>\(to.key)")], sources: [],
                            assertedBy: .rule("test"), review: review, status: status, basis: "test")
        l.certainty = certainty
        return l
    }
    static func projection(_ c: UUID, _ nodes: [CaseMapNode], _ links: [CaseMapLink], question: String? = "What happened?") -> CaseMapProjection {
        let sn = nodes.sorted { $0.id < $1.id }, sl = links.sorted { $0.id < $1.id }
        return CaseMapProjection(caseID: c, title: "Synthetic", stage: .open, isClosed: false, question: question, nodes: sn, links: sl,
                                 groups: CaseMapProjector.groups(sn, sl), parts: Dictionary(uniqueKeysWithValues: CaseMapPart.allCases.map { ($0, .loaded) }),
                                 danglingLinks: 0, withdrawnLinks: 0)
    }
}

@Suite("Smart map S3 — pure graph, map and brief rules")
struct SmartMapS3RuleTests {

    @Test("GRAPH-05/12: cyclic investigative links, deep chains, many memberships and disconnected material — traversal, folds, impact and export all terminate with explicit limits")
    func cyclesDepthBreadth() {
        let c = UUID()
        let q = S3Synth.node(c, .caseFile, c.uuidString, .question, "Case")
        // A 300-deep derivation chain, a 2-cycle of supports links, 40 records placed in one frame, a disconnected island.
        var nodes = [q]
        var links: [CaseMapLink] = []
        var prev = q.id
        for i in 0..<300 {
            let n = S3Synth.node(c, .task, String(format: "t%03d", i), .action, "Step \(i)", workOpen: true)
            nodes.append(n); links.append(S3Synth.link(c, .derivedFrom, n.id, prev)); prev = n.id
        }
        let a = S3Synth.node(c, .hypothesis, "ha", .hypothesis, "A"), b = S3Synth.node(c, .hypothesis, "hb", .hypothesis, "B")
        nodes += [a, b]; links += [S3Synth.link(c, .supports, a.id, b.id), S3Synth.link(c, .supports, b.id, a.id), S3Synth.link(c, .challenges, a.id, q.id)]
        let frame = S3Synth.node(c, .report, "rep", .evidence, "Report")
        nodes.append(frame)
        for i in 0..<40 {
            let m = S3Synth.node(c, .journal, String(format: "j%02d", i), .event, "Event \(i)")
            nodes.append(m); links.append(S3Synth.link(c, .placedIn, frame.id, m.id))
        }
        let island = S3Synth.node(c, .journal, "zz-island", .note, "Unlinked note")
        nodes.append(island)
        let p = S3Synth.projection(c, nodes, links)

        // Traversal: no depth cap, the budget yields a continuation, continuing reaches everything (cycle-safe).
        let t = CaseMapFrames.traverse(from: q.id, in: p, budget: 50)
        #expect(!t.exhausted && t.depth.count > 50)
        let all = CaseMapFrames.traverse(from: q.id, in: p, budget: 100_000)
        #expect(all.exhausted && all.depth[CaseMapNodeID(caseID: c, kind: .task, recordID: "t299")] == 300)
        #expect(all.depth[island.id] == nil, "disconnected material is not reached by a walk — it is in the Unlinked group")
        #expect(p.unlinked.contains(island.id))
        // Folds over a cycle and a deep chain terminate and hold every descendant once.
        #expect(CaseMapFolds.descendants(of: q.id, in: p).count == 300)
        #expect(CaseMapFolds.descendants(of: frame.id, in: p).count == 40)
        #expect(CaseMapFolds.descendants(of: a.id, in: p).isEmpty, "supports links are not containment")
        // Dependency inspection on a cycle terminates.
        let impact = CaseChangeImpactAnalysis.impact(of: a.id, in: p)
        #expect(impact.direct.contains { $0.node == b.id })
        // Export of a cyclic view terminates and lists every link once.
        let r = CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: []))
        let req = CaseMapExportRequest(projection: p, placements: CaseMapLayout.placeNew(p, existing: [:]), shown: r.shown, links: r.links, selection: nil,
                                       viewTitle: "Overview", state: .current(Date()), scopeFingerprint: nil)
        let frozen = CaseMapExportRenderer.freeze(req, restrictions: [])
        #expect(CaseMapExportRenderer.csv(frozen).components(separatedBy: "\n").count >= r.links.count)
        // Containment cycles are refused; investigative cycles are not containment.
        let x = CaseMapNodeID(caseID: c, kind: .report, recordID: "x"), y = CaseMapNodeID(caseID: c, kind: .report, recordID: "y"), z = CaseMapNodeID(caseID: c, kind: .report, recordID: "z")
        #expect(CaseMapContainment.wouldCycle(frame: x, member: x, placements: []))
        #expect(!CaseMapContainment.wouldCycle(frame: x, member: y, placements: [(y, z)]))
        #expect(CaseMapContainment.wouldCycle(frame: z, member: x, placements: [(x, y), (y, z)]))
    }

    @Test("MAP-02: zoom levels add richer content at close zoom and never change records, states or counts")
    func semanticZoom() {
        let c = UUID()
        let n = S3Synth.node(c, .journal, "e1", .event, "Payment approved", status: CaseMapStatus(.unassessed, "Not checked"), review: .unreviewed,
                             date: Date(timeIntervalSince1970: 1_772_000_000), precision: .month, wording: "Approved by the CFO\nmore", sources: 2)
        #expect(CaseMapZoomDetail.level(0.2) == .outline && CaseMapZoomDetail.level(0.5) == .compact && CaseMapZoomDetail.level(1) == .standard && CaseMapZoomDetail.level(2) == .rich)
        #expect(CaseMapZoomDetail.cardLines(n, at: .standard).isEmpty)
        let rich = CaseMapZoomDetail.cardLines(n, at: .rich)
        #expect(rich.contains("Not yet assessed: Not checked") && rich.contains("2 cited source(s)") && rich.contains("Approved by the CFO"))
        #expect(rich.contains { $0.contains("precision") == false && $0.contains("2026") }, "a month-precision date is shown as a month")
        let p = S3Synth.projection(c, [n], [])
        let before = CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: []))
        _ = CaseMapZoomDetail.allCases.map { CaseMapZoomDetail.cardLines(n, at: $0) }
        #expect(CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: [])) == before)
        #expect(!CaseMapZoomDetail.compact.showsLinkLabels && CaseMapZoomDetail.standard.showsLinkLabels)
    }

    @Test("MAP-04: nested folds hold a branch, count it, and say what is new, blocked or waiting for review; counts still reconcile")
    func nestedFolds() {
        let c = UUID()
        let report = S3Synth.node(c, .report, "r", .evidence, "Report")
        let point = S3Synth.node(c, .reportPoint, "p", .statement, "Point", review: .unreviewed)
        let question = S3Synth.node(c, .allegation, "q", .question, "Question raised", review: .unreviewed)
        let action = S3Synth.node(c, .task, "t", .action, "Blocked action", workOpen: true, blocked: true)
        let stale = S3Synth.node(c, .reportPoint, "p2", .statement, "Changed point", status: CaseMapStatus(.stale, "changed"))
        let other = S3Synth.node(c, .person, "w", .person, "Witness")
        let links = [S3Synth.link(c, .derivedFrom, point.id, report.id), S3Synth.link(c, .derivedFrom, question.id, point.id),
                     S3Synth.link(c, .derivedFrom, action.id, point.id), S3Synth.link(c, .derivedFrom, stale.id, report.id),
                     S3Synth.link(c, .mentions, other.id, report.id)]
        let p = S3Synth.projection(c, [report, point, question, action, stale, other], links)
        var f = CaseMapFilter(collapsed: []); f.folded = [report.id]
        let r = CaseMapViewFilter.apply(p, view: .overview, filter: f)
        #expect(r.counts.reconciles && r.counts.folded == 4)
        #expect(r.shown.contains(report.id) && r.shown.contains(other.id) && !r.shown.contains(point.id))
        let s = try? #require(r.folds[report.id])
        #expect(s?.held == 4 && s?.new == 1 && s?.blocked == 1 && s?.reviewRequired == 2)
        #expect(s?.label.contains("waiting for review") == true && s?.label.contains("blocked") == true)
        // Nested: fold the point too; opening the report keeps the point folded with its own count.
        f.folded = [report.id, point.id]
        let both = CaseMapViewFilter.apply(p, view: .overview, filter: f)
        #expect(both.folds[report.id]?.inInnerFolds == 3 && both.folds[point.id] == nil, "the inner fold is inside the outer one")
        f.folded = [point.id]
        let inner = CaseMapViewFilter.apply(p, view: .overview, filter: f)
        #expect(inner.shown.contains(point.id) && inner.folds[point.id]?.held == 2 && inner.counts.reconciles)
    }

    @Test("MAP-07: date buckets keep recorded precision; amount bands stay per currency; a bucket is a set of identities")
    func distributions() {
        let c = UUID()
        let day = S3Synth.node(c, .journal, "a", .event, "Day", date: Date(timeIntervalSince1970: 1_773_000_000), precision: .day)
        let month = S3Synth.node(c, .journal, "b", .event, "Month only", date: Date(timeIntervalSince1970: 1_773_000_000), precision: .month)
        let undated = S3Synth.node(c, .journal, "c", .event, "Undated")
        let inr1 = S3Synth.node(c, .moneyTransaction, "m1", .money, "INR", money: CaseMapMoney(amount: 50_000, currency: "INR"))
        let inr2 = S3Synth.node(c, .moneyTransaction, "m2", .money, "INR 2", money: CaseMapMoney(amount: 50_000, currency: "INR"))
        let usd = S3Synth.node(c, .moneyTransaction, "m3", .money, "USD", money: CaseMapMoney(amount: 600, currency: "USD"))
        let p = S3Synth.projection(c, [day, month, undated, inr1, inr2, usd], [])
        let ids = p.nodes.map(\.id)
        let byDay = CaseMapDistribution.byDate(ids, in: p, grain: .day)
        #expect(byDay.undated == 4)
        #expect(byDay.buckets.count == 2 && byDay.buckets.contains { $0.label.hasSuffix("(month only)") && $0.members == [month.id] })
        let byMonth = CaseMapDistribution.byDate(ids, in: p, grain: .month)
        #expect(byMonth.buckets.count == 1 && byMonth.buckets[0].members.count == 2, "at month grain both belong to their month; at day grain the month-only one stays apart")
        let bands = CaseMapDistribution.byAmount(ids, in: p)
        #expect(bands.count == 2 && Set(bands.compactMap(\.currency)) == ["INR", "USD"])
        #expect(bands.first { $0.currency == "INR" }?.total == 100_000 && bands.first { $0.currency == "INR" }?.members.count == 2)
    }

    @Test("MAP-10/11: view explanations for restricted, failed and unavailable sources; one line width and card size whatever the certainty")
    func explanationsAndVisualRules() {
        let c = UUID()
        let r = S3Synth.node(c, .journal, "r", .event, "Restricted", status: CaseMapStatus(.restricted, "privileged"))
        let f = S3Synth.node(c, .journal, "f", .event, "Failed", status: CaseMapStatus(.failed, "damaged"))
        let u = S3Synth.node(c, .journal, "u", .event, "Gone", status: CaseMapStatus(.unavailable, "out of scope"))
        let p = S3Synth.projection(c, [r, f, u], [])
        let lines = CaseMapViewExplanation.lines(p, result: CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: [])))
        #expect(lines.count == 3 && lines[0].hasPrefix("Access:") && lines[1].hasPrefix("Processing:") && lines[2].hasPrefix("Unavailable:"))
        let sure = S3Synth.link(c, .supports, r.id, f.id, certainty: .statedBySource, review: .confirmed)
        let doubt = S3Synth.link(c, .supports, f.id, u.id, certainty: .doubtful, review: .unreviewed)
        #expect(CaseMapVisual.lineWidth(sure, selected: false) == CaseMapVisual.lineWidth(doubt, selected: false))
        #expect(CaseMapVisual.cardSize(r) == CaseMapVisual.cardSize(f))
        #expect(Set(CaseMapNodeKind.allCases.map(\.symbol)).count == CaseMapNodeKind.allCases.count, "every kind has its own icon")
        #expect(CaseMapLinkType.allCases.allSatisfy { !HelpRegistry.caseMapLinkHelp($0).isEmpty })
        #expect(!CaseMapLinkType.allCases.contains { $0.rawValue.lowercased().contains("cause") }, "no causation type")
        #expect(CaseMapCertainty.notStated.label.contains("not that it is true"))
    }

    @Test("BRIEF-01/03/04/05: the brief lists position, unresolved, contrary material, changes and next work with reasons; states without a percentage; set-aside is listed, not lost")
    func briefCompute() {
        let c = UUID()
        let caseNode = S3Synth.node(c, .caseFile, c.uuidString, .question, "Case")
        let decided = S3Synth.node(c, .allegation, "a1", .question, "A1 — paid twice", review: .confirmed)
        let open = S3Synth.node(c, .allegation, "a2", .question, "A2 — refund", review: .unreviewed)
        let pro = S3Synth.node(c, .journal, "e1", .event, "Invoice paid", status: CaseMapStatus(.unassessed, "x"))
        let contra = S3Synth.node(c, .journal, "e2", .event, "Bank shows one payment")
        let alt = S3Synth.node(c, .hypothesis, "h1", .hypothesis, "Clerical duplicate", review: .unreviewed)
        let overdue = S3Synth.node(c, .task, "t1", .action, "Get statements", status: .recorded("Open — overdue"), workOpen: true)
        let later = S3Synth.node(c, .task, "t2", .action, "Interview", workOpen: true)
        let done = S3Synth.node(c, .task, "t3", .action, "Done", workOpen: false)
        let changed = S3Synth.node(c, .reportPoint, "p1", .statement, "Point", status: CaseMapStatus(.stale, "changed"), review: .unreviewed)
        let p = S3Synth.projection(c, [caseNode, decided, open, pro, contra, alt, overdue, later, done, changed],
                                   [S3Synth.link(c, .supports, pro.id, decided.id), S3Synth.link(c, .challenges, contra.id, decided.id),
                                    S3Synth.link(c, .dependsOn, later.id, overdue.id)])
        let b = CaseMapBrief.compute(p, changed: [pro.id])
        #expect(b.purpose == "What happened?")
        #expect(b.section("position")?.entries.map(\.node) == [decided.id])
        #expect(Set(b.section("unresolved")?.entries.map(\.node) ?? []) == [open.id, alt.id, changed.id])
        let alts = b.section("alternatives")?.entries ?? []
        #expect(alts.contains { $0.node == contra.id && $0.why.contains("Challenges") } && alts.contains { $0.node == alt.id }, "contrary material beside the position")
        #expect(Set(b.section("changes")?.entries.map(\.node) ?? []) == [pro.id, changed.id])
        #expect(b.section("next")?.entries.map(\.node) == [overdue.id, later.id], "overdue first; finished work is not next work")
        #expect(b.allEntries.allSatisfy { p.node($0.node) != nil && !$0.why.isEmpty }, "every entry opens a record and says why")
        #expect(!b.scope.joined().contains("%") && b.evidentialStates.allSatisfy { !$0.label.contains("%") })
        #expect(b.evidentialStates.first { $0.label.hasPrefix("Questions with supporting") }?.count == 1)
        #expect(b.evidentialStates.first { $0.label.hasPrefix("Questions with challenging") }?.count == 1)
        #expect(b.workStates.first { $0.label.hasPrefix("Finished") }?.count == 1)
        // Set aside: gone from the sections, listed, the record untouched.
        let aside = CaseMapBrief.compute(p, changed: [pro.id], setAside: [contra.id])
        #expect(!aside.allEntries.contains { $0.node == contra.id } && aside.setAside.map(\.node) == [contra.id])
        #expect(p.node(contra.id) != nil)
        // A branch brief: only what is reached from the anchor, with its limit stated.
        let branch = CaseMapBrief.compute(p, anchor: decided.id, budget: 1)
        #expect(branch.anchor == decided.id && branch.scope.contains { $0.contains("not expanded") })
    }

    @Test("BRIEF-07: the return view keeps personal unseen changes apart from items waiting for review; blocked work names what it waits for")
    func returnView() {
        let c = UUID()
        let changed = S3Synth.node(c, .journal, "e", .event, "Changed entry")
        let waiting = S3Synth.node(c, .contradiction, "k", .contradiction, "Possible contradiction", review: .unreviewed)
        let first = S3Synth.node(c, .task, "t1", .action, "First", date: Date().addingTimeInterval(86_400), workOpen: true)
        let second = S3Synth.node(c, .task, "t2", .action, "Second", workOpen: true)
        let p = S3Synth.projection(c, [changed, waiting, first, second], [S3Synth.link(c, .dependsOn, second.id, first.id)])
        let feed = CaseChangeFeedLoad(caseID: c, generation: 1, state: .loaded, seen: nil, baseline: nil,
                                      changes: [CaseChange(id: "x", kind: CaseChangeKind.allCases[0], record: changed.id, recordedAt: Date(), actor: "Ada",
                                                           summary: "s", basis: .recorded("the case log"), isNew: true)],
                                      current: CaseChangeSeenState(), readAt: Date(), omitted: 0, failedParts: [])
        var memory = CaseMapWorkspaceMemory(); memory.selectedNode = waiting.id
        let r = CaseReturnView.compute(p, feed: feed, memory: memory)
        #expect(r.unseen.map(\.node) == [changed.id] && r.reviewRequired.map(\.node) == [waiting.id])
        #expect(r.due.map(\.node) == [first.id] && r.blocked.map(\.node) == [second.id] && r.blocked.first?.why.contains("First") == true)
        #expect(r.resumeSelection == waiting.id && r.feedProblem == nil)
        #expect(CaseReturnView.compute(p, feed: nil, memory: nil).feedProblem != nil, "an unread feed is said, never shown as nothing changed")
    }
}

@MainActor
private func s3Defaults() -> UserDefaults {
    let name = "s3.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

/// Counts how often the case file snapshot is read (the branch read path must not read it when nothing changed).
actor S3ReadCounter { var n = 0; func bump() { n += 1 } }

@MainActor
@Suite("Smart map S3 — graph, map and brief on the ledger", .serialized)
struct SmartMapS3LedgerTests {

    @Test("GRAPH-04/08: a drawn link keeps certainty and period; revise makes a new link naming the old, which is withdrawn and kept; fixed fields refuse edits")
    func linkCertaintyAndRevision() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "The seal was cut", actor: "Ada")
        let repo = CaseMapRepository(database: f.db)
        let from = rig.node(.report, rig.report), to = rig.node(.allegation, q)
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        await #expect(throws: CaseMapError.badPeriod) {
            _ = try await repo.addLink(caseID: c, type: .supports, from: from, to: to, rationale: "r", validity: CaseMapValidity(from: start, to: start.addingTimeInterval(-10), text: nil), actor: "Ada")
        }
        let id = try await repo.addLink(caseID: c, type: .supports, from: from, to: to, rationale: "The report says so", certainty: .possible,
                                        validity: CaseMapValidity(from: start, to: nil, text: "from March"), actor: "Ada")
        var p = try await rig.projection()
        let l = try #require(p.links.first { $0.origins.first?.recordID == id.uuidString.lowercased() })
        #expect(l.certainty == .possible && l.validity?.text == "from March" && l.validity?.from == start && l.recordedAt != nil && l.type.family == .evidence)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_map_links SET certainty = 'probable' WHERE id = ?;", [.uuid(id)]) }
        let revised = try await repo.reviseLink(caseID: c, id: id, type: .mentions, rationale: "It only mentions it", certainty: .statedBySource,
                                                validity: nil, reason: "Read the report again", actor: "Ada")
        let all = try await repo.links(caseID: c)
        #expect(all.first { $0.id == id }?.withdrawnReason == "Revised: Read the report again")
        #expect(all.first { $0.id == revised }?.revisesLinkID == id && all.first { $0.id == revised }?.isActive == true)
        #expect(try await repo.linkHistory(caseID: c, id: revised).map(\.id) == [revised, id])
        await #expect(throws: CaseMapError.alreadyWithdrawn) {
            _ = try await repo.reviseLink(caseID: c, id: id, type: .supports, rationale: "x", certainty: .notStated, validity: nil, reason: "y", actor: "Ada")
        }
        p = try await rig.projection()
        #expect(p.links.filter { $0.origins.first?.kind == .investigatorLink }.map(\.type) == [.mentions])
        // A link nobody qualified says so (an older row reads as not stated).
        #expect(CaseMapLinkType.allCases.filter(\.drawable).allSatisfy { !$0.label.isEmpty })
    }

    @Test("GRAPH-09: same-name rows stay two; a recorded decision is the link; withdrawing it restores the pending pair with both rows' links intact; a person erase removes the decision")
    func identityDecisions() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let a = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let b = try await f.file.addPerson(caseID: c, name: "Ravi Kumar", role: .subject, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        try await f.file.addContact(caseID: c, personID: a, at: Date(), mode: "phone", note: "called", actor: "Ada")
        let na = rig.node(.person, a), nb = rig.node(.person, b)
        var p = try await rig.projection()
        #expect(p.links.contains { $0.type == .possibleSamePerson && $0.review == .pendingReview })
        let before = (p.links(of: na).count, p.links(of: nb).count)
        let d = try await f.file.recordIdentityDecision(caseID: c, personA: b, personB: a, decision: .samePerson, rationale: "Same passport number", actor: "Ada")
        await #expect(throws: CaseBriefError.alreadyDecided) {
            _ = try await f.file.recordIdentityDecision(caseID: c, personA: a, personB: b, decision: .differentPeople, rationale: "x", actor: "Ada")
        }
        p = try await rig.projection()
        #expect(p.node(na) != nil && p.node(nb) != nil, "nothing merged")
        #expect(p.links.contains { $0.type == .samePersonDecided && $0.review == .confirmed } && !p.links.contains { $0.type == .possibleSamePerson })
        try await f.file.withdrawIdentityDecision(caseID: c, id: d, reason: "Passport was misread", actor: "Ada")
        p = try await rig.projection()
        #expect(p.links.contains { $0.type == .possibleSamePerson && $0.review == .pendingReview } && !p.links.contains { $0.type == .samePersonDecided })
        #expect((p.links(of: na).count, p.links(of: nb).count) == before, "both histories and relationships as they were")
        #expect(try await f.file.readIdentityDecisions(caseID: c).first?.withdrawnReason == "Passport was misread")
    }

    @Test("GRAPH-05: a placement that would make a branch contain itself is refused inside the write; investigative cycles are allowed")
    func containmentRefused() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q1 = try await f.file.addAllegation(caseID: c, text: "Q1", actor: "Ada"), q2 = try await f.file.addAllegation(caseID: c, text: "Q2", actor: "Ada")
        let n1 = rig.node(.allegation, q1), n2 = rig.node(.allegation, q2), r = rig.node(.report, rig.report)
        _ = try await f.file.placeInFrame(caseID: c, frame: n1, member: n2, purpose: nil, actor: "Ada")
        _ = try await f.file.placeInFrame(caseID: c, frame: n2, member: r, purpose: nil, actor: "Ada")
        await #expect(throws: CaseContractError.containmentCycle) { _ = try await f.file.placeInFrame(caseID: c, frame: r, member: n1, purpose: nil, actor: "Ada") }
        let repo = CaseMapRepository(database: f.db)
        _ = try await repo.addLink(caseID: c, type: .supports, from: n1, to: n2, rationale: "a", actor: "Ada")
        _ = try await repo.addLink(caseID: c, type: .supports, from: n2, to: n1, rationale: "b", actor: "Ada")
        let p = try await rig.projection()
        #expect(CaseMapFrames.traverse(from: n1, in: p, budget: 1_000).exhausted)
        #expect(Set(CaseMapFolds.descendants(of: n1, in: p)) == [n2, r])
    }

    @Test("GRAPH-06/07: coverage names stores the map does not draw (never passing the map's items as the whole case); omitted stores read a page at a time under their branch")
    func coverageAndOmittedStores() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let a = try await f.file.addPerson(caseID: c, name: "Mira", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let b = try await f.file.addPerson(caseID: c, name: "Dev", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        for i in 0..<3 { try await f.file.addContact(caseID: c, personID: a, at: Date(), mode: "visit \(i)", note: nil, actor: "Ada") }
        try await f.file.addContact(caseID: c, personID: b, at: Date(), mode: "email", note: nil, actor: "Ada")
        try await f.file.issueHold(caseID: c, custodian: "Records office", personID: nil, noticeText: "Keep everything", reminderDue: nil, actor: "Ada")
        let repo = CaseMapRepository(database: f.db)
        let p = try await rig.projection()
        let raw = try await repo.coverage(caseID: c)
        let cov = CaseMapCoverage.reconcile(counts: raw.counts, problems: raw.problems, projection: p)
        #expect(cov.undrawn.contains { $0.table == "case_contacts" && $0.rows == 4 } && cov.undrawn.contains { $0.table == "case_hold_notices" && $0.rows == 1 })
        #expect(cov.rows.first { $0.table == "case_people" }.map { $0.rows == 2 && $0.onMap == 2 } == true)
        #expect(cov.rows.first { $0.table == "case_reports" }.map { $0.onMap == 1 } == true)
        #expect(cov.summary?.contains("case contacts (4)") == true && cov.uncounted.isEmpty)
        // The counts line then says so.
        let model = rig.model(s3Defaults())
        let service = CaseMapService(sources: caseMapSources(f))
        await model.refresh(service)
        await model.refreshCoverage(service.repository)
        #expect(model.result?.counts.summary.contains("the map does not draw") == true)
        // Omitted stores: Mira's contacts only, paged; nothing is lost past the page.
        let first = try await repo.omittedRecords(caseID: c, store: .contacts, anchor: rig.node(.person, a), offset: 0, limit: 2)
        #expect(first.total == 3 && first.rows.count == 2 && first.remaining == 1)
        let next = try await repo.omittedRecords(caseID: c, store: .contacts, anchor: rig.node(.person, a), offset: 2, limit: 2)
        #expect(next.rows.count == 1 && next.remaining == 0 && Set((first.rows + next.rows).map(\.id)).count == 3)
        let log = try await repo.omittedRecords(caseID: c, store: .workLog, anchor: nil, limit: 5)
        #expect(log.total >= 6 && log.rows.count == 5)
        #expect(CaseMapOmittedStore.stores(for: .person) == [.contacts, .holdNotices])
    }

    @Test("Branch read path: an unchanged case answers a branch from the last read (fence only, no snapshot read); a change rereads; scope removal drops the record (GRAPH-10)")
    func branchReadAndScope() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let counter = S3ReadCounter()
        var sources = caseMapSources(f)
        let snap = sources.snapshot
        sources.snapshot = { id, custody in await counter.bump(); return try await snap(id, custody) }
        let service = CaseMapService(sources: sources)
        _ = await service.load(caseID: c, generation: 1)
        let reads = await counter.n
        let report = rig.node(.report, rig.report)
        let cached = await service.branch(caseID: c, anchor: report)
        #expect(cached.source == .cached && cached.frame?.anchor == report && cached.traversal?.exhausted == true)
        let afterCached = await counter.n
        #expect(afterCached == reads, "no case read for a branch of an unchanged case")
        _ = try await f.file.addAllegation(caseID: c, text: "New", actor: "Ada")
        let reread = await service.branch(caseID: c, anchor: report)
        let afterReread = await counter.n
        #expect(reread.source == .reread && afterReread > reads)
        // Scope change: the report's document leaves the case scope; the branch read sees it gone, and so does the projection.
        let p0 = try #require(await service.load(caseID: c, generation: 3).projection)
        let doc = try #require(p0.nodes.first { $0.id.kind == .document }?.id)
        try await f.db.exec("UPDATE investigation_case_sources SET in_scope = 0 WHERE case_id = ?;", [.uuid(c)])
        let gone = await service.branch(caseID: c, anchor: doc)
        #expect(gone.source == .reread && gone.frame == nil && gone.problem != nil)
        let p1 = try #require(await service.load(caseID: c, generation: 4).projection)
        #expect(p1.node(doc) == nil && p1.node(report)?.status.kind == .unavailable, "the report says its document is not in the case")
    }

    @Test("GRAPH-11: one action serving two questions is one record, counted once; its result reaches both")
    func sharedWork() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q1 = try await f.file.addAllegation(caseID: c, text: "Q1", actor: "Ada"), q2 = try await f.file.addAllegation(caseID: c, text: "Q2", actor: "Ada")
        let action = try await f.svc.createAction(caseID: c, .init(title: "Examine", purpose: "Both", deliverable: "Note", servesQuestions: [q1, q2]), actor: "Ada")
        let result = try await f.svc.recordResult(caseID: c, taskID: action, title: "Examination note", actor: "Ada")
        let p = try await rig.projection()
        let a = rig.node(.task, action)
        #expect(CaseMapSharedWork.served(by: a, in: p) == [rig.node(.allegation, q1), rig.node(.allegation, q2)].sorted())
        #expect(CaseMapSharedWork.uniqueWork(serving: [rig.node(.allegation, q1), rig.node(.allegation, q2)], in: p) == [a])
        let reach = CaseMapSharedWork.resultsReach(a, in: p)
        #expect(reach.results == [rig.node(.report, result)] && reach.questions.count == 2)
        #expect(p.nodes.filter { $0.id == a }.count == 1)
        let brief = CaseMapBrief.compute(p)
        #expect(brief.section("next")?.entries.filter { $0.node == a }.count == 1, "listed once in next work")
    }

    @Test("BRIEF-02/06: brief versions; an accepted version is never edited; a stale write is refused; later case changes mark it written-before, its own brief writes do not")
    func briefVersions() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let caseNode = rig.node(.caseFile, c)
        await #expect(throws: CaseBriefError.emptyBrief) { _ = try await f.file.writeBrief(caseID: c, anchor: caseNode, text: CaseBriefText(), expectedVersion: 0, actor: "Ada") }
        let v1 = try await f.file.writeBrief(caseID: c, anchor: caseNode, text: CaseBriefText(position: "The seal was intact on arrival"), expectedVersion: 0, actor: "Ada")
        await #expect(throws: CaseBriefError.versionChanged) {
            _ = try await f.file.writeBrief(caseID: c, anchor: caseNode, text: CaseBriefText(position: "x"), expectedVersion: 0, actor: "Ben")
        }
        try await f.file.acceptBrief(caseID: c, id: v1, actor: "Ada")
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_briefs SET position = 'rewritten' WHERE id = ?;", [.uuid(v1)]) }
        await #expect(throws: CaseBriefError.alreadyAccepted) { try await f.file.acceptBrief(caseID: c, id: v1, actor: "Ada") }
        // Relevance and briefing writes do not make the brief stale.
        _ = try await f.file.setBriefRelevance(caseID: c, record: rig.node(.report, rig.report), decision: .setAside, reason: "Background only", actor: "Ada")
        _ = try await f.file.createBriefing(caseID: c, title: "Handover", purpose: nil, actor: "Ada")
        var ledger = try await f.file.briefLedger(caseID: c)
        let first = try #require(ledger.versions(of: caseNode).first)
        #expect(first.version == 1 && first.isAccepted && !ledger.isStale(first) && first.attribution.contains("accepted by Ada"))
        #expect(ledger.setAside == [rig.node(.report, rig.report)])
        // New evidence: the accepted version keeps its words and says it was written before.
        _ = try await f.file.addAllegation(caseID: c, text: "Was the seal cut later?", actor: "Ada")
        ledger = try await f.file.briefLedger(caseID: c)
        let still = try #require(ledger.versions(of: caseNode).first)
        #expect(still.position == "The seal was intact on arrival" && ledger.isStale(still))
        let v2 = try await f.file.writeBrief(caseID: c, anchor: caseNode, text: CaseBriefText(position: "Intact on arrival; cut later is open"), expectedVersion: 1, actor: "Ada")
        ledger = try await f.file.briefLedger(caseID: c)
        #expect(ledger.versions(of: caseNode).map(\.version) == [2, 1] && ledger.versions(of: caseNode).first?.supersedesID == v1 && ledger.versions(of: caseNode).first?.id == v2)
        #expect(ledger.versions(of: caseNode).first.map { !ledger.isStale($0) } == true)
        // A branch brief on a record of another case is refused.
        await #expect(throws: (any Error).self) {
            _ = try await f.file.writeBrief(caseID: c, anchor: CaseMapNodeID(caseID: c, kind: .allegation, id: UUID()), text: CaseBriefText(purpose: "x"), expectedVersion: 0, actor: "Ada")
        }
    }

    @Test("BRIEF-08: a live briefing shows what changed since each step was added; a frozen one keeps every step as it was and refuses changes; a stale map refuses freezing")
    func briefings() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "Was the seal intact?", actor: "Ada")
        let service = CaseMapService(sources: caseMapSources(f))
        var load = await service.load(caseID: c, generation: 1)
        var p = try #require(load.projection)
        let qn = rig.node(.allegation, q)
        let b = try await f.file.createBriefing(caseID: c, title: "Handover to Ben", purpose: "Take over the seal question", actor: "Ada")
        _ = try await f.file.addBriefingItem(caseID: c, briefingID: b, kind: .record, record: qn, revision: p.node(qn)?.revision, actor: "Ada")
        _ = try await f.file.addBriefingItem(caseID: c, briefingID: b, kind: .frame, record: rig.node(.report, rig.report), revision: nil, actor: "Ada")
        _ = try await f.file.addBriefingItem(caseID: c, briefingID: b, kind: .note, note: "Start with the photographs", actor: "Ada")
        // Decide the question: the live step says it changed.
        try await f.file.decide(allegationID: q, caseID: c, disposition: .inconclusive, rationale: "Photos", actor: "Ada")
        load = await service.load(caseID: c, generation: 2)
        p = try #require(load.projection)
        var ledger = try await f.file.briefLedger(caseID: c)
        var steps = CaseBriefings.steps(try #require(ledger.briefings.first), in: p) { _ in nil }
        #expect(steps.count == 3 && steps[0].change?.hasPrefix("Changed since it was added") == true && steps[2].kind == .note)
        // Freezing with an out-of-date map is refused.
        _ = try await f.file.addAllegation(caseID: c, text: "Later", actor: "Ada")
        await #expect(throws: CaseBriefError.staleProjection) { try await f.file.freezeBriefing(caseID: c, briefingID: b, projection: p, fence: load.fence, actor: "Ada") }
        load = await service.load(caseID: c, generation: 3)
        p = try #require(load.projection)
        try await f.file.freezeBriefing(caseID: c, briefingID: b, projection: p, fence: load.fence, actor: "Ada")
        ledger = try await f.file.briefLedger(caseID: c)
        let frozen = try #require(ledger.briefings.first)
        #expect(frozen.isFrozen && frozen.frozen?.count == 3)
        let recorded = frozen.frozen?.first?.state
        await #expect(throws: CaseBriefError.frozen) { _ = try await f.file.addBriefingItem(caseID: c, briefingID: b, kind: .note, note: "x", actor: "Ada") }
        await #expect(throws: CaseBriefError.frozen) { try await f.file.removeBriefingItem(caseID: c, itemID: frozen.items[0].id, actor: "Ada") }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_briefings SET title = 'x' WHERE id = ?;", [.uuid(b)]) }
        // After a later change the frozen steps are as recorded; they still open into the map.
        try await f.file.decide(allegationID: q, caseID: c, disposition: .unsubstantiated, rationale: "Second look", actor: "Ada")
        let p2 = try #require(await service.load(caseID: c, generation: 4).projection)
        steps = CaseBriefings.steps(frozen, in: p2) { _ in nil }
        #expect(steps.first?.state == recorded && steps.first?.record == qn && p2.node(qn) != nil && steps.allSatisfy { $0.change == nil })
        // Withdrawing a frozen briefing is allowed (with a reason); it stays in the ledger.
        try await f.file.withdrawBriefing(caseID: c, briefingID: b, reason: "Superseded", actor: "Ada")
        #expect(try await f.file.briefLedger(caseID: c).briefings.first?.isActive == false)
    }

    @Test("MAP-05/06/09 and saved frames: Forward, presentation and drawer survive re-creation; the new views filter; a saved view reopens its frames; chosen items arrange and pin with Undo")
    func modelNavigation() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "Q", actor: "Ada")
        let defaults = s3Defaults()
        let service = CaseMapService(sources: caseMapSources(f))
        let model = rig.model(defaults)
        await model.refresh(service)
        model.select(.node(rig.node(.report, rig.report)))
        model.go(to: .builtIn(.work))
        model.goBack()
        #expect(model.canGoForward && model.view == .builtIn(.overview))
        model.presentation = .timeline
        model.drawerOpen = true
        let again = rig.model(defaults)
        await again.refresh(service)
        #expect(again.canGoForward && again.presentation == .timeline && again.drawerOpen && !again.listMode)
        again.goForward()
        #expect(again.view == .builtIn(.work) && !again.canGoForward && again.canGoBack)
        // New views hold their kinds.
        let p = try #require(again.projection)
        let evidence = CaseMapViewFilter.apply(p, view: .evidence, filter: CaseMapFilter(collapsed: []))
        #expect(evidence.shown.contains(rig.node(.report, rig.report)) && !evidence.shown.contains(rig.node(.allegation, q)) && evidence.counts.reconciles)
        // A saved view keeps the frames open when it was saved and reopens them.
        await again.openFrame(rig.node(.report, rig.report), service: service)
        let saved = try #require(await again.saveCurrentView(named: "Report branch", repository: service.repository, actor: "Ada"))
        await again.returnToFrame(depth: 0, service: service)
        #expect(again.frameStack.isEmpty)
        again.go(to: .builtIn(.overview))
        again.go(to: .saved(saved))
        #expect(again.frameStack.map(\.anchor) == [rig.node(.report, rig.report)])
        await again.syncFramePlacements(service)
        #expect(again.frame?.anchor == rig.node(.report, rig.report))
        // Chosen items: arrange and pin together, one Undo puts them back.
        await again.returnToFrame(depth: 0, service: service)
        let ids = Set(p.nodes.prefix(3).map(\.id))
        for id in ids { again.toggleMulti(id) }
        await again.setPinned(true, ids, repository: service.repository)
        #expect(ids.allSatisfy { again.placements[$0]?.pinned == true })
        await again.undo(repository: service.repository)
        #expect(ids.allSatisfy { again.placements[$0]?.pinned == false })
        #expect(again.arrangeScope(.chosen(ids)) == ids)
        // Folding and reveal: reveal opens the fold that holds a record.
        let point = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "Seal intact", quote: nil, actor: "Ada")
        await again.refresh(service)
        again.go(to: .builtIn(.overview))
        var m = again.memory; m.collapsed = [CaseMapViewKind.overview.rawValue: []]; again.memory = m
        await again.toggleFold(rig.node(.report, rig.report), repository: service.repository, actor: "Ada")
        #expect(again.result?.shown.contains(rig.node(.reportPoint, point)) == false && (again.result?.counts.folded ?? 0) >= 1)
        #expect(again.reveal(rig.node(.reportPoint, point)) && again.result?.shown.contains(rig.node(.reportPoint, point)) == true)
    }

    @Test("MAP-06: money movements in the case's own documents become money items linked to their documents; a failed read is a named part, not 'no money'")
    func moneyItems() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        var sources = caseMapSources(f)
        let object = rig.doc.object.uuidString.uppercased()
        func transfer(_ amount: Decimal, _ cur: String, _ day: Date?) -> FundsTransfer {
            FundsTransfer(fromID: "E1", fromLabel: "Acme Ltd", toID: "E2", toLabel: "Supplier A", money: FundsMoney(amount: amount, currency: cur),
                          documentID: object, factIDs: ["f-\(amount)-\(cur)"], date: day, reference: nil)
        }
        let txs = FundsTrace.transactions([transfer(50_000, "INR", Date(timeIntervalSince1970: 1_772_000_000)), transfer(600, "USD", nil)])
        sources.money = { _, objects in
            #expect(objects.contains(rig.doc.object))
            return txs
        }
        let p = try #require(await CaseMapService(sources: sources).load(caseID: c, generation: 1).projection)
        let money = p.nodes.filter { $0.kind == .money }
        #expect(money.count == 2 && Set(money.compactMap(\.money?.currency)) == ["INR", "USD"])
        #expect(money.allSatisfy { n in p.links(of: n.id).contains { $0.type == .derivedFrom && $0.to.kind == .document } && !n.isDocumentary })
        #expect(money.first { $0.money?.currency == "INR" }?.datePrecision == .day)
        let view = CaseMapViewFilter.apply(p, view: .money, filter: CaseMapFilter(collapsed: []))
        #expect(money.allSatisfy { view.shown.contains($0.id) })
        var failing = caseMapSources(f)
        failing.money = { _, _ in throw CaseFileError.blank("x") }
        let partial = await CaseMapService(sources: failing).load(caseID: c, generation: 1)
        #expect(partial.projection?.failedParts.contains(.money) == true)
    }

    @Test("v178 → v179: links keep their rows and read as certainty not stated; the new tables exist and integrity holds")
    func migrationFromV178() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 178)
        let c = UUID()
        let l = UUID()
        try await db.exec("INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?);",
                          [.uuid(l), .uuid(c), .text("supports"), .text("case"), .text(c.uuidString.lowercased()), .text("allegation"), .text("x"), .text("r"), .text("Ada"), .real(1)])
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)   // v180 (S4) follows v179
        for t in ["case_person_identity_decisions", "case_briefs", "case_brief_relevance", "case_briefings", "case_briefing_items"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
        let links = try await CaseMapRepository(database: db).links(caseID: c)
        #expect(links.count == 1 && links[0].certainty == .notStated && links[0].validity == nil && links[0].revisesLinkID == nil)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
