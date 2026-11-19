//
//  UIWalkSimulatedPlanTests.swift
//  KalsmritikoshTests
//
//  GUI walk support (release gate ui-consent-and-plans): the DEBUG-only `--ui-walk-simulated-plan=aiIncluded|aiPro`
//  launch argument. It gives the process a simulated verified AI plan and a local credit receipt so the real plan
//  picker, credit meter and per-case permission sheet render — and nothing can be sent, bought or stored for good.
//  The tests use the per-task override (`UIWalkSimulatedPlan.$testPlan`) or private centres and meters, so no
//  other suite running in parallel sees a simulated plan.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("GUI walk — DEBUG-only simulated AI plan", .serialized)
struct UIWalkSimulatedPlanTests {

    static let walkArgs = ["Kalsmritikosh", "--acceptance-case", "--ui-walk-simulated-plan=aiIncluded"]

    // MARK: - The decision

    @Test("Honoured only with --acceptance-case or in sample mode; refused (and so ignored) otherwise; unknown plans refused")
    func decision() {
        #expect(UIWalkSimulatedPlan.decide(arguments: Self.walkArgs, sampleMode: false) == .active(.aiIncluded))
        let pro = ["Kalsmritikosh", "--ui-walk-simulated-plan=aiPro"]
        #expect(UIWalkSimulatedPlan.decide(arguments: pro, sampleMode: true) == .active(.aiPro))
        let alone = UIWalkSimulatedPlan.decide(arguments: pro, sampleMode: false)
        guard case .refused(let why) = alone else {
            Issue.record("without a disposable ledger the argument must be refused, got \(alone)")
            return
        }
        #expect(why.contains("--acceptance-case"))
        let unknown = ["Kalsmritikosh", "--acceptance-case", "--ui-walk-simulated-plan=workbench"]
        if case .refused = UIWalkSimulatedPlan.decide(arguments: unknown, sampleMode: false) {} else {
            Issue.record("an unknown plan must be refused")
        }
        #expect(UIWalkSimulatedPlan.decide(arguments: ["Kalsmritikosh", "--acceptance-case"], sampleMode: false) == .notRequested)
    }

    @MainActor
    @Test("The disposable-ledger argument it requires is the acceptance fixture's own")
    func sameAcceptanceArgument() {
        #expect(UIWalkSimulatedPlan.acceptanceArgument == AcceptanceCaseGUIFixture.launchArgument)
    }

    // MARK: - Plan state and meter

    @MainActor
    @Test("Applied: a verified AI plan (AI Included or AI Pro), its relay credential stand-in, and the meter's local receipt with some credits used")
    func planAndMeterApplied() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let center = PurchaseCenter(talksToStore: false, publishes: false)
        let meter = AICreditMeter()
        let plan = UIWalkSimulatedPlan.activate(arguments: Self.walkArgs, sampleMode: false, center: center, meter: meter,
                                                publishProcessWide: false, now: now)
        #expect(plan == .aiIncluded)
        #expect(center.entitlement.aiTier == .aiIncluded)
        #expect(center.entitlement.allowsPaidUse)
        #expect(center.entitlement.verifiedUntil == now.addingTimeInterval(30 * 86_400))
        let signed = try #require(center.aiSignedTransaction)
        #expect(AIIncludedRelay.isValidSignedTransaction(signed), "the stand-in has the shape the app checks")
        #expect(center.aiSubscriptionID == UIWalkSimulatedPlan.subscriptionID)
        #expect(meter.tier == .aiIncluded)
        let used = UIWalkSimulatedPlan.creditsUsed
        let left = AIPricing.aiIncluded.monthlyCredits - used
        #expect(meter.balance == left)
        let summary = try #require(meter.summaryLine)
        let expected = "\(left.formatted()) of \(AIPricing.aiIncluded.monthlyCredits.formatted()) credits left this month"
        #expect(summary.contains(expected), "meter line: \(summary)")
        #expect(meter.resetText != nil)
        #expect(UIWalkSimulatedPlan.launchPlan == nil, "a test's activation is never process-wide")

        let proCenter = PurchaseCenter(talksToStore: false, publishes: false)
        let proMeter = AICreditMeter()
        let proArgs = ["Kalsmritikosh", "--acceptance-case", "--ui-walk-simulated-plan=aiPro"]
        UIWalkSimulatedPlan.activate(arguments: proArgs, sampleMode: false, center: proCenter, meter: proMeter,
                                     publishProcessWide: false, now: now)
        #expect(proCenter.entitlement.aiTier == .aiPro)
        #expect(proMeter.balance == AIPricing.aiPro.monthlyCredits - used)
        #expect(proMeter.limits == AIPricing.aiPro)
    }

    @MainActor
    @Test("Without --acceptance-case or sample mode the argument is ignored: no plan, no receipt, nothing process-wide")
    func ignoredOnTheOwnersLedger() {
        let center = PurchaseCenter(talksToStore: false, publishes: false)
        let meter = AICreditMeter()
        let args = ["Kalsmritikosh", "--ui-walk-simulated-plan=aiIncluded"]
        let plan = UIWalkSimulatedPlan.activate(arguments: args, sampleMode: false, center: center, meter: meter,
                                                publishProcessWide: true)
        #expect(plan == nil)
        #expect(center.entitlement == .unknown)
        #expect(center.aiSignedTransaction == nil)
        #expect(meter.tier == nil && meter.receipt == nil && meter.balance == nil)
        #expect(UIWalkSimulatedPlan.launchPlan == nil)
        #expect(!UIWalkSimulatedPlan.isActive)
    }

    // MARK: - The permission sheet

    nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _consents: [CaseReadConsentRequest] = []
        private var _sends = 0
        func consent(_ c: CaseReadConsentRequest) -> Bool { lock.withLock { _consents.append(c) }; return true }
        func sent() { lock.withLock { _sends += 1 } }
        var consents: [CaseReadConsentRequest] { lock.withLock { _consents } }
        var sends: Int { lock.withLock { _sends } }
    }

    static let text = "Invoice INV-2041 from Dalmia Traders for ₹10,000 was paid on 4 March 2026."

    @Test("The sheet's request is produced with the documents and the simulated balance; Allow is kept in memory, not in the defaults")
    func sheetRequestProduced() async throws {
        let caseID = UUID(), object = UUID(), version = UUID()
        let recorder = Recorder()
        let plan = CaseWholeReading(
            documents: { _ in [CaseReader.Document(objectID: object, sourceVersionID: version, fileName: "invoice-INV-2041.md", text: Self.text)] },
            gate: { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                    legacyPrivileged: { [] }) },
            reader: { nil },
            permissions: .live,
            askConsent: { recorder.consent($0) },
            providerName: { OnlineProviderKind.included.displayName })
        var withBalance = plan
        let balance = AIPricing.aiIncluded.monthlyCredits - UIWalkSimulatedPlan.creditsUsed
        withBalance.balanceLine = { CaseReadCostLines.balance(balance) }
        let binding = CloudScopeBinding(scopeID: caseID) { [object: [version]] }

        let allowed = await UIWalkSimulatedPlan.$testPlan.withValue(.aiIncluded) { () async -> Bool in
            let (prepared, _) = await withBalance.prepare(caseID: caseID, versions: [version], binding: binding)
            guard let prepared else { return false }
            let ok = await withBalance.permitted(caseID: caseID, prepared: prepared, question: "When was INV-2041 paid?")
            // Kept for the rest of the walk: asked once per case.
            let again = await withBalance.permitted(caseID: caseID, prepared: prepared, question: "Who paid it?")
            let stored = CaseReadPermissionStore.live.permission(caseID: caseID)
            return ok && again && stored?.documentCount == 1
        }
        #expect(allowed)
        #expect(recorder.consents.count == 1, "the sheet is shown once for the case")
        let request = try #require(recorder.consents.first)
        #expect(request.caseID == caseID)
        #expect(request.documents.map(\.name) == ["invoice-INV-2041.md"])
        #expect(request.provider == OnlineProviderKind.included.displayName)
        #expect(request.balance == CaseReadCostLines.balance(balance))
        #expect(CaseReadPermissionStore.live.permission(caseID: caseID) == nil,
                "outside the simulation nothing was stored: the permission never reached the person's defaults")
        #expect(UserDefaults.standard.data(forKey: CaseReadPermissionStore.keyPrefix + caseID.uuidString) == nil)
    }

    // MARK: - Dispatch refused

    static func provider(_ recorder: Recorder, db: Database? = nil) -> OnlineCloudProvider {
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .included, model: OnlineProviderKind.included.defaultModel,
                                      apiKey: UIWalkSimulatedPlan.signedTransaction,
                                      confirmedDocumentTerms: OnlineProviderKind.included.documentTermsVersion, dailyByteCap: nil)
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in true },
                                              transport: { _ in recorder.sent(); return OutboundHTTPResponse(status: 500, body: Data()) })
        seams.casePermission = { _, _ in true }
        return OnlineCloudProvider(outboundLog: db.map { OutboundLogRepository(database: $0) }, knownNames: { [] }, seams: seams)
    }

    @Test("Allow on the sheet still sends nothing: the provider refuses before its transport ('Walk simulation — nothing sent')")
    func dispatchRefused() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let recorder = Recorder()
        let provider = Self.provider(recorder, db: db)
        let caseID = UUID(), object = UUID(), version = UUID()
        let binding = CloudScopeBinding(scopeID: caseID) { [object: [version]] }
        let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                              legacyPrivileged: { [] }).bound(to: binding).clear([object], purpose: "case.reading").clearance
        let send = CaseReadSend(caseID: caseID, prefix: [CaseReader.header, "[Document 1]\n" + Self.text + "\n\n" + CaseReader.footer],
                                suffix: CaseReader.questionSuffix("When was it paid?"), ttl: .fiveMinutes, purpose: "case.question",
                                clearance: clearance)

        let caseRead: String = await UIWalkSimulatedPlan.$testPlan.withValue(.aiIncluded) {
            do { _ = try await provider.readCase(send); return "sent" } catch { return error.localizedDescription }
        }
        #expect(caseRead == UIWalkSimulatedPlan.refusalText)
        let question: String = await UIWalkSimulatedPlan.$testPlan.withValue(.aiPro) {
            do {
                _ = try await provider.generateQuestionOnly(prompt: "When was INV-2041 paid?", options: GenerationOptions(maxTokens: 16, temperature: 0))
                return "sent"
            } catch { return error.localizedDescription }
        }
        #expect(question == UIWalkSimulatedPlan.refusalText)
        #expect(recorder.sends == 0, "nothing reached the transport seam")
        let log = try await OutboundLogRepository(database: db).recent()
        #expect(log.filter { ($0.detail ?? "").contains("walk simulation — nothing sent") }.count == 2)
        #expect(!log.contains { $0.outcome == "sent" || $0.outcome == "pending" })

        // Control: the same provider without the simulation does reach its transport.
        _ = try? await provider.generateQuestionOnly(prompt: "When?", options: GenerationOptions(maxTokens: 16, temperature: 0))
        #expect(recorder.sends == 1, "the seam is wired; only the simulation stopped it")
    }

    @Test("The network helper client refuses too, whatever the caller (relay status, credit packs, lookups)")
    func networkClientRefuses() async {
        let request = OutboundHTTPRequest(url: "https://relay.ui-walk.invalid/v1/status", headers: [:], body: Data())
        let refused: Bool = await UIWalkSimulatedPlan.$testPlan.withValue(.aiIncluded) {
            do { _ = try await NetworkHelperClient.send(request); return false } catch { return error is UIWalkSimulatedPlan.NothingSent }
        }
        #expect(refused)
    }

    @Test("Under the simulation the relay host is the reserved .invalid name, so a request could not resolve anyway")
    func reservedHost() {
        let host = UIWalkSimulatedPlan.$testPlan.withValue(.aiIncluded) { AIIncludedRelay.activeHost }
        #expect(host == "relay.ui-walk.invalid")
        #expect(host.hasSuffix(".invalid"))
    }

    // MARK: - Switches held in memory

    @Test("The AI setup sheet's switches are kept in memory: the stored values are put back and the new ones returned as volatile")
    func switchesKeptInMemory() throws {
        let name = "kalsmritikosh.tests.uiwalk.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("privateMode", forKey: "walk.mode")
        defaults.set(false, forKey: "walk.reading")
        var volatile: [String: Any] = [:]
        let changed = UIWalkSimulatedPlan.keepInMemory(defaults: defaults, domain: name, volatile: { volatile = $0 }) {
            defaults.set("online", forKey: "walk.mode")
            defaults.set(true, forKey: "walk.reading")
            defaults.set("v2", forKey: "walk.terms")
        }
        #expect(changed["walk.mode"] as? String == "online")
        #expect(changed["walk.reading"] as? Bool == true)
        #expect(changed["walk.terms"] as? String == "v2")
        #expect(volatile.count == 3)
        let stored = defaults.persistentDomain(forName: name) ?? [:]
        #expect(stored["walk.mode"] as? String == "privateMode", "the stored choice is unchanged")
        #expect(stored["walk.reading"] as? Bool == false)
        #expect(stored["walk.terms"] == nil, "a new key is not left behind")
    }

    // MARK: - Release guard

    static var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test("The release guard covers the argument and its type, and its self-test (run by ci/guards) proves an unwrapped one is flagged")
    func releaseGuardCoversIt() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/release-check-debug-args.sh"), encoding: .utf8)
        #expect(script.contains("\"--ui-walk-simulated-plan\""))
        #expect(script.contains("\"UIWalkSimulatedPlan\""))
        let selftest = try String(contentsOf: Self.repoRoot.appendingPathComponent("ci/guards/release-check-selftest.sh"), encoding: .utf8)
        #expect(selftest.contains("test_release_check_debug_args.py"))
        let fixtures = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/tests/test_release_check_debug_args.py"), encoding: .utf8)
        #expect(fixtures.contains("test_simulated_plan_argument_outside_debug_fails"))
        #expect(fixtures.contains("test_simulated_plan_type_outside_debug_fails"))
        // The product file itself opens with `#if DEBUG` before any mention of the type.
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent("Kalsmritikosh/App/UIWalkSimulatedPlan.swift"), encoding: .utf8)
        #expect(source.hasPrefix("#if DEBUG"))
        #expect(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
    }
}
