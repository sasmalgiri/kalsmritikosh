//
//  SourceRobustnessTests.swift
//  KalsmritikoshTests
//
//  Smart-map S2-C (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04/§05): IN-03 provenance chains
//  (email attachment, archive member, nested archive), IN-08 re-verification of case records after a reprocess
//  activates a new reading, IN-09 protected inputs (password needed / wrong / correct / unsupported / corrupt /
//  locked, and the password in no ledger row, file or log), IN-10 no external fetch and hostile file names,
//  SRC-05 per-page reading status, SRC-06 derived copies that keep the original, its text and its metadata.
//  Synthetic fixtures written to a temp directory in each test.
//

import AppKit
import CryptoKit
import Foundation
import OSLog
import Testing
@testable import Kalsmritikosh

/// Text recognition stand-in: returns fixed lines (or none), so no test depends on Vision.
private struct RobustnessOCR: OCREngine {
    nonisolated var engineID: String { "robustness-stub" }
    let lines: [String]
    func recognizePrinted(at url: URL) async -> [String] { lines }
    func recognizeHandwritten(at url: URL) async -> [String] { [] }
    func recognizeTable(at url: URL) async -> [[String]] { [] }
}

@Suite("Smart-map S2-C — source provenance, protected inputs, safe processing, reading status", .serialized)
@MainActor
struct SourceRobustnessTests {

    struct Rig { let c: IngestCoordinator; let db: Database; let dir: URL; let vault: EvidenceVault }

    static func rig(ocrLines: [String] = []) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: RobustnessOCR(lines: ocrLines)),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .referenced)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        return Rig(c: c, db: db, dir: dir, vault: vault)
    }

    /// A PDF with one page per entry (nil = a page with nothing drawn); optionally user-password protected.
    static func pdf(pages: [String?], userPassword: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [String: Any] = [:]
        if let userPassword {
            info[kCGPDFContextUserPassword as String] = userPassword
            info[kCGPDFContextOwnerPassword as String] = userPassword + "-owner"
        }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info.isEmpty ? nil : info as CFDictionary) else { return Data() }
        for text in pages {
            ctx.beginPDFPage(nil)
            if let text {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                    .draw(in: CGRect(x: 54, y: 54, width: 504, height: 684))
                NSGraphicsContext.restoreGraphicsState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func email(attachmentName: String, contentType: String, body: Data) -> String {
        let b64 = body.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
        return """
        From: Records <records@agency.example>\r
        To: Investigator <investigator@firm.example>\r
        Subject: Records for matter 4471\r
        Date: Tue, 20 Oct 2026 10:00:00 +0000\r
        Message-ID: <s2c-\(UUID().uuidString)@agency.example>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Please find the summary attached.\r
        --b1\r
        Content-Type: \(contentType); name="\(attachmentName)"\r
        Content-Disposition: attachment; filename="\(attachmentName)"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64)\r
        --b1--\r

        """
    }

    static func children(_ db: Database, of parent: UUID, relation: String) async throws -> [UUID] {
        try await db.query("SELECT child_source_version_id FROM source_version_relations WHERE parent_source_version_id = ? AND relation = ?;",
                           [.uuid(parent), .text(relation)]).compactMap { $0.uuid(0) }
    }

    static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - IN-03 provenance chains

    @Test("IN-03: an extracted passage of an email attachment reconstructs passage → attachment → email → intake receipt")
    func emailAttachmentChain() async throws {
        let r = try await Self.rig()
        let report = Self.pdf(pages: ["Investigation summary 4471. The pump failed on 8 June 2017."])
        let eml = r.dir.appendingPathComponent("records.eml")
        try Self.email(attachmentName: "summary.pdf", contentType: "application/pdf", body: report).write(to: eml, atomically: true, encoding: .utf8)
        let emailVersion = try #require(try await r.c.ingest(fileAt: eml).sourceVersionID)
        let attachment = try #require(try await Self.children(r.db, of: emailVersion, relation: "attachment").first)

        let service = SourceProvenanceChainService(database: r.db)
        let chain = try await service.chain(forVersion: attachment)
        #expect(chain.parentPaths.count == 1)
        let path = try #require(chain.parentPaths.first)
        #expect(path.map(\.sourceVersionID) == [emailVersion])
        #expect(path.first?.relationOfPrevious == "attachment")
        #expect(chain.roots.map(\.sourceVersionID) == [emailVersion])
        let line = try #require(chain.pathDescriptions.first)
        #expect(line.hasPrefix("summary") && line.hasSuffix("attached to records.eml"), "\(line)")
        // The root's intake receipt is part of the chain: when and how the supplied file was received.
        #expect(chain.receipts.contains { $0.sourceVersionID == emailVersion })
        #expect(chain.truncated == false)

        // From the passage itself: the block resolves to the attachment version and the same chain.
        let block = try #require(try await r.db.query(
            "SELECT id FROM evidence_blocks WHERE source_version_id = ? AND raw_text LIKE '%pump failed%' LIMIT 1;", [.uuid(attachment)]).first?.uuid(0))
        let fromBlock = try await service.chain(forBlock: block)
        #expect(fromBlock.block?.sourceVersionID == attachment)
        #expect(fromBlock.block?.page == 1)
        #expect(fromBlock.parentPaths == chain.parentPaths)

        // The email itself was received directly.
        let rootChain = try await service.chain(forVersion: emailVersion)
        #expect(rootChain.parentPaths.isEmpty && rootChain.pathDescriptions == ["records.eml — received directly"])
        await #expect(throws: SourceProvenanceError.self) { _ = try await service.chain(forBlock: UUID()) }
    }

    @Test("IN-03: a member of a nested ZIP keeps its member paths and both archive levels up to the supplied file")
    func nestedZipMemberChain() async throws {
        let r = try await Self.rig()
        let inner = ZIPTestFixture.build([ZIPTestFixture.stored("notes/decision.txt", "SMITH v. JONES. Affirmed on 16 December 1927.")])
        let zip = try ZIPTestFixture.writeZIP([ZIPTestFixture.Entry(name: "bundle/inner.zip", data: inner, method: 0)], named: "case-bundle.zip")
        let outer = try #require(try await r.c.ingest(fileAt: zip).sourceVersionID)
        let innerVersion = try #require(try await Self.children(r.db, of: outer, relation: "archiveMember").first)
        let leaf = try #require(try await Self.children(r.db, of: innerVersion, relation: "archiveMember").first)

        let chain = try await SourceProvenanceChainService(database: r.db).chain(forVersion: leaf)
        let path = try #require(chain.parentPaths.first)
        #expect(path.map(\.sourceVersionID) == [innerVersion, outer])
        #expect(path[0].relationOfPrevious == "archiveMember" && path[0].memberPath == "notes/decision.txt")
        #expect(path[1].relationOfPrevious == "archiveMember" && path[1].memberPath == "bundle/inner.zip")
        #expect(chain.pathDescriptions.first == "decision.txt — unpacked as “notes/decision.txt” from inner.zip — unpacked as “bundle/inner.zip” from case-bundle.zip")
        #expect(chain.receipts.contains { $0.sourceVersionID == outer })
    }

    // MARK: - SRC-05 per-page reading status

    @Test("SRC-05: a blank page is listed as no text found — never as proof of absence — with re-read and original remedies")
    func pageReadingStatus() async throws {
        let r = try await Self.rig(ocrLines: [])
        let url = r.dir.appendingPathComponent("statement.pdf")
        try Self.pdf(pages: ["Statement page one. Transfer of 12,500 on 3 March 2026.", nil]).write(to: url)
        let version = try #require(try await r.c.ingest(fileAt: url).sourceVersionID)

        let report = try await SourcePageReadingService(database: r.db).report(sourceVersionID: version)
        #expect(report.pageCount == 2)
        #expect(report.pages.map(\.state) == [.read, .noTextFound])
        #expect(report.uncertainOrUnread.map(\.page) == [2])
        #expect(report.needsAttention)
        let line = try #require(report.disclosure)
        #expect(line.contains("page 2") && line.contains("not proof") && line.contains("open the original"), "\(line)")

        // A version that was never read has no page account: its contents are unknown, and it says so.
        let locked = r.dir.appendingPathComponent("locked.pdf")
        try Self.pdf(pages: ["Hidden ledger line."], userPassword: "pw-for-page-test").write(to: locked)
        _ = try? await r.c.ingest(fileAt: locked)
        let lockedVersion = try #require(try await r.db.query("SELECT id FROM source_versions WHERE filename = 'locked.pdf' LIMIT 1;").first?.uuid(0))
        let unread = try await SourcePageReadingService(database: r.db).report(sourceVersionID: lockedVersion)
        #expect(unread.limit == .notRead)
        #expect(unread.disclosure?.contains("proves nothing") == true)
    }

    @Test("SRC-05: text recognised from an image is marked uncertain, so it is checked against the original")
    func ocrPageIsUncertain() async throws {
        let r = try await Self.rig(ocrLines: ["Receipt 8812 paid in cash"])
        let png = try #require(DocumentExporter.png([ExportRecord(title: "Receipt", sourceType: "txt", text: "Receipt 8812 paid in cash")]))
        let url = r.dir.appendingPathComponent("receipt.png")
        try png.write(to: url)
        let version = try #require(try await r.c.ingest(fileAt: url).sourceVersionID)
        let report = try await SourcePageReadingService(database: r.db).report(sourceVersionID: version)
        #expect(report.pages.first?.state == .recognizedUncertain, "\(report.pages)")
        #expect(report.disclosure?.contains("misread") == true)
    }

    // MARK: - IN-09 protected inputs

    @Test("IN-09: needs-password, wrong password and the right password are distinct; the opened copy is linked and the original kept; repeating adds nothing")
    func unlockFlow() async throws {
        let r = try await Self.rig()
        let secret = "s3cret-Pa55-\(UUID().uuidString.prefix(6))"
        let wrong = "guess-\(UUID().uuidString.prefix(6))"
        let url = r.dir.appendingPathComponent("ledger.pdf")
        try Self.pdf(pages: ["Ledger entry 4471: transfer of 12,500 approved by the treasurer."], userPassword: secret).write(to: url)
        let originalHash = try Self.sha(url)
        #expect(ProtectedSourceProbe.classify(fileAt: url, type: .pdf).state == .passwordNeeded)
        _ = try? await r.c.ingest(fileAt: url)
        let version = try #require(try await r.db.query("SELECT id FROM source_versions WHERE filename = 'ledger.pdf' LIMIT 1;").first?.uuid(0))
        // The reader reports a locked PDF as protected, not as an empty document.
        #expect(try await EvidenceStore(database: r.db).blocks(forVersion: version).isEmpty)

        let c = r.c
        let service = ProtectedSourceUnlockService(
            database: r.db, byteResolver: SourceVersionByteResolver(database: r.db, vault: r.vault),
            ingestDerivative: { o, b, n in try await c.ingestDerivative(of: o, bytesAt: b, filename: n, methodKey: "opened-with-password").sourceVersionID })
        let start = Date()

        #expect(await service.probe(sourceVersionID: version).state == .passwordNeeded)
        let empty = await service.unlock(sourceVersionID: version, password: "")
        #expect(empty.state == .wrongPassword && empty.derivedSourceVersionID == nil)
        let bad = await service.unlock(sourceVersionID: version, password: wrong)
        #expect(bad.state == .wrongPassword && bad.derivedSourceVersionID == nil)
        #expect(try await service.latest(sourceVersionID: version)?.state == .wrongPassword)

        let good = await service.unlock(sourceVersionID: version, password: secret)
        #expect(good.state == .unlocked, "\(good)")
        let derived = try #require(good.derivedSourceVersionID)
        #expect(derived != version)
        // The copy is readable: its text is in the ledger.
        let text = try await EvidenceStore(database: r.db).blocks(forVersion: derived).map(\.rawText).joined(separator: " ")
        #expect(text.contains("Ledger entry 4471"), "\(text)")
        // Linked to the original by derivedConversion, with the method recorded.
        #expect(try await Self.children(r.db, of: version, relation: "derivedConversion") == [derived])
        #expect(try await SourceConversionRecorder(database: r.db).method(derived: derived) == ProtectedSourceUnlockService.unlockMethod)
        let chain = try await SourceProvenanceChainService(database: r.db).chain(forVersion: derived)
        #expect(chain.derivedFrom.map(\.originalSourceVersionID) == [version])
        #expect(chain.pathDescriptions.first?.contains("made from ledger.pdf") == true)
        // The original is untouched: same bytes, still current, still the locked version.
        #expect(try Self.sha(url) == originalHash)
        let originalRow = try #require(try await r.db.query("SELECT is_current, lower(content_hash) FROM source_versions WHERE id = ?;", [.uuid(version)]).first)
        #expect(originalRow.int(0) == 1 && originalRow.string(1) == originalHash)

        // One logical effect: opening it again finds the same copy, adds no second link or copy.
        let again = await service.unlock(sourceVersionID: version, password: secret)
        #expect(again.state == .unlocked && again.derivedSourceVersionID == derived)
        #expect(try await Self.children(r.db, of: version, relation: "derivedConversion").count == 1)

        // Every attempt is recorded by outcome only.
        let outcomes = try await r.db.query("SELECT outcome FROM source_unlock_attempts WHERE source_version_id = ? ORDER BY attempted_at, rowid;",
                                            [.uuid(version)]).compactMap { $0.string(0) }
        #expect(outcomes == ["passwordNeeded", "wrongPassword", "wrongPassword", "unlocked", "unlocked"])

        // The passwords are in no ledger row, no file under the library, and no log line of this process.
        for needle in [secret, wrong] {
            #expect(try await Self.tablesContaining(r.db, needle).isEmpty, "\(needle.prefix(5))… found in the ledger")
            #expect(try Self.filesContaining(r.dir, needle).isEmpty, "\(needle.prefix(5))… found in a file")
            #expect(Self.logLinesContaining(needle, since: start) == 0, "\(needle.prefix(5))… found in the log")
        }
    }

    @Test("IN-09: unsupported encryption, damage, a file-system lock and an unprotected file are told apart, and a password is not tried on them")
    func protectionStates() async throws {
        let r = try await Self.rig()
        // An encrypted ZIP member: the app does not decrypt ZIP encryption.
        let zip = ZIPTestFixture.build([ZIPTestFixture.Entry(name: "locked.txt", data: Data("x".utf8), encrypted: true)])
        #expect(ProtectedSourceProbe.classify(data: zip, type: .zip).state == .unsupportedEncryption)
        // A password-protected Office file is an OLE2 compound file, not a ZIP.
        var ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]); ole.append(Data(repeating: 0, count: 512))
        #expect(ProtectedSourceProbe.classify(data: ole, type: .docx).state == .unsupportedEncryption)
        #expect(ProtectedSourceProbe.classify(data: Data("%PDF-1.4 not really a pdf".utf8), type: .pdf).state == .corrupt)
        #expect(ProtectedSourceProbe.classify(data: Self.pdf(pages: ["Open text."]), type: .pdf).state == .notProtected)
        // A file the file system refuses to read is locked, not damaged.
        let unreadable = r.dir.appendingPathComponent("refused.pdf")
        try Self.pdf(pages: ["x"]).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        #expect(ProtectedSourceProbe.classify(fileAt: unreadable, type: .pdf).state == .locked)

        // Through the service: an unprotected version records notProtected and makes no copy.
        let open = r.dir.appendingPathComponent("open.pdf")
        try Self.pdf(pages: ["Open text, no password."]).write(to: open)
        let version = try #require(try await r.c.ingest(fileAt: open).sourceVersionID)
        let c = r.c
        let service = ProtectedSourceUnlockService(
            database: r.db, byteResolver: SourceVersionByteResolver(database: r.db, vault: r.vault),
            ingestDerivative: { o, b, n in try await c.ingestDerivative(of: o, bytesAt: b, filename: n, methodKey: "opened-with-password").sourceVersionID })
        let attempt = await service.unlock(sourceVersionID: version, password: "anything")
        #expect(attempt.state == .notProtected && attempt.derivedSourceVersionID == nil)
        #expect(try await Self.children(r.db, of: version, relation: "derivedConversion").isEmpty)
        // A version whose original is gone is unavailable — recorded, never something else opened instead.
        try FileManager.default.removeItem(at: open)
        #expect(await service.probe(sourceVersionID: version).state == .unavailable)
    }

    // MARK: - SRC-06 derived copies

    @Test("SRC-06: converting a text PDF to an image keeps the original file, its selectable text and its metadata; the image is linked with its method")
    func conversionKeepsOriginal() async throws {
        let r = try await Self.rig(ocrLines: ["Invoice 2290 total 4,500"])
        let url = r.dir.appendingPathComponent("invoice.pdf")
        try Self.pdf(pages: ["Invoice 2290. Total 4,500 payable to Dalmia Traders."]).write(to: url)
        let original = try #require(try await r.c.ingest(fileAt: url).sourceVersionID)
        let store = EvidenceStore(database: r.db)
        let blocksBefore = try await store.blocks(forVersion: original)
        let metaBefore = try await r.db.query("SELECT sd.metadata FROM source_versions sv JOIN source_documents sd ON sd.id = sv.document_id WHERE sv.id = ?;",
                                              [.uuid(original)]).first?.string(0)
        let hashBefore = try Self.sha(url)

        let png = try #require(DocumentExporter.png([ExportRecord(title: "Invoice", sourceType: "pdf", text: "Invoice 2290 total 4,500")]))
        let pngURL = r.dir.appendingPathComponent("render.png")
        try png.write(to: pngURL)
        let derived = try #require(try await r.c.ingestDerivative(of: original, bytesAt: pngURL, filename: "invoice.png", methodKey: "converted-to-png").sourceVersionID)
        try await SourceConversionRecorder(database: r.db).record(derived: derived, original: original,
                                                                  method: "Converted to PNG (an image; the PDF keeps its selectable text)", detail: nil, at: Date())
        try FileManager.default.removeItem(at: pngURL)   // the temporary file goes; the copy is in managed custody

        // The original: same bytes, same blocks (selectable text), same metadata, still current.
        #expect(try Self.sha(url) == hashBefore)
        let blocksAfter = try await store.blocks(forVersion: original)
        #expect(blocksAfter.map(\.id) == blocksBefore.map(\.id) && blocksAfter.map(\.rawText) == blocksBefore.map(\.rawText))
        #expect(blocksAfter.contains { $0.rawText.contains("Dalmia Traders") && $0.extractionMethod == .native })
        #expect(try await r.db.query("SELECT sd.metadata FROM source_versions sv JOIN source_documents sd ON sd.id = sv.document_id WHERE sv.id = ?;",
                                     [.uuid(original)]).first?.string(0) == metaBefore)
        // The derived image: linked both ways with its method, read by recognition and marked uncertain.
        let service = SourceProvenanceChainService(database: r.db)
        #expect(try await service.chain(forVersion: original).derivatives.map(\.derivedSourceVersionID) == [derived])
        let link = try #require(try await service.chain(forVersion: derived).derivedFrom.first)
        #expect(link.originalSourceVersionID == original && link.method?.hasPrefix("Converted to PNG") == true)
        #expect(try await SourcePageReadingService(database: r.db).report(sourceVersionID: derived).pages.first?.state == .recognizedUncertain)
        // The derived bytes survive the temp file's removal (managed custody).
        let resolved = try await SourceVersionByteResolver(database: r.db, vault: r.vault).resolve(sourceVersionID: derived, at: Date())
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
        #expect(try Data(contentsOf: resolved.snapshotURL) == png)
    }

    // MARK: - IN-08 re-verification after a reprocess

    @Test("IN-08: a reprocess that activates a new reading re-verifies the citing case record once, keeps the manual work, and records the outcome")
    func reprocessReverifiesCaseRecords() async throws {
        let r = try await Self.rig()
        let url = r.dir.appendingPathComponent("payments.txt")
        try "The supplier delivered the generator on 3 March.\n\nThe invoice was paid on 9 March.".write(to: url, atomically: true, encoding: .utf8)
        let version = try #require(try await r.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)

        let workspaces = WorkspaceRepository(database: r.db)
        let ws = Workspace(title: "Generator payment")
        try await workspaces.upsert(ws)
        let cases = InvestigationCaseRepository(database: r.db)
        let opened = try await cases.createCase(workspaceID: ws.id, title: "Generator payment", actor: "Ada", at: Date())
        _ = try await cases.includeSource(caseID: opened.id, expectedRevision: opened.revision, sourceRef: version.uuidString,
                                          sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let files = CaseFileService(database: r.db, cases: cases, workspaces: workspaces)
        let allegation = try await files.file.addAllegation(caseID: opened.id, text: "The invoice was paid late", actor: "Ada")
        let linkedAt = Date()
        let (linkID, first) = try await files.linkEvidence(
            caseID: opened.id, allegationID: allegation, evidenceRef: version.uuidString, label: "payments", stance: .supports,
            note: "Ada's own note", passage: StudioEvidenceRef(sourceVersionID: version, quote: "The invoice was paid on 9 March"), actor: "Ada", at: linkedAt)
        #expect(first.support.isDocumentary, "\(first.support)")

        // A newer reader produces a different reading of the same bytes (the date reads differently).
        try await r.db.exec("UPDATE source_readiness_dimensions SET producer_version = '0' WHERE source_version_id = ? AND dimension IN ('structuralExtraction','metadataExtraction');",
                            [.uuid(version)])
        let store = EvidenceStore(database: r.db)
        let committed = try await store.blocks(forVersion: version)
        let row = try #require(try await r.db.query("SELECT logical_source_id, content_hash FROM source_versions WHERE id = ?;", [.uuid(version)]).first)
        let fresh = ParsedDocument(id: UUID(), logicalSourceID: try #require(row.uuid(0)), sourceVersionID: version, filename: "payments.txt",
                                   detectedType: .txt, contentHash: row.string(1) ?? "",
                                   blocks: committed.sorted { $0.ordinal < $1.ordinal }.enumerated().map { i, b in
                                       EvidenceBlock(documentID: b.documentID, ordinal: i, kind: b.kind,
                                                     rawText: b.rawText.replacingOccurrences(of: "9 March", with: "19 March"),
                                                     locator: b.locator, attributes: b.attributes)
                                   })
        let reverifier = ReprocessedSourceReverifier(database: r.db, caseFiles: files)
        let c = r.c
        let coordinator = SourceReprocessingCoordinator(
            database: r.db, readiness: SourceReadinessRepository(database: r.db),
            byteResolver: SourceVersionByteResolver(database: r.db, vault: r.vault),
            reparse: { _, _, _ in fresh },
            reindex: { svid in try await c.upgradeIndexing(sourceVersionID: svid) },
            afterActivation: { svid in _ = await reverifier.reverify(sourceVersionID: svid) })
        let outcome = try await coordinator.reprocess(sourceVersionID: version, currentParserVersion: "2", at: Date())
        guard case .activated = outcome else { Issue.record("expected an activated reading, got \(outcome)"); return }

        // Exactly one recorded outcome for the case, naming the earlier-reading pin the new reading lacks.
        let log = try await r.db.query("SELECT detail FROM case_actions WHERE case_id = ? AND action = ?;",
                                       [.uuid(opened.id), .text(ReprocessedSourceReverifier.doneAction)]).compactMap { $0.string(0) }
        #expect(log.count == 1)
        let detail = try #require(log.first)
        #expect(detail.contains("1 checked") && detail.contains("1 pinned to the earlier reading") && detail.contains("1 not found in the new reading"), "\(detail)")
        // The manual work is unchanged; nothing was copied; the state was re-recorded.
        let links = try await files.file.allegationEvidence(caseID: opened.id)
        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.id == linkID && link.quote == "The invoice was paid on 9 March" && link.note == "Ada's own note" && link.stance == .supports)
        // Re-verified now (a fresh recorded state, verified or unverified with its reason), not left as it was.
        #expect((link.verifiedAt ?? .distantPast) > linkedAt)
        #expect(link.verification == "verified" || link.verificationDetail != nil)

        // A rerun for the same reading adds nothing.
        let rerun = await reverifier.reverify(sourceVersionID: version)
        #expect(rerun.count == 1 && rerun.first?.alreadyRecorded == true)
        #expect(try await r.db.query("SELECT COUNT(*) FROM case_actions WHERE case_id = ? AND action = ?;",
                                     [.uuid(opened.id), .text(ReprocessedSourceReverifier.doneAction)]).first?.int(0) == 1)
        #expect(try await files.file.allegationEvidence(caseID: opened.id).count == 1)
        // A version no case cites re-verifies nothing.
        #expect(await reverifier.reverify(sourceVersionID: UUID()).isEmpty)
    }

    // MARK: - IN-10 no external fetch, hostile names

    @Test("IN-10: XML external entities and HTML/OOXML external references are never fetched or read")
    func noExternalFetch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2c-xxe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = "SENTINEL-EXTERNAL-\(UUID().uuidString.prefix(8))"
        let secretFile = dir.appendingPathComponent("outside.txt")
        try sentinel.write(to: secretFile, atomically: true, encoding: .utf8)
        let ref = secretFile.absoluteString   // file:///… — an external entity that, if resolved, would pull the sentinel in

        let xml = Data("""
            <?xml version="1.0"?>
            <!DOCTYPE r [<!ENTITY ext SYSTEM "\(ref)">]>
            <r><p>before &ext; after</p></r>
            """.utf8)
        let parsedXML = try await StructuredTextStructuralParser().parse(data: xml, filename: "x.xml", type: .xml, logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(!parsedXML.blocks.contains { $0.rawText.contains(sentinel) })

        let html = Data("""
            <html><head><link rel="stylesheet" href="\(ref)"></head>
            <body><p>Visible text.</p><img src="\(ref)"><iframe src="\(ref)"></iframe><object data="\(ref)"></object></body></html>
            """.utf8)
        let parsedHTML = try await StructuredTextStructuralParser().parse(data: html, filename: "x.html", type: .html, logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(parsedHTML.blocks.contains { $0.rawText.contains("Visible text") })
        #expect(!parsedHTML.blocks.contains { $0.rawText.contains(sentinel) })

        // A DOCX whose document.xml declares the same external entity, plus an external relationship target.
        let documentXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE w:document [<!ENTITY ext SYSTEM "\(ref)">]>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Body &ext; end</w:t></w:r></w:p></w:body></w:document>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(ref)" TargetMode="External"/></Relationships>
            """
        let docx = ZIPTestFixture.build([ZIPTestFixture.stored("[Content_Types].xml", "<Types/>"),
                                         ZIPTestFixture.stored("word/document.xml", documentXML),
                                         ZIPTestFixture.stored("word/_rels/document.xml.rels", rels)])
        let parsedDocx = try await DocxStructuralParser().parse(data: docx, filename: "x.docx", type: .docx, logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(!parsedDocx.blocks.contains { $0.rawText.contains(sentinel) })
        #expect(!(DocxLoader.structuredExtract(data: Data(documentXML.utf8)) ?? "").contains(sentinel))
    }

    @Test("IN-10: readers in Ingestion contain no network client or web renderer, and every XML parser refuses external entities")
    func ingestionSourceAudit() throws {
        let ingestion = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Ingestion", isDirectory: true)
        // The one known exception: an unreferenced cloud transcription stub (an intentional stub per CLAUDE.md,
        // never registered with a loader). It must stay unreferenced; this list must not grow.
        let allowedNetwork: Set<String> = ["OpenAIWhisperTranscriber.swift"]
        let forbidden = ["URLSession", "WKWebView", "import WebKit", "DocumentType.html", "NSURLConnection", "NWConnection"]
        guard let walker = FileManager.default.enumerator(at: ingestion, includingPropertiesForKeys: nil) else {
            Issue.record("Ingestion sources not found at \(ingestion.path)"); return
        }
        var scanned = 0
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            if !allowedNetwork.contains(file.lastPathComponent) {
                for token in forbidden { #expect(!text.contains(token), "\(file.lastPathComponent) uses \(token)") }
            }
            if text.contains("XMLParser(") {
                #expect(text.contains("shouldResolveExternalEntities = false"), "\(file.lastPathComponent) creates an XMLParser without refusing external entities")
            }
        }
        #expect(scanned > 50)
        // The allowed stub really is unreferenced outside its own file.
        let app = ingestion.deletingLastPathComponent()
        guard let all = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in all where file.pathExtension == "swift" && file.lastPathComponent != "OpenAIWhisperTranscriber.swift" {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("OpenAIWhisperTranscriber("), "\(file.lastPathComponent) wires the cloud stub")
        }
    }

    @Test("IN-10: hostile file names become one safe component inside the staging area, and an over-long attachment name no longer vanishes")
    func hostileFilenames() async throws {
        for raw in ["../../etc/passwd", "..\\..\\boot.ini", "/abs/evil.txt", ".hidden", "..", "a\u{0}b.txt", "C:evil.txt"] {
            let safe = SafeFilename.sanitize(raw)
            #expect(!safe.contains("/") && !safe.contains("\\") && !safe.contains("\u{0}") && !safe.hasPrefix(".") && !safe.contains(":"), "\(raw) → \(safe)")
        }
        let spoof = SafeFilename.sanitize("invoice\u{202E}fdp.exe")
        #expect(!spoof.unicodeScalars.contains { SafeFilename.bidi.contains($0) } && spoof.hasSuffix(".exe"))
        let long = SafeFilename.sanitize(String(repeating: "statement-", count: 40) + ".pdf")
        #expect(long.utf8.count <= SafeFilename.maxBytes - SafeFilename.reservedBytes && long.hasSuffix(".pdf"))
        #expect(SafeFilename.sanitize("\u{0}\u{0}") == "attachment")

        // End to end: an attachment named with traversal and 300+ characters is staged, ingested and linked.
        let r = try await Self.rig()
        let hostile = "../../../" + String(repeating: "x", count: 300) + ".txt"
        let eml = r.dir.appendingPathComponent("hostile.eml")
        try Self.email(attachmentName: hostile, contentType: "text/plain", body: Data("ATTACHED-BODY-5521 is the attachment text.".utf8))
            .write(to: eml, atomically: true, encoding: .utf8)
        let emailVersion = try #require(try await r.c.ingest(fileAt: eml).sourceVersionID)
        let child = try #require(try await Self.children(r.db, of: emailVersion, relation: "attachment").first, "the attachment vanished")
        let name = try #require(try await r.db.query("SELECT filename FROM source_versions WHERE id = ?;", [.uuid(child)]).first?.string(0))
        #expect(!name.contains("/") && !name.hasPrefix(".") && name.utf8.count <= SafeFilename.maxBytes, "\(name)")
        let text = try await EvidenceStore(database: r.db).blocks(forVersion: child).map(\.rawText).joined()
        #expect(text.contains("ATTACHED-BODY-5521"))
    }

    // MARK: - Helpers

    /// Tables holding `needle` in any text or blob column.
    static func tablesContaining(_ db: Database, _ needle: String) async throws -> [String] {
        var hits: [String] = []
        let tables = try await db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';").compactMap { $0.string(0) }
        for t in tables {
            guard let rows = try? await db.query("SELECT * FROM \"\(t)\";") else { continue }
            let found = rows.contains { row in
                row.values.contains { v in
                    switch v {
                    case .text(let s): return s.contains(needle)
                    case .blob(let b): return b.range(of: Data(needle.utf8)) != nil
                    default: return false
                    }
                }
            }
            if found { hits.append(t) }
        }
        return hits
    }

    /// Files under `root` whose name or bytes contain `needle`.
    static func filesContaining(_ root: URL, _ needle: String) throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var hits: [String] = []
        let bytes = Data(needle.utf8)
        for case let file as URL in walker {
            if file.lastPathComponent.contains(needle) { hits.append(file.lastPathComponent); continue }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            if data.range(of: bytes) != nil { hits.append(file.lastPathComponent) }
        }
        return hits
    }

    /// Log lines of this process since `start` containing `needle` (0 when the log store cannot be read).
    static func logLinesContaining(_ needle: String, since start: Date) -> Int {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: start)) else { return 0 }
        var n = 0
        for case let e as OSLogEntryLog in entries where e.composedMessage.contains(needle) { n += 1 }
        return n
    }
}
