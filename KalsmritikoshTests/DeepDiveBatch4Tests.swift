//
//  DeepDiveBatch4Tests.swift
//  KalsmritikoshTests
//
//  Deep dive 2026-11-14 batch 4 (privacy, exports, relay money path) — one regression test per confirmed app-side defect
//  (docs/SMART_MAP_DEFECT_LOG.md, "Deep dive 2026-11-14 batch 4"). The relay's own tests are in relay/test/relay.test.ts.
//  Synthetic data on throwaway migrated databases; no model, no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let dd4Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

private nonisolated final class DD4Script: @unchecked Sendable {
    private let lock = NSLock()
    private var _sends: [CaseReadSend] = []
    func record(_ s: CaseReadSend) -> Int { lock.withLock { _sends.append(s); return _sends.count - 1 } }
    var sends: [CaseReadSend] { lock.withLock { _sends } }
}

private func dd4Reply(calls: [[String: Any]] = [], proposals: [[String: Any]] = []) -> CaseReader.Reply {
    let root: [String: Any] = ["calls": calls, "proposals": proposals, "complete": true]
    let text = String(decoding: (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    var u = CloudCallUsage(inputTokens: 50, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 20, purpose: "case.assist", provider: "test")
    u.model = "answering-model-7"; u.stopReason = "end_turn"
    return CaseReader.Reply(text: text, usage: u)
}

@MainActor
@Suite("Deep dive 2026-11-14 batch 4 — privacy, exports, relay money path", .serialized)
struct DeepDiveBatch4Tests {

    // MARK: 1 — the relay credential is the AI subscription's own transaction

    @Test("1: the credential sent to the relay is the AI subscription's signed transaction, never a credit pack's or Workbench's")
    func credentialIsTheAISubscription() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func rec(_ product: String, _ days: Double?, id: UInt64, jws: String) -> Entitlement.Record {
            var r = Entitlement.Record(productID: product, purchaseDate: now.addingTimeInterval(-86_400), originalPurchaseDate: now.addingTimeInterval(-86_400),
                                       expirationDate: days.map { now.addingTimeInterval($0 * 86_400) }, revoked: false, originalID: id)
            r.signedTransaction = jws
            return r
        }
        let ai = rec(PurchaseProducts.aiMonthly, 20, id: 7, jws: "a.sub.jws")
        // A pack bought later (no expiry) and a Workbench period: neither may become the credential.
        let pack = rec(PurchaseProducts.credits2000, nil, id: 9, jws: "p.pack.jws")
        let workbench = rec(PurchaseProducts.monthly, 25, id: 7, jws: "w.bench.jws")
        let e = Entitlement.subscribed(expiresAt: now.addingTimeInterval(20 * 86_400), plan: .aiMonthly, willRenew: true)
        for records in [[ai, pack], [pack, ai], [pack, ai, workbench]] {
            #expect(Entitlement.aiSignedTransaction(records: records, entitlement: e) == "a.sub.jws")
            #expect(Entitlement.aiSubscriptionID(records: records, entitlement: e) == "7")
        }
        #expect(Entitlement.aiSignedTransaction(records: [pack], entitlement: e) == nil, "a pack alone is never a credential")
    }

    // MARK: 2 / 6 — the relay's refusals the app reads

    @Test("2/6: the app reads provider-unavailable (the relay's honest words) and the bad-request refusal of an unsupported block")
    func relayRefusalsRead() throws {
        let provider = Data(#"{"error":{"code":"provider-unavailable","message":"\#(AIPricing.providerUnavailableMessage)"}}"#.utf8)
        #expect(AIIncludedRelay.refusal(in: provider) == AIPricing.providerUnavailableMessage)
        let response = OutboundHTTPResponse(status: 502, body: provider)
        #expect(throws: AIIncludedRelay.RelayError.refused(AIPricing.providerUnavailableMessage)) { try AIIncludedRelay.object(response) }
        let block = Data(#"{"error":{"code":"bad-request","message":"The request was not in the expected form: content of type \"document\" is not accepted (text and images only)"}}"#.utf8)
        #expect(AIIncludedRelay.refusal(in: block)?.contains("text and images only") == true)
        // The app's request builder sends only text and image blocks (what the relay now forwards).
        let img = OutboundImage(mediaType: "image/png", data: Data([0x89, 0x50]), label: "p1")
        let req = try OnlineRequestBuilder.build(kind: .anthropic, model: "m", apiKey: "k", system: nil, prompt: "read", maxTokens: 500, images: [img])
        let root = try #require(try JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        let content = try #require(((root["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(Set(content.compactMap { $0["type"] as? String }).isSubset(of: ["text", "image"]))
    }

    // MARK: 3 — every protected export is checked again at write

    @Test("3: a source protected while the save panel is open still stops the file (writeRechecked and the multi-file recheck)")
    func protectedAtWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "Timeline\n- 3 March: Meera Iyer called the auditor.\n"
        // Before the panel: nothing protected yet, so prepare passes the text as it is.
        let before = ProtectedIdentityCache.TestOverride.$names.withValue([]) { ProtectedExport.prepare(text) }
        #expect(before == .success(text))
        // At write: Meera was protected meanwhile — replaced in an ordinary export.
        let url = dir.appendingPathComponent("timeline.csv")
        let written = await ProtectedExport.writeRechecked(text, to: url, refuseIfPresent: false, names: { ["Meera Iyer"] })
        guard case .success(let out) = written else { Issue.record("not written: \(written)"); return }
        let disk = try String(contentsOf: url, encoding: .utf8)
        #expect(disk == out && !disk.contains("Meera") && disk.contains("auditor"))
        // A sealed proof bundle (several files) is refused before any file is written.
        let sealed = await ProtectedExport.recheck(text, refuseIfPresent: true, names: { ["Meera Iyer"] })
        guard case .failure(let why) = sealed else { Issue.record("a sealed bundle with a protected name passed"); return }
        #expect(why.reason.contains("marked protected while the save window was open"))
        struct Unreadable: Error {}
        let closed = await ProtectedExport.recheck(text, refuseIfPresent: false, names: { throw Unreadable() })
        guard case .failure = closed else { Issue.record("passed without a readable register"); return }
        #expect(await ProtectedExport.recheck(text, refuseIfPresent: true, names: { [] }) == .success(text))
    }

    @Test("3: source audit — no view that checks an export with prepare/protectedExportText writes the file without the at-write check")
    func everyProtectedExportRechecksAtWrite() throws {
        let plainWrite = try NSRegularExpression(pattern: #"\.write\(\s*to:|\.write\(\s*toFile:|createFile\(\s*atPath:"#)
        var scanned: [String] = [], offenders: [String] = []
        guard let en = FileManager.default.enumerator(at: dd4Root.appendingPathComponent("Kalsmritikosh"), includingPropertiesForKeys: nil) else {
            Issue.record("source folder not found"); return
        }
        for case let url as URL in en where url.pathExtension == "swift" && url.lastPathComponent != "ExportProtection.swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            guard src.contains("ProtectedExport.prepare(") || src.contains("protectedExportText(") else { continue }
            scanned.append(url.lastPathComponent)
            let ns = src as NSString
            for m in plainWrite.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
                offenders.append("\(url.lastPathComponent):\(line) writes without ProtectedExport.writeRechecked")
            }
            // A multi-file write (a proof bundle folder) must be preceded by the at-write recheck.
            if let into = src.range(of: ".write(into:") {
                let recheck = src.range(of: "ProtectedExport.recheck(")
                if recheck.map({ $0.lowerBound > into.lowerBound }) ?? true { offenders.append("\(url.lastPathComponent): folder write without ProtectedExport.recheck") }
            }
            let panels = src.contains("NSSavePanel()") || src.contains("NSOpenPanel()")
            let rechecks = src.contains("ProtectedExport.writeRechecked(") || src.contains("ProtectedExport.recheck(")
            if panels && src.contains("ProtectedExport.prepare(") && !rechecks { offenders.append("\(url.lastPathComponent): save panel without the at-write check") }
            if rechecks && !src.contains("protectedNamesNow()") { offenders.append("\(url.lastPathComponent): the at-write check does not read the register fresh") }
        }
        for expected in ["TimelineView.swift", "WatchlistView.swift", "WorkspacesView.swift", "KnowledgeView.swift", "NotebookView.swift",
                         "StructuredComparisonView.swift", "CrossDocumentMatrixView.swift", "AskView.swift", "SendToDevonthink.swift",
                         "TranscriptsView.swift", "CaseStoryView.swift", "IssueChronologyView.swift", "CaseSliceView.swift"] {
            #expect(scanned.contains(expected), "\(expected) not scanned")
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    // MARK: 5 — the AI money tool holds every row behind its figures

    private func assistant(_ f: CaseFileTests.Fixture, privileged: Set<UUID>, script: DD4Script) -> CaseAIAssistService {
        let objects = KnowledgeObjectRepository(database: f.db)
        let plan = CaseWholeReading(
            documents: { versions in
                let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
                var out: [CaseReader.Document] = []
                for id in byObject.keys {
                    guard let text = try await objects.fetchContent(id: id), !text.isEmpty else { continue }
                    out.append(CaseReader.Document(objectID: id, sourceVersionID: byObject[id]?.sorted { $0.uuidString < $1.uuidString }.first, fileName: nil, text: text))
                }
                return out
            },
            gate: { CloudSourceGate(resolve: { id in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: privileged.contains(id))) }, legacyPrivileged: { [] }) },
            reader: {
                CaseReader { send in
                    let i = script.record(send)
                    return i == 0 ? dd4Reply(calls: [["tool": "money"]]) : dd4Reply(proposals: [["kind": "claim", "statement": "A payment is recorded"]])
                }
            },
            permissions: CaseReadPermissionStore.inMemory(account: { nil }),
            askConsent: { _ in true })
        return CaseAIAssistService(database: f.db, caseFiles: f.svc, plan: plan, search: nil,
                                   identity: { .init(provider: "test-provider", model: "configured-model-3") })
    }

    private func moneyOutcome(_ f: CaseFileTests.Fixture, privileged: Set<UUID>) async throws -> (outcome: String?, sends: [CaseReadSend]) {
        let script = DD4Script()
        // A distinct note per run: the same request on the same documents would be served from the finished run (AI-12).
        let task = CaseAIAssistTask(kind: .review, note: "run \(UUID().uuidString)")
        let run = try await assistant(f, privileged: privileged, script: script).run(caseID: f.caseID, task: task, actor: "Ada")
        #expect(run.tools.first?.tool == "money", "\(run.tools)")
        return (run.tools.first?.outcome, script.sends)
    }

    @Test("5: an account, holder or statement resting on a document the AI was not sent holds every figure back")
    func moneyToolHoldsAccountsHoldersStatements() async throws {
        for what in ["account", "holder", "statement"] {
            let f = try await CaseFileTests.fixture(title: "Money scope \(what)")
            _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt", text: "Transfer of INR 10,000.")
            let memo = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "counsel.txt", text: "Account 7781 is held by Meera Iyer.")
            let onMemo = what == "account" ? memo.version : nil
            let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "7781", institution: "Coast Bank", currency: "INR", sourceVersionID: onMemo, actor: "Ada")
            if what == "holder" {
                _ = try await f.file.recordAccountRelation(caseID: f.caseID, accountID: acct, holderName: "Meera Iyer", relation: .holder, basis: .source,
                                                           sourceVersionID: memo.version, actor: "Ada")
            }
            if what == "statement" {
                _ = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-03-01", periodEnd: "2026-03-31", opening: "INR 0",
                                                       closing: "INR 10,000", currency: "INR", sourceVersionID: memo.version, actor: "Ada")
            }
            var i = CaseMoneyRecordInput(kind: .payment, amountText: "INR 10,000"); i.date = "2026-03-06"; i.payerAccountID = acct
            _ = try await f.file.recordMoney(caseID: f.caseID, i, actor: "Ada")
            let held = try await moneyOutcome(f, privileged: [memo.object])
            #expect(held.outcome == "rejected", "\(what): figures shown although it rests on a document not sent")
            // The same case with that document sent: the figures are shown.
            let shown = try await moneyOutcome(f, privileged: [])
            #expect(shown.outcome == "ran", "\(what): held although every document was sent")
        }
    }

    @Test("5: a carried money record (job result, exchange import) with no source is held; an investigator's own entry is not")
    func moneyToolHoldsCarriedWithoutSource() async throws {
        let f = try await CaseFileTests.fixture(title: "Carried money")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "statement.txt", text: "Transfer of INR 10,000.")
        var own = CaseMoneyRecordInput(kind: .payment, amountText: "INR 10,000"); own.date = "2026-03-06"
        _ = try await f.file.recordMoney(caseID: f.caseID, own, actor: "Ada")
        #expect(try await moneyOutcome(f, privileged: []).outcome == "ran", "an investigator's entry with no source is not held")
        var carried = CaseMoneyRecordInput(kind: .payment, amountText: "INR 70,000"); carried.date = "2026-03-09"
        _ = try await f.file.recordMoney(caseID: f.caseID, carried, carry: CaseCarryStamp(origin: "job:\(UUID().uuidString):r1:row:3"), actor: "Ada")
        let r = try await moneyOutcome(f, privileged: [])
        #expect(r.outcome == "rejected")
        #expect(r.sends.allSatisfy { !$0.suffix.contains("70,000") })
        // The rule on its own: nothing held when nothing rests outside what was sent.
        let ledger = try await f.file.moneyLedger(caseID: f.caseID)
        #expect(ledger.heldFromAssistant(sent: [], carriedRecordIDs: []) == 0)
        #expect(ledger.heldFromAssistant(sent: [], carriedRecordIDs: Set(ledger.records.map(\.id))) == 2)
    }

    // MARK: 7 — file errors are not public in the log

    @Test("7: LegalProduction and the export path log a file error's description privately")
    func fileErrorsLoggedPrivately() throws {
        for file in ["Kalsmritikosh/Export/LegalProduction.swift", "Kalsmritikosh/App/ExportProtection.swift", "Kalsmritikosh/App/BackupService.swift",
                     "Kalsmritikosh/Investigate/CaseFile/CitedPlaceReader.swift"] {
            let src = try String(contentsOf: dd4Root.appendingPathComponent(file), encoding: .utf8)
            #expect(!src.contains("localizedDescription, privacy: .public"), "\(file)")
        }
    }

    // MARK: 8 — diagnostics paths are cut whole

    @Test("8: a private path is cut to the end of its quoted span or string, with spaces and accents; other paths stay")
    func diagnosticsPathsCutWhole() {
        let cases: [(String, String)] = [
            ("Code 6 at /Users/ada lovelace/Client Files/Meera Iyer.pdf token", "Code 6 at /Users/[path removed]"),
            ("open '/Volumes/Évidence Drive/Dossiers/Núñez — contrat.pdf' failed (errno 2)", "open '/Volumes/[path removed]' failed (errno 2)"),
            ("cache at ~/Library/Caches/Jürgen Müller/x.db", "cache at ~/[path removed]"),
            ("tmp /private/var/folders/xy/T/Meera Iyer.txt", "tmp /private/var/folders/[path removed]"),
            ("file \"/var/folders/ab/T/日本語 ファイル.txt\" is busy", "file \"/var/folders/[path removed]\" is busy"),
            ("“/Users/ada/Café Notes.txt” then /Volumes/USB/Meera Iyer", "“/Users/[path removed]” then /Volumes/[path removed]"),
        ]
        for (raw, want) in cases { #expect(DiagnosticsSanitizer.clean(raw) == want, "\(raw)") }
        for leak in ["Meera", "Núñez", "Jürgen", "Café", "日本語", "lovelace"] {
            #expect(!cases.map { DiagnosticsSanitizer.clean($0.0) }.joined().contains(leak), "\(leak)")
        }
        // System paths and a tilde inside a word are not personal: kept.
        #expect(DiagnosticsSanitizer.clean("/System/Library/Frameworks/Foundation.framework") == "/System/Library/Frameworks/Foundation.framework")
        #expect(DiagnosticsSanitizer.clean("version~/x") == "version~/x")
        // Through the whole sanitizer, a JSON payload with such a value.
        let payload = Data(#"{"diagnosticMetaData":{"terminationReason":"at /Volumes/Case Drive/Meera Iyer/a.pdf"}}"#.utf8)
        let clean = String(decoding: DiagnosticsSanitizer.sanitize(payload), as: UTF8.self)
        #expect(!clean.contains("Meera") && !clean.contains("Case Drive") && clean.contains("/Volumes/[path removed]"), "\(clean)")
    }

    // MARK: 9 — masking and the redaction check fold accents and line breaks

    @Test("9: the online masker masks a protected name written without its accents, in another case, or across a line break")
    func maskerFoldsAccentsAndBreaks() {
        let m = OnlinePIIMasker(names: ["José Núñez", "Jane Doe", "Jane Doe Smith"])
        let input = "👍🏽 Jose  Nunez met JANE\nDOE.\r\nJOSÉ NÚÑEZ paid Jane Doe Smith; Núñez alone stays."
        let out = m.mask(input)
        for leak in ["Jose", "Nunez", "JANE", "DOE", "JOSÉ", "NÚÑEZ", "Smith"] { #expect(!out.text.contains(leak), "\(leak) in \(out.text)") }
        #expect(out.text.hasPrefix("👍🏽 [NAME_"), "\(out.text)")
        #expect(out.text.contains("Núñez alone stays"), "a part of a name alone is not the name: \(out.text)")
        #expect(OnlinePIIMasker.unmask(out.text, mapping: out.mapping) == input, "restored exactly as written")
        // The longer name is found first and keeps its own placeholder.
        let both = m.mask("Jane Doe Smith and Jane Doe")
        #expect(both.mapping.values.contains("Jane Doe Smith") && both.mapping.values.contains("Jane Doe"), "\(both.mapping)")
        // ASCII text behaves as before.
        #expect(OnlinePIIMasker(names: ["Meera Iyer"]).mask("Ask meera iyer.").text == "Ask [NAME_1].")
    }

    @Test("9: the redaction check finds a protected name written without its accents, and stays at least as strict as before")
    func verifierFoldsAccents() {
        let v = RedactionVerifier()
        #expect(v.leaks(in: "Paid to Jose Nunez on 3 March", protectedTerms: ["José Núñez"]).first?.channel == .diacriticFolded)
        #expect(v.leaks(in: "Paid to JOSE\nNUNEZ", protectedTerms: ["José Núñez"]).count == 1)
        #expect(v.leaks(in: "Paid to José Núñez", protectedTerms: ["Jose Nunez"]).count == 1, "the other way round too")
        #expect(v.leaks(in: "Jane\nDoe signed", protectedTerms: ["Jane Doe"]).first?.channel == .whitespaceCollapsed)
        #expect(v.leaks(in: "Jo<b>sé Nú</b>ñez", protectedTerms: ["José Núñez"]).count == 1)
        // The earlier channels are unchanged.
        #expect(v.leaks(in: "José Núñez", protectedTerms: ["José Núñez"]).first?.channel == .exact)
        #expect(v.leaks(in: "josé núñez", protectedTerms: ["José Núñez"]).first?.channel == .caseInsensitive)
        #expect(v.isClean("Josephine Nuno paid", of: ["José Núñez"]))
        // The export gate uses the same check: a sealed file holding the unaccented spelling is refused.
        let refused = ProtectedIdentityCache.TestOverride.$names.withValue(["José Núñez"]) { ProtectedExport.prepare("Jose Nunez was paid.", refuseIfPresent: true) }
        guard case .failure = refused else { Issue.record("a sealed file with the unaccented name passed"); return }
    }
}
