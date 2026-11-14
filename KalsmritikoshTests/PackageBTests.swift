//
//  PackageBTests.swift
//  KalsmritikoshTests
//
//  Package B (2026-11-06) — scaffolding only, deterministic, no network: the relay model mirror (Opus 5.5),
//  CloudReaders.isEmpty, LN1 (question-only sends in a case carry the case marker and are erased with it),
//  LN3 (the setup sheet names the posture change), the coverage readout (read / partly / not read with
//  reasons) in the report with the evidence requests, the reviewed item handed to the report without
//  retyping, and the cost/recovery words (fake failures, no transport).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Package B — relay mirror, readers, legal fixes, coverage, report, cost and recovery", .serialized)
struct PackageBTests {

    // MARK: B1

    @Test("B1: AI plans use Opus 5.5 for estimates; reservations stay at the dearest fallback (Opus 5); the own key stays Opus 5")
    func relayModelMirror() {
        #expect(AIPricing.relayModel == "claude-opus-5-5" && OnlineProviderKind.included.defaultModel == "claude-opus-5-5")
        #expect(OnlineProviderKind.anthropic.defaultModel == "claude-opus-5")
        #expect(OnlineProviderKind.included.displayName.contains("Opus 5.5"))
        // Cheaper actual cost: the same usage costs 20 % less on Opus 5.5, 60 % less for cache reads.
        let u: [String: Any] = ["input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000]
        #expect(AIPricing.actualUSD(model: "claude-opus-5-5", usage: u) == 4 + 20 + 0.2)
        #expect(AIPricing.actualUSD(model: "claude-opus-5", usage: u) == 5 + 25 + 0.5)
        // The worst case reserved is unchanged from Opus 5 (a fallback model may answer at its rates), so
        // the plans' whole-case limits are unchanged.
        #expect(AIPricing.relayReservation(inputCharacters: 300_000, maxOutputTokens: 10_000) == Int(((Double(100_064) * 5 + 10_000 * 25) / 10_000).rounded(.up)))
        #expect(AIPricing.caseReadTokenCeiling(creditCeiling: AIPricing.aiIncluded.caseReadCredits) > 0)
        #expect(AIPricing.dearestRates(["claude-unknown"]) == AIPricing.dearestRates([]))
    }

    // MARK: B2

    @Test("B2: CloudReaders.isEmpty reflects every reader, including the role, draft and whole-case readers")
    func readersIsEmpty() {
        #expect(CloudReaders().isEmpty)
        var r = CloudReaders(); r.roleReader = VerifiedRoleReader { _, _ in "" }
        #expect(!r.isEmpty)
        r = CloudReaders(); r.draftReader = CaseDraftReader { _, _ in "" }
        #expect(!r.isEmpty)
        r = CloudReaders(); r.caseReader = CaseReader { _ in .init(text: "") }
        #expect(!r.isEmpty)
    }

    // MARK: B3

    @Test("LN1: a question-only send made while asking in a case carries the case marker; outside a case it does not")
    func questionOnlySendCarriesCaseMarker() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let reply = Data(#"{"content":[{"type":"text","text":"{}"}],"usage":{"input_tokens":3,"output_tokens":2}}"#.utf8)
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in true },
                                              transport: { _ in OutboundHTTPResponse(status: 200, body: reply) })
        seams.ownKeyRefusal = { _ in nil }
        seams.ownKeyTally = { _, _ in }
        let repo = OutboundLogRepository(database: db)
        let provider = OnlineCloudProvider(outboundLog: repo, knownNames: { [] }, seams: seams)
        let caseID = UUID()
        _ = try await CaseSendScope.$caseID.withValue(caseID) {
            try await provider.generateQuestionOnly(prompt: "Who signed the SECRET amendment?", options: GenerationOptions(maxTokens: 16))
        }
        _ = try await provider.generateQuestionOnly(prompt: "an archive question", options: GenerationOptions(maxTokens: 16))
        let log = try await repo.recent()
        let marker = OnlineCloudProvider.caseMarker(caseID)
        let inCase = log.filter { $0.payloadText.contains("SECRET") }
        #expect(!inCase.isEmpty && inCase.allSatisfy { ($0.detail ?? "").contains(marker) }, "\(inCase.map(\.detail))")
        #expect(log.filter { $0.payloadText.contains("an archive question") }.allSatisfy { !($0.detail ?? "").contains("case ") })
    }

    @Test("LN3: the setup sheet says it changes Fully private to evidence-gated, and says nothing else changes otherwise")
    func setupSheetNamesPostureChange() {
        let fromPrivate = AISetupText.turnsOn(regime: .fullyPrivate)
        #expect(fromPrivate.contains(AIRegime.fullyPrivate.label) && fromPrivate.contains(AIRegime.gated.label))
        #expect(!AISetupText.turnsOn(regime: .gated).contains(AIRegime.fullyPrivate.label))
        #expect(!AIRegime.gated.summary.contains("nothing leaves your Mac") && !AIRegime.free.summary.contains("100%"))
    }

    // MARK: B5

    static func item(_ v: UUID, _ state: SourceCompletionState, limits: [String] = [], blockers: [String] = [], root: Bool = true) -> CaseCoverageItem {
        CaseCoverageItem(logicalSourceID: UUID(), sourceVersionID: v, sourceType: .pdf, isDirectRoot: root, parentPaths: ["root:pdf"],
                         completionState: state, isSearchReady: state == .evidenceReady, isEvidenceReady: state == .evidenceReady,
                         isAnalyticallyReady: false, limitations: limits, blockers: blockers, custodyMode: "referenced", preservationStatus: "ok")
    }

    static func manifest(_ items: [CaseCoverageItem], unadmitted: [UnadmittedContainerMemberItem] = [], limitations: [String] = []) -> CaseCoverageManifest {
        let z = CaseCoverageSummary(directRoots: 0, canonicalSources: items.count, sourceOccurrences: items.count, containerMembersDiscovered: 0,
                                    containerMembersAdmitted: 0, containerMembersNotAdmitted: 0, searchable: 0, evidenceReady: 0, analyticallyReady: 0,
                                    preservedOnly: 0, deferred: 0, encrypted: 0, corrupt: 0, unsupported: 0, failed: 0, safetyBlocked: 0, unavailable: 0)
        return CaseCoverageManifest(workspaceID: UUID(), workspaceUpdatedAt: Date(timeIntervalSince1970: 0), generatedAt: Date(timeIntervalSince1970: 0),
                                    directRoots: items, canonicalSources: items, unadmittedContainerMembers: unadmitted, summary: z,
                                    limitations: limitations, blockers: [])
    }

    @Test("B5: the coverage readout counts read, partly and not read with the reason, keeps to the case scope and names unadmitted members")
    func coverageReadout() {
        let ok = UUID(), legacy = UUID(), scan = UUID(), locked = UUID(), odd = UUID(), zip = UUID(), outside = UUID(), empty = UUID()
        let m = Self.manifest([
            Self.item(ok, .evidenceReady), Self.item(legacy, .preservedOnly), Self.item(empty, .preservedOnly),
            Self.item(scan, .searchablePartial, limits: ["ocr: partial"]), Self.item(locked, .encrypted),
            Self.item(odd, .unsupported), Self.item(zip, .evidenceReady), Self.item(outside, .failed),
        ], unadmitted: [UnadmittedContainerMemberItem(parentSourceVersionID: zip, memberID: UUID(), memberPath: "inner/huge.mov",
                                                      detectedType: nil, disposition: .blockedSizeLimit, detail: nil)],
           limitations: ["Container \(zip.uuidString.prefix(8)) has not been inspected (container inspection missing)."])
        let labels = [ok: "a.pdf", legacy: "old.docx", scan: "scan.pdf", locked: "statement.pdf", odd: "file.xyz", zip: "bundle.zip", empty: "blank.pdf"]
        let r = CaseCoverageReadout.make(manifest: m, scope: [ok, legacy, scan, locked, odd, zip, empty], labels: labels, hasLedgerText: [legacy])
        #expect(r.read == 3, "a.pdf, bundle.zip and old.docx (no readiness record, text in the ledger)")
        #expect(r.partlyRead == [.init(name: "scan.pdf", status: .partlyRead, reason: "some pages could not be read (text recognition failed)")])
        #expect(Set(r.notRead.map(\.name)) == ["statement.pdf", "file.xyz", "blank.pdf", "huge.mov (in bundle.zip)"])
        #expect(r.notRead.first { $0.name == "statement.pdf" }?.reason == "password-protected")
        #expect(r.notRead.first { $0.name == "file.xyz" }?.reason == "unsupported file type")
        #expect(r.notRead.first { $0.name.hasPrefix("huge.mov") }?.reason == "too large")
        #expect(!r.entries.contains { $0.name.contains(outside.uuidString.prefix(8)) }, "a source outside the case is not counted")
        #expect(r.summaryLine.hasPrefix("Read: 3 · Partly read: 1 · Not read: 4"))
        #expect(r.notes == ["The archive bundle.zip has not been opened yet, so what it holds is not counted."])
        #expect(r.reportSection.contains("## What the app could read") && r.reportSection.contains("statement.pdf — not read: password-protected"))
        #expect(r.total == 3 + 5)
    }

    @Test("LS14: a case document the coverage record does not list is counted — read with ledger text, else not read with no reading record; another version of a listed document is not a second document")
    func coverageCountsUnlistedCaseDocuments() {
        let listed = UUID(), withText = UUID(), noRecord = UUID(), olderOfListed = UUID(), twinA = UUID(), twinB = UUID()
        let item = Self.item(listed, .evidenceReady)
        let m = Self.manifest([item])
        let twinSource = UUID()
        let r = CaseCoverageReadout.make(manifest: m, scope: [listed, withText, noRecord, olderOfListed, twinA, twinB],
                                         labels: [listed: "a.pdf", noRecord: "memo.docx"], hasLedgerText: [withText, twinA, twinB],
                                         logicalSources: [olderOfListed: item.logicalSourceID, twinA: twinSource, twinB: twinSource])
        #expect(r.read == 3, "a.pdf, the unlisted document with text, and the two versions of one document counted once")
        #expect(r.notRead == [.init(name: "memo.docx", status: .notRead, reason: CaseCoverageReadout.noReadingRecord)])
        #expect(r.total == 4)
        #expect(r.summaryLine == "Read: 3 · Partly read: 0 · Not read: 1 (1 no reading record)")
        #expect(r.entryLines == ["memo.docx — not read: no reading record"])
        // Without a scope (the whole workspace) nothing is added.
        #expect(CaseCoverageReadout.make(manifest: m, scope: nil, labels: [:], hasLedgerText: []).total == 1)
    }

    @Test("B5: the permission sheet carries what was not read and the balance; a plain request has neither")
    func consentRequestCarriesCoverage() {
        let plain = CaseReadConsentRequest(caseID: UUID(), provider: "p", documents: [], excluded: [], totalBytes: 0, estimatedTokens: 0,
                                           readsWhole: true, estimate: "e", fingerprint: "f")
        #expect(plain.notReadable.isEmpty && plain.balance == nil)
        let r = CaseReadConsentRequest(caseID: UUID(), provider: "p", documents: [], excluded: [], totalBytes: 0, estimatedTokens: 0,
                                       readsWhole: true, estimate: "e", fingerprint: "f",
                                       notReadable: [.init(name: "statement.pdf", bytes: 0, reason: "not read: password-protected")],
                                       balance: CaseReadCostLines.balance(840))
        #expect(r.notReadable.count == 1 && r.balance == "You have 840 credits left (this month's allowance and credit packs).")
    }

    // MARK: B6

    @Test("B6: the case report carries the coverage and the evidence requests (status, received versions, missing); a confirmed item is in it without retyping")
    @MainActor func reportHandover() async throws {
        let f = try await CaseFileTests.fixture()
        let a = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "invoice-a.txt",
                                                          text: "The invoice total was 500 dollars. It was paid in March.")
        let b = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "invoice-b.txt",
                                                          text: "The invoice total was 650 dollars. It was paid in April.")
        let evidence = EvidenceStore(database: f.db)
        let contradictions = ContradictionsRepository(database: f.db)
        let desk = InvestigationContradictionGapService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                        contradictions: contradictions, gaps: GapNodeRepository(database: f.db),
                                                        reviews: InvestigationDeskReviewRepository(database: f.db))
        let finding = CaseContradictionFinder.Finding(kind: .amount, subject: "The invoice", attribute: "total",
                                                      quoteA: "The invoice total was 500 dollars.", quoteB: "The invoice total was 650 dollars.",
                                                      objectA: a.object, objectB: b.object, versionA: a.version, versionB: b.version,
                                                      valueA: "500 dollars", valueB: "650 dollars", provenance: .rules)
        await contradictions.insertMany([finding.contradiction()])
        let id = finding.contradiction().id
        _ = try await desk.reviewContradiction(caseID: f.caseID, contradictionID: id, decision: .confirmed, reason: nil, note: "same invoice", actor: "Ada", at: Date())
        let item = try #require(try await desk.contradictionReviewItems(caseID: f.caseID).first { $0.id == id })
        try await JobResultHandoff.addReviewedToReport(item, caseFiles: f.svc, actor: "Ada")
        let snap = try #require(try await f.svc.snapshot(caseID: f.caseID, custody: []))

        let reqID = UUID(), march = UUID(), april = UUID(), now = Date(timeIntervalSince1970: 1_780_000_000)
        let request = EvidenceRequest(id: reqID, caseID: f.caseID, hypothesisID: nil, description: "Bank statements", status: .partial, revision: 2,
                                      actor: "Ada", createdAt: now, updatedAt: now, custodian: "First Bank", dueAt: now)
        let file = EvidenceRequestFile(
            request: request,
            items: [EvidenceRequestItem(id: march, requestID: reqID, ordinal: 0, label: "March", periodStart: nil, periodEnd: nil),
                    EvidenceRequestItem(id: april, requestID: reqID, ordinal: 1, label: "April", periodStart: nil, periodEnd: nil)],
            receipts: [EvidenceRequestReceipt(id: UUID(), requestID: reqID, itemID: march, sourceVersionID: a.version, knowledgeObjectID: a.object,
                                              contentHash: "abcdef0123456789", duplicateOf: nil, origin: .manual, note: nil, linkedBy: "Ada",
                                              linkedAt: now, withdrawnBy: nil, withdrawnAt: nil, withdrawnReason: nil)],
            events: [])
        let coverage = CaseCoverageReadout(read: 2, entries: [.init(name: "statement-april.pdf", status: .notRead, reason: "password-protected")], notes: [])
        let report = CaseFileDocuments.caseFileReport(snap, coverage: coverage, requests: [file], by: "Ada")
        #expect(report.contains(JobResultHandoff.reviewText(item.contradiction)), "the confirmed item, as reviewed — nothing retyped")
        #expect(report.contains("## Reviewed results included in this report") || report.contains("## Provisional material included in this report"))
        #expect(report.contains("## What the app could read") && report.contains("Read: 2 · Partly read: 0 · Not read: 1 (1 password-protected)"))
        #expect(report.contains("statement-april.pdf — not read: password-protected"))
        #expect(report.contains("## Evidence requests") && report.contains("Bank statements — **Partly provided** · from First Bank"))
        #expect(report.contains("1 of 2 received · still missing: April"))
        #expect(report.contains("Received (source version): \(a.version.uuidString.prefix(8)) SHA-256 abcdef012345"))
        // Without a readout the report says the coverage was not available, never that everything was read.
        #expect(CaseFileDocuments.caseFileReport(snap, by: "Ada").contains("Not available when this report was written"))
    }

    // MARK: B7

    @Test("B7: each failure names its cause and one fix; a failed request is said not to be charged, a timeout is not promised zero")
    func recovery() {
        let credits = CaseReadRecovery.make(kind: .other, reason: AIPricing.creditsUsedMessage(estimate: 400, balance: 10), offers: [.buyCredits, .upgrade])
        #expect(credits?.fix == .buyCredits && credits?.charge.hasPrefix("Nothing was charged") == true)
        #expect(CaseReadRecovery.make(kind: .other, reason: AIPricing.tooCostlyMessage(estimate: 900, ceiling: 600, large: true), offers: [.upgrade])?.fix == .upgrade)
        let paused = CaseReadRecovery.make(kind: .other, reason: "The AI service has reached this month's capacity and is paused until the 1st.", offers: [])
        #expect(paused?.fix == .tryLater)
        #expect(CaseReadRecovery.make(kind: .other, reason: AIPricing.dailyLimitMessage(limit: 1500), offers: [])?.fix == .tryLater)
        #expect(CaseReadRecovery.make(kind: .invalidKey, reason: "", offers: [])?.fix == .openSettings)
        #expect(CaseReadRecovery.make(kind: .network, reason: "", offers: [])?.fix == .retry)
        let timeout = CaseReadRecovery.make(kind: .timeout, reason: "", offers: [])
        #expect(timeout?.fix == .retry && timeout?.charge.contains("may still have been charged") == true)
        #expect(CaseReadRecovery.make(kind: .declined, reason: "", offers: []) == nil)
        #expect(CaseReadRecovery.make(kind: nil, reason: "", offers: []) == nil)
        // A real failure classified from a fake transport's reply (no network): a 401 is the key.
        let parsed: Error
        do { _ = try OnlineRequestBuilder.parse(kind: .anthropic, response: OutboundHTTPResponse(status: 401, body: Data("{}".utf8))); return }
        catch { parsed = error }
        #expect(CaseReadRecovery.make(kind: OnlineFailure.classify(parsed), reason: parsed.localizedDescription, offers: [])?.fix == .openSettings)
        #expect(CaseReadFix.allTitles.count == 5)
        #expect(CaseReadCostLines.charged(12, balance: 1_828) == "This read was charged 12 credits (the actual cost). 1,828 left.")
        #expect(CaseReadCostLines.cancelled.contains("only what it actually used is charged"))
        #expect(CaseReadCostLines.progress(planBalance: nil, onPlan: true).contains("charges only what is used"))
    }
}

extension CaseReadFix {
    static var allTitles: Set<String> { Set([CaseReadFix.buyCredits, .upgrade, .retry, .openSettings, .tryLater].map(\.title)) }
}
