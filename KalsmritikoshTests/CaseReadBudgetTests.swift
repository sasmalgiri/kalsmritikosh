//
//  CaseReadBudgetTests.swift
//  KalsmritikoshTests
//
//  The four gaps the plan-journey simulations found (2026-11-04), each fixed and pinned here:
//   1. the whole-case limit is derived from the verified plan (AIPricing, mirror of relay/src/policy.ts);
//   2. the app and the relay size text with ONE estimator, and the app's limit keeps a safety margin so
//      the relay never refuses a read the app offered (golden numbers shared with relay/test);
//   3. the own-key monthly dollar limit is checked (worst case) and tallied on whole-case reads;
//   4. the credit meter's refusals are checked before an AI Included / AI Pro send, in the relay's words.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case read budget — plan limits, one estimator, own-key limit, credit pre-check", .serialized)
struct CaseReadBudgetTests {

    // MARK: 1. Plan → whole-case limit

    @Test("The whole-case limit comes from the plan: Workbench/own key → the setting (default 300k); AI Included → 300k; AI Pro → 800k")
    func planToLimit() {
        #expect(CaseReadLimits.limit(kind: .anthropic, tier: nil, ownKeySetting: 0) == CaseWholeReading.defaultLimit)
        #expect(CaseReadLimits.limit(kind: .anthropic, tier: .workbench, ownKeySetting: 0) == 300_000)
        #expect(CaseReadLimits.limit(kind: .anthropic, tier: .aiPro, ownKeySetting: 0) == 300_000, "own key on any plan: the own-key setting")
        #expect(CaseReadLimits.limit(kind: .anthropic, tier: nil, ownKeySetting: 120_000) == 120_000)
        #expect(CaseReadLimits.limit(kind: .included, tier: .aiIncluded, ownKeySetting: 999_999) == AIPricing.aiIncluded.caseReadTokens)
        #expect(CaseReadLimits.limit(kind: .included, tier: .aiIncluded, ownKeySetting: 0) == 300_000)
        #expect(CaseReadLimits.limit(kind: .included, tier: .aiPro, ownKeySetting: 0) == AIPricing.aiPro.caseReadTokens)
        #expect(CaseReadLimits.limit(kind: .included, tier: .aiPro, ownKeySetting: 0) == 800_000)
        #expect(CaseReadLimits.limit(kind: .included, tier: nil, ownKeySetting: 0) == 300_000, "no plan known yet: the smaller plan")
        #expect(CaseWholeReading.proLimit == AIPricing.aiPro.caseReadTokens)
    }

    @Test("The shared meter's verified plan is what CaseReadLimits reads (a private meter never changes it)")
    @MainActor
    func verifiedTierSnapshot() {
        let before = AICreditMeter.verifiedTier
        let m = AICreditMeter()
        m.planChanged(before == .aiPro ? .aiIncluded : .aiPro)
        #expect(AICreditMeter.verifiedTier == before)
    }

    // MARK: 2. One estimator, app and relay

    @Test("The estimator agrees with the relay: the same constants (policy.ts) and the golden reservations of relay/test")
    func estimatorAgreesWithRelay() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("relay/src/policy.ts")
        let ts = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "_", with: "")
        for (name, v) in [("CHARSPERTOKEN", AIPricing.charsPerToken), ("TOKENOVERHEAD", AIPricing.tokenOverhead), ("IMAGETOKENS", AIPricing.imageTokens),
                          ("MAXOUTPUTTOKENS", AIPricing.maxOutputTokens), ("MAXINPUTCHARS", AIPricing.maxInputChars),
                          ("LARGEREADMAXINPUTCHARS", AIPricing.largeReadMaxInputChars)] {
            #expect(ts.range(of: "export const \(name)(: [A-Za-z]+)? = \(v);", options: .regularExpression) != nil, "\(name) = \(v) not in policy.ts")
        }
        for (name, l) in [("ai", AIPricing.aiIncluded), ("pro", AIPricing.aiPro)] {
            let line = ts.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(name):") && $0.contains("caseReadTokens") }.map(String.init) ?? ""
            #expect(line.range(of: "caseReadTokens:\\s*\(l.caseReadTokens)\\b", options: .regularExpression) != nil, "\(name).caseReadTokens: \(line)")
        }
        // Golden numbers (relay/test/relay.test.ts, "the size estimator").
        #expect(AIPricing.maxTokensForText(characters: 0) == 64)
        #expect(AIPricing.maxTokensForText(characters: 900_000) == 300_064)
        #expect(AIPricing.relayReservation(inputCharacters: 900_000, maxOutputTokens: 24_000, cacheWrite1h: true) == 361)
        #expect(AIPricing.relayReservation(inputCharacters: 10_000, images: 2, maxOutputTokens: 4_000) == 14)
        #expect(AIPricing.relayReservation(inputCharacters: 1, maxOutputTokens: 1_024, cacheWrite5m: true) == 3)
        // The case reader sizes text with it (UTF-8 bytes ≥ the relay's UTF-16 count).
        #expect(CaseReader.estimatedTokens(["abc", "défg"]) == AIPricing.maxTokensForText(characters: 3 + 5))
        #expect(AIPricing.relayCharacters(system: nil, texts: ["défg"]) == 2 + 4)
    }

    @Test("Near the limit: the largest case the app reads whole on each plan fits the relay's size limit and the plan's read ceiling, with margin; one step beyond the credit ceiling does not")
    func limitKeepsSafetyMargin() {
        for tier in [PlanTier.aiIncluded, .aiPro] {
            let plan = tier.limits!
            let limit = CaseReadLimits.limit(kind: .included, tier: tier, ownKeySetting: 0)
            let caseBytes = (limit - AIPricing.tokenOverhead) * AIPricing.charsPerToken
            #expect(AIPricing.maxTokensForText(characters: caseBytes) == limit)
            #expect(AIPricing.caseReadFits(caseCharacters: caseBytes, creditCeiling: plan.caseReadCredits), "\(tier.name): the app's largest whole read fits")
            // Exactly as the relay would size it, masking growth and the largest task included.
            let sent = Int((Double(caseBytes) * AIPricing.caseReadMaskGrowth).rounded(.up)) + AIPricing.caseReadTaskAllowanceCharacters
            #expect(sent <= AIPricing.largeReadMaxInputChars)
            #expect(AIPricing.relayReservation(inputCharacters: sent, maxOutputTokens: AIPricing.maxOutputTokens, cacheWrite1h: true) <= plan.caseReadCredits)
            // The credit/size cap itself is a true boundary.
            let cap = AIPricing.caseReadTokenCeiling(creditCeiling: plan.caseReadCredits)
            #expect(cap >= limit)
            #expect(AIPricing.caseReadFits(caseCharacters: (cap - 64) * 3, creditCeiling: plan.caseReadCredits))
            #expect(!AIPricing.caseReadFits(caseCharacters: (cap + 1 - 64) * 3, creditCeiling: plan.caseReadCredits))
        }
        // A smaller ceiling than the token limit would bind: the limit follows the credits.
        let small = AIPricing.caseReadTokenCeiling(creditCeiling: 100)
        #expect(small > 0 && small < 100_000)
        #expect(AIPricing.caseReadTokenCeiling(creditCeiling: 1) == 0, "nothing fits one credit")
    }

    // MARK: Provider rig

    nonisolated final class Bodies: @unchecked Sendable {
        private let lock = NSLock(); private var items: [OutboundHTTPRequest] = []
        func add(_ r: OutboundHTTPRequest) { lock.withLock { items.append(r) } }
        var all: [OutboundHTTPRequest] { lock.withLock { items } }
    }

    static let reply = Data(#"{"content":[{"type":"text","text":"{\"status\":\"not_stated\"}"}],"usage":{"input_tokens":30,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":80}}"#.utf8)

    struct Rig {
        let provider: OnlineCloudProvider
        let send: CaseReadSend
        let bodies: Bodies
        /// This rig's own failure status (deep dive 2026-11-14 batch 1): the shared one is overwritten by concurrent tests.
        let status: OnlineStatus
    }

    static func rig(kind: OnlineProviderKind, caseText: String = "On March 3, 2021, John Smith was sentenced.",
                    creditCheck: (@Sendable (Int, Bool) async -> AIPlanRefusal?)? = nil,
                    ownKey: Budget = Budget(limit: nil, spent: 0),
                    reply: Data = CaseReadBudgetTests.reply) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID(), o = UUID(), v = UUID()
        let binding = CloudScopeBinding(scopeID: caseID) { [o: [v]] }
        let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                              legacyPrivileged: { [] }).bound(to: binding).clear([o], purpose: "case.reading").clearance
        let bodies = Bodies()
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: kind, model: "claude-opus-5", apiKey: kind == .included ? "eyJhbGciOiJFUzI1NiJ9.eyJ0ZXN0Ijp0cnVlfQ.dGVzdC1zaWduYXR1cmU" : "test-key",
                                      confirmedDocumentTerms: kind.documentTermsVersion, dailyByteCap: nil)
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in true },
                                              transport: { req in bodies.add(req); return OutboundHTTPResponse(status: 200, body: reply) })
        seams.casePermission = { _, _ in true }
        if let creditCheck { seams.creditCheck = creditCheck }
        seams.ownKeyRefusal = { ownKey.refusal($0) }
        seams.ownKeyTally = { ownKey.tally($0, $1) }
        let status = await MainActor.run { OnlineStatus() }
        seams.status = { status }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        let send = CaseReadSend(caseID: caseID, prefix: [CaseReader.header, "[Document 1]\n" + caseText + "\n\n" + CaseReader.footer],
                                suffix: CaseReader.questionSuffix("When?"), ttl: .oneHour, purpose: "case.question", clearance: clearance)
        return Rig(provider: provider, send: send, bodies: bodies, status: status)
    }

    /// An own-key budget for one test (the person's real limit and tally are never touched): the same
    /// rule as OwnKeyBudget (`refusal(estimateUSD:limit:spent:)`) and the same pricing of a reply.
    nonisolated final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var _limit: Double?, _spent: Double
        init(limit: Double?, spent: Double) { _limit = limit; _spent = spent }
        var spent: Double { lock.withLock { _spent } }
        func refusal(_ estimate: Double) -> String? { lock.withLock { OwnKeyBudget.refusal(estimateUSD: estimate, limit: _limit, spent: _spent) } }
        func tally(_ body: Data, _ model: String) {
            guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let u = root["usage"] as? [String: Any],
                  let v = AIPricing.actualUSD(model: model, usage: u) else { return }
            lock.withLock { _spent += v }
        }
    }

    // MARK: 3. Own-key monthly limit on whole-case reads

    @Test("Own key: a whole-case read whose worst case would pass the monthly limit is refused before sending; within it, sent and tallied")
    func ownKeyLimitOnReadCase() async throws {
        // A case of ~60k characters: worst case ≈ 20k tokens × $10/MTok (1-hour write) + the output allowance.
        let text = String(repeating: "Ledger line, nothing found. ", count: 2_200)
        func run(_ budget: Budget) async throws -> Rig {
            try await Self.rig(kind: .anthropic, caseText: text, ownKey: budget)
        }
        let probe = try await run(Budget(limit: nil, spent: 0))
        let worst = try #require(AIPricing.worstCaseUSD(model: "claude-opus-5",
                                                        inputCharacters: AIPricing.relayCharacters(system: nil, texts: probe.send.prefix + [probe.send.suffix]),
                                                        maxOutputTokens: OnlineRequestBuilder.anthropicMaxTokens(probe.send.replyTokens), cacheWrite1h: true))
        #expect(worst > 0.2 && worst < 2)

        let near = Budget(limit: 1.0, spent: 1.0 - worst / 2)
        let r1 = try await run(near)
        do {
            _ = try await r1.provider.readCase(r1.send)
            Issue.record("expected the own-key limit refusal")
        } catch let e as OwnKeyBudget.LimitReached {
            #expect(e.reason.hasPrefix("Not sent: this request could cost up to") && e.reason.contains("monthly limit for your own AI key ($1.00)"), "\(e.reason)")
        }
        #expect(r1.bodies.all.isEmpty, "nothing sent")

        let reached = Budget(limit: 1.0, spent: 1.0)
        let r2 = try await run(reached)
        await #expect(throws: OwnKeyBudget.LimitReached.self) { _ = try await r2.provider.readCase(r2.send) }
        #expect(r2.bodies.all.isEmpty)

        let room = Budget(limit: 50, spent: 0.25)
        let r3 = try await run(room)
        _ = try await r3.provider.readCase(r3.send)
        #expect(r3.bodies.all.count == 1)
        let expected = 0.25 + (AIPricing.actualUSD(model: "claude-opus-5", usage: ["input_tokens": 30, "cache_creation_input_tokens": 5000, "output_tokens": 80]) ?? 0)
        #expect(abs(room.spent - expected) < 1e-9, "the reply's usage is tallied by readCase itself: \(room.spent) vs \(expected)")

        // The rule: no limit → always; the worst case within the limit → may go.
        #expect(OwnKeyBudget.refusal(estimateUSD: 5, limit: nil, spent: 100) == nil)
        #expect(OwnKeyBudget.refusal(estimateUSD: 0.5, limit: 1, spent: 0.5) == nil)
        #expect(OwnKeyBudget.refusal(estimateUSD: 0.51, limit: 1, spent: 0.5) != nil)
        // The live seams use the person's budget.
        let live = OnlineCloudProvider.Seams.live
        #expect(live.ownKeyRefusal(0) == OwnKeyBudget.refusal())
    }

    // MARK: 4. The credit pre-check

    @MainActor
    static func meter(_ tier: PlanTier, allowanceLeft: Int, topUps: Int = 0, dailyUsed: Int = 0, at: Date = Date()) -> AICreditMeter {
        let m = AICreditMeter()
        m.planChanged(tier)
        let l = tier.limits!
        m.apply(AIIncludedRelay.Receipt(plan: tier == .aiPro ? "pro" : "ai", monthlyCredits: l.monthlyCredits, allowanceLeft: allowanceLeft, topUps: topUps,
                                        dailyUsed: dailyUsed, dailyLimit: l.dailyCredits, perRequestCredits: l.perRequestCredits,
                                        caseReadCredits: l.caseReadCredits, periodEndsAt: at.addingTimeInterval(20 * 86_400), charged: nil, reserved: nil), at: at)
        return m
    }

    @Test("Meter pre-check: too-costly, daily-limit, credits-used in the relay's order and words, with Buy credits / Upgrade; unknown or stale → nil (the relay decides)")
    @MainActor
    func localRefusals() {
        let now = Date()
        let m = Self.meter(.aiIncluded, allowanceLeft: 50, topUps: 10, dailyUsed: 1_400, at: now)
        // The ceiling first (relay: `reserved > ceiling` before anything else).
        let costly = m.localRefusal(reserved: 700, largeRead: true, now: now)
        #expect(costly?.code == .tooCostly && costly?.message == AIPricing.tooCostlyMessage(estimate: 700, ceiling: 600, large: true) && costly?.offers == [.upgrade])
        #expect(m.localRefusal(reserved: 401, largeRead: false, now: now)?.code == .tooCostly)
        // The day's limit (1,400 + 101 > 1,500), then the balance.
        let daily = m.localRefusal(reserved: 101, largeRead: true, now: now)
        #expect(daily?.code == .dailyLimit && daily?.message == AIPricing.dailyLimitMessage(limit: 1_500))
        let m2 = Self.meter(.aiIncluded, allowanceLeft: 50, topUps: 10, at: now)
        let used = m2.localRefusal(reserved: 61, largeRead: true, now: now)
        #expect(used?.code == .creditsUsed && used?.message == AIPricing.creditsUsedMessage(estimate: 61, balance: 60) && used?.offers == [.buyCredits, .upgrade])
        #expect(m2.localRefusal(reserved: 60, largeRead: true, now: now) == nil, "exactly the balance fits")
        // AI Pro: no Upgrade offered.
        let pro = Self.meter(.aiPro, allowanceLeft: 0, at: now)
        #expect(pro.localRefusal(reserved: 5, largeRead: false, now: now)?.offers == [.buyCredits])
        // Stale (older than ten minutes), past the period's end, or no receipt: only the plan's fixed ceiling is known.
        #expect(m2.localRefusal(reserved: 61, largeRead: true, now: now.addingTimeInterval(11 * 60)) == nil)
        #expect(m2.localRefusal(reserved: 61, largeRead: true, now: now.addingTimeInterval(21 * 86_400)) == nil)
        let fresh = AICreditMeter(); fresh.planChanged(.aiIncluded)
        #expect(fresh.localRefusal(reserved: 599, largeRead: true, now: now) == nil)
        #expect(fresh.localRefusal(reserved: 601, largeRead: true, now: now)?.code == .tooCostly)
        // No plan known: nothing refused here (the relay answers not-subscribed).
        #expect(AICreditMeter().localRefusal(reserved: 10_000, largeRead: true, now: now) == nil)
        // A receipt is for its plan: changing plan forgets it.
        m2.planChanged(.aiPro)
        #expect(m2.balance == nil && m2.localRefusal(reserved: 61, largeRead: true, now: now) == nil)
    }

    @Test("The pre-check's words are the relay's (relay/src/policy.ts REFUSALS, word for word)")
    func refusalWordsMatchRelay() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("relay/src/policy.ts")
        let ts = try String(contentsOf: url, encoding: .utf8)
        func template(_ s: String) -> String {
            s.replacingOccurrences(of: "123457", with: "${estimate}").replacingOccurrences(of: "98765", with: "${balance}")
             .replacingOccurrences(of: "4321", with: "${ceiling}").replacingOccurrences(of: "1112", with: "${limit}")
        }
        let used = template(AIPricing.creditsUsedMessage(estimate: 123457, balance: 98765))
        let daily = template(AIPricing.dailyLimitMessage(limit: 1112))
        let large = template(AIPricing.tooCostlyMessage(estimate: 123457, ceiling: 4321, large: true))
        let small = template(AIPricing.tooCostlyMessage(estimate: 123457, ceiling: 4321, large: false))
        for t in [used, daily, large, small] { #expect(ts.contains("`\(t)`"), "not in policy.ts: \(t)") }
    }

    @Test("Provider: a case read or question the meter shows would be refused is not sent (nothing dispatched, the relay's words, offers recorded); unknown → sent")
    func providerUsesPreCheck() async throws {
        let calls = Bodies()
        let refusing: @Sendable (Int, Bool) async -> AIPlanRefusal? = { reserved, large in
            calls.add(OutboundHTTPRequest(url: "check://\(reserved)/\(large)", headers: [:], body: Data()))
            return AIPlanRefusal(code: .creditsUsed, message: AIPricing.creditsUsedMessage(estimate: reserved, balance: 1), estimate: reserved, offers: [.buyCredits, .upgrade])
        }
        let r = try await Self.rig(kind: .included, creditCheck: refusing)
        do {
            _ = try await r.provider.readCase(r.send)
            Issue.record("expected the local credit refusal")
        } catch let e as AIPlanRefusal {
            #expect(e.code == .creditsUsed && e.message.contains("Nothing was sent"))
        }
        #expect(r.bodies.all.isEmpty, "nothing dispatched")
        // Sized exactly as the relay sizes the request, as a confirmed large read with the 1-hour write.
        let expected = AIPricing.relayReservation(inputCharacters: AIPricing.relayCharacters(system: nil, texts: r.send.prefix + [r.send.suffix]),
                                                  maxOutputTokens: OnlineRequestBuilder.anthropicMaxTokens(r.send.replyTokens), cacheWrite1h: true)
        #expect(calls.all.first?.url == "check://\(expected)/true")
        let offers = await MainActor.run { r.status.lastFailureOffers }
        #expect(offers == [.buyCredits, .upgrade])

        // An ordinary question (send) on the same plan: checked as a non-large request.
        let q = try await Self.rig(kind: .included, creditCheck: refusing)
        await #expect(throws: AIPlanRefusal.self) {
            _ = try await q.provider.generateQuestionOnly(prompt: "When was it paid?", options: GenerationOptions(maxTokens: 500))
        }
        #expect(q.bodies.all.isEmpty)
        #expect(calls.all.last?.url.hasSuffix("/false") == true)

        // The meter does not know (nil): sent, and the relay decides.
        let relayReply = Data(#"{"content":[{"type":"text","text":"{\"status\":\"not_stated\"}"}],"usage":{"input_tokens":30,"output_tokens":80}}"#.utf8)
        let ok = try await Self.rig(kind: .included, creditCheck: { _, _ in nil }, reply: relayReply)
        _ = try await ok.provider.readCase(ok.send)
        #expect(ok.bodies.all.count == 1 && ok.bodies.all[0].headers["x-kals-large-read"] == "confirmed")
    }

    @Test("Seams.live wires the shared meter's pre-check; the plain seams never refuse")
    func liveSeamWiring() async {
        let plain = OnlineCloudProvider.Seams(settings: { OnlineSnapshot.current() }, consent: { _ in false }, transport: { _ in OutboundHTTPResponse(status: 500, body: Data()) })
        #expect(await plain.creditCheck(1_000_000, true) == nil)
        // The live seam asks the shared meter: a request above every plan's ceiling is refused whenever a plan is known.
        let tier = await MainActor.run { AICreditMeter.shared.tier }
        let live = await OnlineCloudProvider.Seams.live.creditCheck(1_000_000, true)
        #expect((live != nil) == (tier?.limits != nil))
    }
}
