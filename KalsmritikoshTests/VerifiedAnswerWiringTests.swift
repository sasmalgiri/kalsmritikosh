//
//  VerifiedAnswerWiringTests.swift
//  KalsmritikoshTests
//
//  P1 — the verified answer composer through the real pipeline: offline (no reader, or a reader that
//  sends nothing) the answer is byte-identical to today; with a reader the archive brain AND the
//  case-scoped brain (through AppState's one reader holder) answer from verified claims; an unreadable
//  reply leaves the evidence-only answer, flagged. A fake reader stands in for the provider.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Verified answer composer — wiring on the archive and in-case brains", .serialized)
struct VerifiedAnswerWiringTests {
    typealias C = VerifiedAnswerComposer

    actor Calls { var n = 0; func add() { n += 1 } }

    static let documents: [(file: String, text: String)] = [
        ("inspection-report.txt", """
        Inspection Report

        The inspection of the Riverside plant on March 3, 2021 found Listeria in two of the five samples taken from the packing line. \
        The plant manager ordered the packing line closed the same day.
        """),
        ("budget-memo.txt", """
        Quarterly Budget Memo

        The finance office approved a budget of $250,000 for new equipment on June 9, 2020.
        """),
    ]
    static let question = "What did the inspection of the Riverside plant find?"
    static let sentence = "found Listeria in two of the five samples taken from the packing line"

    /// A reader that quotes the passage holding the inspection finding.
    static func fakeReader(_ calls: Calls) -> C {
        C { prompt, _ in
            await calls.add()
            let parts = prompt.components(separatedBy: "\n[Passage ")
            guard let hit = parts.dropFirst().first(where: { $0.contains(Self.sentence) }),
                  let n = Int(hit.prefix { $0.isNumber }) else { return #"{"status":"not_stated","claims":[],"answer":""}"# }
            return #"{"status":"answered","claims":[{"text":"The inspection found Listeria in two of the five samples taken from the packing line.","quote":"\#(Self.sentence)","passage":\#(n)}],"answer":"Listeria was found."}"#
        }
    }

    static func withArchive(_ body: (AppState, Database, [UUID]) async throws -> Void) async throws {
        await SharedSettingsLock.shared.acquire()
        defer { Task { await SharedSettingsLock.shared.release() } }
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = previous
        settings["kalsmritikosh.privacy.offlineNoLLM"] = true
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pj-verified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("verified.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            Issue.record("ledger did not boot"); return
        }
        var files: [UUID] = []
        for d in documents {
            let url = temp.appendingPathComponent(d.file)
            try d.text.write(to: url, atomically: true, encoding: .utf8)
            files.append(try await ingest.ingest(fileAt: url).fileRecord.id)
        }
        try await body(state, db, files)
    }

    static func same(_ a: VerifiedAnswer, _ b: VerifiedAnswer) -> Bool {
        a.body == b.body && a.answerText == b.answerText && a.citations == b.citations && a.confidence == b.confidence
            && a.refused == b.refused && a.refusalReason == b.refusalReason && a.intentKind == b.intentKind
    }

    @Test("Offline the answer is byte-identical; with a reader the archive brain ships verified claims; garbage is flagged")
    func archiveBrain() async throws {
        try await Self.withArchive { state, _, _ in
            let brain = await state.brain
            let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
            #expect(await brain.installedReaders.composer == false, "boot installs no composer while document reading is off")
            let first = await brain.answer(question: Self.question, access: access)
            let second = await brain.answer(question: Self.question, access: access)
            try #require(Self.same(first, second), "the fixture answers deterministically")
            #expect(C.writer(of: first) == "rules")

            // No reader at all, and a reader that sends nothing: unchanged.
            await brain.setCloudReaders(CloudReaders())
            #expect(Self.same(await brain.answer(question: Self.question, access: access), first))
            await brain.setCloudReaders(CloudReaders(answerComposer: C { _, _ in throw C.NotSent("Online is off") }, modelsAllowedOverride: true))
            #expect(Self.same(await brain.answer(question: Self.question, access: access), first))

            // A reader: the answer is the verified claim, with its source and the truthful receipt.
            let calls = Calls()
            await brain.setCloudReaders(CloudReaders(answerComposer: Self.fakeReader(calls), modelsAllowedOverride: true))
            let read = await brain.answer(question: Self.question, access: access)
            #expect(C.writer(of: read) == "ai-verified", "body: \(read.body)")
            #expect(read.body.hasPrefix("The inspection found Listeria in two of the five samples taken from the packing line."))
            #expect(read.body.contains("inspection-report.txt"))
            #expect(read.body.contains("every quote checked against its source"))
            #expect(!read.body.contains("no model was consulted"))
            #expect(!read.body.contains("Listeria was found."), "the model's own prose is never shown")
            #expect(await calls.n == 1)

            // An unreadable reply: the evidence-only answer, said so.
            await brain.setCloudReaders(CloudReaders(answerComposer: C { _, _ in "<<garbage>>" }, modelsAllowedOverride: true))
            let failed = await brain.answer(question: Self.question, access: access)
            #expect(C.writer(of: failed) == "rules-ai-failed")
            #expect(failed.citations == first.citations)
        }
    }

    @Test("The case-scoped brain gets the same readers through AppState's holder, and only offline answers without them")
    func inCaseBrain() async throws {
        try await Self.withArchive { state, db, files in
            let now = Date()
            let ws = UUID()
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                              [.uuid(ws), .text("Riverside"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            try await (try #require(await state.workspaceSourceCoordinator)).addSources(Set(files), to: ws, at: now)
            let c = try await (try #require(await state.investigationCases)).createCase(workspaceID: ws, title: "Riverside", actor: "test", at: now)
            _ = try await (try #require(await state.investigationWorkspaceIntake)).includeWorkspaceSources(caseID: c.id, actor: "test", at: now)
            let service = try #require(await state.investigationAnswers)
            let access = SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .retrieval))

            let offline = try await service.answer(caseID: c.id, question: Self.question, access: access).verified
            #expect(C.writer(of: offline) == "rules")

            let calls = Calls()
            state.cloudReaderHolder.set(CloudReaders(answerComposer: Self.fakeReader(calls), modelsAllowedOverride: true))
            let read = try await service.answer(caseID: c.id, question: Self.question, access: access).verified
            #expect(C.writer(of: read) == "ai-verified", "body: \(read.body)")
            #expect(await calls.n == 1, "the case-scoped brain called the reader")

            state.cloudReaderHolder.set(CloudReaders())
            let again = try await service.answer(caseID: c.id, question: Self.question, access: access).verified
            #expect(C.writer(of: again) == "rules")
            #expect(again.body == offline.body)
        }
    }
}
