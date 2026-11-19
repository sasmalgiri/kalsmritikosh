//
//  CaseAskConversationTests.swift
//  KalsmritikoshTests
//
//  Candidate review LS24 — Ask inside a case keeps its own conversation (v174 conversations.case_id):
//  opening Ask on another case or on the whole library never shows it; reopening the case resumes it.
//  Erasing the case removes its question and answer turns and every answer made in it (a refused one
//  and one citing a document another case shares included); library questions and another case's stay.
//  A legal hold refuses the erase with nothing removed. A pre-v174 conversation stays a library one.
//  No network: case questions take the offline path (no AI reader installed).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Ask conversations bound to their case (LS24)", .serialized)
struct CaseAskConversationTests {

    typealias Fixture = CaseErasureTests.Fixture

    static func count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
        Int(try await db.query(sql, b).first?.int(0) ?? -1)
    }

    /// One question asked the way AskView asks it: the scope's conversation, the user turn, the answer
    /// (the case's own answering path in a case), the assistant turn, the saved answer stamped with the
    /// case, and the turn linked to it. Returns (conversation id, saved answer id).
    @discardableResult
    static func ask(_ f: Fixture, caseID: UUID?, _ question: String, answer given: VerifiedAnswer? = nil) async throws -> (UUID, UUID) {
        let repo = try #require(await f.state.conversations)
        let (conv, _) = try await repo.resumeOrCreate(caseID: caseID)
        try await repo.appendTurn(ConversationTurn(conversationID: conv.id, ordinal: try await repo.nextOrdinal(for: conv.id), role: .user, body: question))
        let answer: VerifiedAnswer
        if let given {
            answer = given
        } else if let caseID {
            let ws = try #require(try await f.db.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.uuid(0))
            answer = await f.state.answerInCase(AskCaseScope(caseID: caseID, workspaceID: ws, title: "Case"), question: question)
        } else {
            answer = VerifiedAnswer(body: "Library answer to \(question)", citations: [], confidence: .zero, refused: false)
        }
        let turn = ConversationTurn(conversationID: conv.id, ordinal: try await repo.nextOrdinal(for: conv.id), role: .assistant, body: answer.body)
        try await repo.appendTurn(turn)
        let saved = try #require(await f.state.recordAnswer(question: question, answer: answer, originScopeID: caseID))
        try await repo.linkAnswer(turnID: turn.id, answerLedgerID: saved)
        return (conv.id, saved)
    }

    @Test("Case A's question is not shown when Ask opens on case B or on the whole library; case A's conversation resumes for case A")
    func askIsScopedToItsCase() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = try #require(await f.state.conversations)
        let (library, _) = try await Self.ask(f, caseID: nil, "library question about the press release")
        // Case A's conversation is the most recent conversation of all (the old Ask resumed it everywhere).
        let (convA, _) = try await Self.ask(f, caseID: f.caseA, "case A secret question about Wyko")

        let (onB, turnsB) = try await repo.resumeOrCreate(caseID: f.caseB)
        #expect(onB.id != convA && onB.id != library && onB.caseID == f.caseB && turnsB.isEmpty, "Ask on case B opens a new case B conversation")
        let historyB = try await repo.recent(limit: 200, caseID: f.caseB)
        #expect(historyB.map(\.id) == [onB.id], "case B's history lists only case B's conversation")

        let (onLibrary, turnsLibrary) = try await repo.resumeOrCreate(caseID: nil)
        #expect(onLibrary.id == library && onLibrary.caseID == nil)
        #expect(!turnsLibrary.contains { $0.body.contains("case A secret") }, "\(turnsLibrary.map(\.body))")
        #expect(turnsLibrary.first?.body == "library question about the press release")
        let libraryList = try await repo.recent(limit: 200, caseID: nil)
        #expect(!libraryList.contains { $0.id == convA })

        let (onA, turnsA) = try await repo.resumeOrCreate(caseID: f.caseA)
        #expect(onA.id == convA && onA.caseID == f.caseA, "case A's conversation resumes for case A")
        #expect(turnsA.first?.body == "case A secret question about Wyko" && turnsA.count == 2)
        // A second question in case A goes into the same conversation.
        let (again, _) = try await Self.ask(f, caseID: f.caseA, "case A follow-up")
        let turnsAfter = try await repo.turns(for: convA)
        #expect(again == convA && turnsAfter.count == 4)
    }

    /// Erasure fixture: case A's asked question (real case path), a refused case A answer, a case A answer
    /// citing the document case B shares; a library question citing the same shared document; a case B question.
    struct Asked { let convA: UUID; let caseAAnswers: [UUID]; let library: UUID; let libraryAnswer: UUID; let convB: UUID; let caseBAnswer: UUID }

    static func seed(_ f: Fixture) async throws -> Asked {
        let sharedKO = try await CaseErasureTests.firstKO(f.db, f.sharedFile)
        func citeShared(_ answer: UUID) async throws {
            let claim = UUID()
            try await f.db.exec("INSERT INTO answer_claims (id, answer_id, claim_text, support_status, created_at) VALUES (?,?,?,?,?);",
                                [.uuid(claim), .uuid(answer), .text("shared passage"), .text("supported"), .date(Date())])
            try await f.db.exec("INSERT INTO claim_evidence (claim_id, object_id) VALUES (?,?);", [.uuid(claim), .text(sharedKO)])
        }
        let (convA, asked) = try await ask(f, caseID: f.caseA, "case A: who signed the decision?")
        let (_, refused) = try await ask(f, caseID: f.caseA, "case A: what was never written down?",
                                         answer: AskCaseScope.failure("the ledger isn't ready yet."))
        let (_, sharedCiting) = try await ask(f, caseID: f.caseA, "case A: what does the shared decision say?",
                                              answer: VerifiedAnswer(body: "The decision says…", citations: [], confidence: .zero, refused: false))
        try await citeShared(sharedCiting)
        let (library, libraryAnswer) = try await ask(f, caseID: nil, "library: what does the decision say?")
        try await citeShared(libraryAnswer)
        let (convB, caseBAnswer) = try await ask(f, caseID: f.caseB, "case B: when was the decision made?",
                                                 answer: VerifiedAnswer(body: "Case B answer", citations: [], confidence: .zero, refused: false))
        return Asked(convA: convA, caseAAnswers: [asked, refused, sharedCiting], library: library, libraryAnswer: libraryAnswer,
                     convB: convB, caseBAnswer: caseBAnswer)
    }

    @Test("Erasing case A removes its turns and in-case answers (a refused one and one citing a shared document included); the library question and case B's stay")
    func caseErasureRemovesCaseAsk() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let s = try await Self.seed(f)
        let c1 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?;", [.uuid(s.convA)])
        #expect(c1 == 6)
        for a in s.caseAAnswers {
            let origin = try await f.db.query("SELECT origin_scope_id FROM answers WHERE id = ?;", [.uuid(a)]).first?.uuid(0)
            #expect(origin == f.caseA, "the in-case answer is stamped with the case")
        }

        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        let c2 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversations WHERE id = ? OR case_id = ?;", [.uuid(s.convA), .uuid(f.caseA)])
        #expect(c2 == 0)
        let c3 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?;", [.uuid(s.convA)])
        #expect(c3 == 0)
        let c4 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE body LIKE 'case A:%';")
        #expect(c4 == 0, "no case A question survives")
        for a in s.caseAAnswers {
            let c5 = try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(a)])
            #expect(c5 == 0, "in-case answer \(a) kept")
            let c6 = try await Self.count(f.db, "SELECT COUNT(*) FROM answer_claims WHERE answer_id = ?;", [.uuid(a)])
            #expect(c6 == 0)
        }
        let c7 = try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE origin_scope_id = ?;", [.uuid(f.caseA)])
        #expect(c7 == 0)
        #expect(out.report.answersRemoved >= 3 && (out.report.rowsErased["conversation_turns"] ?? 0) == 6, "\(out.report.rowsErased)")
        // Kept: the library question (it cites the same shared document) and case B's.
        let c8 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?;", [.uuid(s.library)])
        #expect(c8 == 2)
        let c9 = try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(s.libraryAnswer)])
        #expect(c9 == 1)
        let c10 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?;", [.uuid(s.convB)])
        #expect(c10 == 2)
        let c11 = try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(s.caseBAnswer)])
        #expect(c11 == 1)
        let repo = try #require(await f.state.conversations)
        let listB = try await repo.recent(limit: 10, caseID: f.caseB)
        #expect(listB.map(\.id) == [s.convB])
        // The erasure record names the kinds and counts only, never the question text.
        let json = try #require(try await f.db.query("SELECT rows_json FROM case_erasures WHERE case_id = ?;", [.uuid(f.caseA)]).first?.string(0))
        #expect(json.contains("conversation_turns") && !json.contains("signed the decision"))
    }

    @Test("A legal hold on the case refuses the erase; its conversation, turns and answers are all kept")
    func holdRefusesCaseAskErasure() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let s = try await Self.seed(f)
        let hold = UUID()
        try await f.db.exec("INSERT INTO legal_holds (id, name, created_at) VALUES (?,?,?);", [.uuid(hold), .text("Hold"), .date(Date())])
        try await f.db.exec("INSERT INTO legal_hold_items (hold_id, object_id, created_at) VALUES (?,?,?);", [.uuid(hold), .text(f.caseA.uuidString), .date(Date())])
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused?.contains("legal hold") == true && out.report.erasureID == nil, "\(out.report.refused ?? "")")
        let c12 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversations WHERE id = ? AND case_id = ?;", [.uuid(s.convA), .uuid(f.caseA)])
        #expect(c12 == 1)
        let c13 = try await Self.count(f.db, "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?;", [.uuid(s.convA)])
        #expect(c13 == 6)
        for a in s.caseAAnswers {
            let c14 = try await Self.count(f.db, "SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(a)])
            #expect(c14 == 1)
        }
    }

    @Test("v174 from a v173 ledger: an existing conversation and its turns are kept as a library conversation")
    func migrationKeepsOldConversationsInLibrary() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 173)
        let conv = UUID(), turn = UUID()
        try await db.exec("INSERT INTO conversations (id, started_at, title) VALUES (?,?,?);", [.uuid(conv), .date(Date()), .text("Old question")])
        try await db.exec("INSERT INTO conversation_turns (id, conversation_id, ordinal, role, body, created_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(turn), .uuid(conv), .integer(0), .text("user"), .text("an old question"), .date(Date())])
        try await SchemaMigrations.migrate(db)
        let version = try await db.currentUserVersion()
        #expect(version == SchemaMigrations.latestVersion)
        let migratedCase = try await db.query("SELECT case_id FROM conversations WHERE id = ?;", [.uuid(conv)]).first?.string(0)
        #expect(migratedCase == nil)
        let repo = ConversationsRepository(database: db)
        let library = try await repo.recent(limit: 10, caseID: nil)
        #expect(library.map(\.id) == [conv] && library.first?.caseID == nil)
        let inCase = try await repo.recent(limit: 10, caseID: UUID())
        #expect(inCase.isEmpty, "an old conversation is never shown inside a case")
        let (resumed, turns) = try await repo.resumeOrCreate(caseID: nil)
        #expect(resumed.id == conv && turns.map(\.body) == ["an old question"])
        let integrity = try await MigrationFaultHarness.integrityOK(db)
        #expect(integrity)
    }
}
