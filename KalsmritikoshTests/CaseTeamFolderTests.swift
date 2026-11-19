//
//  CaseTeamFolderTests.swift
//  KalsmritikoshTests
//
//  Team work over a shared folder (owner decision 2026-11-18: no server, no accounts). Each "Mac" here is its own ledger
//  and its own signing key; they share only a temporary folder, as two real Macs share a file server or an external disk.
//  The archive step is a seeded passage per file (the app's ingest in production).
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@MainActor
@Suite("Team work over a shared folder (v198)", .serialized)
struct CaseTeamFolderTests {

    /// One Mac: a ledger with a case, its team service and its own key.
    struct Mac {
        let f: CaseFileTests.Fixture
        let team: CaseTeamService
        let intake: InvestigationWorkspaceIntake
        let key = Curve25519.Signing.PrivateKey()
        var member: String { TeamIdentity.memberID(key.publicKey) }

        static func make(_ title: String) async throws -> Mac {
            let f = try await CaseFileTests.fixture(title: title)
            let intake = InvestigationWorkspaceIntake(cases: f.cases, workspaces: f.workspaces, coverage: CaseCoverageRepository(database: f.db))
            let db = f.db, cases = f.cases
            // The archive step: the file becomes a source version of the archive (held by another case of this ledger, as
            // any archive document may be), not yet in the case under test.
            let holding = try await cases.createCase(workspaceID: f.workspaceID, title: "Archive holding", actor: "Ada", at: Date()).id
            let team = CaseTeamService(file: f.file, intake: intake) { url in
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(binary)"
                return try await CaseFileTestSources.seedPassage(db, cases: cases, caseID: holding, name: url.lastPathComponent, text: text).version
            }
            return Mac(f: f, team: team, intake: intake)
        }
    }

    static func tempDir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("team-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func file(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        return u
    }

    @Test("TEAM-02/03, IN-01: a scoped request reaches only its contributor; their submission enters the case through the intake contract with who supplied it; the receipt goes back; the same file again is a duplicate")
    func contributionRoundTrip() async throws {
        let lead = try await Mac.make("Was the supplier paid twice?")
        let c = lead.f.caseID
        let root = try Self.tempDir("contrib"), work = try Self.tempDir("files")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: work) }
        let folderURL = root.appendingPathComponent("Supplier contributions", isDirectory: true)
        let link = try await lead.team.linkFolder(caseID: c, folder: folderURL, create: true, name: "Supplier contributions", purpose: .contribution,
                                                  displayName: "Ada (lead)", key: lead.key, actor: "Ada")
        // The contributor joins the folder from their own Mac: no case, no ledger.
        let ravi = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let folder = try #require(TeamCase.open(folderURL))
        let raviID = try folder.join(displayName: "Ravi (accounts)", key: ravi)
        let otherID = try folder.join(displayName: "Someone else", key: other)
        let input = try Self.file(work, "invoice-INV-2041.txt", "Invoice INV-2041 for INR 10,000.")
        let req = try await lead.team.publishRequest(caseID: c, linkID: link, title: "Bank statement for March", deliverable: "The March statement of account 7718",
                                                     recipient: raviID, due: "2026-11-25", inputs: [input], workRef: nil, key: lead.key, actor: "Ada")
        #expect(req.state == "published" && req.publishedAt != nil, "\(req.stateLine)")
        // TEAM-03: Ravi sees the request and its input — nothing else of the case; another member does not see it.
        let raviView = CaseTeamService.contributorView(folder: folder, member: raviID)
        #expect(raviView.requests.map(\.value.title) == ["Bank statement for March"])
        let shared = try #require(raviView.requests.first?.value.inputs.first)
        #expect(TeamCase.sha256(of: folder.inputURL(requestID: req.id.uuidString, name: shared.name)) == shared.sha256)
        #expect(CaseTeamService.contributorView(folder: folder, member: otherID).requests.isEmpty, "a request for Ravi is not shown to someone else")
        let stmt = try Self.file(work, "statement-7718-march.txt", "Statement 7718. 5 March: debit INR 10,000 to Dalmia Traders, ref INV-2041.")
        let sub = try folder.submit(requestID: req.id.uuidString, files: [stmt], note: "From the bank portal", member: raviID, key: ravi)
        // The lead's case reads the folder: one new submission, waiting for a person.
        let read = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        #expect(read.newSubmissions == 1 && read.reachable, "\(read.summary)")
        let again = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        #expect(again.newSubmissions == 0, "a second read adds nothing")
        let waiting = try #require(try await lead.f.file.teamSubmissions(caseID: c).first)
        #expect(waiting.outcome == "waiting" && waiting.submitterName == "Ravi (accounts)" && waiting.files.count == 1)
        // Include: the document is read in and taken in through the intake contract, channel teamSubmission, supplied by Ravi.
        let decided = try await lead.team.decide(caseID: c, submissionID: waiting.id, include: true, note: nil, key: lead.key, actor: "Ada")
        #expect(decided.outcome == "received" && decided.receiptState == "written", "\(decided.outcomeLine)")
        let version = try #require(decided.files.first?.sourceVersionID)
        let intakeRows = try await lead.f.db.query("SELECT channel, supplied_by, entered_by, decision, decided_via, provenance FROM case_intake_items WHERE case_id = ? AND source_version_id = ?;",
                                                   [.uuid(c), .uuid(version)])
        #expect(intakeRows.count == 1)
        #expect(intakeRows.first?.string(0) == "teamSubmission" && intakeRows.first?.string(1) == "Ravi (accounts)" && intakeRows.first?.string(2) == "Ada")
        #expect(intakeRows.first?.string(3) == "included" && intakeRows.first?.string(4) == "person")
        #expect(intakeRows.first?.string(5)?.contains("Bank statement for March") == true)
        #expect(try #require(try await lead.f.cases.fetch(caseID: c)).sources.contains { $0.sourceRef == version.uuidString && $0.inScope })
        // GUI walk 2026-11-19: the case log lists the document entering the case (it listed none).
        let logLines = try await lead.f.db.query("SELECT detail FROM case_actions WHERE case_id = ? AND action = 'document included';", [.uuid(c)])
        #expect(logLines.contains { ($0.string(0) ?? "").contains("statement-7718-march.txt") }, "\(logLines.map { $0.string(0) ?? "" })")
        // The receipt reaches Ravi, from the request's author only.
        let receipt = try #require(CaseTeamService.contributorView(folder: folder, member: raviID).receipts[sub.id])
        #expect(receipt.outcome == "received" && receipt.lines.first?.status == "received")
        // The same file in a new submission: a duplicate, not read twice, not a second intake record.
        _ = try folder.submit(requestID: req.id.uuidString, files: [stmt], note: "Sent again", member: raviID, key: ravi)
        _ = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        let second = try #require(try await lead.f.file.teamSubmissions(caseID: c).first { $0.id != waiting.id })
        let dup = try await lead.team.decide(caseID: c, submissionID: second.id, include: true, note: nil, key: lead.key, actor: "Ada")
        #expect(dup.outcome == "duplicate" && dup.files.first?.duplicateOf == waiting.id.uuidString, "\(dup.outcomeLine)")
        #expect(try await lead.f.db.query("SELECT 1 FROM case_intake_items WHERE case_id = ? AND channel = 'teamSubmission';", [.uuid(c)]).count == 1)
        // Decided once; a decline needs a reason.
        await #expect(throws: CaseTeamError.self) { _ = try await lead.team.decide(caseID: c, submissionID: waiting.id, include: true, note: nil, key: lead.key, actor: "Ada") }
    }

    @Test("TEAM-07 / PERF-09: a cut-off submission is finished, not announced half-copied; a folder that went away keeps the request pending with its error and writes it when it is back")
    func interruptedAndQueued() async throws {
        let lead = try await Mac.make("Seal intact?")
        let c = lead.f.caseID
        let root = try Self.tempDir("queue"), work = try Self.tempDir("qfiles")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: work) }
        let folderURL = root.appendingPathComponent("Team", isDirectory: true)
        let link = try await lead.team.linkFolder(caseID: c, folder: folderURL, create: true, name: "Team", purpose: .contribution,
                                                  displayName: "Ada", key: lead.key, actor: "Ada")
        let folder = try #require(TeamCase.open(folderURL))
        let bea = Curve25519.Signing.PrivateKey()
        let beaID = try folder.join(displayName: "Bea", key: bea)
        let req = try await lead.team.publishRequest(caseID: c, linkID: link, title: "Seal photos", deliverable: "Photos of bag 7's seal", recipient: "anyone",
                                                     due: nil, inputs: [], workRef: nil, key: lead.key, actor: "Ada")
        // A copy cut off part-way: one file is not there yet; nothing is announced, the marker stays.
        let present = try Self.file(work, "photo-1.txt", "Photo 1: seal intact.")
        let missing = work.appendingPathComponent("photo-2.txt")
        #expect(throws: TeamFolderError.self) { _ = try folder.submit(id: "6D0A4C5E-0000-4000-8000-000000000001", requestID: req.id.uuidString, files: [present, missing], note: nil, member: beaID, key: bea) }
        #expect(try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada").newSubmissions == 0, "a half-copied submission is never taken")
        let cut = try #require(folder.incompleteSubmissions(member: beaID).first)
        _ = try Self.file(work, "photo-2.txt", "Photo 2: seal number 4471.")
        let resumed = try folder.resumeSubmission(cut, key: bea)
        #expect(resumed.files.count == 2 && folder.incompleteSubmissions(member: beaID).isEmpty)
        #expect(try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada").newSubmissions == 1)
        // The folder goes away (a share disconnected): the request stays pending with its error; nothing else changes.
        // A share that went away: its contents are not there (a bookmark follows a moved folder, so moving it is not an outage).
        let away = root.appendingPathComponent("log-away", isDirectory: true)
        try FileManager.default.moveItem(at: folderURL.appendingPathComponent("log"), to: away)
        let queued = try await lead.team.publishRequest(caseID: c, linkID: link, title: "Custody log", deliverable: "The custody log page", recipient: "anyone",
                                                        due: nil, inputs: [], workRef: nil, key: lead.key, actor: "Ada")
        #expect(queued.state == "error" && queued.stateLine.hasPrefix("Not yet in the team folder"), "\(queued.stateLine)")
        let down = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        #expect(!down.reachable && down.summary.contains("can't be reached"))
        #expect(try await lead.f.file.teamLinks(caseID: c).first?.lastError != nil)
        // Back: the waiting request is written once; a further read writes nothing again.
        try FileManager.default.moveItem(at: away, to: folderURL.appendingPathComponent("log"))
        let up = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        #expect(up.reachable && up.retried == 1, "\(up.summary)")
        #expect(try await lead.f.file.teamRequests(caseID: c).first { $0.id == queued.id }?.state == "published")
        #expect(try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada").retried == 0)
        let titles = CaseTeamService.contributorView(folder: try #require(TeamCase.open(folderURL)), member: beaID).requests.map(\.value.title)
        #expect(titles.filter { $0 == "Custody log" }.count == 1, "written once: \(titles)")
        #expect(try await lead.f.file.teamLinks(caseID: c).first?.lastError == nil)
    }

    @Test("IN-05 / CHANGE-07: a named team-submission policy includes new submissions and the record names it; without one they wait; a closed case refuses a decision; a decline needs a reason and is receipted")
    func policyClosedAndDecline() async throws {
        let lead = try await Mac.make("Night shift")
        let c = lead.f.caseID
        let root = try Self.tempDir("policy"), work = try Self.tempDir("pfiles")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: work) }
        let folderURL = root.appendingPathComponent("Contrib", isDirectory: true)
        let link = try await lead.team.linkFolder(caseID: c, folder: folderURL, create: true, name: "Contrib", purpose: .contribution, displayName: "Ada", key: lead.key, actor: "Ada")
        let folder = try #require(TeamCase.open(folderURL))
        let k = Curve25519.Signing.PrivateKey()
        let kid = try folder.join(displayName: "Kiran", key: k)
        let req = try await lead.team.publishRequest(caseID: c, linkID: link, title: "Rota", deliverable: "The March rota", recipient: kid, due: nil, inputs: [], workRef: nil, key: lead.key, actor: "Ada")
        // A decline needs a reason; it is receipted.
        _ = try folder.submit(requestID: req.id.uuidString, files: [try Self.file(work, "wrong.txt", "Not the rota.")], note: nil, member: kid, key: k)
        _ = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        let s1 = try #require(try await lead.f.file.teamSubmissions(caseID: c).first)
        await #expect(throws: CaseTeamError.self) { _ = try await lead.team.decide(caseID: c, submissionID: s1.id, include: false, note: " ", key: lead.key, actor: "Ada") }
        let declined = try await lead.team.decide(caseID: c, submissionID: s1.id, include: false, note: "Not the March rota", key: lead.key, actor: "Ada")
        #expect(declined.outcome == "declined" && declined.files.first?.status == "declined" && declined.receiptState == "written")
        #expect(try await lead.f.db.query("SELECT 1 FROM case_intake_items WHERE case_id = ?;", [.uuid(c)]).isEmpty, "a declined file is never read in")
        // A named policy for team submissions: the next submission is included under it, and the record names it.
        let policy = try await lead.intake.ledger.createArrivalPolicy(caseID: c, name: "Kiran's rota returns", channel: .teamSubmission, actor: "Ada", at: Date())
        _ = try folder.submit(requestID: req.id.uuidString, files: [try Self.file(work, "rota-march.txt", "Rota March: night shift Ward 4.")], note: nil, member: kid, key: k)
        let r = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        #expect(r.newSubmissions == 1 && r.admittedByPolicy == 1, "\(r.summary)")
        let row = try await lead.f.db.query("SELECT decided_via, policy_id, decision_note, channel FROM case_intake_items WHERE case_id = ?;", [.uuid(c)])
        #expect(row.count == 1 && row.first?.string(0) == "policy" && row.first?.uuid(1) == policy.id && row.first?.string(3) == "teamSubmission")
        #expect(row.first?.string(2)?.contains("Kiran's rota returns") == true)
        // A closed case decides nothing.
        try await lead.intake.ledger.withdrawPolicy(policy.id, reason: "Rota received", actor: "Ada", at: Date())
        _ = try folder.submit(requestID: req.id.uuidString, files: [try Self.file(work, "rota-april.txt", "Rota April.")], note: nil, member: kid, key: k)
        _ = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        let s3 = try #require(try await lead.f.file.teamSubmissions(caseID: c).first { $0.outcome == "waiting" })
        try await lead.f.file.markClosed(caseID: c, reopened: false, actor: "Ada")
        await #expect(throws: (any Error).self) { _ = try await lead.team.decide(caseID: c, submissionID: s3.id, include: true, note: nil, key: lead.key, actor: "Ada") }
        #expect(try await lead.f.file.teamSubmissions(caseID: c).first { $0.id == s3.id }?.outcome == "waiting", "it waits; nothing is lost")
    }

    @Test("TEAM-05 / TEAM-06 / DATA-09: shared work is pending until it is in the folder; another Mac takes in changes made from what it holds; two edits from the same revision are both kept as a conflict, never last-write-wins; the resolution reaches both")
    func sharedWorkAndConflicts() async throws {
        let a = try await Mac.make("Case on Mac A"), b = try await Mac.make("Case on Mac B")
        let root = try Self.tempDir("work")
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("Ward 4 team", isDirectory: true)
        let la = try await a.team.linkFolder(caseID: a.f.caseID, folder: folderURL, create: true, name: "Ward 4 team", purpose: .team, displayName: "Ada", key: a.key, actor: "Ada")
        let lb = try await b.team.linkFolder(caseID: b.f.caseID, folder: folderURL, create: false, name: "", purpose: .team, displayName: "Ben", key: b.key, actor: "Ben")
        #expect(try await a.f.file.teamLinks(caseID: a.f.caseID).first?.teamCaseID == (try await b.f.file.teamLinks(caseID: b.f.caseID).first?.teamCaseID), "the same team folder, one id")
        // A assigns; it is confirmed only once it is in the folder.
        let r1 = try await a.team.shareWork(caseID: a.f.caseID, linkID: la, kind: .assignment, localID: "task-17", label: "Interview the night porter",
                                            payload: ["assignee": "Ben", "note": "before Friday"], key: a.key, actor: "Ada")
        #expect(r1.state == "confirmed" && r1.revision == 1, "\(r1.stateLine)")
        let tid = r1.teamRecordID
        // B takes it in, then reassigns it (revision 2 from 1); A takes that in.
        #expect(try await b.team.read(caseID: b.f.caseID, linkID: lb, key: b.key, actor: "Ben").newRecords == 1)
        let atB = try #require(try await b.f.file.teamRecords(caseID: b.f.caseID).first)
        #expect(atB.state == "received" && atB.payload["assignee"] == "Ben" && atB.authorName == "Ada" && atB.teamRecordID == tid)
        let r2 = try await b.team.shareWork(caseID: b.f.caseID, linkID: lb, kind: .assignment, teamRecordID: tid, localID: nil, label: atB.label,
                                            payload: ["assignee": "Cara", "note": "Ben is on leave"], key: b.key, actor: "Ben")
        #expect(r2.revision == 2 && r2.baseRevision == 1 && r2.state == "confirmed")
        #expect(try await a.team.read(caseID: a.f.caseID, linkID: la, key: a.key, actor: "Ada").newRecords == 1)
        #expect(try await a.f.file.teamRecords(caseID: a.f.caseID).first?.payload["assignee"] == "Cara")
        // Both change it from revision 2 at the same time: each keeps its own and records a conflict with both sides.
        _ = try await a.team.shareWork(caseID: a.f.caseID, linkID: la, kind: .assignment, teamRecordID: tid, localID: nil, label: atB.label,
                                       payload: ["assignee": "Dev", "note": "Cara asked to swap"], key: a.key, actor: "Ada")
        _ = try await b.team.shareWork(caseID: b.f.caseID, linkID: lb, kind: .assignment, teamRecordID: tid, localID: nil, label: atB.label,
                                       payload: ["assignee": "Cara", "note": "Cara confirmed"], key: b.key, actor: "Ben")
        let ra = try await a.team.read(caseID: a.f.caseID, linkID: la, key: a.key, actor: "Ada")
        #expect(ra.conflicts == 1 && ra.newRecords == 0, "\(ra.summary)")
        #expect(try await a.f.file.teamRecords(caseID: a.f.caseID).first?.payload["assignee"] == "Dev", "A's own edit is not overwritten")
        #expect(try await b.team.read(caseID: b.f.caseID, linkID: lb, key: b.key, actor: "Ben").conflicts == 1)
        #expect(try await a.team.read(caseID: a.f.caseID, linkID: la, key: a.key, actor: "Ada").conflicts == 0, "kept once")
        let conflict = try #require(try await a.f.file.teamConflicts(caseID: a.f.caseID).first)
        #expect(conflict.localPayload["assignee"] == "Dev" && conflict.remotePayload["assignee"] == "Cara" && conflict.remoteAuthor == "Ben")
        // A takes Ben's; the resolution is a new revision after both, and B takes it in.
        let resolved = try await a.team.resolveConflict(caseID: a.f.caseID, conflictID: conflict.id, keepOurs: false, combined: nil, note: "Cara confirmed",
                                                        key: a.key, actor: "Ada")
        #expect(resolved.revision == 4 && resolved.payload["assignee"] == "Cara" && resolved.state == "confirmed")
        #expect(try await b.team.read(caseID: b.f.caseID, linkID: lb, key: b.key, actor: "Ben").newRecords == 1)
        #expect(try await b.f.file.teamRecords(caseID: b.f.caseID).first?.revision == 4)
        await #expect(throws: (any Error).self) { try await a.f.db.exec("UPDATE case_team_conflicts SET remote_payload = '{}';", []) }
        // A change made while the folder is away is shown as only on this Mac, then confirmed when it is back.
        let away = root.appendingPathComponent("log-away", isDirectory: true)
        try FileManager.default.moveItem(at: folderURL.appendingPathComponent("log"), to: away)
        let offline = try await a.team.shareWork(caseID: a.f.caseID, linkID: la, kind: .actionReview, localID: "action-3", label: "Check the CCTV export",
                                                 payload: ["review": "returned", "comment": "timestamps missing"], key: a.key, actor: "Ada")
        #expect(offline.state == "error" && offline.stateLine.hasPrefix("Only on this Mac"), "\(offline.stateLine)")
        try FileManager.default.moveItem(at: away, to: folderURL.appendingPathComponent("log"))
        #expect(try await a.team.read(caseID: a.f.caseID, linkID: la, key: a.key, actor: "Ada").retried == 1)
        #expect(try await a.f.file.teamRecords(caseID: a.f.caseID).first { $0.kind == .actionReview }?.state == "confirmed")
    }

    @Test("RECOVERY-08 / integrity: another installation's key cannot act as the linked member; an entry changed after signing is dropped from that point and reported")
    func otherInstallationAndTampering() async throws {
        let lead = try await Mac.make("Kestrel")
        let c = lead.f.caseID
        let root = try Self.tempDir("tamper")
        defer { try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("T", isDirectory: true)
        let link = try await lead.team.linkFolder(caseID: c, folder: folderURL, create: true, name: "T", purpose: .contribution, displayName: "Ada", key: lead.key, actor: "Ada")
        let restored = Curve25519.Signing.PrivateKey()   // a restored or moved ledger on another Mac: a new key
        await #expect(throws: CaseTeamError.otherInstallation) {
            _ = try await lead.team.publishRequest(caseID: c, linkID: link, title: "x", deliverable: "y", recipient: "anyone", due: nil, inputs: [], workRef: nil, key: restored, actor: "Ada")
        }
        await #expect(throws: CaseTeamError.otherInstallation) { _ = try await lead.team.read(caseID: c, linkID: link, key: restored, actor: "Ada") }
        _ = try await lead.team.publishRequest(caseID: c, linkID: link, title: "First", deliverable: "a", recipient: "anyone", due: nil, inputs: [], workRef: nil, key: lead.key, actor: "Ada")
        _ = try await lead.team.publishRequest(caseID: c, linkID: link, title: "Second", deliverable: "b", recipient: "anyone", due: nil, inputs: [], workRef: nil, key: lead.key, actor: "Ada")
        let folder = try #require(TeamCase.open(folderURL))
        let log = folder.logDir.appendingPathComponent("\(lead.member).jsonl")
        let text = try String(contentsOf: log, encoding: .utf8)
        try text.replacingOccurrences(of: "First", with: "Forged").write(to: log, atomically: true, encoding: .utf8)
        let (entries, problems) = folder.verifiedEntries()
        #expect(entries.isEmpty && problems.contains { if case .badSignature = $0 { return true }; return false }, "\(problems.map(\.text))")
        let viewer = Curve25519.Signing.PrivateKey()
        #expect(CaseTeamService.contributorView(folder: folder, member: try folder.join(displayName: "V", key: viewer)).requests.isEmpty)
        let r = try await lead.team.read(caseID: c, linkID: link, key: lead.key, actor: "Ada")
        #expect(!r.problems.isEmpty && r.summary.contains("log problem"), "\(r.summary)")
    }

    @Test("v198 from a v197 ledger: intake policies and items are kept unchanged and accept the team channel; the erase trigger still removes intake rows; the team tables exist and are inventoried")
    func migrationV198() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 197)
        let ws = Workspace(title: "WS")
        try await WorkspaceRepository(database: db).upsert(ws)
        let c1 = try await InvestigationCaseRepository(database: db).createCase(workspaceID: ws.id, title: "Case", actor: "Ada", at: Date()).id
        try await db.exec("INSERT INTO case_intake_policies (id, case_id, name, rule, channel, created_by, created_at) VALUES ('p1',?,'Shared','channelArrivals','shareInbox','Ada',1);", [.uuid(c1)])
        try await db.exec("""
            INSERT INTO case_intake_items (id, case_id, channel, content_form, record_kind, record_id, label, provenance, entered_by, received_at, recorded_at)
            VALUES ('i1',?,'manualEntry','typedEntry','journal','j1','Call note','Typed','Ada',1,1);
            """, [.uuid(c1)])
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 198)
        #expect(try await db.query("SELECT name FROM case_intake_policies WHERE id = 'p1';").first?.string(0) == "Shared")
        #expect(try await db.query("SELECT label FROM case_intake_items WHERE id = 'i1';").first?.string(0) == "Call note")
        try await db.exec("INSERT INTO case_intake_policies (id, case_id, name, rule, channel, created_by, created_at) VALUES ('p2',?,'Team','channelArrivals','teamSubmission','Ada',2);", [.uuid(c1)])
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_intake_items SET entered_by = 'x' WHERE id = 'i1';") }
        for t in ["case_team_links", "case_team_requests", "case_team_submissions", "case_team_submission_files", "case_team_records", "case_team_conflicts"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t)")
            #expect(CaseDataInventory.entries.contains { $0.table == t }, "\(t) inventoried for erasure")
        }
        #expect(try await db.query("SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = 'source_versions_erase_intake';").count == 1)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
