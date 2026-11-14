//
//  IntakeContractTests.swift
//  KalsmritikoshTests
//
//  Smart map S2 — IN-01, IN-05, IN-06, IN-07, IN-11, IN-12 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04).
//  Real ledgers (AppState.boot over a temp database), real ingestion, the app's own intake paths. Each test checks data
//  integrity and the failure paths, not the wording.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case intake contract: channels, trusted-source policies, attribution, batch receipts, sameness", .serialized)
struct IntakeContractTests {

    // MARK: - Rig

    struct Rig {
        let state: AppState
        let db: Database
        let ingest: IngestCoordinator
        let temp: URL
    }

    private func boot(_ tag: String) async throws -> Rig {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)
        return Rig(state: state, db: db, ingest: ingest, temp: temp)
    }

    private func finish(_ r: Rig) async {
        await r.state.shutdown()
        try? FileManager.default.removeItem(at: r.temp)
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func workspace(_ r: Rig, _ title: String, at now: Date) async throws -> UUID {
        let ws = UUID()
        try await r.db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                            [.uuid(ws), .text(title), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        return ws
    }

    private func count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
        Int(try await db.query(sql, binds).first?.int(0) ?? 0)
    }

    private func logical(_ db: Database, _ version: UUID) async throws -> UUID {
        try #require(try await db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(version)]).first?.uuid(0))
    }

    /// One intake batch through the app's own per-file loop (the one "Read all" uses), recorded as a batch receipt.
    private func batch(_ r: Rig, folder: URL, arrivals: IntakeArrivalHint, planned: Int) async throws -> UUID {
        let runs = try #require(await r.state.ingestRuns)
        let receipts = IntakeReceiptRepository(database: r.db)
        let run = try await runs.startRun(totalFiles: planned, atMillis: Date().timeIntervalSince1970 * 1000)
        await receipts.setChannel(run: run, channel: arrivals.channel)
        await r.state.enumerateAndIngest(url: folder, ingest: r.ingest, label: "IntakeContractTests", run: run, runs: runs,
                                         receipts: receipts, arrivals: arrivals)
        try await runs.finish(run: run, status: .completed, atMillis: Date().timeIntervalSince1970 * 1000)
        return run
    }

    private func pause() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    // MARK: - IN-01 / IN-05: the opening policy and the person's review

    @Test("Opening a case includes what the workspace held under a named policy; later documents wait for the person; every inclusion has one contract record; the database refuses an unnamed or withdrawn policy and edits to attribution")
    func openingPolicyCoversOnlyWhatTheWorkspaceHeld() async throws {
        let r = try await boot("open")
        let docs = r.temp.appendingPathComponent("docs", isDirectory: true)
        let first = try await r.ingest.ingest(fileAt: try write("Opening memo. Dalmia Traders invoiced 10,000 on 3 March 2026.", "memo.txt", in: docs))
        let v1 = try #require(first.sourceVersionID)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds: the ledger stores REAL seconds
        let ws = try await workspace(r, "Supplier payment", at: now)
        let coordinator = try #require(await r.state.workspaceSourceCoordinator)
        try await coordinator.addSources([first.fileRecord.id], to: ws, at: now)
        let cases = try #require(await r.state.investigationCases)
        let intake = try #require(await r.state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Supplier payment", actor: "Priya Nair", at: now)
        let (_, included) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
        #expect(included == 1)

        let policies = try await intake.ledger.policies(caseID: c.id)
        let opening = try #require(policies.first)
        #expect(policies.count == 1 && opening.rule == .workspaceAtOpening && opening.coversUntil == now && opening.isActive)
        let items = try await intake.ledger.items(caseID: c.id)
        #expect(items.count == 1, "one contract record per inclusion")
        let item = try #require(items.first)
        #expect(item.sourceVersionID == v1 && item.form == .sourceDocument)
        #expect(item.decision == .included && item.decidedVia == .policy && item.policyID == opening.id)
        #expect(item.channel == .workspace, "ingested directly, so no batch names another channel")
        #expect(item.attribution.enteredBy == "Priya Nair" && item.attribution.suppliedBy == nil && item.attribution.claimedAuthor == nil)
        #expect(item.attribution.capturedAt == nil, "no capture time is invented")
        let archived = try #require(try await r.db.query("SELECT intake_recorded_at FROM source_versions WHERE id = ?;", [.uuid(v1)]).first?.date(0))
        #expect(item.attribution.receivedAt == archived, "the receipt time is when the archive received it, not when the case was opened")
        let record = try #require(try await cases.fetch(caseID: c.id))
        #expect(record.sources.first { $0.sourceRef == v1.uuidString }?.note?.contains(opening.name) == true, "the inclusion names its policy")

        // A document added to the workspace later is not covered, even if the opening runs again.
        let second = try await r.ingest.ingest(fileAt: try write("Bank statement. A refund of 2,000 was credited on 9 March 2026.", "bank.txt", in: docs))
        let v2 = try #require(second.sourceVersionID)
        try await coordinator.addSources([second.fileRecord.id], to: ws, at: now.addingTimeInterval(60))
        let (_, again) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now.addingTimeInterval(120))
        #expect(again == 0, "the opening policy does not broaden the scope to what came later")
        let preview = try await intake.preview(caseID: c.id)
        #expect(preview.pending.map(\.sourceVersionID) == [v2])
        #expect(preview.activePolicies.map(\.id) == [opening.id])
        let (_, added) = try await intake.include(caseID: c.id, approved: [v2], actor: "Priya Nair", at: now.addingTimeInterval(180))
        #expect(added == 1)
        let personItem = try #require(try await intake.ledger.items(caseID: c.id).first { $0.sourceVersionID == v2 })
        #expect(personItem.decision == .included && personItem.decidedVia == .person && personItem.policyID == nil)

        // Withdrawn: it authorises nothing more and is not silently re-created with a later cut-off.
        try await intake.ledger.withdrawPolicy(opening.id, reason: "Scope narrowed to March", actor: "Priya Nair", at: now.addingTimeInterval(200))
        #expect(try await intake.ledger.openingPolicy(caseID: c.id, actor: "Priya Nair", at: now.addingTimeInterval(210)) == nil)
        await #expect(throws: CaseIntakeError.policyWithdrawn(opening.id)) {
            try await intake.ledger.withdrawPolicy(opening.id, reason: "again", actor: "Priya Nair", at: now.addingTimeInterval(220))
        }
        let third = try await r.ingest.ingest(fileAt: try write("Delivery challan 77 for the generator service.", "challan.txt", in: docs))
        let v3 = try #require(third.sourceVersionID)
        // The database itself refuses an automatic decision naming a withdrawn policy, or none.
        for policy in [SQLValue.uuid(opening.id), .null] {
            await #expect(throws: (any Error).self) {
                try await r.db.exec("""
                    INSERT INTO case_intake_items (id, case_id, channel, content_form, source_version_id, label, provenance, entered_by,
                        received_at, recorded_at, decision, decided_via, decided_by, decided_at, policy_id)
                    VALUES (?,?,'workspace','sourceDocument',?,'challan.txt','test','Priya Nair',?,?,'included','policy','Priya Nair',?,?);
                    """, [.uuid(UUID()), .uuid(c.id), .uuid(v3), .date(now), .date(now), .date(now), policy])
            }
        }
        // A record's attribution is fixed; the first decision is recorded once.
        let pending = try await intake.ledger.recordSourceArrival(caseID: c.id, sourceVersionID: v3, channel: .folderImport, label: "challan.txt",
                                                                  provenance: "Folder read", ingestRunID: nil,
                                                                  attribution: CaseIntakeAttribution(enteredBy: "Priya Nair", receivedAt: now), at: now)
        #expect(pending.decision == nil)
        let repeated = try await intake.ledger.recordSourceArrival(caseID: c.id, sourceVersionID: v3, channel: .shareInbox, label: "other",
                                                                   provenance: "other", ingestRunID: nil,
                                                                   attribution: CaseIntakeAttribution(enteredBy: "Someone", receivedAt: now), at: now)
        #expect(repeated.id == pending.id && repeated.channel == .folderImport, "a second arrival of the same version keeps the first record")
        await #expect(throws: (any Error).self) {
            try await r.db.exec("UPDATE case_intake_items SET supplied_by = 'Changed later' WHERE id = ?;", [.uuid(pending.id)])
        }
        #expect(try await intake.ledger.recordDecision(itemID: pending.id, decision: .excluded, via: .person, policyID: nil,
                                                       actor: "Priya Nair", note: "Not this supplier", at: now) == true)
        #expect(try await intake.ledger.recordDecision(itemID: pending.id, decision: .included, via: .person, policyID: nil,
                                                       actor: "Priya Nair", note: nil, at: now) == false)
        await #expect(throws: CaseIntakeError.wrongChannel(.manualEntry)) {
            _ = try await intake.ledger.recordSourceArrival(caseID: c.id, sourceVersionID: v3, channel: .manualEntry, label: "x", provenance: "x",
                                                            ingestRunID: nil, attribution: CaseIntakeAttribution(enteredBy: "P", receivedAt: now), at: now)
        }
        await finish(r)
    }

    // MARK: - IN-01 / IN-05: the Share inbox feeds the review; channel policies name themselves; exclusions persist

    @Test("Items shared to the app after the case opened are offered in its review, not included; an exclusion persists through a trusted-source policy; the policy includes only later arrivals of its channel and names itself")
    func sharedItemsReachTheReviewAndPoliciesNameThemselves() async throws {
        let r = try await boot("share")
        let docs = r.temp.appendingPathComponent("docs", isDirectory: true)
        let memo = try await r.ingest.ingest(fileAt: try write("Opening memo for the warehouse matter.", "memo.txt", in: docs))
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds: the ledger stores REAL seconds
        let ws = try await workspace(r, "Warehouse", at: now)
        try await #require(await r.state.workspaceSourceCoordinator).addSources([memo.fileRecord.id], to: ws, at: now)
        let cases = try #require(await r.state.investigationCases)
        let intake = try #require(await r.state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Warehouse", actor: "Priya Nair", at: now)
        _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
        try await pause()

        // Two items arrive through the Share inbox.
        let inbox = r.temp.appendingPathComponent("Intake", isDirectory: true)
        let note = try write("Site note from the visit on 4 March 2026: the rear door was open.", "site-note.txt", in: inbox)
        let early = try write("Gate register page for 4 March 2026.", "gate-register.txt", in: inbox)
        let run1 = try await batch(r, folder: inbox, arrivals: IntakeArrivalHint(channel: .shareInbox, files: [note, early]), planned: 2)
        let receipts = IntakeReceiptRepository(database: r.db)
        let receipt1 = try #require(try await receipts.receipt(run: run1))
        #expect(receipt1.received == 2 && receipt1.lines.allSatisfy { $0.channel == .shareInbox })
        let noteV = try #require(receipt1.lines.first { $0.name == "site-note.txt" }?.sourceVersionID)
        let earlyV = try #require(receipt1.lines.first { $0.name == "gate-register.txt" }?.sourceVersionID)

        let preview = try await intake.preview(caseID: c.id)
        let offered = preview.pending.filter(\.offeredFromChannel)
        #expect(Set(offered.map(\.sourceVersionID)) == [noteV, earlyV])
        #expect(offered.allSatisfy { $0.channel == .shareInbox && $0.isRoot })
        #expect(try #require(try await cases.fetch(caseID: c.id)).sources.filter(\.inScope).count == 1, "offering includes nothing")

        // The person excludes one, with a reason (a blank reason is refused).
        await #expect(throws: CaseIntakeError.blankReason) {
            _ = try await intake.exclude(caseID: c.id, versions: [noteV], note: "  ", actor: "Priya Nair", at: Date())
        }
        let (_, excluded) = try await intake.exclude(caseID: c.id, versions: [noteV], note: "Personal note, not part of the matter", actor: "Priya Nair", at: Date())
        #expect(excluded == 1)
        let exItem = try #require(try await intake.ledger.items(caseID: c.id).first { $0.sourceVersionID == noteV })
        #expect(exItem.decision == .excluded && exItem.decidedVia == .person && exItem.channel == .shareInbox && exItem.ingestRunID == run1)
        let workspaceFiles = Set(try await WorkspaceRepository(database: r.db).sourceIDs(in: ws))
        #expect(!workspaceFiles.contains(try await logical(r.db, noteV)), "an excluded offer does not join the workspace")
        let afterExclusion = try await intake.preview(caseID: c.id)
        #expect(!afterExclusion.pending.contains { $0.sourceVersionID == noteV })
        #expect(afterExclusion.excluded.map(\.label).contains("site-note.txt"))

        // A trusted-source policy for shared items: typed channels are refused.
        await #expect(throws: CaseIntakeError.wrongChannel(.manualEntry)) {
            _ = try await intake.ledger.createArrivalPolicy(caseID: c.id, name: "Typed", channel: .manualEntry, actor: "Priya Nair", at: Date())
        }
        try await pause()
        let policy = try await intake.ledger.createArrivalPolicy(caseID: c.id, name: "Items the client shares with me", channel: .shareInbox,
                                                                 actor: "Priya Nair", at: Date())
        try await pause()
        let challan = try write("Signed delivery challan 77, received 5 March 2026.", "challan.txt", in: inbox)
        let run2 = try await batch(r, folder: inbox, arrivals: IntakeArrivalHint(channel: .shareInbox, files: [challan]), planned: 3)
        await r.state.afterIntakeBatch(run: run2)   // what the app runs after every batch
        let receipt2 = try #require(try await receipts.receipt(run: run2))
        #expect(receipt2.received == 1 && receipt2.alreadyHeld == 2, "\(receipt2.summaryLine)")
        #expect(receipt2.lines.filter { $0.outcome == .alreadyHeld }.allSatisfy { $0.channel == .folderImport },
                "files the trigger did not bring are a folder re-read, not shared again")
        let challanV = try #require(receipt2.lines.first { $0.name == "challan.txt" }?.sourceVersionID)

        let record = try #require(try await cases.fetch(caseID: c.id))
        let challanScope = try #require(record.sources.first { $0.sourceRef == challanV.uuidString })
        #expect(challanScope.inScope && challanScope.note?.contains(policy.name) == true)
        #expect(record.sources.first { $0.sourceRef == noteV.uuidString }?.inScope == false, "the exclusion persists")
        #expect(!record.sources.contains { $0.sourceRef == earlyV.uuidString }, "shared before the policy existed: offered, never included by it")
        let polItem = try #require(try await intake.ledger.items(caseID: c.id).first { $0.sourceVersionID == challanV })
        #expect(polItem.decidedVia == .policy && polItem.policyID == policy.id && polItem.channel == .shareInbox && polItem.ingestRunID == run2)
        #expect(Set(try await WorkspaceRepository(database: r.db).sourceIDs(in: ws)).contains(try await logical(r.db, challanV)))
        #expect(await intake.applyArrivalPolicies(at: Date()) == 0, "applying again includes nothing twice")
        #expect(try await intake.preview(caseID: c.id).pending.contains { $0.sourceVersionID == earlyV && $0.offeredFromChannel })

        // Withdrawn: the next shared item is offered, not included.
        try await intake.ledger.withdrawPolicy(policy.id, reason: "Client relationship ended", actor: "Priya Nair", at: Date())
        try await pause()
        let late = try write("A late photo caption.", "late.txt", in: inbox)
        let run3 = try await batch(r, folder: inbox, arrivals: IntakeArrivalHint(channel: .shareInbox, files: [late]), planned: 4)
        await r.state.afterIntakeBatch(run: run3)
        let lateV = try #require(try await receipts.receipt(run: run3)?.lines.first { $0.name == "late.txt" }?.sourceVersionID)
        let afterWithdrawal = try #require(try await cases.fetch(caseID: c.id))
        #expect(!afterWithdrawal.sources.contains { $0.sourceRef == lateV.uuidString })
        await finish(r)
    }

    // MARK: - IN-11: attribution of typed entries

    @Test("A typed entry records who supplied it, who entered it, its claimed author, capture and receipt time separately; it stays an unverified typed entry; carried entries are not intake")
    func typedEntryAttributionIsSeparateAndNeverVerified() async throws {
        let r = try await boot("typed")
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds: the ledger stores REAL seconds
        let ws = try await workspace(r, "Interview", at: now)
        let cases = try #require(await r.state.investigationCases)
        let caseFiles = try #require(await r.state.caseFiles)
        let intake = try #require(await r.state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Interview", actor: "Priya Nair", at: now)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let captured = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 18)))
        let received = now.addingTimeInterval(-3600)
        let attribution = CaseIntakeAttribution(enteredBy: "Priya Nair", receivedAt: received, suppliedBy: "  Ravi (witness)  ",
                                                claimedAuthor: "Ravi Kumar", capturedAt: captured, capturedText: "the evening of 3 March")
        let account = try await caseFiles.file.addJournal(caseID: c.id, kind: .chronology,
                                                          text: "Ravi says he saw the van leave the warehouse at about 6 pm.",
                                                          eventDate: nil, evidenceRef: nil, attribution: attribution, channel: .message,
                                                          actor: "Priya Nair", at: now)
        let record = try #require(try await intake.ledger.typedEntry(caseID: c.id, journalID: account))
        #expect(record.form == .typedEntry && record.channel == .message && record.sourceVersionID == nil)
        #expect(record.attribution.suppliedBy == "Ravi (witness)", "trimmed, kept apart from who typed it")
        #expect(record.attribution.enteredBy == "Priya Nair" && record.attribution.claimedAuthor == "Ravi Kumar")
        #expect(record.attribution.capturedAt == captured && record.attribution.capturedText == "the evening of 3 March")
        #expect(record.attribution.receivedAt == received && record.recordedAt == now, "receipt time and entry time are separate facts")
        #expect(record.decision == .included && record.decidedVia == .person && record.decidedBy == "Priya Nair")
        // Still a typed account: no person's verified mark, no documentary verification.
        #expect(try await count(r.db, "SELECT COUNT(*) FROM case_fact_attestations WHERE journal_entry_id = ?;", [.uuid(account)]) == 0)
        #expect(try #require(try await r.db.query("SELECT verification FROM case_journal WHERE id = ?;", [.uuid(account)]).first).isNull(0))

        // Without attribution: who typed it and when, nothing invented.
        let plain = try await caseFiles.file.addJournal(caseID: c.id, kind: .note, text: "Call back the depot manager.", eventDate: nil,
                                                        evidenceRef: nil, actor: "Priya Nair", at: now)
        let plainRecord = try #require(try await intake.ledger.typedEntry(caseID: c.id, journalID: plain))
        #expect(plainRecord.channel == .manualEntry && plainRecord.attribution.suppliedBy == nil && plainRecord.attribution.claimedAuthor == nil)
        #expect(plainRecord.attribution.capturedAt == nil && plainRecord.attribution.receivedAt == now)
        // A carried entry (it has an origin) is not a typed intake item.
        let carried = try await caseFiles.file.addJournal(caseID: c.id, kind: .chronology, text: "Carried from a reviewed result.", eventDate: nil,
                                                          evidenceRef: nil, origin: "test-origin-\(UUID().uuidString)", actor: "Priya Nair", at: now)
        #expect(try await intake.ledger.typedEntry(caseID: c.id, journalID: carried) == nil)
        // The database refuses a typed entry pretending to be a document, and a document arriving through a typed channel.
        await #expect(throws: (any Error).self) {
            try await r.db.exec("""
                INSERT INTO case_intake_items (id, case_id, channel, content_form, source_version_id, record_kind, record_id, label, provenance,
                    entered_by, received_at, recorded_at) VALUES (?,?,'manualEntry','typedEntry',?,'journal',?,'x','x','P',?,?);
                """, [.uuid(UUID()), .uuid(c.id), .uuid(UUID()), .text(UUID().uuidString), .date(now), .date(now)])
        }
        // A failed entry writes no record: the journal row and its intake record commit together or not at all.
        let before = try await count(r.db, "SELECT COUNT(*) FROM case_intake_items WHERE case_id = ?;", [.uuid(c.id)])
        await #expect(throws: (any Error).self) {
            _ = try await caseFiles.file.addJournal(caseID: c.id, kind: .note, text: "No one entered this.", eventDate: nil, evidenceRef: nil,
                                                    attribution: CaseIntakeAttribution(enteredBy: "P", receivedAt: now), channel: .folderImport,
                                                    actor: "Priya Nair", at: now)
        }
        #expect(try await count(r.db, "SELECT COUNT(*) FROM case_intake_items WHERE case_id = ?;", [.uuid(c.id)]) == before)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM case_journal WHERE case_id = ? AND text = 'No one entered this.';", [.uuid(c.id)]) == 0)
        await finish(r)
    }

    // MARK: - IN-12: batch receipts and coverage traced to them

    @Test("A batch receipt reconciles every selected file (received, exact duplicate, failed; already held on a re-read) and the case coverage traces its documents to the batches and names what could not be taken in")
    func batchReceiptReconcilesAndCoverageTraces() async throws {
        let r = try await boot("batch")
        let dir = r.temp.appendingPathComponent("dropped", isDirectory: true)
        let invoice = try write("Invoice INV-104 from Dalmia Traders for 100,000, dated 1 March 2026.", "invoice.txt", in: dir)
        try FileManager.default.copyItem(at: invoice, to: dir.appendingPathComponent("invoice copy.txt"))
        let locked = try write("Unreadable", "locked.txt", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let run1 = try await batch(r, folder: dir, arrivals: IntakeArrivalHint(channel: .dragDrop, roots: [dir]), planned: 3)
        let receipts = IntakeReceiptRepository(database: r.db)
        let receipt1 = try #require(try await receipts.receipt(run: run1))
        #expect(receipt1.channel == .dragDrop && receipt1.selected == 3, "\(receipt1.summaryLine)")
        #expect(receipt1.received == 1 && receipt1.duplicates == 1 && receipt1.failed == 1 && receipt1.pending == 0 && receipt1.notReached == 0,
                "\(receipt1.summaryLine)")
        #expect(receipt1.lines.allSatisfy { $0.channel == .dragDrop })
        #expect(receipt1.failures.map { $0.name } == ["locked.txt"])
        let receivedLine = try #require(receipt1.lines.first { $0.outcome == .received })
        let duplicateLine = try #require(receipt1.lines.first { $0.outcome == .duplicate })
        let v = try #require(receivedLine.sourceVersionID)
        #expect(duplicateLine.sourceVersionID == v && duplicateLine.intakeOutcome == .aliased, "an exact copy is another occurrence, not a second document")
        #expect(receipt1.lines.first { $0.name == "locked.txt" }?.sourceVersionID == nil)
        let custody = try await r.db.query("SELECT outcome, original_url FROM source_intake_receipts WHERE source_version_id = ? ORDER BY recorded_at;", [.uuid(v)])
            .map { "\($0.string(0) ?? "?") \(($0.string(1) ?? "") as NSString).lastPathComponent" }
        #expect(custody.count == 2, "each occurrence keeps its own custody receipt: \(custody)")

        try await pause()
        let run2 = try await batch(r, folder: dir, arrivals: .folderReread, planned: 3)
        let receipt2 = try #require(try await receipts.receipt(run: run2))
        #expect(receipt2.received == 0 && receipt2.alreadyHeld == 1 && receipt2.duplicates == 1 && receipt2.failed == 1, "\(receipt2.summaryLine)")
        #expect(receipt2.lines.allSatisfy { $0.channel == .folderImport })

        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds: the ledger stores REAL seconds
        let ws = try await workspace(r, "Dalmia", at: now)
        try await #require(await r.state.workspaceSourceCoordinator).addSources([try await logical(r.db, v)], to: ws, at: now)
        let cases = try #require(await r.state.investigationCases)
        let intake = try #require(await r.state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Dalmia", actor: "Priya Nair", at: now)
        _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
        let item = try #require(try await intake.ledger.items(caseID: c.id).first)
        #expect(item.channel == .dragDrop && item.ingestRunID == run1, "the contract record names the batch and channel it arrived through")

        let rec = try await intake.reconciliation(caseID: c.id)
        #expect(rec.included == 1 && rec.tracedToBatches == 1 && rec.untraced == 0)
        #expect(Set(rec.batchIDs) == [run1, run2])
        #expect(rec.latestBatch?.id == run2)
        #expect(rec.notReceived == ["locked.txt"])
        let coverage = try await CaseCoverageReadout.load(database: r.db, workspaceID: ws, scope: [v], caseID: c.id)
        #expect(coverage.intake == rec)
        #expect(coverage.reportSection.contains("Traced to intake receipts: 1 of 1"), "\(coverage.reportSection)")
        #expect(coverage.reportSection.contains("locked.txt"), "\(coverage.reportSection)")
        #expect(try await CaseCoverageReadout.load(database: r.db, workspaceID: ws, scope: [v]).intake == nil)
        await finish(r)
    }

    // MARK: - IN-07: the per-item intake list

    @Test("The case intake list shows each item with inclusion state, processing stage and remedy, including a file that never became a document")
    func intakeListShowsEveryItemWithItsRemedy() async throws {
        let r = try await boot("list")
        let docs = r.temp.appendingPathComponent("docs", isDirectory: true)
        let a = try await r.ingest.ingest(fileAt: try write("Purchase order PO-9 for 12 pumps, 2 March 2026.", "po.txt", in: docs))
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds: the ledger stores REAL seconds
        let ws = try await workspace(r, "Pumps", at: now)
        let coordinator = try #require(await r.state.workspaceSourceCoordinator)
        try await coordinator.addSources([a.fileRecord.id], to: ws, at: now)
        let cases = try #require(await r.state.investigationCases)
        let intake = try #require(await r.state.investigationWorkspaceIntake)
        let c = try await cases.createCase(workspaceID: ws, title: "Pumps", actor: "Priya Nair", at: now)
        _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
        let b = try await r.ingest.ingest(fileAt: try write("Goods received note for 10 pumps, 6 March 2026.", "grn.txt", in: docs))
        let d = try await r.ingest.ingest(fileAt: try write("Unrelated canteen menu.", "menu.txt", in: docs))
        try await coordinator.addSources([b.fileRecord.id, d.fileRecord.id], to: ws, at: now.addingTimeInterval(60))
        _ = try await intake.exclude(caseID: c.id, versions: [try #require(d.sourceVersionID)], note: "Not related", actor: "Priya Nair", at: now.addingTimeInterval(90))
        _ = try await #require(await r.state.caseFiles).file.addJournal(caseID: c.id, kind: .note, text: "Supplier says two pumps are back-ordered.",
                                                                        eventDate: nil, evidenceRef: nil, actor: "Priya Nair", at: now)
        let bad = r.temp.appendingPathComponent("bad", isDirectory: true)
        let locked = try write("x", "scan-locked.pdf", in: bad)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        _ = try await batch(r, folder: bad, arrivals: IntakeArrivalHint(channel: .fileImport, roots: [bad]), planned: 1)

        let list = try await intake.intakeList(caseID: c.id)
        let included = try #require(list.first { $0.sourceVersionID == a.sourceVersionID })
        #expect(included.inclusion == .included && !included.remedies.contains(.reviewInclusion))
        #expect(included.item?.decidedVia == .policy)
        #expect([CaseIntakeStage.available, .partial, .processing].contains(included.stage), "\(included.stage)")
        let pending = try #require(list.first { $0.sourceVersionID == b.sourceVersionID })
        #expect(pending.inclusion == .pendingReview && pending.remedies.first == .reviewInclusion && pending.item == nil)
        let excluded = try #require(list.first { $0.sourceVersionID == d.sourceVersionID })
        #expect(excluded.inclusion == .excluded && excluded.remedies.isEmpty && excluded.item?.decision == .excluded)
        let typed = try #require(list.first { $0.stage == .typedEntry })
        #expect(typed.inclusion == .included && typed.channel == .manualEntry && typed.remedies.isEmpty)
        let notReceived = try #require(list.first { $0.label == "scan-locked.pdf" })
        #expect(notReceived.inclusion == .notReceived && notReceived.stage == .notReceived && notReceived.remedies == [.addFileAgain])
        #expect(notReceived.channel == .fileImport && notReceived.stageDetail?.isEmpty == false)
        #expect(list.filter { $0.sourceVersionID != nil }.count == 3, "each document once")
        await finish(r)
    }

    /// Ten readiness dimensions for one version, all required and not started unless overridden.
    private func dimensions(_ overrides: [SourceReadinessDimension: (SourceReadinessDimensionState, SourceReadinessCondition?, Int?)]) -> [SourceReadinessDimensionRecord] {
        let sv = UUID(), at = Date()
        return SourceReadinessDimension.ordered.map { d in
            let o = overrides[d] ?? (.notStarted, nil, nil)
            return SourceReadinessDimensionRecord(sourceVersionID: sv, dimension: d, state: o.0, applicability: .required, condition: o.1,
                                                  completedUnits: o.2, totalUnits: o.2, producerID: "test", producerVersion: "1",
                                                  basis: nil, detail: nil, revision: 1, updatedAt: at)
        }
    }

    private func snapshot(_ overrides: [SourceReadinessDimension: (SourceReadinessDimensionState, SourceReadinessCondition?, Int?)]) -> SourceReadinessSnapshot {
        let dims = dimensions(overrides)
        return SourceReadinessEvaluator.evaluate(sourceVersionID: dims[0].sourceVersionID, aggregateRevision: 1, dimensions: dims, updatedAt: Date())
    }

    @Test("Processing stages and remedies come from the readiness ledger: password, OCR running, nothing readable, no record, and what an exclusion silences")
    func stagesAndRemediesFromReadiness() {
        let encrypted = snapshot([.preservation: (.ready, nil, nil), .textExtraction: (.blocked, .encrypted, nil)])
        let (s1, _) = CaseIntakeStages.stage(snapshot: encrypted, hasLedgerText: false)
        #expect(s1 == .passwordNeeded)
        #expect(CaseIntakeStages.remedies(inclusion: .included, stage: s1) == [.providePassword])

        let ocr = snapshot([.preservation: (.ready, nil, nil), .ocr: (.running, nil, nil)])
        let (s2, d2) = CaseIntakeStages.stage(snapshot: ocr, hasLedgerText: false)
        #expect(s2 == .processing && d2 == "text recognition (OCR)")
        #expect(CaseIntakeStages.remedies(inclusion: .pendingReview, stage: s2) == [.reviewInclusion, .wait])

        var finished: [SourceReadinessDimension: (SourceReadinessDimensionState, SourceReadinessCondition?, Int?)] = [:]
        for dim in SourceReadinessDimension.allCases { finished[dim] = (.ready, nil, 0) }
        finished[.preservation] = (.ready, nil, nil)
        let empty = snapshot(finished)
        let (s3, _) = CaseIntakeStages.stage(snapshot: empty, hasLedgerText: false)
        #expect(s3 == .keptWithoutText, "read to the end with no text is not 'available'")
        #expect(CaseIntakeStages.remedies(inclusion: .included, stage: s3) == [.readAgain])

        #expect(CaseIntakeStages.stage(snapshot: nil, hasLedgerText: false).0 == .received)
        #expect(CaseIntakeStages.stage(snapshot: nil, hasLedgerText: true).0 == .available)
        #expect(CaseIntakeStages.remedies(inclusion: .excluded, stage: .failed).isEmpty)
        #expect(CaseIntakeStages.remedies(inclusion: .notReceived, stage: .notReceived) == [.addFileAgain])
    }

    // MARK: - IN-06: duplicates, content-equivalent sources and confirmed revisions

    @Test("Exact copies, content-equivalent sources, revisions of one document and confirmed revisions across locations are told apart; nothing is merged and every receipt stays")
    func sourceSamenessKeepsEverythingApart() async throws {
        let r = try await boot("same")
        let d1 = r.temp.appendingPathComponent("v1", isDirectory: true)
        let d2 = r.temp.appendingPathComponent("v2", isDirectory: true)
        let d3 = r.temp.appendingPathComponent("copies", isDirectory: true)
        let memo1 = try write("Payment of 50,000 approved on 3 March 2026.\nReference INV-104.", "memo.txt", in: d1)
        let v1 = try #require(try await r.ingest.ingest(fileAt: memo1).sourceVersionID)
        let v3 = try #require(try await r.ingest.ingest(fileAt: try write("Payment of 50,000   approved on 3 March 2026.\r\n\r\nReference   INV-104.\r\n",
                                                                          "memo-resaved.txt", in: d3)).sourceVersionID)
        let v2 = try #require(try await r.ingest.ingest(fileAt: try write("Payment of 45,000 approved on 9 March 2026.\nReference INV-104 (revised).",
                                                                          "memo.txt", in: d2)).sourceVersionID)
        try FileManager.default.copyItem(at: memo1, to: d3.appendingPathComponent("memo copy.txt"))
        let copy = try await r.ingest.ingest(fileAt: d3.appendingPathComponent("memo copy.txt"))
        #expect(copy.intakeOutcome == .aliased && copy.sourceVersionID == v1)

        let tables = ["source_versions", "source_intake_receipts", "knowledge_objects", "events", "files"]
        var before: [String: Int] = [:]
        for t in tables { before[t] = try await count(r.db, "SELECT COUNT(*) FROM \(t);") }

        let same = SourceSamenessRepository(database: r.db)
        for v in [v1, v2, v3] { #expect(try await same.recordTextDigest(sourceVersionID: v, at: Date()) != nil) }
        #expect(try await same.sameness(v1, v3) == .contentEquivalent)
        #expect(try await same.contentEquivalents(of: v1) == [v3])
        #expect(try await same.sameness(v1, v1) == .sameVersion)
        #expect(try await same.sameness(v1, v2) == .distinct)
        #expect(try await same.revisionCandidates(for: v2) == [v1], "same file name, another document: a suggestion only")
        #expect(try await same.revisionLinks(of: v2).isEmpty, "nothing is linked without a person")

        await #expect(throws: SourceSamenessError.blankBasis) {
            _ = try await same.confirmRevision(revised: v2, earlier: v1, basis: " ", actor: "Priya Nair", at: Date())
        }
        let link = try await same.confirmRevision(revised: v2, earlier: v1, basis: "Same memo number; the amount was revised", actor: "Priya Nair", at: Date())
        #expect(try await same.sameness(v1, v2) == .revision)
        #expect(try await same.confirmRevision(revised: v2, earlier: v1, basis: "again", actor: "Priya Nair", at: Date()).id == link.id)
        #expect(try await same.revisionCandidates(for: v2).isEmpty)
        await #expect(throws: (any Error).self) {
            try await r.db.exec("UPDATE source_version_links SET basis = 'edited' WHERE id = ?;", [.uuid(link.id)])
        }
        await #expect(throws: SourceSamenessError.blankReason) { try await same.withdrawRevisionLink(link.id, reason: "", actor: "Priya Nair", at: Date()) }
        try await same.withdrawRevisionLink(link.id, reason: "Different memo after all", actor: "Priya Nair", at: Date())
        #expect(try await same.sameness(v1, v2) == .distinct)
        #expect(try await same.revisionLinks(of: v1).map(\.isActive) == [false], "a withdrawn link is kept, marked withdrawn")

        // A revision at the same location is already a version of the same document: nothing to link.
        try "Payment of 50,000 approved on 3 March 2026.\nReference INV-104. Countersigned.".write(to: memo1, atomically: true, encoding: .utf8)
        let v1b = try #require(try await r.ingest.ingest(fileAt: memo1).sourceVersionID)
        #expect(v1b != v1)
        #expect(try await same.sameness(v1b, v1) == .revision)
        await #expect(throws: SourceSamenessError.sameDocument) {
            _ = try await same.confirmRevision(revised: v1b, earlier: v1, basis: "same file", actor: "Priya Nair", at: Date())
        }

        // Nothing was merged by any of it: the only new rows are the new version of memo.txt and its receipt.
        #expect(try await count(r.db, "SELECT COUNT(*) FROM source_versions;") == (before["source_versions"] ?? 0) + 1)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM source_intake_receipts;") == (before["source_intake_receipts"] ?? 0) + 1)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM files;") == before["files"])
        #expect(try await count(r.db, "SELECT COUNT(*) FROM source_versions WHERE id IN (?, ?, ?);", [.uuid(v1), .uuid(v2), .uuid(v3)]) == 3)
        await finish(r)
    }

    // MARK: - Erasure

    @Test("Erasing a case removes its intake records and policies (and, with its own documents, their batch lines and digests) and leaves another case's")
    func erasureTakesIntakeRecordsWithTheCase() async throws {
        let r = try await boot("erase")
        let dir = r.temp.appendingPathComponent("in", isDirectory: true)
        try write("Case A only: the warehouse lease, signed 1 March 2026.", "lease.txt", in: dir)
        try write("Case B only: the canteen contract, signed 2 March 2026.", "canteen.txt", in: dir)
        let run = try await batch(r, folder: dir, arrivals: IntakeArrivalHint(channel: .fileImport, roots: [dir]), planned: 2)
        let lines = try #require(try await IntakeReceiptRepository(database: r.db).receipt(run: run)).lines
        let va = try #require(lines.first { $0.name == "lease.txt" }?.sourceVersionID)
        let vb = try #require(lines.first { $0.name == "canteen.txt" }?.sourceVersionID)
        let same = SourceSamenessRepository(database: r.db)
        try await same.recordTextDigest(sourceVersionID: va, at: Date())
        try await same.recordTextDigest(sourceVersionID: vb, at: Date())
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds: the ledger stores REAL seconds
        let cases = try #require(await r.state.investigationCases)
        let intake = try #require(await r.state.investigationWorkspaceIntake)
        let coordinator = try #require(await r.state.workspaceSourceCoordinator)
        var ids: [UUID] = []
        for (title, v) in [("Lease", va), ("Canteen", vb)] {
            let ws = try await workspace(r, title, at: now)
            try await coordinator.addSources([try await logical(r.db, v)], to: ws, at: now)
            let c = try await cases.createCase(workspaceID: ws, title: title, actor: "Priya Nair", at: now)
            _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Priya Nair", at: now)
            _ = try await intake.ledger.createArrivalPolicy(caseID: c.id, name: "Shared items", channel: .shareInbox, actor: "Priya Nair", at: now)
            ids.append(c.id)
        }
        let report = try await CaseEraser(database: r.db).erase(caseID: ids[0], sourceVersionIDs: [va], eraseExclusiveSources: true,
                                                                reason: "Retention period ended", legalBasis: nil, actor: "Priya Nair")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        for t in ["case_intake_items", "case_intake_policies"] {
            #expect(try await count(r.db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(ids[0])]) == 0, "\(t)")
            #expect(try await count(r.db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(ids[1])]) >= 1, "\(t) of the other case")
        }
        #expect(try await count(r.db, "SELECT COUNT(*) FROM ingest_run_files WHERE source_version_id = ?;", [.uuid(va)]) == 0)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM source_text_digests WHERE source_version_id = ?;", [.uuid(va)]) == 0)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM ingest_run_files WHERE source_version_id = ?;", [.uuid(vb)]) == 1)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM source_text_digests WHERE source_version_id = ?;", [.uuid(vb)]) == 1)
        #expect(CaseDataInventory.entry("case_intake_items")?.lifecycle == .caseID && CaseDataInventory.entry("case_intake_policies")?.lifecycle == .caseID)
        await finish(r)
    }
}
