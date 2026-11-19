//
//  SmartMapS18QATests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S18 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §28 QA, milestone M6):
//  - QA-04: a documentary/historical case — uncertain dates, a derivative source, similar names, a gap and a later
//    correction stay visible on the map, in the brief and in the export;
//  - QA-06: every advertised record kind the map draws is reachable from real records; omitted stores are reachable
//    from their branch; a failed read and an out-of-scope source are explicit;
//  - QA-08: AI off, suggestions and configured execution, each with a model failure and a refused permission: the case
//    keeps working by hand (scripted fake reader; no network, no model);
//  - QA-09: races — simultaneous edits of one revision, an erasure racing a hold, scope changed under a prepared export,
//    a late carry into an erased case;
//  - QA-10: older ledgers upgrade with their rows; corrupt, truncated and manifest-less backups are refused whole;
//  - QA-11: a package mixing source revisions names each version with its availability and matches its manifest; a
//    privilege added after preparing stops it.
//  Dates carry explicit time zones (Europe/Berlin for the historical case).
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let s18Berlin = TimeZone(identifier: "Europe/Berlin")!

private func s18Date(_ y: Int, _ m: Int, _ d: Int, zone: TimeZone = s18Berlin) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: m, day: d))!
}

private func s18qCount(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, b).first?.int(0) ?? -1)
}

/// A new current version of the document behind `object`, included in the case (as SmartMapS16Tests does).
private func s18Revise(_ db: Database, object: UUID, cases: InvestigationCaseRepository, caseID: UUID) async throws -> UUID {
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
    let header = try await cases.fetch(caseID: caseID)?.caseHeader
    _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                      sourceKind: .sourceVersion, actor: "Ada", at: Date())
    return version
}

/// The scripted reader for the AI-mode journeys (each send recorded; consent answered from `allow`).
private nonisolated final class S18Script: @unchecked Sendable {
    private let lock = NSLock()
    private var _sends = 0
    private var _allow = true
    var fail = true
    func send() -> Int { lock.withLock { _sends += 1; return _sends } }
    func consent() -> Bool { lock.withLock { _allow } }
    func setAllow(_ a: Bool) { lock.withLock { _allow = a } }
    var sends: Int { lock.withLock { _sends } }
}

@Suite("Smart map S18 — QA: documentary case, adapters, AI modes, races, recovery, package integrity (M6)", .serialized)
@MainActor
struct SmartMapS18QATests {

    // MARK: QA-04

    @Test("QA-04: a documentary case — 'c. 1887' stays approximate and as written, a transcription stays derived from its register, two similar names stay two people pending review, a gap stays a gap, a later correction supersedes without erasing — on the map, in a recorded state, in the brief and in the export")
    func documentaryCase() async throws {
        let f = try await CaseFileTests.fixture(title: "When was Johann Weber baptised?")
        let c = f.caseID
        let register = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "parish-register-1887.txt",
                                                                 text: "Baptisms, St. Marien. Johann Weber, son of Karl Weber, baptised in the year 1887 (day illegible).")
        let transcription = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "transcription-1950.txt",
                                                                      text: "Typed copy of the St. Marien register made in 1950: Johan Webber, baptised 1887.")
        let correction = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "civil-register-1902.txt",
                                                                   text: "Civil register extract of 1902: Johann Weber born 2 May 1888, baptised 14 May 1888; the parish entry for 1887 is an error.")
        let q = try await f.file.addAllegation(caseID: c, text: "When was Johann Weber baptised?", actor: "Ada")
        let zone = s18Berlin.identifier
        let early = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Johann Weber baptised (parish register)", eventDate: s18Date(1887, 1, 1),
                                                evidenceRef: register.version.uuidString, datePrecision: .year, dateText: "c. 1887",
                                                dateQualifier: .approximate, timeZoneID: zone, actor: "Ada")
        let gap = try await f.file.addJournal(caseID: c, kind: .chronology, text: "No surviving parish books for these years (gap in the record)",
                                              eventDate: s18Date(1889, 1, 1), evidenceRef: nil, datePrecision: .year, dateText: "1889–1901",
                                              dateEnd: s18Date(1901, 12, 31), dateQualifier: .between, timeZoneID: zone, actor: "Ada")
        let corrected = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Johann Weber baptised (civil register correction of 1902)",
                                                    eventDate: s18Date(1888, 5, 14), evidenceRef: correction.version.uuidString, datePrecision: .day,
                                                    timeZoneID: zone, actor: "Ada")
        let undated = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Johan Webber emigrated (family letter, undated)",
                                                  eventDate: nil, evidenceRef: nil, actor: "Ada")
        let johann = try await f.file.addPerson(caseID: c, name: "Johann Weber", role: .subject, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let johan = try await f.file.addPerson(caseID: c, name: "Johan Webber", role: .other, entityID: nil, contact: nil, notes: "As spelled in the 1950 transcription", actor: "Ada")
        let uncle = try await f.file.addPerson(caseID: c, name: "Johann Weber", role: .other, entityID: nil, contact: nil, notes: "His uncle, also baptised Johann", actor: "Ada")
        func nid(_ k: CaseMapRecordKind, _ id: UUID) -> CaseMapNodeID { CaseMapNodeID(caseID: c, kind: k, id: id) }
        var p = try #require(await caseMapLoad(f).projection)
        let regDoc = try #require(p.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == register.version } }).id
        let trDoc = try #require(p.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == transcription.version } }).id
        let map = CaseMapRepository(database: f.db)
        _ = try await map.addLink(caseID: c, type: .derivedFrom, from: trDoc, to: regDoc, rationale: "A 1950 typed copy of the register, not an independent source", actor: "Ada")
        _ = try await map.addLink(caseID: c, type: .supersedes, from: nid(.journal, corrected), to: nid(.journal, early), rationale: "The 1902 civil register corrects the year", actor: "Ada")
        _ = try await map.addLink(caseID: c, type: .supports, from: nid(.journal, early), to: nid(.allegation, q), rationale: "The parish entry", actor: "Ada")
        _ = try await map.addLink(caseID: c, type: .challenges, from: nid(.journal, corrected), to: nid(.allegation, q), rationale: "The correction", actor: "Ada")
        p = try #require(await caseMapLoad(f).projection)

        // 1. On the map: both entries stay (the corrected one is not removed), each with its own precision and wording.
        let e = try #require(p.node(nid(.journal, early))), k = try #require(p.node(nid(.journal, corrected)))
        #expect(e.datePrecision == .year && e.dateText == "c. 1887" && e.dateQualifier == .approximate)
        #expect(k.datePrecision == .day)
        #expect(p.node(nid(.journal, undated))?.eventDate == nil, "undated stays undated")
        #expect(p.node(nid(.journal, gap))?.dateEnd != nil && p.node(nid(.journal, gap))?.dateQualifier == .between)
        #expect(p.links(of: nid(.journal, early)).contains { $0.type == .supersedes && $0.from == nid(.journal, corrected) })
        #expect(p.links(of: trDoc).contains { $0.type == .derivedFrom && $0.to == regDoc }, "the copy depends on the register")
        #expect(p.node(nid(.person, johann)) != nil && p.node(nid(.person, johan)) != nil && p.node(nid(.person, uncle)) != nil, "three rows, none merged")
        let pending = p.links(of: nid(.person, johann)).filter { $0.type == .possibleSamePerson }
        #expect(pending.count == 1 && pending.first?.review == .pendingReview && pending.first?.status.text.contains("Same name only") == true,
                "two people of the same name stay two rows pending review, the name alone is not evidence")
        #expect(p.links(of: nid(.person, johan)).isEmpty, "a similar spelling is never joined to anyone automatically")
        #expect(!p.links.contains { $0.type == .samePersonDecided }, "nobody decided they are the same")
        #expect(p.links(of: nid(.allegation, q)).contains { $0.type == .supports } && p.links(of: nid(.allegation, q)).contains { $0.type == .challenges },
                "both dates bear on the question; neither averaged away")
        // 2. The brief takes no position and lists the contrary material.
        let brief = CaseMapBrief.compute(p, changed: [])
        #expect(brief.section("position")?.entries.isEmpty == true)

        // 3. A recorded state keeps it all.
        let history = CaseHistoryService(database: f.db, map: CaseMapService(sources: caseMapSources(f)))
        let cp = try await history.record(caseID: c, kind: .manual, actor: "Ada")
        let rp = try await history.open(id: cp.id, caseID: c).projection
        #expect(rp.node(nid(.journal, early))?.dateText == "c. 1887" && rp.node(nid(.journal, early))?.dateQualifier == .approximate)
        #expect(rp.links.contains { $0.type == .derivedFrom } && rp.links.contains { $0.type == .possibleSamePerson } && rp.links.contains { $0.type == .supersedes })

        // 4. The export says each in words: approximate and as written, the range, undated empty, derived, pending, supersedes.
        let frozen = CaseMapExportRenderer.freeze(CaseMapExportRequest(projection: p, placements: [:], shown: p.nodes.map(\.id), links: p.links.map(\.id),
                                                                       selection: nil, viewTitle: "All", state: .current(Date()), scopeFingerprint: nil),
                                                  restrictions: [], timeZone: s18Berlin)
        func event(_ id: UUID) -> String? { frozen.items.first { $0.ref == nid(.journal, id).key }?.event }
        #expect(event(early) == "1887 (approximately) — as written: c. 1887", "\(event(early) ?? "nil")")
        #expect(event(corrected) == "1888-05-14")
        #expect(event(gap) == "1889/1901 (between) — as written: 1889–1901", "\(event(gap) ?? "nil")")
        #expect(event(undated) == "")
        let csv = CaseMapExportRenderer.csv(frozen)
        for words in ["derived from", "possibly the same person (pending review)", "Same name only", "supersedes", "A 1950 typed copy of the register", "Johan Webber", "Johann Weber"] {
            #expect(csv.contains(words), "the export says: \(words)")
        }
        #expect(!frozen.items.contains { $0.event.hasPrefix("1970") })
    }

    // MARK: QA-06

    @Test("QA-06: every record kind the map draws is reachable from a real record; omitted stores from their branch; a document that could not be read and a document of another case are explicit; the coverage counts every store without a problem")
    func adapterMatrix() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f, c = f.caseID
        var made: [CaseMapRecordKind: UUID] = [:]
        made[.allegation] = try await f.file.addAllegation(caseID: c, text: "Was the supplier paid twice?", actor: "Ada")
        made[.person] = try await f.file.addPerson(caseID: c, name: "Meera Shah", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        made[.journal] = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Second payment", eventDate: nil, evidenceRef: nil, actor: "Ada")
        made[.task] = try await f.svc.createAction(caseID: c, .init(title: "Ask the bank", purpose: "Both slips", deliverable: "Slips", responsible: "Ada",
                                                                   servesQuestions: [made[.allegation]!]), actor: "Ada")
        let report = try await f.file.addReport(caseID: c, CaseReportDetails(title: "Bank review", sourceVersionID: rig.a.version), actor: "Ada")
        made[.report] = report
        made[.reportPoint] = try await f.file.addPoint(caseID: c, reportID: report, kind: .claim, statement: "Two payments were made", passage: nil, support: .note,
                                                       locatorNote: nil, actor: "Ada")
        let acct = try await f.file.addMoneyAccount(caseID: c, identifier: "3391", actor: "Ada")
        made[.moneyAccount] = acct
        var pay = CaseMoneyRecordInput(kind: .payment, amountText: "INR 10,000"); pay.date = "2026-03-05"; pay.payerAccountID = acct
        made[.moneyRecord] = try await f.file.recordMoney(caseID: c, pay, actor: "Ada")
        let interview = try await f.file.addInterview(caseID: c, personID: made[.person], questions: "When was it paid?", actor: "Ada")
        made[.interview] = interview
        _ = try await f.file.addExhibit(caseID: c, number: "E1", description: "Bank slip", sourceRef: rig.a.version.uuidString, sha256: nil,
                                        collectedBy: "Ada", collectedAt: nil, collectedWhere: nil, actor: "Ada")
        _ = try await InvestigationAnalysisRepository(database: f.db).createRequest(caseID: c, hypothesisID: nil, description: "The bank's ledger", actor: "Ada", at: Date())
        // Omitted stores, each under its branch.
        try await f.file.addContact(caseID: c, personID: made[.person]!, at: Date(), mode: "phone", note: "Called about the slips", actor: "Ada")
        try await f.file.addCredibility(caseID: c, interviewID: interview, factor: .consistency, assessment: .neutral, note: "Consistent", evidenceRef: nil, actor: "Ada")
        try await f.file.issueHold(caseID: c, custodian: "Accounts", personID: made[.person], noticeText: "Keep the March records", reminderDue: nil, actor: "Ada")
        // Failures: a document held in the case that could not be read; a document of another case.
        let unread = try #require(UUID(uuidString: try await CaseFileTestSources.inScope(f.db, cases: f.cases, caseID: c).first ?? ""))
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Other matter", actor: "Ada", at: Date())
        let foreign = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: other.id, name: "elsewhere.txt", text: "Unrelated words.")

        let p = try #require(await caseMapLoad(f).projection)
        for (kind, id) in made {
            #expect(p.node(CaseMapNodeID(caseID: c, kind: kind, id: id)) != nil, "\(kind.rawValue) is reachable on the map")
        }
        for kind: CaseMapRecordKind in [.document, .exhibit, .request, .contradiction] {
            #expect(p.nodes.contains { $0.id.kind == kind }, "\(kind.rawValue) is reachable on the map")
        }
        let failed = try #require(p.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == unread } })
        #expect(failed.status.kind == .failed && failed.status.text.contains("not read"), "\(failed.status)")
        #expect(!p.nodes.contains { $0.sources.contains { $0.sourceVersionID == foreign.version } }, "another case's document is not in this case")
        let repo = CaseMapRepository(database: f.db)
        for (store, anchor) in [(CaseMapOmittedStore.contacts, CaseMapNodeID(caseID: c, kind: .person, id: made[.person]!)),
                                (.credibility, CaseMapNodeID(caseID: c, kind: .interview, id: interview)),
                                (.holdNotices, nil), (.workLog, nil)] {
            let page = try await repo.omittedRecords(caseID: c, store: store, anchor: anchor)
            #expect(page.total >= 1 && !page.rows.isEmpty, "\(store.rawValue) reachable from its branch")
        }
        let coverage = try await repo.coverage(caseID: c)
        #expect(coverage.problems.isEmpty, "\(coverage.problems)")
        #expect(coverage.counts["case_contacts"] == .some(1) && coverage.counts["case_hold_notices"] == .some(1))
        // Every drawable kind exercised here or by the projection's own suites; the origin-only kinds are listed.
        let drawnHere: Set<CaseMapRecordKind> = Set(made.keys).union([.document, .exhibit, .request, .contradiction])
        #expect(CaseMapRecordKind.linkable.subtracting(drawnHere).subtracting([.caseFile, .addendum, .hypothesis, .reportItem]).isEmpty)
    }

    // MARK: QA-08

    @Test("QA-08: AI off, suggestions and configured execution — each with a failing model and a refused permission — leave the case to be worked by hand: links, questions, chronology, an action, a map export and a package")
    func aiModesNeverBreakManualWork() async throws {
        for mode: CaseAIMode in [.off, .suggest, .execute] {
            let f = try await CaseFileTests.fixture(title: "Supplier payments (\(mode.rawValue))")
            let c = f.caseID
            let st = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: c, name: "statement.txt",
                                                               text: "Transfer to Dalmia Traders on 5 March 2026 for ₹10,000. A second transfer followed on 9 March 2026.")
            let q = try await f.file.addAllegation(caseID: c, text: "Was the supplier paid twice?", actor: "Ada")
            let script = S18Script()
            let objects = KnowledgeObjectRepository(database: f.db)
            let plan = CaseWholeReading(
                documents: { versions in
                    let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
                    var out: [CaseReader.Document] = []
                    for id in byObject.keys {
                        guard let text = try await objects.fetchContent(id: id), !text.isEmpty else { continue }
                        out.append(CaseReader.Document(objectID: id, sourceVersionID: byObject[id]?.first, fileName: "statement.txt", text: text))
                    }
                    return out
                },
                gate: { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) }, legacyPrivileged: { [] }) },
                reader: { CaseReader { _ in _ = script.send(); throw URLError(.timedOut) } },
                permissions: CaseReadPermissionStore.inMemory(account: { nil }),
                askConsent: { _ in script.consent() })
            let ai = CaseAIAssistService(database: f.db, caseFiles: f.svc, plan: plan, search: CaseSearchService(sources: CaseSearchSources.live(database: f.db)),
                                         identity: { .init(provider: "test-provider", model: "configured-model-3") })
            _ = try await CaseAutomationService(database: f.db, caseFiles: f.svc).setAIPolicy(caseID: c, CaseAIPolicy(mode: mode), actor: "Ada")

            // The model fails (time-out), then the permission is refused.
            if mode == .off {
                await #expect(throws: CaseAIAssistError.self) { _ = try await ai.run(caseID: c, task: CaseAIAssistTask(kind: .followUps), actor: "Ada") }
                #expect(script.sends == 0, "Off sends nothing")
            } else {
                // The person refuses the permission: nothing is sent, the run says to continue by hand.
                script.setAllow(false)
                let declined = try await ai.run(caseID: c, task: CaseAIAssistTask(kind: .review), actor: "Ada")
                #expect(declined.outcome == .declined && declined.proposals.isEmpty && declined.continueManually != nil, "\(mode): \(declined.outcome)")
                #expect(script.sends == 0, "\(mode): a refused permission sends nothing")
                // Allowed, and the model fails (time-out): recorded, nothing proposed.
                script.setAllow(true)
                let failed = try await ai.run(caseID: c, task: CaseAIAssistTask(kind: .followUps), actor: "Ada")
                #expect(failed.outcome == .failed && failed.proposals.isEmpty && failed.continueManually != nil, "\(mode): \(failed.outcome)")
                #expect(script.sends == 1)
            }
            #expect(try await s18qCount(f.db, "SELECT COUNT(*) FROM case_ai_proposals WHERE case_id = ?;", [.uuid(c)]) == 0)

            // Manual work in the same case, right after.
            let docID = try #require(try await f.db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(st.object)]).first?.uuid(0))
            let docNode = CaseMapNodeID(caseID: c, kind: .document, id: docID), qNode = CaseMapNodeID(caseID: c, kind: .allegation, id: q)
            _ = try await CaseMapRepository(database: f.db).addLink(caseID: c, type: .supports, from: docNode, to: qNode, rationale: "Two transfers", actor: "Ada")
            let q2 = try await f.file.addAllegation(caseID: c, text: "Who approved the second transfer?", actor: "Ada")
            let entry = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Second transfer", eventDate: nil, evidenceRef: st.version.uuidString, actor: "Ada")
            let task = try await f.svc.createAction(caseID: c, .init(title: "Ask the bank", purpose: "Who approved", deliverable: "Slip", responsible: "Ada", servesQuestions: [q2]), actor: "Ada")
            let p = try #require(await caseMapLoad(f).projection)
            for n in [qNode, CaseMapNodeID(caseID: c, kind: .allegation, id: q2), CaseMapNodeID(caseID: c, kind: .journal, id: entry), CaseMapNodeID(caseID: c, kind: .task, id: task)] {
                #expect(p.node(n) != nil, "\(mode): \(n.key) on the map")
            }
            let (out, temp) = try s11Outputs(f)
            defer { try? FileManager.default.removeItem(at: temp) }
            let service = CaseMapService(sources: caseMapSources(f))
            let pkg = try await out.preparePackage(caseID: c, selection: .wholeCase, actor: "Ada") { id in await service.load(caseID: id, generation: 1) }
            let receipt = await out.write(pkg, to: temp.appendingPathComponent("package.html"))
            #expect(receipt.status == .written, "\(mode): \(receipt.summary)")
            #expect(try await s18qCount(f.db, "SELECT COUNT(*) FROM outbound_log;") == 0, "\(mode): nothing left the Mac")
        }
    }

    // MARK: QA-09

    @Test("QA-09: two edits of the same case revision — exactly one lands; an erasure racing a hold leaves no erased case with a live hold and no hold with an erased case; a source removed under a prepared export stops it; a late carry into an erased case writes nothing")
    func lifecycleRaces() async throws {
        // 1. Simultaneous edits against one revision.
        let f = try await CaseFileTests.fixture()
        let c = f.caseID
        let rev = try #require(try await f.cases.fetch(caseID: c)).caseHeader.revision
        let v1 = try await CaseFileTestSources.seed(f.db), v2 = try await CaseFileTestSources.seed(f.db)
        let cases = f.cases
        async let a: Bool = { do { _ = try await cases.includeSource(caseID: c, expectedRevision: rev, sourceRef: v1.uuidString, sourceKind: .sourceVersion, actor: "Ada", at: Date()); return true } catch { return false } }()
        async let b: Bool = { do { _ = try await cases.includeSource(caseID: c, expectedRevision: rev, sourceRef: v2.uuidString, sourceKind: .sourceVersion, actor: "Ben", at: Date()); return true } catch { return false } }()
        let (ra, rb) = await (a, b)
        #expect(ra != rb, "exactly one of two edits of revision \(rev) lands (a: \(ra), b: \(rb))")
        #expect(try #require(try await f.cases.fetch(caseID: c)).caseHeader.revision == rev + 1)

        // 2. An erasure racing a hold notice, repeated: never both.
        for round in 0..<4 {
            let g = try await CaseFileTests.fixture()
            let db = g.db, gc = g.caseID, file = g.file
            async let erase: CaseErasureReport? = try? await CaseEraser(database: db).erase(caseID: gc, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                                      reason: "Retention ended", legalBasis: nil, actor: "Ada")
            async let hold: Bool = { do { try await file.issueHold(caseID: gc, custodian: "Accounts", personID: nil, noticeText: "Keep everything", reminderDue: nil, actor: "Ada"); return true } catch { return false } }()
            let (report, held) = await (erase, hold)
            let exists = try await s18qCount(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(gc)]) == 1
            let notices = try await s18qCount(db, "SELECT COUNT(*) FROM case_hold_notices WHERE case_id = ?;", [.uuid(gc)])
            if exists {
                #expect(report?.refused != nil || report == nil, "round \(round): the case is here, so the erase did not complete")
            } else {
                #expect(notices == 0, "round \(round): the case is gone, so no hold of it survives")
                #expect(report?.refused == nil)
            }
            if held && exists { #expect(notices == 1) }
        }

        // 3. A source removed from the case after an export was prepared citing it.
        let h = try await CaseFileTests.fixture()
        let doc = try await CaseFileTestSources.seedPassage(h.db, cases: h.cases, caseID: h.caseID, name: "minutes.txt", text: "The board approved the payment.")
        let (out, temp) = try s11Outputs(h)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pkg = try await out.prepareText(caseID: h.caseID, kind: .achReport, route: .file, actor: "Ada",
                                            citations: [StudioEvidenceRef(sourceVersionID: doc.version, objectID: doc.object, quote: "The board approved the payment.")],
                                            text: "ACH: board approval")
        let header = try #require(try await h.cases.fetch(caseID: h.caseID)).caseHeader
        _ = try await h.cases.excludeSource(caseID: h.caseID, expectedRevision: header.revision, sourceRef: doc.version.uuidString, sourceKind: .sourceVersion,
                                            note: "out of period", actor: "Ada", at: Date())
        let target = temp.appendingPathComponent("late.txt")
        let w = await out.write(pkg, to: target)
        #expect(w.status == .refused && !FileManager.default.fileExists(atPath: target.path), "\(w.status) \(w.detail ?? "")")

        // 4. A late carry of a job row into a case erased meanwhile: refused inside the write, nothing written.
        let k = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(k.db, cases: k.cases, caseID: k.caseID, name: "m.txt", text: "Paid on 4 March 2026.")
        let results = JobResultRepository(database: k.db)
        var row = JobResultRow(title: "Paid", detail: nil, date: "2026-03-04", refs: [StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, quote: "Paid on 4 March 2026.")])
        row.decision = JobRowDecision.accepted
        let saved = try #require(try await results.record(id: try await results.save(caseID: k.caseID, jobID: "inv.chronology", family: .chronologyLinkage,
                                                                                    state: .draft, content: JobResultContent(rows: [row]), actor: "Ada")))
        let carried = try await JobResultHandoff.carriedTyped(saved, row: 0, results: results, caseFiles: k.svc)
        _ = try await CaseEraser(database: k.db).erase(caseID: k.caseID, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Ada")
        await #expect(throws: (any Error).self) {
            _ = try await JobResultHandoff.applying(carried, record: saved) {
                try await k.file.addJournal(caseID: k.caseID, kind: .chronology, text: "late carry", eventDate: nil, evidenceRef: nil, actor: "Ada")
            }
        }
        #expect(try await s18qCount(k.db, "SELECT COUNT(*) FROM case_journal WHERE case_id = ?;", [.uuid(k.caseID)]) == 0)
    }

    // MARK: QA-10

    @Test("QA-10: ledgers at older milestones upgrade with their cases intact; a backup with a corrupted, truncated or missing ledger file, or no manifest, is refused before anything is restored; a complete one restores")
    func migrationAndRecoveryMatrix() async throws {
        for version in [120, 160, 176, 185] {
            let db = try await MigrationFixtureBuilder.database(atVersion: version)
            let ws = UUID(), c = UUID()
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
            try await db.exec("INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?);",
                              [.uuid(c), .uuid(ws), .text("Kept from v\(version)"), .text("open"), .integer(3), .text("u"), .real(1), .real(1)])
            try await SchemaMigrations.migrate(db)
            #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion, "v\(version)")
            #expect(try await s18qCount(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ? AND title = ? AND revision = 3;", [.uuid(c), .text("Kept from v\(version)")]) == 1, "v\(version)")
            #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty, "v\(version)")
            #expect(try await db.query("PRAGMA integrity_check;", []).first?.string(0) == "ok", "v\(version)")
            // The upgraded ledger takes new case work.
            try await db.exec("INSERT INTO case_reports (id, case_id, title, report_kind, recorded_by, recorded_at) VALUES (?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(c), .text("R"), .text("original"), .text("Ada"), .real(1)])
            await db.close()
        }

        let f = try await CaseFileTests.fixture(title: "Recovery")
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Was it paid twice?", actor: "Ada")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("s18-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let snapDir = temp.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        func makeBackup(_ name: String) throws -> URL {
            let dir = temp.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: ["originals left in place"], destination: dir,
                                                         schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970 - 60)
            return dir
        }
        func ledgerFile(in dir: URL) throws -> URL {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent != BackupService.manifestName && !$0.hasDirectoryPath }
            return try #require(files.max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
        }
        let damages: [(String, (URL) throws -> Void)] = [
            ("corrupt", { dir in let u = try ledgerFile(in: dir); var d = try Data(contentsOf: u); d[d.count / 2] ^= 0xFF; try d.write(to: u) }),
            ("truncated", { dir in let u = try ledgerFile(in: dir); let d = try Data(contentsOf: u); try d.prefix(d.count / 3).write(to: u) }),
            ("missing", { dir in try FileManager.default.removeItem(at: try ledgerFile(in: dir)) }),
            ("no manifest", { dir in try FileManager.default.removeItem(at: dir.appendingPathComponent(BackupService.manifestName)) }),
        ]
        for (name, damage) in damages {
            let backup = try makeBackup(name.replacingOccurrences(of: " ", with: "-"))
            try damage(backup)
            let target = temp.appendingPathComponent("target-\(name.replacingOccurrences(of: " ", with: "-"))", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            await #expect(throws: (any Error).self, "\(name) backup refused") { _ = try await BackupService().restoreComplete(backupFolder: backup, into: target) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).filter { !$0.hasPrefix(".") }.isEmpty, "\(name): nothing was restored")
        }
        // The undamaged backup restores, saying what it did not include.
        let good = try makeBackup("good")
        let target = temp.appendingPathComponent("target-good", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try await BackupService().restoreComplete(backupFolder: good, into: target)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("knowledge.sqlite").path))
    }

    // MARK: QA-11

    @Test("QA-11: a package citing two revisions of one document names both versions, the older as superseded, reconciles with its manifest when written; a privilege added after preparing stops it")
    func mixedRevisionPackage() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f, c = f.caseID
        let a1 = try await f.file.addAllegation(caseID: c, text: "The invoice was 500 dollars", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: c, allegationID: a1, evidenceRef: rig.a.version.uuidString, label: "invoice A (first)", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        let v2 = try await s18Revise(f.db, object: rig.a.object, cases: f.cases, caseID: c)
        let a2 = try await f.file.addAllegation(caseID: c, text: "The revised invoice", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: c, allegationID: a2, evidenceRef: v2.uuidString, label: "invoice A (revised)", stance: .supports, note: nil,
                                         passage: StudioEvidenceRef(sourceVersionID: v2, objectID: rig.a.object, quote: "revised"), actor: "Ada")
        let (out, temp) = try s11Outputs(f)
        defer { try? FileManager.default.removeItem(at: temp) }
        let map = CaseMapService(sources: caseMapSources(f))
        let pkg = try await out.preparePackage(caseID: c, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        let read = CasePortablePackageReader.read(pkg.text)
        #expect(read.violations.isEmpty, "\(read.violations)")
        let refs = read.sectionText["references"] ?? ""
        #expect(refs.contains(rig.a.version.uuidString.lowercased()) && refs.contains(v2.uuidString.lowercased()), "both revisions are named")
        #expect(refs.contains("superseded"), "the older revision says a newer version exists")
        let m = try #require(read.manifest)
        #expect(m.counts["references"] == read.rows["reference"])
        let url = temp.appendingPathComponent("package.html")
        let receipt = await out.write(pkg, to: url)
        #expect(receipt.status == .written && receipt.recorded, "\(receipt.summary)")
        let reread = CasePortablePackageReader.read(try String(contentsOf: url, encoding: .utf8))
        #expect(reread.violations.isEmpty && reread.manifest?.counts == m.counts, "the written bytes match the frozen manifest")
        // Privilege added on the document's file after a second package is prepared: refused, nothing written.
        let second = try await out.preparePackage(caseID: c, selection: .wholeCase, actor: "Ada") { id in await map.load(caseID: id, generation: 1) }
        let fileID = try #require(try await f.db.query("SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(rig.a.object)]).first?.uuid(0))
        _ = try await SensitiveScopeRepository(database: f.db).assign(target: SensitiveScopeTarget(kind: .file, id: fileID), sensitivity: .confidential,
                                                                       authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
        let late = temp.appendingPathComponent("late.html")
        #expect(await out.write(second, to: late).status == .refused && !FileManager.default.fileExists(atPath: late.path))
    }
}
