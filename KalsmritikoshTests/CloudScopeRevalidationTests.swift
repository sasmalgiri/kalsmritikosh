//
//  CloudScopeRevalidationTests.swift
//  KalsmritikoshTests
//
//  Completion instructions 2026-10-29, B4 — a document-bearing cloud request is bound to the asking
//  case and the exact source versions it was built from. After the consent dialog the send boundary
//  re-resolves the case's membership as well as each document's protection: a document taken out of
//  the asking case (while another case still holds it), or the asking case being erased (its shared
//  documents kept), stops the send. Driven through the real Online provider path with a scripted
//  consent and a transport spy: zero unauthorised dispatches.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Cloud sends are re-checked against the asking case (B4)", .serialized)
struct CloudScopeRevalidationTests {

    nonisolated final class Spy: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    /// A gate whose labels all clear ("internal", not privileged), bound to one case's live scope.
    static func gate(_ f: CaseErasureTests.Fixture, caseID: UUID) async throws -> CloudSourceGate {
        let answers = try #require(await f.state.investigationAnswers)
        let binding = await answers.cloudScope(caseID: caseID)
        return CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                               legacyPrivileged: { [] }).bound(to: binding)
    }

    static func objects(_ f: CaseErasureTests.Fixture, file: UUID) async throws -> [UUID] {
        try await f.db.query("SELECT id FROM knowledge_objects WHERE file_id = ?;", [.uuid(file)]).compactMap { $0.uuid(0) }
    }

    static func excludeShared(_ f: CaseErasureTests.Fixture, from caseID: UUID) async throws {
        let cases = try #require(await f.state.investigationCases)
        let header = try #require(try await cases.fetch(caseID: caseID)).caseHeader
        let version = try #require(try await f.db.query("SELECT id FROM source_versions WHERE logical_source_id = ? LIMIT 1;", [.uuid(f.sharedFile)]).first?.string(0))
        _ = try await cases.excludeSource(caseID: caseID, expectedRevision: header.revision, sourceRef: version, sourceKind: .sourceVersion,
                                          note: "not relevant", actor: "Tester", at: Date())
    }

    @Test("Only the asking case's documents clear; one taken out of the case during consent stops the send, though another case still holds it")
    func removedFromAskingCase() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let shared = try await Self.objects(f, file: f.sharedFile)
        let exclusive = try await Self.objects(f, file: f.exclusiveFile)
        // Case B holds only the shared document: the exclusive one is denied as outside the case.
        let gateB = try await Self.gate(f, caseID: f.caseB)
        let forB = await gateB.clear(shared + exclusive, purpose: "answer.synthesis")
        #expect(forB.clearance.clearedObjectIDs == Set(shared))
        #expect(Set(forB.denied.keys) == Set(exclusive) && forB.denied.values.allSatisfy { $0 == "not part of this case" })
        // Case A asks with both; the clearance records each document's exact versions.
        let gateA = try await Self.gate(f, caseID: f.caseA)
        let forA = await gateA.clear(shared + exclusive, purpose: "answer.synthesis")
        #expect(forA.clearance.clearedObjectIDs == Set(shared + exclusive) && !forA.clearance.versions.isEmpty)
        #expect(await forA.clearance.stillCleared() == nil, "unchanged, it still clears")
        // While the dialog is open the shared document is taken out of case A (case B keeps it).
        try await Self.excludeShared(f, from: f.caseA)
        #expect(await forA.clearance.stillCleared()?.contains("no longer part of this case") == true)
        #expect(await forB.clearance.stillCleared() == nil, "case B still holds it")
    }

    @Test("Erasing the asking case during consent stops the send, while its shared documents stay in the ledger")
    func askingCaseErased() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let shared = try await Self.objects(f, file: f.sharedFile)
        let forA = await (try await Self.gate(f, caseID: f.caseA)).clear(shared, purpose: "answer.synthesis")
        #expect(forA.denied.isEmpty)
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil && out.report.sourcesKeptShared == 1)
        #expect(try await Self.objects(f, file: f.sharedFile).count == shared.count, "the shared document stays")
        #expect(await forA.clearance.stillCleared() != nil, "the erased case's request is not sent")
    }

    @Test("Through the real provider path: a source change during consent dispatches nothing; an unchanged one is sent once")
    func providerPathTransportSpy() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let shared = try await Self.objects(f, file: f.sharedFile)
        let spy = Spy()
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let reply = Data(#"{"content":[{"type":"text","text":"An answer."}]}"#.utf8)
        func provider(onConsent: @escaping @Sendable () async -> Void) -> OnlineCloudProvider {
            OnlineCloudProvider(outboundLog: OutboundLogRepository(database: f.db), knownNames: { [] },
                                seams: .init(settings: { snapshot },
                                             consent: { _ in await onConsent(); return true },
                                             transport: { _ in spy.hit(); return OutboundHTTPResponse(status: 200, body: reply) }))
        }
        let clearance = await (try await Self.gate(f, caseID: f.caseA)).clear(shared, purpose: "answer.synthesis").clearance
        let options = GenerationOptions(maxTokens: 64, temperature: 0.2, systemPrompt: nil, sourceClearance: clearance)
        // Unchanged: sent once.
        let text = try await provider(onConsent: {}).generateFromDocuments(prompt: "Passage [C1]", options: options)
        #expect(text == "An answer." && spy.count == 1)
        // The document leaves the asking case while the dialog is open: refused, nothing dispatched.
        let fixture = f
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await provider(onConsent: { try? await Self.excludeShared(fixture, from: fixture.caseA) })
                .generateFromDocuments(prompt: "Passage [C1]", options: options)
        }
        #expect(spy.count == 1, "no unauthorised dispatch")
        let log = try await OutboundLogRepository(database: f.db).recent()
        #expect(log.contains { $0.outcome == "blocked" && ($0.detail ?? "").contains("sources changed") })
    }
}
