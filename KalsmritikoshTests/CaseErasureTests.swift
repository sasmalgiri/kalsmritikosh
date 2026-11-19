//
//  CaseErasureTests.swift
//  KalsmritikoshTests
//
//  K10 — case and person erasure on a booted app over two real documents and two cases:
//  a hold refuses with nothing deleted; a case erase removes every case-scoped row (append-only
//  ones included) and, when asked, the document only that case used, while the document another
//  case uses is kept; the other case is untouched; the erasure record carries no content; a person
//  erase removes the derived record and reports the documents that still name them.
//

import Foundation
import OSLog
import Testing
@testable import Kalsmritikosh

@Suite("Case and person erasure (K10)", .serialized)
struct CaseErasureTests {

    struct Fixture {
        let state: AppState
        let db: Database
        let caseA: UUID, caseB: UUID
        let exclusiveFile: UUID, sharedFile: UUID
        let temp: URL
    }

    static func boot() async throws -> Fixture {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("k10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("case.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            throw CaseErasureError.caseNotFound
        }
        var ids: [UUID] = []
        for name in ["investigator-press-release.txt", "lawyer-decision.txt"] {
            let dst = temp.appendingPathComponent(name)
            try FileManager.default.copyItem(at: try InvestigationCasePacks.url(name), to: dst)
            ids.append(try await ingest.ingest(fileAt: dst).fileRecord.id)
        }
        let now = Date()
        let sources = try #require(await state.workspaceSourceCoordinator)
        let cases = try #require(await state.investigationCases)
        let intake = try #require(await state.investigationWorkspaceIntake)
        func open(_ title: String, _ files: Set<UUID>) async throws -> UUID {
            let ws = UUID()
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                              [.uuid(ws), .text(title), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            try await sources.addSources(files, to: ws, at: now)
            let c = try await cases.createCase(workspaceID: ws, title: title, actor: "Tester", at: now)
            _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Tester", at: now)
            return c.id
        }
        let a = try await open("Case A — secret title", [ids[0], ids[1]])
        let b = try await open("Case B", [ids[1]])
        // Case work: an append-only action and a job result for each case.
        for (c, n) in [(a, 1), (b, 1)] {
            try await db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(c), .integer(Int64(n)), .text("Tester"), .text("note"), .text("secret detail"), .date(now)])
            try await JobResultRepository(database: db).save(caseID: c, jobID: "inv.linkage", family: .chronologyLinkage, state: .draft,
                                                            content: JobResultContent(rows: [JobResultRow(title: "secret row")]), actor: "Tester")
        }
        return Fixture(state: state, db: db, caseA: a, caseB: b, exclusiveFile: ids[0], sharedFile: ids[1], temp: temp)
    }

    static func count(_ db: Database, _ sql: String, _ b: [SQLValue]) async throws -> Int {
        Int(try await db.query(sql, b).first?.int(0) ?? -1)
    }

    @Test("A legal hold on one of the case's documents refuses the erase; nothing is deleted")
    func holdRefuses() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ko = try #require(try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(f.exclusiveFile)]).first?.string(0))
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(ko), .date(Date())])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused?.contains("legal hold") == true && out.report.erasureID == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseA)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1)
    }

    @Test("A case erase removes every case row and its exclusive document; the shared document and the other case stay; the record has no content")
    func caseErase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        // Blank actor or reason is refused before anything happens.
        await #expect(throws: CaseErasureError.blankReason) {
            _ = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: " ", legalBasis: nil, actor: "Tester")
        }
        // LS25 — contradictions quoting the case's own document go with it; one between shared documents stays.
        let exclusiveKO = try #require(try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(f.exclusiveFile)]).first?.uuid(0))
        let sharedKO = try #require(try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(f.sharedFile)]).first?.uuid(0))
        let contradictions = ContradictionsRepository(database: f.db)
        let quoting = Contradiction(kind: .date, description: "Conflicting dates", claimA: "SECRET erased quote", claimB: "other side",
                                    evidenceA: sharedKO, evidenceB: exclusiveKO)
        let sharedOnly = Contradiction(kind: .date, description: "Conflicting dates", claimA: "kept quote", claimB: "kept other",
                                       evidenceA: sharedKO, evidenceB: sharedKO)
        await contradictions.insertMany([quoting, sharedOnly])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: "GDPR art. 17", actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(out.report.sourcesErased == 1 && out.report.sourcesKeptShared == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM contradictions WHERE id = ?;", [.uuid(quoting.id)]) == 0, "LS25: the quote of the erased document is gone")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM contradictions WHERE id = ?;", [.uuid(sharedOnly.id)]) == 1)
        // Every table that carries case_id holds nothing for case A — append-only case_actions included.
        let tables = try await f.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", [])
            .compactMap { $0.string(0) }
        for t in tables where !CaseEraser.keptTables.contains(t) {
            let cols = try await f.db.query("PRAGMA table_info(\"\(t)\");", []).compactMap { $0.string(1) }
            guard cols.contains("case_id") else { continue }
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \"\(t)\" WHERE case_id = ?;", [.uuid(f.caseA)]) == 0, "\(t) kept case A rows")
        }
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 0)
        // The exclusive document and everything derived from it are gone; the shared one stays.
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM knowledge_objects WHERE file_id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM source_versions WHERE logical_source_id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'Goodyear';", []) == 0, "the erased text is not searchable")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.sharedFile)]) == 1)
        // Case B is untouched.
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseB)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM job_results WHERE case_id = ?;", [.uuid(f.caseB)]) == 1)
        // The erasure record: who, why, how much — no title, no detail, no row text; fixed.
        let rec = try #require(try await f.db.query("SELECT reason, legal_basis, rows_json, erased_by FROM case_erasures WHERE case_id = ?;", [.uuid(f.caseA)]).first)
        #expect(rec.string(0) == "Client request" && rec.string(1) == "GDPR art. 17" && rec.string(3) == "Tester")
        let json = rec.string(2) ?? ""
        #expect(!json.contains("secret") && json.contains("case_actions"))
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_erasures SET reason = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_erasures;", []) }
        // Ordinary deletes on case B's append-only rows are still refused.
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_actions WHERE case_id = ?;", [.uuid(f.caseB)]) }
    }

    @Test("LB1/PB2: erasing a case removes the text it sent to the AI from the outbound record; the audit line (time, destination, size, SHA-256) stays; another case's entries stay")
    func caseEraseRemovesOutboundText() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let log = OutboundLogRepository(database: f.db)
        let dA = String(repeating: "a", count: 64), dLegacy = String(repeating: "b", count: 64), dB = String(repeating: "c", count: 64)
        let markA = OnlineCloudProvider.caseMarker(f.caseA), markB = OnlineCloudProvider.caseMarker(f.caseB)
        func entry(_ text: String, _ detail: String?) -> OutboundLogEntry {
            OutboundLogEntry(id: UUID(), sentAt: Date(), provider: "included", model: "m", host: "relay.example", bytesSent: text.utf8.count,
                             maskedCount: 0, payloadSHA256: "sha-" + String(text.count), payloadText: text, responseBytes: 10, outcome: "sent", detail: detail)
        }
        let rows = [
            entry("SECRET whole case A text", OnlineCloudProvider.caseTextFullTag(dA, caseID: f.caseA)),
            // A full copy written before entries carried the case marker, pointed to by a case-A reference.
            entry("SECRET legacy case A text", OnlineCloudProvider.caseTextFullTag(dLegacy)),
            entry("[Case text not repeated: … — \(markA), document set x, case text SHA-256 \(dLegacy), 9 bytes.]\n\nSECRET question", "case text \(dLegacy) (see the full copy)"),
            entry("SECRET passages of case A", "case read; \(markA)"),
            entry("SECRET whole case B text", OnlineCloudProvider.caseTextFullTag(dB, caseID: f.caseB)),
            entry("question about something else", nil),
        ]
        for r in rows { try await log.record(r) }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(out.report.rowsErased["outbound_log (text removed)"] == 4)
        let after = Dictionary(uniqueKeysWithValues: try await log.recent().map { ($0.id, $0) })
        for r in rows.prefix(4) {
            let e = try #require(after[r.id], "the entry itself is kept")
            #expect(e.payloadText.hasPrefix(CaseEraser.erasedOutboundPrefix + f.caseA.uuidString), "\(e.payloadText)")
            #expect(!e.payloadText.contains("SECRET"))
            #expect(e.payloadSHA256 == r.payloadSHA256 && e.bytesSent == r.bytesSent && e.host == r.host && e.sentAt.timeIntervalSince1970.rounded() == r.sentAt.timeIntervalSince1970.rounded())
        }
        #expect(after[rows[4].id]?.payloadText == "SECRET whole case B text", "case B's record is untouched")
        #expect(after[rows[5].id]?.payloadText == "question about something else")
        #expect(rows[4].detail?.contains(markB) == true)
    }

    @Test("LS13: asking in a case with a cloud interpreter and rewriter installed (fake transport), then erasing the case, replaces the stored question text; a question outside the case keeps its text")
    func askInCaseThenEraseReplacesQuestionText() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        // The person's provider with a fake transport (no network): every send is recorded in the ledger's
        // outbound log, exactly as in the app.
        let log = OutboundLogRepository(database: f.db)
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let reply = Data(#"{"content":[{"type":"text","text":"{}"}],"usage":{"input_tokens":3,"output_tokens":2}}"#.utf8)
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in true },
                                              transport: { _ in OutboundHTTPResponse(status: 200, body: reply) })
        seams.ownKeyRefusal = { _ in nil }
        seams.ownKeyTally = { _, _ in }
        let provider = OnlineCloudProvider(outboundLog: log, knownNames: { [] }, seams: seams)
        // The cloud steps of question understanding, wired as AppState.installCloudReaders wires them.
        let readers = CloudReaders(
            interpreterCloud: CloudQuestionInterpreter { prompt in
                try await provider.generateQuestionOnly(prompt: prompt, options: GenerationOptions(maxTokens: 16, temperature: 0))
            },
            rewriterCloud: CloudQuestionRewriter { prompt in
                try await provider.generateQuestionOnly(prompt: prompt, options: GenerationOptions(maxTokens: 300, temperature: 0))
            },
            // A document reader is installed (so the case question takes the AI path, not offline search
            // results, which clear every reader), but it sends nothing: this test is about question-only sends.
            answerComposer: VerifiedAnswerComposer { _, _ in throw VerifiedAnswerComposer.NotSent("test: no document reading") },
            modelsAllowedOverride: true)
        // The app's own case-ask service (booted brain, case-scoped retrieval over the ingested documents),
        // with the readers installed the way the app installs them.
        f.state.cloudReaderHolder.set(readers)
        let service = try #require(await f.state.investigationAnswers)
        // Names from the case documents (so their extracted facts are retrieved) and no field word, so the
        // rules cannot place the question and the cloud interpreter is asked.
        let question = "Wyko Tire Technology and Bancitaly Corporation: the zebrafinch SECRET bit?"
        _ = try await service.answer(caseID: f.caseA, question: question, access: .testUnrestricted())
        // Outside any case: the same provider, no case scope.
        _ = try await provider.generateQuestionOnly(prompt: "an archive question about zebrafinch", options: GenerationOptions(maxTokens: 16))
        let before = try await log.recent()
        let inCase = before.filter { $0.payloadText.contains("zebrafinch SECRET") }
        #expect(!inCase.isEmpty, "the in-case question was not sent by the interpreter, so this proves nothing: \(before.map { $0.payloadText.prefix(80) })")
        #expect(inCase.allSatisfy { ($0.detail ?? "").contains(OnlineCloudProvider.caseMarker(f.caseA)) }, "\(inCase.map(\.detail))")

        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        let after = Dictionary(uniqueKeysWithValues: try await log.recent().map { ($0.id, $0) })
        for e in inCase {
            let kept = try #require(after[e.id], "the entry itself is kept")
            #expect(kept.payloadText.hasPrefix(CaseEraser.erasedOutboundPrefix + f.caseA.uuidString), "\(kept.payloadText)")
            #expect(!kept.payloadText.contains("SECRET"))
            #expect(kept.payloadSHA256 == e.payloadSHA256 && kept.bytesSent == e.bytesSent)
        }
        #expect(after.values.contains { $0.payloadText.contains("an archive question about zebrafinch") }, "a send outside the case keeps its text")
    }

    @Test("LB3: a case erase removes that case's workspace preference (search text, last source); another case's stays")
    func caseEraseRemovesWorkspacePreference() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let prefs = AppState.erasePreferences
        var state = CaseWorkspaceState()
        state.contradictionSearch = "Jane Doe payment"
        state.lastSource = CaseSourcePosition(objectID: UUID(), origin: .caseEntry(id: UUID()), revision: nil)
        CaseWorkspaceStore.save(state, caseID: f.caseA, defaults: prefs)
        CaseWorkspaceStore.save(state, caseID: f.caseB, defaults: prefs)
        defer { CaseWorkspaceStore.forget(caseID: f.caseB, defaults: prefs) }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(prefs.object(forKey: CaseWorkspaceStore.key(f.caseA)) == nil)
        #expect(CaseWorkspaceStore.load(caseID: f.caseB, defaults: prefs).contradictionSearch == "Jane Doe payment")
    }

    @Test("A case erase without its documents keeps them in the library and says so")
    func caseEraseKeepsDocuments() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Closed matter", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil && out.report.sourcesErased == 0 && out.report.sourcesKeptInLibrary == 1)
        #expect(out.summary.contains("stay in your library"))
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1)
    }

    @Test("A person erase removes the derived record, records a hash not the name, and reports documents that still name them")
    func personErase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let id = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        let out = try await f.state.erasePerson(id, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(id)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM entity_mentions WHERE entity_id = ?;", [.uuid(id)]) == 0)
        #expect(out.report.documentsStillNaming >= 1 && out.summary.contains("still name this person"))
        let rec = try #require(try await f.db.query("SELECT subject_sha256, rows_json FROM case_erasures WHERE scope = 'person';", []).first)
        #expect(rec.string(0)?.count == 64 && !(rec.string(1) ?? "").contains(name))
    }

    @Test("K5: a case report exports only while it is current — a source labelled privileged after the build stops the export")
    func caseReportExportReauthorised() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let findings = try #require(await f.state.investigationFindings)
        let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]).first?.string(0).flatMap(UUID.init(uuidString:)))
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted,
                                                                  permitsPrivilegedMaterial: false, purpose: .export))
        let built = try await findings.buildFindings(caseID: f.caseA, access: access, actor: "Tester", at: Date())
        let check = try #require(await f.state.findingsExportCheck())
        try await check(built)   // current: passes

        // A cited source is labelled privileged after the build.
        let version = try #require(built.authorizedSourceVersionIDs.first)
        _ = try await SensitiveScopeRepository(database: f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Tester", confirmationID: UUID(), privileged: true), reason: "privileged advice")
        await #expect(throws: ReportExportRefusal.sourcesWithdrawn(1)) { try await check(built) }
        #expect(ReportExportRefusal.sourcesWithdrawn(1).errorDescription?.contains("no longer cleared for export") == true)
    }

    // MARK: - Audit 182c7e4c regressions (A3–A5)

    static func firstKO(_ db: Database, _ file: UUID) async throws -> String {
        try #require(try await db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(file)]).first?.string(0))
    }
    static func firstBlock(_ db: Database, _ file: UUID) async throws -> String {
        try #require(try await db.query("""
            SELECT eb.id FROM evidence_blocks eb JOIN source_versions sv ON sv.id = eb.source_version_id
            WHERE sv.logical_source_id = ? LIMIT 1;
            """, [.uuid(file)]).first?.string(0))
    }

    @Test("A3: erasing one person never deletes a same-name person's facts; a held namesake document does not block it")
    func namesakeSafe() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let id = try #require(row.string(0)), name = try #require(row.string(1))
        // A distinct person with the same name, mentioned only in the other document (kept apart from
        // ours by an identity decision, so it has its own normalized key).
        let otherKO = try await Self.firstKO(f.db, f.sharedFile)
        let other = UUID().uuidString
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);", [.text(other), .text("person"), .text(name), .text(name.lowercased() + "|distinct"), .text(otherKO)])
        try await f.db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id) VALUES (?,?,?,?,?,?);",
                            [.text(UUID().uuidString), .text(other), .text("person"), .text(name), .text(name.lowercased()), .text(otherKO)])
        // A fact naming the other person, sourced from their document; and one subject-linked to ours.
        let block = try await Self.firstBlock(f.db, f.sharedFile)
        let theirFact = UUID().uuidString, ourFact = UUID().uuidString
        for (fid, subject, blocks) in [(theirFact, Optional<String>.none, "[\"\(block)\"]"), (ourFact, Optional(id), "[]")] {
            try await f.db.exec("""
                INSERT INTO generic_facts (id, subject_id, subject_label, field, value, status, confidence, source_blocks_json, created_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.text(fid), subject.map { .text($0) } ?? .null, .text("x"), .text("defendant"), .text(name), .text("active"), .real(0.9), .text(blocks), .date(Date())])
        }
        // The namesake's document is on hold — that must not block erasing our person.
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("H"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(otherKO), .date(Date())])
        let out = try await f.state.erasePerson(try #require(UUID(uuidString: id)), reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM generic_facts WHERE id = ?;", [.text(theirFact)]) == 1, "the namesake's fact is kept")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM generic_facts WHERE id = ?;", [.text(ourFact)]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM entities WHERE id = ?;", [.text(other)]) == 1, "the namesake is untouched")
        #expect(out.report.ambiguousFactsKept >= 1 && out.summary.contains("facts kept as ambiguous"))
    }

    @Test("A4: a hold on the case itself, or on one of its source versions, refuses the case erase; nothing changes")
    func caseAndVersionHolds() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let version = try #require(try await f.db.query("SELECT id FROM source_versions WHERE logical_source_id = ? LIMIT 1;", [.uuid(f.exclusiveFile)]).first?.string(0))
        for target in [f.caseA.uuidString, version] {
            let hold = UUID()
            try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("H"), .date(Date())])
            try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(target), .date(Date())])
            let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "r", legalBasis: nil, actor: "Tester")
            #expect(out.report.refused?.contains("legal hold") == true, "a hold on \(target) was missed")
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 1)
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1)
            try await f.db.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
        }
        // A refused erase leaves no operation record behind.
        let records = try FileManager.default.contentsOfDirectory(atPath: f.temp.path).filter { $0.hasPrefix(".case-erase-") }
        #expect(records.isEmpty)
    }

    @Test("A5: a case erase clears its drafts' captured legacy store, removes saved answers quoting its erased documents, and keeps others")
    func legacyAndAnswers() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let now = Date()
        let draft = UUID()
        try await f.db.exec("""
            INSERT INTO studio_records (id, studio, case_id, payload_json, payload_sha256, created_by, created_at, updated_by, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(draft), .text("siu"), .uuid(f.caseA), .text("{\"secret\":1}"), .text("h"), .text("T"), .date(now), .text("T"), .date(now)])
        try await f.db.exec("INSERT INTO studio_legacy_blobs (source_key, raw_blob, sha256, byte_count, captured_at) VALUES (?,?,?,?,?);",
                            [.text("legacy.siu"), .text("[{\"secret\":1}]"), .text("h"), .integer(14), .date(now)])
        try await f.db.exec("INSERT INTO studio_legacy_outcomes (source_key, element_index, record_id, outcome, detail, recorded_at) VALUES (?,?,?,?,?,?);",
                            [.text("legacy.siu"), .integer(0), .uuid(draft), .text("imported"), .text("ok"), .date(now)])
        // Two saved answers: one cites the exclusive (erased) document, one the shared (kept) one.
        let erasedKO = try await Self.firstKO(f.db, f.exclusiveFile), keptKO = try await Self.firstKO(f.db, f.sharedFile)
        var answerIDs: [String] = []
        for ko in [erasedKO, keptKO] {
            let a = UUID().uuidString, c = UUID().uuidString
            answerIDs.append(a)
            try await f.db.exec("INSERT INTO answers (id, question, answer_state, body, created_at) VALUES (?,?,?,?,?);", [.text(a), .text("q"), .text("verifiedFinal"), .text("quoted text"), .date(now)])
            try await f.db.exec("INSERT INTO answer_claims (id, answer_id, claim_text, support_status, created_at) VALUES (?,?,?,?,?);", [.text(c), .text(a), .text("quoted"), .text("supported"), .date(now)])
            try await f.db.exec("INSERT INTO claim_evidence (claim_id, object_id) VALUES (?,?);", [.text(c), .text(ko)])
        }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await f.db.query("SELECT raw_blob FROM studio_legacy_blobs WHERE source_key = 'legacy.siu';", []).first?.string(0) == "")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM studio_erasures WHERE record_id = ?;", [.uuid(draft)]) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.text(answerIDs[0])]) == 0, "the answer quoting the erased document is removed")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.text(answerIDs[1])]) == 1, "an answer from a kept document stays")
        #expect(out.report.answersRemoved == 1)
    }

    @Test("A5: a case erase interrupted after its ledger commit finishes its file steps at the next launch")
    func interruptedFileStepsResume() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let vault = EvidenceVault(root: f.temp.appendingPathComponent("EvidenceVault", isDirectory: true))
        let orphan = try await vault.store(Data("copy of an erased document".utf8))
        let kept = try await vault.store(Data("copy still used".utf8))
        let used = try #require(try await f.db.query("SELECT id FROM source_versions LIMIT 1;", []).first?.string(0))
        try await f.db.exec("PRAGMA foreign_keys = OFF;")
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE id = ?;", [.text(kept), .text(used)])
        try await f.db.exec("PRAGMA foreign_keys = ON;")
        // A record for an erased case (the case no longer exists) and one whose case still exists.
        let gone = UUID()
        let ledgerURL = f.temp.appendingPathComponent("case.sqlite")
        let recordGone = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: gone)
        try AppState.writeCaseEraseRecord(recordGone, vault: [orphan, kept], dropVectorCache: false)
        let recordLive = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: f.caseB)
        try AppState.writeCaseEraseRecord(recordLive, vault: [orphan], dropVectorCache: false)
        await AppState.resumePendingCaseErasures(besideLedgerAt: ledgerURL, database: f.db)
        #expect(await vault.contains(orphan) == false, "the erased case's copy is removed")
        #expect(await vault.contains(kept), "a copy a remaining version uses is never removed")
        #expect(!FileManager.default.fileExists(atPath: recordGone.path) && !FileManager.default.fileExists(atPath: recordLive.path))
    }

    // MARK: - B1 — fail-closed preparation and file steps

    static func caseRows(_ f: Fixture) async throws -> Int {
        try await count(f.db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)])
    }

    @Test("B1: a studio change that would not save stops the case erase before anything is deleted; work for another ledger does not")
    @MainActor
    func failedSaveStopsErase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        struct Down: Error {}
        // A studio on another ledger with a failed save: not this erase's concern.
        let elsewhere = StudioStorage(studio: "siu", legacyKey: "test.b1o.\(UUID().uuidString)")
        elsewhere.repositoryOverride = StudioRecordRepository(database: try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion))
        elsewhere.writeFault = { throw Down() }
        elsewhere.persist([SIUReferral(title: "Other ledger", now: Date())], app: nil)
        await elsewhere.flush()
        // A studio on this ledger with an unsaved draft not yet bound to any case: it may be this case's.
        let here = StudioStorage(studio: "siu", legacyKey: "test.b1h.\(UUID().uuidString)")
        here.repositoryOverride = StudioRecordRepository(database: f.db)
        here.writeFault = { throw Down() }
        here.persist([SIUReferral(title: "Unsaved here", now: Date())], app: nil)
        await here.flush()
        #expect(here.hasUnsavedChanges && elsewhere.hasUnsavedChanges)
        await #expect(throws: CaseErasureError.self) {
            _ = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        }
        #expect(try await Self.caseRows(f) == 1, "nothing was erased")
        #expect(here.hasUnsavedChanges, "the unsaved change is kept, not discarded")
        // Once it saves, the erase proceeds; the other ledger's failure never blocked it.
        here.writeFault = nil
        here.retry(app: nil)
        await here.flush()
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil && out.fileResidue.isEmpty)
        #expect(try await Self.caseRows(f) == 0)
        elsewhere.writeFault = nil
    }

    @Test("B1: an erase plan that cannot be written stops the erase; the case and its documents are untouched")
    func unwritablePlanStopsErase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ledgerURL = await f.db.url
        // A folder where the plan file must go makes the atomic write fail.
        let record = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: f.caseA)
        try FileManager.default.createDirectory(at: record.appendingPathComponent("block"), withIntermediateDirectories: true)
        let before = try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)])
        do {
            _ = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
            Issue.record("the erase must refuse without a durable plan")
        } catch let e as CaseErasureError {
            if case .preparationFailed = e {} else { Issue.record("unexpected \(e)") }
        }
        #expect(try await Self.caseRows(f) == 1)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == before)
    }

    @Test("B1: an unreadable or corrupt erase plan is reported as unfinished and kept; no file is removed")
    func corruptPlanKept() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ledgerURL = await f.db.url
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        let orphan = try await vault.store(Data("copy of an erased document b1".utf8))
        let gone = UUID()
        let record = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: gone)
        try Data("{not json".utf8).write(to: record)
        let pending = await AppState.resumePendingCaseErasures(besideLedgerAt: ledgerURL, database: f.db)
        #expect(pending[gone.uuidString]?.first?.contains("could not be read") == true, "\(pending)")
        #expect(FileManager.default.fileExists(atPath: record.path), "the record stays for a retry")
        let has1 = await vault.contains(orphan)
        #expect(has1)
        // Missing record (removed by hand between steps): also unfinished, not success.
        try FileManager.default.removeItem(at: record)
        let left = await AppState.finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: f.db)
        #expect(!left.isEmpty)
    }

    @Test("B1: when the shared-use check cannot be answered, the vault copy and the plan are kept and named")
    func sharedCheckFailureKeepsFile() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ledgerURL = await f.db.url
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        let copy = try await vault.store(Data("perhaps shared b1".utf8))
        let record = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: UUID())
        try AppState.writeCaseEraseRecord(record, vault: [copy], dropVectorCache: false)
        struct ReadFailed: Error {}
        let left = await AppState.finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: f.db,
                                                       isUsed: { _ in throw ReadFailed() })
        #expect(left.count == 1 && left[0].contains("could not check"))
        let has2 = await vault.contains(copy)
        #expect(has2, "a copy whose use is unknown is never removed")
        #expect(FileManager.default.fileExists(atPath: record.path))
        // The next attempt, with the ledger answering, finishes the work.
        let again = await AppState.finishCaseEraseFiles(record: record, ledgerURL: ledgerURL, database: f.db)
        let has3 = await vault.contains(copy)
        #expect(again.isEmpty && !has3 && !FileManager.default.fileExists(atPath: record.path))
    }

    @Test("B1: a crash after the ledger commit, before the file steps, resumes at launch; shared evidence survives")
    func crashBetweenCommitAndFilesResumes() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let ledgerURL = await f.db.url
        let vault = EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        // A vault copy for each of case A's documents: the exclusive one and the one case B shares.
        let exclusiveCopy = try await vault.store(Data("exclusive original b1".utf8))
        let sharedCopy = try await vault.store(Data("shared original b1".utf8))
        try await f.db.exec("PRAGMA foreign_keys = OFF;")
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE logical_source_id = ?;", [.text(exclusiveCopy), .uuid(f.exclusiveFile)])
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE logical_source_id = ?;", [.text(sharedCopy), .uuid(f.sharedFile)])
        try await f.db.exec("PRAGMA foreign_keys = ON;")
        let cache = ledgerURL.deletingLastPathComponent().appendingPathComponent("hnsw-index.bin")
        try Data("cache".utf8).write(to: cache)
        // The app's steps up to the commit; then the "crash": no file step runs.
        let answers = try #require(await f.state.investigationAnswers)
        let versions = try await answers.scopeContext(caseID: f.caseA).scope.authorizedSourceVersionIDs
        let candidates = try await CaseEraser(database: f.db).vaultCandidates(sourceVersionIDs: Set(versions))
        #expect(Set(candidates) == [exclusiveCopy, sharedCopy])
        let record = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: f.caseA)
        try AppState.writeCaseEraseRecord(record, vault: candidates, dropVectorCache: true)
        let report = try await CaseEraser(database: f.db).erase(caseID: f.caseA, sourceVersionIDs: Set(versions), eraseExclusiveSources: true,
                                                                reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil && report.sourcesErased == 1 && report.sourcesKeptShared == 1)
        let has4 = await vault.contains(exclusiveCopy)
        #expect(has4, "the crash left the copy behind")
        // Next launch.
        let pending = await AppState.resumePendingCaseErasures(besideLedgerAt: ledgerURL, database: f.db)
        #expect(pending.isEmpty, "\(pending)")
        let has5 = await vault.contains(exclusiveCopy)
        #expect(!has5, "the erased document's copy is removed")
        let has6 = await vault.contains(sharedCopy)
        #expect(has6, "the copy case B still uses survives")
        #expect(!FileManager.default.fileExists(atPath: cache.path) && !FileManager.default.fileExists(atPath: record.path))
    }
}

// MARK: - Living case map (v171)

extension CaseErasureTests {

    static func seedMapRows(_ db: Database, caseID: UUID, personID: UUID? = nil) async throws {
        try await db.exec("""
            INSERT INTO case_map_views (id, case_id, name, base_view, filters_json, ordinal, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text("secret view name"), .text("overview"), .text(#"{"search":"secret words"}"#), .integer(0), .text("Tester"), .real(1), .real(1)])
        try await db.exec("INSERT INTO case_map_layout (case_id, record_kind, record_id, x, y, pinned, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(caseID), .text("case"), .text(caseID.uuidString.lowercased()), .real(1), .real(2), .integer(1), .real(1)])
        try await db.exec("""
            INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text("dependsOn"), .text("case"), .text(caseID.uuidString.lowercased()), .text("allegation"),
                  .text(UUID().uuidString.lowercased()), .text("secret rationale"), .text("Tester"), .real(1)])
        if let personID {
            let pid = personID.uuidString.lowercased()
            try await db.exec("INSERT INTO case_map_layout (case_id, record_kind, record_id, x, y, pinned, updated_at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(caseID), .text("person"), .text(pid), .real(5), .real(6), .integer(0), .real(1)])
            try await db.exec("""
                INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text("attributedTo"), .text("case"), .text(caseID.uuidString.lowercased()), .text("person"),
                      .text(pid), .text("about the person"), .text("Tester"), .real(1)])
        }
    }

    static func mapRows(_ db: Database, _ caseID: UUID) async throws -> Int {
        var n = 0
        for t in ["case_map_views", "case_map_layout", "case_map_links"] { n += try await count(db, "SELECT COUNT(*) FROM \(t) WHERE case_id = ?;", [.uuid(caseID)]) }
        return n
    }

    @Test("Case map: a case erase removes its saved views, layout and links (a hold refuses and keeps them); another case's map rows stay")
    func caseEraseCoversMap() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        try await Self.seedMapRows(f.db, caseID: f.caseA)
        try await Self.seedMapRows(f.db, caseID: f.caseB)
        #expect(try await Self.mapRows(f.db, f.caseA) == 3)
        // A hold on the case refuses the erase: nothing goes.
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(f.caseA.uuidString), .date(Date())])
        let refused = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(refused.report.refused?.contains("legal hold") == true)
        #expect(try await Self.mapRows(f.db, f.caseA) == 3)
        try await f.db.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await Self.mapRows(f.db, f.caseA) == 0)
        #expect(try await Self.mapRows(f.db, f.caseB) == 3)
        let json = try #require(try await f.db.query("SELECT rows_json FROM case_erasures WHERE case_id = ?;", [.uuid(f.caseA)]).first?.string(0))
        #expect(json.contains("case_map_links") && !json.contains("secret"))
    }

    @Test("Case map: a person erase removes the map positions and links that point at their case-person rows; the case's other map rows stay")
    func personEraseCoversMap() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let entity = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let person = UUID()
        try await f.db.exec("INSERT INTO case_people (id, case_id, name, role, entity_id, created_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(person), .uuid(f.caseA), .text(row.string(1) ?? "x"), .text("witness"), .uuid(entity), .real(1)])
        try await Self.seedMapRows(f.db, caseID: f.caseA, personID: person)
        #expect(try await Self.mapRows(f.db, f.caseA) == 5)
        let out = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_map_layout WHERE record_kind = 'person';", []) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_map_links WHERE to_kind = 'person' OR from_kind = 'person';", []) == 0)
        #expect(try await Self.mapRows(f.db, f.caseA) == 3)
    }

    @Test("Case map: a full erase empties the map tables and the per-case workspace preference holding map state")
    func fullEraseCoversMap() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        try await Self.seedMapRows(f.db, caseID: f.caseA)
        var state = CaseWorkspaceState()
        var m = CaseMapWorkspaceMemory(); m.view = "people"; m.selectedNode = CaseMapNodeID(caseID: f.caseA, kind: .caseFile, id: f.caseA)
        state.map = m
        CaseWorkspaceStore.save(state, caseID: f.caseA, defaults: AppState.erasePreferences)
        _ = await f.state.deleteAllData()
        for t in ["case_map_views", "case_map_layout", "case_map_links"] {
            #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM \(t);", []) == 0, "\(t) not emptied")
        }
        #expect(AppState.erasePreferences.data(forKey: CaseWorkspaceStore.key(f.caseA)) == nil)
    }
}

// MARK: - Saved case searches (v172)

extension CaseErasureTests {

    static func seedSavedSearch(_ db: Database, caseID: UUID, words: String) async throws {
        try await db.exec("""
            INSERT INTO case_saved_searches (id, case_id, name, kind, query_text, query_version, query_json, options_json, scope_fingerprint,
                scope_versions_json, index_revision, executed_at, result_json, created_by, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text("secret search"), .text("live"), .text(words), .integer(1), .text("{}"), .text("{}"),
                  .text("fp"), .text("[]"), .text("v1-x"), .real(1), .text(#"{"names":{}}"#), .text("Tester"), .real(1)])
    }

    static func savedSearches(_ db: Database, _ caseID: UUID) async throws -> Int {
        try await count(db, "SELECT COUNT(*) FROM case_saved_searches WHERE case_id = ?;", [.uuid(caseID)])
    }

    @Test("Saved case searches: a case erase removes them (a hold refuses and keeps them); another case's stay")
    func caseEraseCoversSavedSearches() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        try await Self.seedSavedSearch(f.db, caseID: f.caseA, words: "secret words")
        try await Self.seedSavedSearch(f.db, caseID: f.caseB, words: "other words")
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(f.caseA.uuidString), .date(Date())])
        let refused = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(refused.report.refused?.contains("legal hold") == true)
        #expect(try await Self.savedSearches(f.db, f.caseA) == 1)
        try await f.db.exec("UPDATE legal_holds SET released_at = ? WHERE id = ?;", [.date(Date()), .uuid(hold)])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(try await Self.savedSearches(f.db, f.caseA) == 0)
        #expect(try await Self.savedSearches(f.db, f.caseB) == 1)
    }

    @Test("Saved case searches: a person erase removes the searches whose words name the person; others stay")
    func personEraseCoversSavedSearches() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let entity = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        try await Self.seedSavedSearch(f.db, caseID: f.caseA, words: "person:\"\(name)\" AND payment")
        try await Self.seedSavedSearch(f.db, caseID: f.caseA, words: "invoice")
        let out = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_saved_searches WHERE instr(lower(query_text), lower(?)) > 0;", [.text(name)]) == 0)
        #expect(try await Self.savedSearches(f.db, f.caseA) == 1)
    }

    @Test("Saved case searches: a full erase empties them")
    func fullEraseCoversSavedSearches() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        try await Self.seedSavedSearch(f.db, caseID: f.caseA, words: "secret words")
        _ = await f.state.deleteAllData()
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM case_saved_searches;", []) == 0)
    }
}

// MARK: - LS19: person erasure reaches the map's free text; names match across case and accents

extension CaseErasureTests {

    @Test("LS19: names match ignoring case and diacritics in any script; another name does not match")
    func unicodeNameMatch() {
        #expect(CaseEraser.names("met zoe muller on Monday", ["Zoë Müller"]))
        #expect(CaseEraser.names("ZOË MÜLLER signed", ["Zoë Müller"]))
        #expect(CaseEraser.names("Zoe\u{0308} Mu\u{0308}ller (decomposed)", ["zoë müller"]))
        #expect(CaseEraser.names("Иван ПЕТРОВ", ["петров"]))
        #expect(!CaseEraser.names("Zoe Miller", ["Zoë Müller"]))
        #expect(!CaseEraser.names(nil, ["Zoë Müller"]))
    }

    @Test("LS19: a person erase removes saved map views and saved searches naming them (accented name saved unaccented), clears recorded states naming them in content or milestone name to a stub, and reports link reasons it keeps")
    func personEraseCoversMapFreeText() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let entity = UUID()
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("Zoë Müller"), .text("zoë müller"), .text(try await Self.firstKO(f.db, f.exclusiveFile))])
        func view(_ name: String, _ filters: String) async throws {
            try await f.db.exec("""
                INSERT INTO case_map_views (id, case_id, name, base_view, filters_json, ordinal, created_by, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(f.caseA), .text(name), .text("overview"), .text(filters), .integer(0), .text("Tester"), .real(1), .real(1)])
        }
        try await view("ZOË MÜLLER timeline", "{}")
        try await view("Payments", #"{"search":"zoe muller"}"#)
        try await view("Invoices", #"{"search":"invoice"}"#)
        try await Self.seedSavedSearch(f.db, caseID: f.caseA, words: "zoe muller AND payment")
        try await Self.seedSavedSearch(f.db, caseID: f.caseA, words: "invoice")
        try await f.db.exec("""
            INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(f.caseA), .text("dependsOn"), .text("case"), .text(f.caseA.uuidString.lowercased()), .text("allegation"),
                  .text(UUID().uuidString.lowercased()), .text("Told to us by zoe muller"), .text("Tester"), .real(1)])
        let milestone = UUID(), named = UUID(), other = UUID()
        for (id, kind, label, payload) in [(milestone, "milestone", "Before the Zoe Müller interview" as String?, "{}"),
                                           (named, "manual", nil, #"{"items":[{"title":"zoe muller"}]}"#),
                                           (other, "manual", "Week 2" as String?, #"{"items":[{"title":"Invoice 7"}]}"#)] {
            try await f.db.exec("""
                INSERT INTO case_checkpoints (id, case_id, kind, name, fence, scope_fingerprint, content_digest, manifest_json, payload_json, format_version, recorded_by, recorded_at)
                VALUES (?,?,?,?,'f','s','d','{}',?,1,'Tester',1);
                """, [.uuid(id), .uuid(f.caseA), .text(kind), label.map { .text($0) } ?? .null, .text(payload)])
        }
        let out = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        let views = try await f.db.query("SELECT name FROM case_map_views WHERE case_id = ?;", [.uuid(f.caseA)]).compactMap { $0.string(0) }
        #expect(views == ["Invoices"])
        let searches = try await f.db.query("SELECT query_text FROM case_saved_searches WHERE case_id = ?;", [.uuid(f.caseA)]).compactMap { $0.string(0) }
        #expect(searches == ["invoice"])
        #expect(out.report.rowsErased["case_map_views"] == 2 && out.report.rowsErased["case_saved_searches"] == 1)
        // Recorded states: the two naming her are stubs (content and name gone); the other is untouched.
        for id in [milestone, named] {
            let r = try #require(try await f.db.query("SELECT name, payload_json, erased_at FROM case_checkpoints WHERE id = ?;", [.uuid(id)]).first)
            #expect(r.date(2) != nil && r.string(1) == "{}")
            #expect(!CaseEraser.names(r.string(0), ["Zoë Müller"]))
        }
        let milestoneName = try await f.db.query("SELECT name FROM case_checkpoints WHERE id = ?;", [.uuid(milestone)]).first?.string(0)
        #expect(milestoneName == CaseEraser.erasedCheckpointName)
        let kept = try #require(try await f.db.query("SELECT name, erased_at FROM case_checkpoints WHERE id = ?;", [.uuid(other)]).first)
        #expect(kept.string(0) == "Week 2" && kept.date(1) == nil)
        #expect(out.report.rowsErased["case_checkpoints (content cleared)"] == 2)
        // The link between other records keeps its reason (links are never edited) and is reported.
        #expect(out.report.stillNamedIn["case map link reasons"] == 1)
        #expect(out.summary.contains("case map link reasons"))
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM ledger_person_erase;", []) == 0)
    }

    @Test("LS23: the 'still named in' counts match the name ignoring case and accents — 'Zoë Müller' written 'zoe muller' in a saved answer, a document and a studio draft is counted; 'Zoe Miller' is not")
    func personEraseInventoryMatchesUnicode() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let now = Date()
        let entity = UUID()
        let ko = try await Self.firstKO(f.db, f.sharedFile)
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("Zoë Müller"), .text("zoë müller"), .text(ko)])
        // A document naming her without accents (originals are kept and counted, never edited).
        try await f.db.exec("UPDATE knowledge_objects SET content = coalesce(content, '') || ' Signed by ZOE MULLER.' WHERE id = ?;", [.text(ko)])
        for (body, n) in [("We met zoe muller on Monday.", 1), ("Zoe Miller is someone else.", 2)] {
            try await f.db.exec("INSERT INTO answers (id, question, answer_state, body, created_at) VALUES (?,?,?,?,?);",
                                [.text(UUID().uuidString), .text("q\(n)"), .text("verifiedFinal"), .text(body), .date(now)])
        }
        for payload in [#"{"note":"interview zoe muller"}"#, #"{"note":"interview Zoe Miller"}"#] {
            try await f.db.exec("""
                INSERT INTO studio_records (id, studio, case_id, payload_json, payload_sha256, created_by, created_at, updated_by, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .text("siu"), .uuid(f.caseB), .text(payload), .text("h"), .text("T"), .date(now), .text("T"), .date(now)])
        }
        // More rows than one page, so the paged scan crosses a page boundary.
        for i in 0..<(CaseEraser.namingPageSize + 5) {
            try await f.db.exec("INSERT INTO answers (id, question, answer_state, body, created_at) VALUES (?,?,?,?,?);",
                                [.text(UUID().uuidString), .text("filler \(i)"), .text("verifiedFinal"), .text("unrelated \(i)"), .date(now)])
        }
        try await f.db.exec("INSERT INTO answers (id, question, answer_state, body, created_at) VALUES (?,?,?,?,?);",
                            [.text(UUID().uuidString), .text("last"), .text("verifiedFinal"), .text("Zoe\u{0308} Mu\u{0308}ller, decomposed"), .date(now)])
        let out = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        #expect(out.report.documentsStillNaming == 1)
        #expect(out.report.stillNamedIn["saved answers"] == 2, "the plain and the decomposed answer; not the Zoe Miller one")
        #expect(out.report.stillNamedIn["studio drafts"] == 1)
    }
}

// MARK: - SEC-07 / TEAM-08 reminders and RECOVERY-06 erasure register

/// A notification centre the test can see into (the real one is never touched by the test host).
nonisolated final class FakeReminderCenter: CaseReminderCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [(id: String, title: String)]
    private var _delivered: [(id: String, title: String)]
    init(pending: [(id: String, title: String)], delivered: [(id: String, title: String)]) { _pending = pending; _delivered = delivered }
    var pendingIDs: [String] { lock.withLock { _pending.map(\.id) } }
    var deliveredIDs: [String] { lock.withLock { _delivered.map(\.id) } }
    func pending() async -> [(id: String, title: String)] { lock.withLock { _pending } }
    func delivered() async -> [(id: String, title: String)] { lock.withLock { _delivered } }
    func removePending(_ ids: [String]) { lock.withLock { _pending.removeAll { ids.contains($0.id) } } }
    func removeDelivered(_ ids: [String]) { lock.withLock { _delivered.removeAll { ids.contains($0.id) } } }
}

extension CaseErasureTests {

    @Test("SEC-07/TEAM-08: reminders name nothing; erasing a case removes its pending and shown reminders, a person erase removes old titled ones, a full erase removes all")
    func remindersFollowErasure() async throws {
        #expect(CaseReminders.title == "A case task is due today" && !CaseReminders.body.contains("\\("))
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let a = CaseReminders.prefix(f.caseA), b = CaseReminders.prefix(f.caseB)
        let center = FakeReminderCenter(
            pending: [(a + "t1", CaseReminders.title), (b + "t2", CaseReminders.title), (b + "t3", "Due today: Interview Roberts"), ("other-app-thing", "x")],
            delivered: [(a + "t0", "Due today: Call the whistleblower"), (b + "t4", CaseReminders.title)])
        try await CaseReminders.$center.withValue(center) {
            let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Tester")
            #expect(out.report.refused == nil)
            #expect(!center.pendingIDs.contains { $0.hasPrefix(a) } && !center.deliveredIDs.contains { $0.hasPrefix(a) }, "case A's reminders went with it")
            #expect(center.pendingIDs.contains(b + "t2") && center.deliveredIDs.contains(b + "t4"), "case B's are kept")
            // A person erase: a reminder an older build wrote with a title (it may name them) goes; content-free ones stay.
            let entity = try #require(try await f.db.query("SELECT id FROM entities WHERE kind = 'person' LIMIT 1;", []).first?.string(0).flatMap(UUID.init(uuidString:)))
            let person = try await f.state.erasePerson(entity, reason: "Subject request", legalBasis: nil, actor: "Tester")
            #expect(person.report.refused == nil)
            #expect(!center.pendingIDs.contains(b + "t3") && center.pendingIDs.contains(b + "t2"))
            _ = await f.state.deleteAllData()
            #expect(center.pendingIDs == ["other-app-thing"] && center.deliveredIDs.isEmpty, "a full erase removes every case reminder, nothing else")
        }
    }

    @Test("RECOVERY-06: back up, erase a case, restore the backup — the case does not come back; the register holds hashes only")
    func restoreDoesNotResurrectErasedCase() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        // 1. A complete backup while case A exists (its documents travel with it).
        let originals = try await f.db.query("SELECT id, url FROM files;", []).compactMap { r -> (fileID: UUID, url: URL)? in
            guard let id = r.string(0).flatMap(UUID.init(uuidString:)), let u = r.string(1).flatMap(URL.init(string:)) else { return nil }
            return (id, u)
        }
        let snapDir = f.temp.appendingPathComponent("snap", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = f.temp.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: originals, notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970 - 60)
        // 2. Erase case A (and the document only it used).
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil && out.fileResidue.isEmpty, "\(out.fileResidue)")
        let ledger = f.temp.appendingPathComponent("case.sqlite")
        let raw = try String(contentsOf: ErasureRegister.url(besideLedgerAt: ledger), encoding: .utf8)
        #expect(raw.contains(ErasureRegister.hash(f.caseA)))
        #expect(!raw.contains(f.caseA.uuidString) && !raw.contains(f.caseA.uuidString.lowercased()) && !raw.contains("secret") && !raw.contains("Case A"),
                "identifiers by hash only, no titles")
        // 3. Restore the older backup into the ledger's folder on another launch: the register beside the ledger
        //    is not part of the backup, so the restore leaves it in place.
        let mac = f.temp.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let restoredLedger = mac.appendingPathComponent("knowledge.sqlite")
        try FileManager.default.copyItem(at: ErasureRegister.url(besideLedgerAt: ledger), to: ErasureRegister.url(besideLedgerAt: restoredLedger))
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: mac)
        #expect(try ErasureRegister.load(besideLedgerAt: restoredLedger).entries.count == 1, "the restore did not replace the register")
        let check = try Database(url: restoredLedger, key: LedgerKeychain.load())
        #expect(try await Self.count(check, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 1,
                "the backup itself still holds case A (the defect: without the register it would come back)")
        let exclusiveURL = try #require(try await check.query("SELECT url FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]).first?.string(0).flatMap(URL.init(string:)))
        #expect(FileManager.default.fileExists(atPath: exclusiveURL.path), "the backup restored the erased document's original")
        await check.close()
        // 4. The ledger opens: case A is erased again before anything is shown; case B is untouched.
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: restoredLedger)
        guard case .ready = await state.phase, let db = await state.database else { Issue.record("restored ledger did not open"); return }
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseA)]) == 0, "the erased case did not come back")
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;", [.uuid(f.caseB)]) == 1)
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM case_actions WHERE case_id = ?;", [.uuid(f.caseA)]) == 0)
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 0, "its own document is erased again")
        #expect(!FileManager.default.fileExists(atPath: exclusiveURL.path), "and the restored copy of that original is removed from disk")
        #expect(try await Self.count(db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.sharedFile)]) == 1, "the shared document stays")
        let notice = await state.restoreNotice
        #expect(notice?.contains("erased again") == true, "\(notice ?? "nil")")
        // Opening again changes nothing more.
        let again = await state.applyErasureRegister()
        #expect(again == nil)
    }

    @Test("RECOVERY-06: a backup made before a full erase is refused at restore; the ledger is unchanged; an unreadable register refuses too")
    func restoreOlderThanFullEraseRefused() async throws {
        defer { PendingRestore.cancel() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let snap = dir.appendingPathComponent("snap.sqlite")
        try await db.backupSnapshot(to: snap)
        let backup = dir.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: [], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1_000)
        let live = dir.appendingPathComponent("live", isDirectory: true).appendingPathComponent("knowledge.sqlite")
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current ledger".utf8).write(to: live)
        try ErasureRegister.record(.init(kind: .full, idHash: nil, eraseSources: nil, erasedAt: 2_000), besideLedgerAt: live)
        #expect(PendingRestore.schedule(backupFolder: backup) == nil)
        guard case .failed(let why) = await PendingRestore.performIfScheduled(databaseURL: live, recoveryKey: nil) else {
            Issue.record("a backup older than a full erase was restored"); return
        }
        #expect(why.contains("made before all data was erased"))
        #expect(try String(contentsOf: live, encoding: .utf8) == "current ledger", "the ledger was not touched")
        #expect(!PendingRestore.isScheduled)
        // A backup made after the full erase is not refused by the register.
        #expect(ErasureRegister.refusal(backupCreatedAt: 3_000, besideLedgerAt: live) == nil)
        // An unreadable register is never read as "nothing erased".
        try Data("{not json".utf8).write(to: ErasureRegister.url(besideLedgerAt: live))
        #expect(ErasureRegister.refusal(backupCreatedAt: 3_000, besideLedgerAt: live)?.contains("could not be read") == true)
        #expect(throws: ErasureRegister.RegisterError.self) { try ErasureRegister.record(.init(kind: .case, idHash: "x", erasedAt: 1), besideLedgerAt: live) }
    }
}

// MARK: - LS26 — "Stop and forget everything from this folder" and the vault copies

extension CaseErasureTests {

    /// Log lines of this process since `start` containing `needle` (nil when the log store cannot be read).
    nonisolated static func ls26LogLines(_ needle: String, since start: Date) -> Int? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: start)) else { return nil }
        var n = 0
        for case let e as OSLogEntryLog in entries where e.composedMessage.contains(needle) { n += 1 }
        return n
    }

    struct LS26CheckFailed: LocalizedError {
        let marker: String
        var errorDescription: String? { marker }
    }

    /// Ingest `texts` into a fresh subfolder of the fixture; each file's source versions are pointed at its own
    /// vault copy (stored here) so the test controls which copy each file uses.
    static func ls26Folder(_ f: Fixture, _ name: String, _ texts: [String]) async throws -> (root: URL, ids: [UUID], copies: [String]) {
        let ingest = try #require(await f.state.ingest)
        let dir = f.temp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = EvidenceVault(root: f.temp.appendingPathComponent("EvidenceVault", isDirectory: true))
        var ids: [UUID] = [], copies: [String] = []
        var root: URL?
        for (i, text) in texts.enumerated() {
            let url = dir.appendingPathComponent("file-\(i).txt")
            try Data("\(name) file \(i): \(text)".utf8).write(to: url)
            let record = try await ingest.ingest(fileAt: url).fileRecord
            ids.append(record.id)
            root = record.url.deletingLastPathComponent()
            copies.append(try await vault.store(Data("vault copy of \(name) \(i): \(text)".utf8)))
        }
        try await f.db.exec("PRAGMA foreign_keys = OFF;")
        for (id, copy) in zip(ids, copies) {
            try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE logical_source_id = ?;", [.text(copy), .uuid(id)])
        }
        try await f.db.exec("PRAGMA foreign_keys = ON;")
        return (try #require(root), ids, copies)
    }

    @Test("LS26: Stop and forget removes the folder's unshared vault copies and their opened copies, keeps shared ones, and counts back")
    func forgetFolderRemovesUnsharedCopies() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let files = try #require(await f.state.files)
        let ledgerURL = await f.db.url
        let vault = EvidenceVault(root: f.temp.appendingPathComponent("EvidenceVault", isDirectory: true))
        // Three files: one used only here, one whose copy a document outside the folder also uses, one a case names.
        let folder = try await Self.ls26Folder(f, "forget", ["only here", "also outside", "named by a case"])
        let only = folder.copies[0], shared = folder.copies[1], inCase = folder.copies[2]
        try await f.db.exec("PRAGMA foreign_keys = OFF;")
        try await f.db.exec("UPDATE source_versions SET content_hash = ? WHERE logical_source_id = ?;", [.text(shared), .uuid(f.exclusiveFile)])
        try await f.db.exec("PRAGMA foreign_keys = ON;")
        try await f.db.exec("""
            INSERT INTO investigation_case_sources (id, case_id, source_ref, source_kind, in_scope, note, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(f.caseB), .uuid(folder.ids[2]), .text("logicalSource"), .integer(1), .null, .real(1)])
        // An opened copy of the unshared original (what viewing it leaves behind).
        let opened = try #require(await vault.url(for: only, filename: "only.txt"))
        #expect(FileManager.default.fileExists(atPath: opened.path))

        let outcome = try await AppState.forgetFolder(rootURL: folder.root, ledgerURL: ledgerURL, database: f.db, files: files)
        #expect(outcome.filesForgotten == 3)
        #expect(outcome.files.removed == 1, "\(outcome)")
        #expect(outcome.files.keptInUse == 2, "\(outcome)")
        #expect(outcome.files.left.isEmpty && outcome.pendingID == nil, "\(outcome)")
        #expect(outcome.summary.contains("Removed 1 stored") && outcome.summary.contains("Kept 2 stored"), "\(outcome.summary)")
        let hasOnly = await vault.contains(only)
        let hasShared = await vault.contains(shared)
        let hasInCase = await vault.contains(inCase)
        #expect(!hasOnly, "the copy only the folder used is removed")
        #expect(hasShared, "a copy another remaining source uses is kept")
        #expect(hasInCase, "a copy a case still names is kept")
        #expect(!FileManager.default.fileExists(atPath: opened.path), "its opened copy goes with it")
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE url LIKE ?;", [.text(folder.root.absoluteString + "%")]) == 0)
        #expect(try await Self.count(f.db, "SELECT COUNT(*) FROM files WHERE id = ?;", [.uuid(f.exclusiveFile)]) == 1, "files outside the folder stay")
        let records = try FileManager.default.contentsOfDirectory(atPath: f.temp.path).filter { $0.hasPrefix(".case-erase-") }
        #expect(records.isEmpty, "the plan is dropped once the file step is done: \(records)")
    }

    @Test("LS26: a failed shared-use check keeps the copy, is logged and reported, and is finished at the next launch")
    func forgetFolderFailedCheckIsLoggedAndResumed() async throws {
        let f = try await Self.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let files = try #require(await f.state.files)
        let ledgerURL = await f.db.url
        let vault = EvidenceVault(root: f.temp.appendingPathComponent("EvidenceVault", isDirectory: true))
        let folder = try await Self.ls26Folder(f, "forget-fail", ["unshared"])
        let start = Date()
        let marker = "LS26-check-\(UUID().uuidString)"
        let outcome = try await AppState.forgetFolder(rootURL: folder.root, ledgerURL: ledgerURL, database: f.db, files: files,
                                                      isUsed: { _ in throw LS26CheckFailed(marker: marker) })
        #expect(outcome.filesForgotten == 1 && outcome.files.removed == 0 && outcome.files.keptInUse == 0)
        #expect(outcome.files.left.count == 1 && outcome.files.left[0].contains("could not check"), "\(outcome)")
        #expect(outcome.summary.contains("Not removed yet"), "\(outcome.summary)")
        let pendingID = try #require(outcome.pendingID)
        let hasCopy = await vault.contains(folder.copies[0])
        #expect(hasCopy, "a copy whose use is unknown is never removed")
        let logged = Self.ls26LogLines(marker, since: start)
        #expect(logged != nil, "the process log could be read")
        #expect((logged ?? 0) >= 1, "the failed check is logged")
        // The next launch finishes it from the recorded plan: the forgotten files no longer count as users.
        let pending = await AppState.resumePendingCaseErasures(besideLedgerAt: ledgerURL, database: f.db)
        #expect(pending[pendingID] == nil && pending.isEmpty, "\(pending)")
        let stillThere = await vault.contains(folder.copies[0])
        #expect(!stillThere, "the copy is removed at the next launch")
        let record = AppState.caseEraseRecordURL(besideLedgerAt: ledgerURL, caseID: try #require(UUID(uuidString: pendingID)))
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }
}
