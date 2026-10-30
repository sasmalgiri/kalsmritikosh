//
//  CaseOutputServiceTests.swift
//  KalsmritikoshTests
//
//  App Store completion instructions 2026-10-30 §4 — every case output route releases the same
//  frozen, revalidated, protected bytes and records what actually happened. Acceptance: a protected
//  name in a free-text note; a source withdrawn or made privileged after the preview (the save panel
//  was open); an output-log failure; cancellation; an altered output file; an ACH citation outside
//  the case. On a throwaway migrated ledger — never the owner's.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("§4 — one door for case output", .serialized)
struct CaseOutputServiceTests {

    private struct Rig {
        let f: CaseFileTests.Fixture
        let outputs: CaseOutputService
        let temp: URL
        let passage: (version: UUID, object: UUID, blocks: [UUID])
        let allegation: UUID
    }

    /// A case with one verified passage link, a chronology note and a protected source identity.
    private func rig(custodyFails: Bool = false) async throws -> Rig {
        let f = try await CaseFileTests.fixture(title: "Night shift")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("case-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc,
                                        custody: { _ in if custodyFails { throw CaseFileError.alreadyCarried("custody") }; return [] },
                                        pendingDirectory: temp.appendingPathComponent("pending", isDirectory: true))
        let passage = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "rota.txt",
                                                                text: "The rota shows Sam Okafor off shift on 3 March. The manager shouted at staff that evening.")
        let a = try await f.file.addAllegation(caseID: f.caseID, text: "Shouted at staff on 3 March", actor: "Ada")
        _ = try await f.svc.linkEvidence(caseID: f.caseID, allegationID: a, evidenceRef: passage.version.uuidString, label: "Rota", stance: .supports, note: "Meera Iyer pointed me to the rota",
                                         passage: StudioEvidenceRef(sourceVersionID: passage.version, quote: "The manager shouted at staff that evening"), actor: "Ada")
        // A protected source identity (jrn.source-vault) and a free-text note that names them.
        let vault = JobResultRow(title: "Source", detail: "", fields: ["protected": "yes", "identity": "Meera Iyer"])
        _ = try await JobResultRepository(database: f.db).save(caseID: f.caseID, jobID: "jrn.source-vault", family: .interviewsQuotes, state: .draft,
                                                               content: JobResultContent(rows: [vault]), actor: "Ada")
        _ = try await f.file.addJournal(caseID: f.caseID, kind: .note, text: "Meera Iyer told me the rota was changed afterwards.", eventDate: nil, evidenceRef: nil, actor: "Ada")
        return Rig(f: f, outputs: outputs, temp: temp, passage: passage, allegation: a)
    }

    @Test("A file export: frozen, DRAFT-labelled, protected name scrubbed from the free-text note, written atomically, read back, recorded with the file digest in the ledger and the case log; nothing is recorded by a preview alone (cancellation)")
    func fileExportIsRecordedTruthfully() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.temp) }
        let pkg = try await r.outputs.prepare(caseID: r.f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        #expect(pkg.text.hasPrefix("> DRAFT case file — not an approved findings report."))
        #expect(!pkg.text.contains("Meera Iyer") && pkg.text.contains("— [PROTECTED SOURCE] pointed me to the rota"), "the protected name is scrubbed from the free-text note on the link: \(pkg.text)")
        #expect(pkg.text.contains("(verified passage)") && pkg.text.contains("The manager shouted at staff that evening"))
        #expect(pkg.scopeFingerprint != nil && pkg.approved == false)
        // Preview / cancelled panel: nothing recorded.
        #expect(try await r.outputs.outputs(caseID: r.f.caseID).isEmpty)
        #expect(try await r.f.file.actions(caseID: r.f.caseID).filter { $0.action == "exported" }.isEmpty)
        // Written.
        let url = r.temp.appendingPathComponent("Case file.md")
        let receipt = await r.outputs.write(pkg, to: url)
        #expect(receipt.status == .written && receipt.recorded && receipt.fileSHA256 == pkg.digest && receipt.fileName == "Case file.md")
        #expect(StudioRecordRepository.sha256(try Data(contentsOf: url)) == pkg.digest)
        let records = try await r.outputs.outputs(caseID: r.f.caseID)
        #expect(records.count == 1 && records[0].status == .written && records[0].fileSHA256 == pkg.digest && records[0].snapshotSHA256 == pkg.digest && records[0].kind == .caseFileReport && records[0].route == .file)
        let logged = try await r.f.file.actions(caseID: r.f.caseID).filter { $0.action == "exported" }
        #expect(logged.count == 1 && logged[0].detail?.contains("caseFileReport · file · Case file.md · sha256 \(pkg.digest.prefix(16))") == true)
        // Copy and print record the digest of the released text, and say it is not the printer's bytes.
        let copy = try await r.outputs.prepareText(caseID: r.f.caseID, kind: .achReport, route: .clipboard, actor: "Ada", citations: [], text: "ACH about Meera Iyer")
        #expect(copy.text == "ACH about [PROTECTED SOURCE]")
        let released = await r.outputs.released(copy)
        #expect(released.status == .released && released.recorded && released.fileSHA256 == nil && released.detail?.contains("not of the recipient's bytes") == true)
        #expect(try await r.outputs.outputs(caseID: r.f.caseID).first?.route == .clipboard)
    }

    @Test("Changes while the save panel is open: a source removed from the case, or labelled privileged, after the preview refuses the release — and the refusal is recorded; a custody record that cannot be read refuses a custody report and marks every prose document INCOMPLETE")
    func revalidationAfterTheDialog() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.temp) }
        // The preview passed…
        _ = try await r.outputs.prepare(caseID: r.f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        // …then, with the panel open, the source is labelled privileged.
        _ = try await SensitiveScopeRepository(database: r.f.db).assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: r.passage.version), sensitivity: .confidential,
            authority: .userConfirmed(actorID: "Ada", confirmationID: UUID(), privileged: true), reason: "legal advice")
        await #expect(throws: CaseOutputError.sourcesWithdrawn(1)) {
            _ = try await r.outputs.prepare(caseID: r.f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        }
        var records = try await r.outputs.outputs(caseID: r.f.caseID)
        #expect(records.count == 1 && records[0].status == .refused && records[0].detail?.contains("no longer cleared for export") == true)
        #expect(try await r.f.file.actions(caseID: r.f.caseID).contains { $0.action == "exportRefused" })
        // An ACH report citing that version is refused on every route; one citing nothing is not.
        await #expect(throws: CaseOutputError.sourcesWithdrawn(1)) {
            _ = try await r.outputs.prepareText(caseID: r.f.caseID, kind: .achReport, route: .print, actor: "Ada",
                                                citations: [StudioEvidenceRef(sourceVersionID: r.passage.version, quote: "shouted")], text: "ACH")
        }
        _ = try await r.outputs.prepareText(caseID: r.f.caseID, kind: .achReport, route: .print, actor: "Ada", citations: [], text: "ACH")
        // A second rig: the source leaves the case between preview and release.
        let r2 = try await rig()
        defer { try? FileManager.default.removeItem(at: r2.temp) }
        _ = try await r2.outputs.prepare(caseID: r2.f.caseID, kind: .exhibitList, route: .file, actor: "Ada") { CaseFileDocuments.exhibitListCSV($0) }
        let header = try #require(try await r2.f.cases.fetch(caseID: r2.f.caseID)).caseHeader
        _ = try await r2.f.cases.excludeSource(caseID: r2.f.caseID, expectedRevision: header.revision, sourceRef: r2.passage.version.uuidString,
                                               sourceKind: .sourceVersion, note: "out of period", actor: "Ada", at: Date())
        await #expect(throws: CaseOutputError.sourcesWithdrawn(1)) {
            _ = try await r2.outputs.prepare(caseID: r2.f.caseID, kind: .exhibitList, route: .file, actor: "Ada") { CaseFileDocuments.exhibitListCSV($0) }
        }
        // Custody unreadable.
        let r3 = try await rig(custodyFails: true)
        defer { try? FileManager.default.removeItem(at: r3.temp) }
        await #expect(throws: CaseOutputError.custodyUnreadable) {
            _ = try await r3.outputs.prepare(caseID: r3.f.caseID, kind: .custodyReport, route: .file, actor: "Ada") { CaseFileDocuments.custodyReport($0, by: "Ada") }
        }
        let incomplete = try await r3.outputs.prepare(caseID: r3.f.caseID, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        #expect(incomplete.custodyIncomplete && incomplete.text.hasPrefix("> DRAFT case file") && incomplete.text.contains("> INCOMPLETE — the custody record could not be read"))
        let csv = try await r3.outputs.prepare(caseID: r3.f.caseID, kind: .caseLog, route: .file, actor: "Ada") { CaseFileDocuments.actionLogCSV($0) }
        #expect(!csv.text.contains("INCOMPLETE"), "a CSV list carries no banner; the record says custody was incomplete")
        records = try await r3.outputs.outputs(caseID: r3.f.caseID)
        #expect(records.first?.status == .refused && records.first?.kind == .custodyReport)
    }

    @Test("An altered output file is not an export; a write that lands but cannot be recorded keeps a pending record beside the ledger, is reported as pending (never as a clean export), and lands at the next resume")
    func alteredFileAndPendingRecord() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.temp) }
        let pkg = try await r.outputs.prepare(caseID: r.f.caseID, kind: .caseLog, route: .file, actor: "Ada") { CaseFileDocuments.actionLogCSV($0) }
        // Altered between the write and the read-back.
        await r.outputs.setHooks(.init(afterWrite: { url in try Data("tampered".utf8).write(to: url) }))
        let tampered = await r.outputs.write(pkg, to: r.temp.appendingPathComponent("log.csv"))
        #expect(tampered.status == .failed && tampered.detail?.contains("does not hold the released content") == true)
        #expect(try await r.outputs.outputs(caseID: r.f.caseID).first?.status == .failed)
        #expect(try await r.f.file.actions(caseID: r.f.caseID).contains { $0.action == "exportFailed" })
        // The record fails after a good write.
        await r.outputs.setHooks(.init(recordFault: { throw CaseOutputError.scopeUnavailable }))
        let url = r.temp.appendingPathComponent("log2.csv")
        let pending = await r.outputs.write(pkg, to: url)
        #expect(pending.status == .recordPending && !pending.recorded && pending.pendingRetained && pending.fileSHA256 == pkg.digest)
        #expect(pending.summary.contains("could not be saved") && pending.summary.contains("kept and will be recorded"))
        let kept = try FileManager.default.contentsOfDirectory(at: r.outputs.pendingDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(kept.count == 1)
        #expect(try await r.outputs.outputs(caseID: r.f.caseID).filter { $0.status == .written }.isEmpty, "not recorded yet")
        // Resume with the fault gone: the record lands once and the pending file goes.
        await r.outputs.setHooks(.init())
        #expect(await r.outputs.resumePending() == 1)
        #expect(await r.outputs.resumePending() == 0)
        let written = try await r.outputs.outputs(caseID: r.f.caseID).filter { $0.status == .written }
        #expect(written.count == 1 && written[0].fileName == "log2.csv" && written[0].fileSHA256 == pkg.digest && written[0].id == pending.id && written[0].snapshotSHA256 == pkg.digest)
        #expect(try FileManager.default.contentsOfDirectory(at: r.outputs.pendingDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.isEmpty)
        // Content with no case is still protected but is not recorded anywhere, and says so.
        let loose = try await r.outputs.prepareText(caseID: nil, kind: .achReport, route: .clipboard, actor: "Ada", citations: [], text: "Notes on Meera Iyer")
        #expect(loose.text == "Notes on [PROTECTED SOURCE]" && loose.scopeFingerprint == nil)
        let looseReceipt = await r.outputs.released(loose)
        #expect(!looseReceipt.recorded && looseReceipt.detail?.contains("no case to record it in") == true)
        // A binary document: protected text first, then the bytes; a name that survives in any input refuses it.
        let cell = try await r.outputs.protectedText("Paid by Meera Iyer")
        #expect(cell == "Paid by [PROTECTED SOURCE]")
        let xlsx = DocumentExporter.xlsx(grid: [["Payee"], [cell]])
        let bin = try await r.outputs.prepareData(caseID: r.f.caseID, kind: .dataset, route: .file, actor: "Ada", citations: [], texts: ["Payee", cell], data: xlsx)
        #expect(bin.data == xlsx && bin.digest == StudioRecordRepository.sha256(xlsx) && bin.scopeFingerprint != nil)
        let binReceipt = await r.outputs.write(bin, to: r.temp.appendingPathComponent("payees.xlsx"))
        #expect(binReceipt.status == .written && binReceipt.fileSHA256 == StudioRecordRepository.sha256(xlsx))
        await #expect(throws: CaseOutputError.protectedIdentityLeak(1)) {
            _ = try await r.outputs.prepareData(caseID: r.f.caseID, kind: .dataset, route: .file, actor: "Ada", citations: [], texts: ["Paid by Meera Iyer"], data: xlsx)
        }
        // Empty content and a gone case are refused.
        await #expect(throws: CaseOutputError.emptyContent) { _ = try await r.outputs.prepareText(caseID: r.f.caseID, kind: .holdNotice, route: .file, actor: "Ada", citations: [], text: "  ") }
        await #expect(throws: CaseOutputError.caseGone) { _ = try await r.outputs.prepare(caseID: UUID(), kind: .caseLog, route: .file, actor: "Ada") { CaseFileDocuments.actionLogCSV($0) } }
    }
}
