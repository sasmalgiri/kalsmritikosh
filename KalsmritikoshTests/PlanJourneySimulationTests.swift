//
//  PlanJourneySimulationTests.swift
//  KalsmritikoshTests
//
//  Plans and credits + plan A (owner decisions 2026-11-04) — one SIMULATED end-to-end journey per plan,
//  composed from the real units in sequence:
//
//    StoreKit purchase (SKTestSession, the committed .storekit) → PurchaseCenter's verified entitlement
//    → plan tier / AI subscription number → AICreditMeter (the app's credit mirror) → the case's
//    permission sheet (CaseWholeReading + CaseReadPermissionStore, pinned to the document set)
//    → InvestigationAnswerService's whole-case path → OnlineCloudProvider.readCase (eligibility,
//    stored-permission fingerprint, masking, re-clearance, outbound record) → a scripted transport
//    → the verifier (CaseReader.verdict) → the shown answer.
//
//  Simulated seams (no network anywhere):
//    • the transport: a fake Anthropic API (own key) and a fake relay that mirrors relay/src/policy.ts +
//      index.ts `metered` (worst-case reservation, ceilings, daily limit, allowance → packs, charge the
//      actual usage rounded up, refunds, the `kals` receipt, the refusal codes);
//    • the relay's crediting of a credit pack (the app's relay host is empty in this build);
//    • the own-key monthly tally — the same OwnKeyBudget call readCase makes, at a fixed past month so the
//      real tally is never touched;
//    • the consent sheet's Allow / Not now (a recorder answers it).
//
//  Nested in PurchaseStoreKitTests (serialized) so these journeys never run alongside its SKTestSession
//  tests: the StoreKit testing environment is one per process.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Kalsmritikosh

extension PurchaseStoreKitTests {

@Suite("Plan journeys — simulated end to end (Workbench, AI Included, AI Pro, offline)", .serialized)
@MainActor
struct PlanJourneySimulationTests {

    // MARK: - StoreKit (same configuration and quirks as PurchaseStoreKitTests)

    private static func session() throws -> SKTestSession {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try SKTestSession(contentsOf: root.appendingPathComponent("StoreKit/Kalsmritikosh.storekit"))
        s.resetToDefaultState()
        s.disableDialogs = true
        s.clearTransactions()
        // Never set storefront/locale (paid purchases then fail with "Item Unavailable" here).
        AppDefaults.store.removeObject(forKey: CachedEntitlement.key)
        return s
    }

    private static func centre() async -> PurchaseCenter {
        let c = PurchaseCenter(talksToStore: true)
        c.aiSellable = { true }   // the relay's /v1/sellable answer, scripted
        await c.loadProducts()
        await c.refresh()
        return c
    }

    @discardableResult
    private static func settle(_ c: PurchaseCenter, within seconds: Double = 8, until done: (Entitlement) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            await c.refresh()
            if done(c.entitlement) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - The case

    nonisolated struct Doc: Sendable { let version: UUID; let object: UUID; let name: String; let text: String }

    static let sentencing = "On March 3, 2021, John Smith was sentenced to 60 months in prison for wire fraud."
    static let charging = "A federal grand jury charged John Smith with wire fraud on June 9, 2019."
    static let appeal = "John Smith appealed on May 2, 2021."

    nonisolated static func baseDocs() -> [Doc] {
        [Doc(version: UUID(), object: UUID(), name: "a-sentencing.txt", text: sentencing),
         Doc(version: UUID(), object: UUID(), name: "b-indictment.txt", text: charging),
         Doc(version: UUID(), object: UUID(), name: "c-appeal.txt", text: appeal)]
    }

    /// A large exhibit (sorted last, so the sentencing record stays document 1) of about `bytes` bytes.
    nonisolated static func exhibit(bytes: Int) -> Doc {
        let line = "Exhibit ledger line: account reconciliation entry, no finding recorded.\n"
        let text = String(repeating: line, count: max(1, bytes / line.utf8.count))
        return Doc(version: UUID(), object: UUID(), name: "z-exhibits.txt", text: text)
    }

    /// The reader's reply (Anthropic text content): one claim quoting the sentencing record verbatim.
    nonisolated static let answeredReply: String = {
        let claim: [String: Any] = ["text": "John Smith was sentenced on March 3, 2021.",
                                    "quote": "On March 3, 2021, John Smith was sentenced to 60 months in prison",
                                    "passage": 1, "about": "John Smith"]
        let data = (try? JSONSerialization.data(withJSONObject: ["status": "answered", "claims": [claim],
                                                                  "answer": "John Smith was sentenced on March 3, 2021."] as [String: Any])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    nonisolated final class Consents: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [CaseReadConsentRequest] = []
        private var _allow = true
        private var _usages: [CloudCallUsage] = []
        func ask(_ r: CaseReadConsentRequest) -> Bool { lock.withLock { _items.append(r); return _allow } }
        func setAllow(_ a: Bool) { lock.withLock { _allow = a } }
        func addUsage(_ u: CloudCallUsage?) { if let u { lock.withLock { _usages.append(u) } } }
        var items: [CaseReadConsentRequest] { lock.withLock { _items } }
        var usages: [CloudCallUsage] { lock.withLock { _usages } }
    }

    struct Journey {
        let service: InvestigationAnswerService
        let caseID: UUID
        let cases: InvestigationCaseRepository
        let consents: Consents
        let provider: OnlineCloudProvider
        let db: Database
    }

    /// A ledger with one case over `docs[..<included]`, answered through the REAL provider's case read
    /// with `snapshot` (the person's Online settings) and `transport` (the simulated network).
    static func journey(_ docs: [Doc], included: Int? = nil, snapshot: OnlineSnapshot,
                        limit: @escaping @Sendable () -> Int,
                        transport: @escaping @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse) async throws -> Journey {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = try await cases.createCase(workspaceID: ws, title: "Smith", actor: "u", at: t0)
        for d in docs.prefix(included ?? docs.count) {
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: d.version.uuidString,
                                              sourceKind: .sourceVersion, actor: "u", at: t0)
        }
        let byVersion = Dictionary(uniqueKeysWithValues: docs.map { ($0.version, $0) })
        let consents = Consents()
        let permissions = CaseReadPermissionStore.inMemory()
        var seams = OnlineCloudProvider.Seams(settings: { snapshot },
                                              consent: { _ in Issue.record("a case read never shows the per-send dialog"); return false },
                                              transport: transport)
        seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        // As AppState wires it: the reader exists only when the provider may read documents now.
        let reader = CaseReader { send in
            let r = try await provider.readCase(send)
            consents.addUsage(r.usage)
            return CaseReader.Reply(text: r.text, usage: r.usage)
        }
        let plan = CaseWholeReading(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                CaseReader.Document(objectID: $0.object, sourceVersionID: $0.version, fileName: $0.name, text: $0.text) } },
            gate: { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                    legacyPrivileged: { [] }) },
            reader: { await provider.acceptsDocuments() ? reader : nil },
            permissions: permissions,
            askConsent: { consents.ask($0) },
            wholeCaseLimit: limit,
            providerName: { snapshot.kind.displayName },
            estimate: { caseTokens, questionTokens in
                CaseReadCostEstimate.line(kind: snapshot.kind, caseTokens: caseTokens, questionTokens: questionTokens,
                                          maxOutputTokens: OnlineRequestBuilder.anthropicMaxTokens(OnlineRequestBuilder.caseReadReplyTokens),
                                          oneHourCache: true)
            })
        let service = InvestigationAnswerService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), baseRetriever: CaseWholeReadingTests.EmptyRetriever(),
            evidence: evidence, makeBrain: { MasterBrain(retriever: $0) },
            objectVersions: { versions in
                Dictionary(uniqueKeysWithValues: versions.compactMap { byVersion[$0] }.map { ($0.object, Set([$0.version])) })
            },
            caseReading: plan)
        return Journey(service: service, caseID: c.id, cases: cases, consents: consents, provider: provider, db: db)
    }

    static func add(_ d: Doc, to j: Journey) async throws {
        let c = try #require(try await j.cases.fetch(caseID: j.caseID)).caseHeader
        _ = try await j.cases.includeSource(caseID: j.caseID, expectedRevision: c.revision, sourceRef: d.version.uuidString,
                                            sourceKind: .sourceVersion, actor: "u", at: Date())
    }

    static let question = "When was John Smith sentenced?"
    static let claim = "John Smith was sentenced on March 3, 2021."

    // MARK: - Simulated network: Anthropic and the relay

    /// Anthropic's Messages API as seen by the app: caches a prefix on first sight (1-hour write), reads
    /// it afterwards, replies with the scripted text and a `usage` block.
    nonisolated final class FakeAnthropic: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Set<String> = []
        private var _bodies: [[String: Any]] = []
        let outputTokens: Int
        init(outputTokens: Int = 1_500) { self.outputTokens = outputTokens }
        var calls: Int { lock.withLock { _bodies.count } }

        nonisolated static func blocks(_ body: [String: Any]) -> [String] {
            let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            return content.compactMap { $0["text"] as? String }
        }

        func respond(to body: [String: Any]) -> [String: Any] {
            let texts = Self.blocks(body)
            let prefix = texts.dropLast().joined()
            let prefixTokens = (prefix.utf8.count + 3) / 4
            let suffixTokens = ((texts.last ?? "").utf8.count + 3) / 4
            let hit = lock.withLock { () -> Bool in
                _bodies.append(body)
                return !cached.insert(prefix).inserted
            }
            let usage: [String: Any] = [
                "input_tokens": suffixTokens,
                "cache_creation_input_tokens": hit ? 0 : prefixTokens,
                "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": hit ? 0 : prefixTokens],
                "cache_read_input_tokens": hit ? prefixTokens : 0,
                "output_tokens": outputTokens]
            return ["content": [["type": "text", "text": PlanJourneySimulationTests.answeredReply]], "stop_reason": "end_turn", "usage": usage]
        }

        /// The own-key transport.
        func transport(_ req: OutboundHTTPRequest) -> OutboundHTTPResponse {
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            return OutboundHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: respond(to: body))) ?? Data())
        }
    }

    /// Mirror of relay/src/policy.ts `anthropicCost` (micro-dollars, rounded up) at `model`'s rates — the
    /// relay's Claude Opus 5.5 by default (Package B 2026-11-06); the own-key tally passes claude-opus-5.
    nonisolated static func costMicro(_ u: [String: Any], model: String = "claude-opus-5-5") -> Double {
        let r = AIPricing.rates[model] ?? AIPricing.Rates(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5)
        func n(_ k: String, _ d: [String: Any] = u) -> Double { Double(max(0, d[k] as? Int ?? 0)) }
        let split = u["cache_creation"] as? [String: Any] ?? [:]
        let w5 = n("ephemeral_5m_input_tokens", split)
        let w1 = max(n("ephemeral_1h_input_tokens", split), n("cache_creation_input_tokens") - w5)
        let p = r.inputPerMTok
        let m = n("input_tokens") * p + w5 * p * r.cacheWrite5m + w1 * p * r.cacheWrite1h + n("cache_read_input_tokens") * p * r.cacheRead + n("output_tokens") * r.outputPerMTok
        return m.rounded(.up)
    }
    /// Mirror of `creditsFor`.
    nonisolated static func creditsFor(micro: Double) -> Int { max(1, Int((micro / 10_000).rounded(.up))) }

    /// The relay (relay/src/index.ts `messages` + `metered`), in process: the subscriber header, the
    /// large-read header, size limits, the worst-case reservation (AIPricing.relayReservation, the app's
    /// mirror of worstCaseCost), the ceiling, the day's limit, the balance (allowance first, then packs),
    /// forwarding, the actual charge (never above the reservation), and the `kals` receipt.
    nonisolated final class FakeRelay: @unchecked Sendable {
        struct Exchange: Sendable {
            let status: Int
            let code: String?
            let reserved: Int?
            let charged: Int?
            let large: Bool
            let chars: Int
            let texts: [String]
            let responseBody: Data
        }
        let subscription: String
        let tier: PlanTier
        let upstream: FakeAnthropic
        private let lock = NSLock()
        private var allowanceLeft: Int
        private var topUps = 0
        private var dailyUsed = 0
        private var creditedPacks: Set<String> = []
        private var _log: [Exchange] = []

        init(subscription: String, tier: PlanTier, upstream: FakeAnthropic) {
            self.subscription = subscription; self.tier = tier; self.upstream = upstream
            self.allowanceLeft = tier.limits?.monthlyCredits ?? 0
        }
        var log: [Exchange] { lock.withLock { _log } }
        var limits: AIPricing.PlanLimits { tier.limits ?? AIPricing.aiIncluded }

        /// The rest of the month's use, applied directly (the journey does not make 100 calls).
        func setBalance(allowanceLeft a: Int, dailyUsed d: Int = 0) { lock.withLock { allowanceLeft = a; dailyUsed = d } }
        /// Packs spent elsewhere (simulated): leave `n` credits in packs.
        func setPacks(_ n: Int) { lock.withLock { topUps = n } }

        func receipt(charged: Int?, reserved: Int?) -> [String: Any] {
            lock.withLock {
                var k: [String: Any] = ["plan": tier == .aiPro ? "pro" : "ai", "monthlyCredits": limits.monthlyCredits,
                                        "allowanceUsed": limits.monthlyCredits - allowanceLeft, "allowanceLeft": allowanceLeft, "topUps": topUps,
                                        "dailyUsed": dailyUsed, "dailyLimit": limits.dailyCredits, "perRequestCredits": limits.perRequestCredits,
                                        "caseReadCredits": limits.caseReadCredits, "periodStartsAt": "2026-11-04T10:00:00.000Z",
                                        "periodEndsAt": "2026-12-04T10:00:00.000Z"]
                if let charged { k["charged"] = charged }
                if let reserved { k["reserved"] = reserved }
                return k
            }
        }

        private func refuse(_ status: Int, _ code: String, _ message: String, reserved: Int?, large: Bool, chars: Int, texts: [String]) -> OutboundHTTPResponse {
            var e: [String: Any] = ["code": code, "message": message]
            if let reserved { e["estimate"] = reserved }
            let body = (try? JSONSerialization.data(withJSONObject: ["error": e])) ?? Data()
            lock.withLock { _log.append(Exchange(status: status, code: code, reserved: reserved, charged: nil, large: large, chars: chars, texts: texts, responseBody: body)) }
            return OutboundHTTPResponse(status: status, body: body)
        }

        func handle(_ req: OutboundHTTPRequest) -> OutboundHTTPResponse {
            let large = req.headers["x-kals-large-read"] == "confirmed"
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let texts = FakeAnthropic.blocks(body)
            // estimateMessagesInput: JS string length (UTF-16) of the text blocks (+ system).
            let chars = texts.reduce(0) { $0 + $1.utf16.count } + ((body["system"] as? String)?.utf16.count ?? 0)
            guard req.headers["x-kals-subscription"] == subscription, req.headers["x-api-key"] == nil else {
                return refuse(402, "not-subscribed", "No AI plan (AI Included or AI Pro) is active for this Apple account.", reserved: nil, large: large, chars: chars, texts: texts)
            }
            if chars > (large ? 2_800_000 : 120_000) {
                return refuse(413, "too-large", "This request is larger than the AI service accepts. Select fewer passages and try again.", reserved: nil, large: large, chars: chars, texts: texts)
            }
            let raw = String(decoding: req.body, as: UTF8.self)
            let oneHour = raw.range(of: #""ttl"\s*:\s*"1h""#, options: .regularExpression) != nil
            let fiveMin = !oneHour && raw.contains("cache_control")
            let maxOut = min(24_000, max(1_024, body["max_tokens"] as? Int ?? 24_000))
            let reserved = AIPricing.relayReservation(inputCharacters: chars, maxOutputTokens: maxOut, cacheWrite1h: oneHour, cacheWrite5m: fiveMin)
            let ceiling = large ? limits.caseReadCredits : limits.perRequestCredits
            if reserved > ceiling {
                return refuse(413, "too-costly", large
                    ? "Reading this much at once needs up to \(reserved) credits, more than this plan's \(ceiling)-credit limit for one read. Nothing was sent; select fewer documents (AI Pro reads more at once)."
                    : "This request needs up to \(reserved) credits, more than the \(ceiling) one request may use. Nothing was sent; select fewer passages, or confirm it as a large read.",
                    reserved: reserved, large: large, chars: chars, texts: texts)
            }
            // reserveCredits: the day's limit, then the balance (allowance, then packs).
            enum Held { case ok(fromAllowance: Int, fromPacks: Int), daily, balance(Int) }
            let held: Held = lock.withLock {
                if dailyUsed + reserved > limits.dailyCredits { return .daily }
                let balance = allowanceLeft + topUps
                if reserved > balance { return .balance(balance) }
                let a = min(allowanceLeft, reserved), p = reserved - a
                allowanceLeft -= a; topUps -= p; dailyUsed += reserved
                return .ok(fromAllowance: a, fromPacks: p)
            }
            switch held {
            case .daily:
                return refuse(429, "daily-limit", "Today's AI limit of \(limits.dailyCredits) credits for this plan is reached. Nothing was sent; it resets at midnight UTC.",
                              reserved: reserved, large: large, chars: chars, texts: texts)
            case .balance(let b):
                return refuse(402, "credits-used", "This request needs up to \(reserved) credits and \(b) are left (this month's allowance and your credit packs). Nothing was sent. Buy a credit pack, wait for the allowance to reset, or use your own AI key in Settings.",
                              reserved: reserved, large: large, chars: chars, texts: texts)
            case .ok(let fromAllowance, let fromPacks):
                // Forward (the relay's own key, model and output ceiling), then settle.
                var reply = upstream.respond(to: body)
                let usage = reply["usage"] as? [String: Any] ?? [:]
                let charged = min(reserved, PlanJourneySimulationTests.creditsFor(micro: PlanJourneySimulationTests.costMicro(usage)))
                lock.withLock {
                    // refundSplit: the charge kept from the allowance first; refunds go back to the packs first.
                    let keepA = min(fromAllowance, charged), keepP = charged - keepA
                    allowanceLeft += fromAllowance - keepA
                    topUps += fromPacks - min(fromPacks, keepP)
                    dailyUsed -= reserved - charged
                }
                reply["kals"] = receipt(charged: charged, reserved: reserved)
                let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                lock.withLock { _log.append(Exchange(status: 200, code: nil, reserved: reserved, charged: charged, large: large, chars: chars, texts: texts, responseBody: data)) }
                return OutboundHTTPResponse(status: 200, body: data)
            }
        }

        /// /v1/topup: a verified pack bought with this subscription's appAccountToken is credited once.
        func topUp(transactionID: String, productID: String, appAccountToken: UUID?) -> OutboundHTTPResponse {
            let ok = appAccountToken == AIIncludedRelay.accountToken(subscription: subscription)
            let credits = PurchaseProducts.credits(inPack: productID) ?? 0
            let credited: Bool = lock.withLock {
                guard ok, credits > 0, creditedPacks.insert(transactionID).inserted else { return false }
                topUps += credits
                return true
            }
            guard ok else {
                return OutboundHTTPResponse(status: 400, body: Data(#"{"error":{"code":"bad-request","message":"The request was not in the expected form: not a valid top-up"}}"#.utf8))
            }
            let body: [String: Any] = ["credited": credited, "revoked": false, "kals": receipt(charged: nil, reserved: nil)]
            return OutboundHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        }
    }

    static func snapshot(_ kind: OnlineProviderKind, key: String?, cloudAllowed: Bool = true) -> OnlineSnapshot {
        OnlineSnapshot(cloudAllowed: cloudAllowed, kind: kind, model: "claude-opus-5", apiKey: key,
                       confirmedDocumentTerms: key == nil ? nil : kind.documentTermsVersion, dailyByteCap: nil)
    }

    /// The plan → whole-case limit, as the app derives it (CaseReadLimits: AI plans from AIPricing, the
    /// mirror of relay/src/policy.ts; no plan / own key: the own-key default).
    nonisolated static func wholeCaseLimit(for tier: PlanTier?) -> Int {
        CaseReadLimits.limit(kind: tier?.limits == nil ? .anthropic : .included, tier: tier, ownKeySetting: 0)
    }

    // MARK: - 1. Workbench

    @Test("Workbench: 14-day trial → no relay credits → own Anthropic key: consent once per case, whole-case read, verified; own-key dollars tallied")
    func workbenchJourney() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.monthly)
        guard case .introductoryTrial(let ends, .monthly, _) = c.entitlement else {
            Issue.record("expected the Workbench free trial, got \(c.entitlement)"); return
        }
        #expect(ends > Date().addingTimeInterval(13 * 86_400) && ends < Date().addingTimeInterval(15 * 86_400))
        #expect(c.entitlement.allowsPaidUse && c.allowPaidAction("ask in a case"))
        // No AI of ours: no AI tier, no relay subscription number, no credits, no credit packs.
        #expect(c.entitlement.aiTier == nil && !c.entitlement.includesAI && c.aiSubscriptionID == nil)
        let meter = AICreditMeter()
        meter.planChanged(c.entitlement.aiTier)
        #expect(meter.balance == nil && meter.summaryLine == nil)
        #expect(meter.refusal(credits: 1, largeRead: true)?.contains("No AI plan") == true)
        await c.buyCredits(PurchaseProducts.credits500)
        #expect(c.message == "Credit packs are for AI Included and AI Pro subscribers. Choose an AI plan first.")
        #expect(!s.allTransactions().contains { $0.productIdentifier == PurchaseProducts.credits500 })

        // Own key: Online on, Anthropic, the person's key, document terms confirmed.
        let anthropic = FakeAnthropic()
        let requests = Requests()
        let docs = Self.baseDocs()
        let key = "sk-ant-journey-0000-test"
        let j = try await Self.journey(docs, included: 2, snapshot: Self.snapshot(.anthropic, key: key),
                                       limit: { Self.wholeCaseLimit(for: nil) },
                                       transport: { req in requests.add(req); return anthropic.transport(req) })

        // First question: the permission sheet, once, in dollars on the own key.
        let a1 = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(await j.service.lastCasePath == .wholeCase)
        #expect(j.consents.items.count == 1)
        let sheet = try #require(j.consents.items.first)
        #expect(sheet.readsWhole && sheet.documents.map(\.name) == ["a-sentencing.txt", "b-indictment.txt"])
        #expect(sheet.estimate.hasPrefix("At most about $") && sheet.estimate.contains("on your own key"), "\(sheet.estimate)")
        #expect(a1.intentKind == VerifiedAnswerComposer.verifiedKind, "\(a1.body)")
        #expect(a1.body.contains(Self.claim) && a1.citations.first?.objectID == docs[0].object)
        // Straight to Anthropic with the person's key; nothing of the relay.
        let r1 = try #require(requests.all.first)
        #expect(r1.url == "https://api.anthropic.com/v1/messages")
        #expect(r1.headers["x-api-key"] == key && r1.headers["x-kals-subscription"] == nil && r1.headers["x-kals-large-read"] == nil)

        // Second question: no sheet; the case comes from the cache.
        _ = try await j.service.answer(caseID: j.caseID, question: "What was John Smith sentenced to?", access: .testUnrestricted())
        #expect(j.consents.items.count == 1 && requests.all.count == 2)
        let usages = j.consents.usages
        #expect(usages.count == 2 && usages[0].cacheWriteTokens > 0 && usages[1].cacheReadTokens == usages[0].cacheWriteTokens)
        #expect(usages.allSatisfy { $0.provider == "anthropic" })

        // The own-key tally (the hook's own call, at a fixed past month): what Anthropic's usage costs.
        let month = Date(timeIntervalSince1970: 949_363_200)   // February 2000: nothing real uses it
        let tallyKey = OwnKeyBudget.tallyPrefix + OwnKeyBudget.monthKey(month)
        OwnKeyBudget.defaults.removeObject(forKey: tallyKey)
        defer { OwnKeyBudget.defaults.removeObject(forKey: tallyKey) }
        var expected = 0.0
        for u in usages {
            let dict: [String: Any] = ["input_tokens": u.inputTokens, "cache_creation_input_tokens": u.cacheWriteTokens,
                                       "cache_read_input_tokens": u.cacheReadTokens, "output_tokens": u.outputTokens]
            OwnKeyBudget.record(usage: dict, model: "claude-opus-5", at: month)
            expected += Self.costMicro(dict, model: "claude-opus-5") / 1_000_000
        }
        #expect(abs(OwnKeyBudget.spentUSD(now: month) - expected) < 1e-5, "\(OwnKeyBudget.spentUSD(now: month)) vs \(expected)")
        #expect(OwnKeyBudget.spentUSD(now: month) > 0)

        // A new document: the sheet comes back; Not now sends nothing.
        try await Self.add(docs[2], to: j)
        j.consents.setAllow(false)
        let a3 = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(j.consents.items.count == 2 && j.consents.items[1].documents.count == 3)
        #expect(j.consents.items[1].fingerprint != j.consents.items[0].fingerprint)
        #expect(requests.all.count == 2, "Not now: nothing sent")
        #expect(await j.service.lastCasePath == .notPermitted && a3.body.contains("search results"))
    }

    nonisolated final class Requests: @unchecked Sendable {
        private let lock = NSLock(); private var items: [OutboundHTTPRequest] = []
        func add(_ r: OutboundHTTPRequest) { lock.withLock { items.append(r) } }
        var all: [OutboundHTTPRequest] { lock.withLock { items } }
    }

    // MARK: - 2. AI Included

    @Test("AI Included: purchase → 2,000 credits → consent pinned to the documents → metered case reads (rounded up, from the receipt) → allowance used → credit pack → refusal codes, nothing truncated")
    func aiIncludedJourney() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.aiMonthly)
        let isAI = await Self.settle(c) { $0.aiTier == .aiIncluded }
        #expect(isAI, "after buying AI Included: \(c.entitlement)")
        #expect(c.entitlement.plan == .aiMonthly && c.entitlement.includesAI)
        let sub = try #require(c.aiSubscriptionID, "the AI subscription number the relay is told")
        #expect(AIIncludedRelay.isValidSubscription(sub))
        let meter = AICreditMeter()
        meter.planChanged(c.entitlement.aiTier)
        #expect(meter.limits == AIPricing.aiIncluded && meter.summaryLine == "AI Included: 2,000 credits a month")

        let relay = FakeRelay(subscription: sub, tier: .aiIncluded, upstream: FakeAnthropic())
        let docs = Self.baseDocs()
        let j = try await Self.journey(docs, included: 2, snapshot: Self.snapshot(.included, key: sub),
                                       limit: { Self.wholeCaseLimit(for: .aiIncluded) },
                                       transport: { req in relay.handle(req) })

        // 1st question: the sheet once, in credits; one confirmed large read; charged the actual cost rounded up.
        let a1 = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(await j.service.lastCasePath == .wholeCase)
        let sheet = try #require(j.consents.items.first)
        #expect(j.consents.items.count == 1 && sheet.estimate.contains("credits") && !sheet.estimate.contains("$"), "\(sheet.estimate)")
        #expect(a1.intentKind == VerifiedAnswerComposer.verifiedKind && a1.body.contains(Self.claim), "\(a1.body)")
        let x1 = try #require(relay.log.last)
        #expect(x1.status == 200 && x1.large, "an allowed case read is a confirmed large read")
        let usage1 = try #require(j.consents.usages.last)
        let micro1 = Self.costMicro(["input_tokens": usage1.inputTokens, "cache_creation_input_tokens": usage1.cacheWriteTokens,
                                     "cache_creation": ["ephemeral_1h_input_tokens": usage1.cacheWriteTokens], "cache_read_input_tokens": usage1.cacheReadTokens,
                                     "output_tokens": usage1.outputTokens])
        let charged1 = try #require(x1.charged)
        #expect(charged1 == Self.creditsFor(micro: micro1) && Double(charged1) * 10_000 >= micro1 && Double(charged1 - 1) * 10_000 < micro1,
                "rounded up: \(charged1) credits for \(micro1) µ$")
        #expect(charged1 <= (x1.reserved ?? 0), "never more than reserved")
        let receipt1 = try #require(AIIncludedRelay.receipt(in: x1.responseBody))
        meter.apply(receipt1)
        #expect(meter.lastCharged == charged1 && meter.balance == 2_000 - charged1)
        #expect(meter.summaryLine == "\((2_000 - charged1).formatted()) of 2,000 credits left this month · last request \(charged1) credit\(charged1 == 1 ? "" : "s")")

        // 2nd question: no sheet; the cached case costs less.
        _ = try await j.service.answer(caseID: j.caseID, question: "What was John Smith sentenced to?", access: .testUnrestricted())
        #expect(j.consents.items.count == 1)
        let x2 = try #require(relay.log.last)
        let charged2 = try #require(x2.charged)
        #expect(charged2 <= charged1 && (j.consents.usages.last?.cacheReadTokens ?? 0) > 0)
        meter.apply(try #require(AIIncludedRelay.receipt(in: x2.responseBody)))
        #expect(meter.balance == 2_000 - charged1 - charged2)

        // A new document: asked again (new fingerprint); Allow; read.
        try await Self.add(docs[2], to: j)
        _ = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted())
        #expect(j.consents.items.count == 2 && j.consents.items[1].documents.count == 3 && j.consents.items[1].fingerprint != sheet.fingerprint)
        let x3 = try #require(relay.log.last)
        #expect(x3.status == 200 && (x3.charged ?? 0) >= 1)
        let callsBefore = relay.upstream.calls

        // The month's allowance used up (simulated: 1 credit left): the relay refuses with credits-used before
        // forwarding; the request carried the whole case — nothing was truncated to make it fit.
        relay.setBalance(allowanceLeft: 1)
        let a4 = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        let x4 = try #require(relay.log.last)
        #expect(x4.status == 402 && x4.code == "credits-used" && x4.charged == nil)
        #expect(relay.upstream.calls == callsBefore, "nothing forwarded to Claude")
        let sent = x4.texts.joined()
        #expect(sent.contains(Self.sentencing) && sent.contains(Self.charging) && sent.contains(Self.appeal), "the whole case, not a truncated part")
        #expect(a4.intentKind != VerifiedAnswerComposer.verifiedKind && a4.body.contains("are left"), "the relay's words reach the answer: \(a4.body)")
        meter.apply(AIIncludedRelay.Receipt(plan: "ai", monthlyCredits: 2_000, allowanceLeft: 1, topUps: 0, dailyUsed: 0, dailyLimit: 1_500,
                                            perRequestCredits: 400, caseReadCredits: 600, periodEndsAt: nil, charged: nil, reserved: nil))
        #expect(meter.refusal(credits: x4.reserved ?? 2, largeRead: true)?.contains("Buy a credit pack") == true)

        // A credit pack (500), bought FOR this subscription (appAccountToken) in StoreKit.
        await c.buyCredits(PurchaseProducts.credits500)
        let pack = try #require(s.allTransactions().first { $0.productIdentifier == PurchaseProducts.credits500 }, "the pack was bought: \(c.message ?? "")")
        var bought: Transaction?
        for await r in Transaction.unfinished { if case .verified(let t) = r, t.productID == PurchaseProducts.credits500 { bought = t } }
        let t = try #require(bought)
        #expect(t.appAccountToken == AIIncludedRelay.accountToken(subscription: sub), "the pack belongs to this AI subscription")
        if !AIIncludedRelay.isConfigured {
            // This build has no relay host: the pack is kept unfinished and credited later, never lost.
            #expect(c.message?.hasPrefix("The credit pack was bought but the AI service could not add it yet") == true, "\(c.message ?? "nil")")
        }
        // SIMULATED: the relay's /v1/topup credits it (once), the app reads the reply strictly, then finishes it.
        let topUp = relay.topUp(transactionID: String(t.id), productID: t.productID, appAccountToken: t.appAccountToken)
        #expect(try AIIncludedRelay.parseTopUp(topUp) == .onAccount)
        #expect(try AIIncludedRelay.parseTopUp(relay.topUp(transactionID: String(t.id), productID: t.productID, appAccountToken: t.appAccountToken)) == .onAccount,
                "already credited: still on the account, never twice")
        await t.finish()
        let status = try #require(AIIncludedRelay.receipt(in: topUp.body))
        #expect(status.allowanceLeft == 1 && status.topUps == 500)
        meter.apply(status)
        #expect(meter.balance == 501 && meter.summaryLine?.contains("500 in packs") == true)
        #expect(pack.productIdentifier == PurchaseProducts.credits500)

        // The same question again: the allowance's last credit first, then the pack.
        let a5 = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        let x5 = try #require(relay.log.last)
        let charged5 = try #require(x5.charged)
        #expect(x5.status == 200 && a5.intentKind == VerifiedAnswerComposer.verifiedKind)
        let r5 = try #require(AIIncludedRelay.receipt(in: x5.responseBody))
        #expect(r5.allowanceLeft == max(0, 1 - charged5) && r5.topUps == 500 - max(0, charged5 - 1), "allowance first, then packs: \(r5)")
        meter.apply(r5)
        #expect(meter.balance == 501 - charged5)

        // Out of everything (SIMULATED: the packs spent down to one credit short of a read's reservation):
        // credits-used again, nothing forwarded, nothing charged.
        let reserve = x5.reserved ?? 30
        relay.setBalance(allowanceLeft: 0)
        relay.setPacks(max(0, reserve - 1))
        let before = relay.upstream.calls
        _ = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted())
        let x6 = try #require(relay.log.last)
        #expect(x6.code == "credits-used" && relay.upstream.calls == before)

        // The day's limit is its own code (AI Included: 1,500 a day).
        relay.setBalance(allowanceLeft: 2_000, dailyUsed: 1_500)
        _ = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted())
        #expect(relay.log.last?.code == "daily-limit" && relay.log.last?.status == 429 && relay.upstream.calls == before)

        // Consistency of the plan's numbers: a case at AI Included's whole-case limit fits its case-read ceiling.
        let atLimit = AIPricing.relayReservation(inputCharacters: (CaseWholeReading.defaultLimit - AIPricing.tokenOverhead) * AIPricing.charsPerToken, maxOutputTokens: OnlineRequestBuilder.anthropicMaxTokens(OnlineRequestBuilder.caseReadReplyTokens), cacheWrite1h: true)
        #expect(atLimit <= AIPricing.aiIncluded.caseReadCredits, "a whole case at the limit reserves \(atLimit) of \(AIPricing.aiIncluded.caseReadCredits)")
    }

    // MARK: - 3. AI Pro

    @Test("AI Pro: purchase → 6,000 credits and the larger whole-case limit: a case too large for AI Included is read whole; above Pro's limit, retrieval with an honest note")
    func aiProJourney() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.proMonthly)
        let isPro = await Self.settle(c) { $0.aiTier == .aiPro }
        #expect(isPro, "after buying AI Pro: \(c.entitlement)")
        let sub = try #require(c.aiSubscriptionID)
        let meter = AICreditMeter()
        meter.planChanged(c.entitlement.aiTier)
        #expect(meter.limits?.monthlyCredits == 6_000 && meter.limits?.caseReadCredits == 3_000)

        // A case of about 600k tokens: above AI Included's 300k whole-case limit, within AI Pro's 800k.
        var docs = Array(Self.baseDocs().prefix(2))
        docs.append(Self.exhibit(bytes: 2_100_000))

        // On AI Included's limit: not read whole — retrieval, said so, nothing sent to the relay.
        let included = FakeRelay(subscription: sub, tier: .aiIncluded, upstream: FakeAnthropic())
        let small = try await Self.journey(docs, snapshot: Self.snapshot(.included, key: sub),
                                           limit: { Self.wholeCaseLimit(for: .aiIncluded) }, transport: { included.handle($0) })
        let a0 = try await small.service.answer(caseID: small.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(await small.service.lastCasePath == .retrievalFallback)
        #expect(a0.body.contains("This case is too large for the AI to read whole") && a0.body.contains("the limit is \(CaseWholeReading.defaultLimit.formatted())"), "\(a0.body.suffix(300))")
        #expect(included.log.isEmpty && small.consents.items.first?.readsWhole == false)

        // On AI Pro's limit (SIMULATED selection from the tier): read whole, one confirmed large read.
        let pro = FakeRelay(subscription: sub, tier: .aiPro, upstream: FakeAnthropic())
        let tier = c.entitlement.aiTier
        let j = try await Self.journey(docs, snapshot: Self.snapshot(.included, key: sub),
                                       limit: { Self.wholeCaseLimit(for: tier) }, transport: { pro.handle($0) })
        let a1 = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(await j.service.lastCasePath == .wholeCase)
        #expect(a1.intentKind == VerifiedAnswerComposer.verifiedKind && a1.body.contains(Self.claim), "\(a1.body.prefix(400))")
        let sheet = try #require(j.consents.items.first)
        #expect(sheet.readsWhole && sheet.documents.count == 3 && sheet.estimatedTokens > CaseWholeReading.defaultLimit && sheet.estimatedTokens <= CaseWholeReading.proLimit)
        let x1 = try #require(pro.log.last)
        let reserved = try #require(x1.reserved)
        #expect(x1.status == 200 && x1.large)
        #expect(reserved > AIPricing.aiIncluded.caseReadCredits && reserved <= AIPricing.aiPro.caseReadCredits,
                "reserved \(reserved): above AI Included's 600-credit read, within AI Pro's 3,000")
        let r1 = try #require(AIIncludedRelay.receipt(in: x1.responseBody))
        #expect(r1.plan == "pro" && r1.monthlyCredits == 6_000 && r1.balance == 6_000 - (x1.charged ?? 0))
        meter.apply(r1)
        #expect(meter.tier == .aiPro && meter.balance == 6_000 - (x1.charged ?? 0))

        // The same read on AI Included's relay ceiling (forced past the app's limit): too-costly, nothing forwarded.
        let forced = try await Self.journey(docs, snapshot: Self.snapshot(.included, key: sub),
                                            limit: { CaseWholeReading.proLimit }, transport: { included.handle($0) })
        let af = try await forced.service.answer(caseID: forced.caseID, question: Self.question, access: .testUnrestricted()).verified
        let xf = try #require(included.log.last)
        #expect(xf.status == 413 && xf.code == "too-costly" && included.upstream.calls == 0)
        #expect(af.body.contains("more than this plan"), "the relay's reason reaches the answer: \(af.body.suffix(400))")

        // Above AI Pro's limit (≈ 820k tokens): retrieval with the honest note; nothing sent.
        var huge = Array(Self.baseDocs().prefix(2))
        huge.append(Self.exhibit(bytes: 2_870_000))
        let big = FakeRelay(subscription: sub, tier: .aiPro, upstream: FakeAnthropic())
        let k = try await Self.journey(huge, snapshot: Self.snapshot(.included, key: sub),
                                       limit: { Self.wholeCaseLimit(for: .aiPro) }, transport: { big.handle($0) })
        let a2 = try await k.service.answer(caseID: k.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(await k.service.lastCasePath == .retrievalFallback)
        #expect(a2.body.contains("This case is too large for the AI to read whole") && a2.body.contains("the limit is \(CaseWholeReading.proLimit.formatted())"), "\(a2.body.suffix(300))")
        #expect(big.log.isEmpty)

        // Consistency: at AI Pro's whole-case limit the reservation fits Pro's case-read ceiling.
        let maxOut = OnlineRequestBuilder.anthropicMaxTokens(OnlineRequestBuilder.caseReadReplyTokens)
        let atLimit = AIPricing.relayReservation(inputCharacters: (CaseWholeReading.proLimit - AIPricing.tokenOverhead) * AIPricing.charsPerToken, maxOutputTokens: maxOut, cacheWrite1h: true)
        #expect(atLimit <= AIPricing.aiPro.caseReadCredits)
    }

    /// Boundary between the app's Pro limit and the relay's large-read size limit (LARGE_READ_MAX_INPUT_CHARS
    /// = 2,800,000 characters INCLUDING the question): both now size text with the ONE estimator (3
    /// characters a token + 64), so the largest case the app reads whole on AI Pro — question, masking
    /// growth and all — is accepted by the relay, and one byte more falls back to retrieval.
    @Test("AI Pro boundary: a case the app reads whole at the 800k limit also fits the relay's large-read size limit")
    func proLimitMatchesRelaySizeLimit() throws {
        let question = CaseReader.questionSuffix(Self.question)
        func prefix(_ fillerBytes: Int) -> [String] {
            let docs = [CaseReader.Document(objectID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, fileName: "a.txt", text: Self.sentencing),
                        CaseReader.Document(objectID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, fileName: "z.txt",
                                            text: String(repeating: "x", count: fillerBytes))]
            return CaseReader.prefix(CaseReader.prepare(docs).documents)
        }
        let limit = CaseReadLimits.limit(kind: .included, tier: .aiPro, ownKeySetting: 0)
        #expect(limit == CaseWholeReading.proLimit && limit == AIPricing.aiPro.caseReadTokens)
        // The largest prefix whose estimate is within the limit: (limit − 64) × 3 bytes.
        let maxBytes = (limit - AIPricing.tokenOverhead) * AIPricing.charsPerToken
        let probe = prefix(1_000).reduce(0) { $0 + $1.utf8.count } - 1_000
        let p = prefix(maxBytes - probe)
        let bytes = p.reduce(0) { $0 + $1.utf8.count }
        #expect(bytes == maxBytes, "\(bytes)")
        #expect(CaseReader.estimatedTokens(p) == limit, "the app reads this case whole on AI Pro")
        #expect(CaseReader.estimatedTokens(prefix(maxBytes - probe + 1)) > limit, "one byte more: retrieval")
        let relayChars = AIPricing.relayCharacters(system: nil, texts: p + [question])
        #expect(relayChars <= AIPricing.largeReadMaxInputChars, "relay counts \(relayChars) characters: within its large-read size limit")
        // Even with masking growth and the largest task, the worst case fits the size limit and Pro's credits.
        #expect(AIPricing.caseReadFits(caseCharacters: bytes, creditCeiling: AIPricing.aiPro.caseReadCredits))
        let reserved = AIPricing.relayReservation(inputCharacters: relayChars, maxOutputTokens: OnlineRequestBuilder.anthropicMaxTokens(OnlineRequestBuilder.caseReadReplyTokens), cacheWrite1h: true)
        #expect(reserved <= AIPricing.aiPro.caseReadCredits, "reserved \(reserved)")
    }

    // MARK: - 4. Offline

    @Test("Offline: no plan, no key, Online off → Ask in a case returns 'Search results for …' and sends nothing; a labelled field is 'Found in the record'")
    func offlineJourney() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        #expect(c.entitlement == .notStarted && c.entitlement.aiTier == nil && c.aiSubscriptionID == nil, "\(c.entitlement)")
        let meter = AICreditMeter()
        meter.planChanged(c.entitlement.aiTier)
        #expect(meter.refusal(credits: 1, largeRead: false)?.contains("No AI plan") == true)

        let requests = Requests()
        let j = try await Self.journey(Self.baseDocs(), snapshot: Self.snapshot(.anthropic, key: nil, cloudAllowed: false),
                                       limit: { Self.wholeCaseLimit(for: nil) },
                                       transport: { req in requests.add(req); return OutboundHTTPResponse(status: 500, body: Data()) })
        let available = await j.provider.isAvailable()
        let acceptsDocuments = await j.provider.acceptsDocuments()
        #expect(!available && !acceptsDocuments)
        let a = try await j.service.answer(caseID: j.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(await j.service.lastCasePath == .offlineSearch)
        #expect(a.intentKind == OfflineSearchResults.searchKind, "\(a.body)")
        #expect(a.body.hasPrefix("Search results for"), "\(a.body)")
        #expect(requests.all.isEmpty && j.consents.items.isEmpty, "no sheet, no send")

        // Even a direct case read refuses before anything is built or sent.
        let send = CaseReadSend(caseID: j.caseID, prefix: [CaseReader.header, Self.sentencing, CaseReader.footer], suffix: CaseReader.questionSuffix(Self.question),
                                ttl: .oneHour, purpose: "case.question",
                                clearance: CloudSourceClearance(clearedObjectIDs: [UUID()], deniedCount: 0, checkedAt: Date(), purpose: "case.reading"))
        await #expect(throws: (any Error).self) { _ = try await j.provider.readCase(send) }
        #expect(requests.all.isEmpty)

        // The offline presentation of what the search found (SIMULATED at the unit: the fixture's retriever is
        // empty): passages with the question's words in bold, and an exact labelled value as "Found in the record".
        let id = UUID()
        let prose = OfflineSearchResults.present(VerifiedAnswer(body: "The documents suggest John Smith was sentenced in 2021.", answerText: "x",
                                                                citations: [.init(objectID: id, snippet: Self.sentencing)], confidence: Confidence(0.8)),
                                                 question: Self.question)
        #expect(prose.intentKind == OfflineSearchResults.searchKind && prose.body.contains("**John** **Smith** was **sentenced**") && prose.citations.map(\.objectID) == [id], "\(prose.body)")
        let field = OfflineSearchResults.present(VerifiedAnswer(body: "Class II", answerText: "Class II",
                                                                citations: [.init(objectID: id, snippet: "Recall Number: Z-1234-2020\nClassification: Class II\nReason: mislabeled")],
                                                                confidence: Confidence(0.9)),
                                                 question: "What was the recall's classification?")
        #expect(field.intentKind == OfflineSearchResults.recordValueKind && field.body.hasPrefix("Found in the record: Class II"), "\(field.body)")
    }
}
}
