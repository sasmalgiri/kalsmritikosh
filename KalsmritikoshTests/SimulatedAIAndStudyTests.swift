//
//  SimulatedAIAndStudyTests.swift
//  KalsmritikoshTests
//
//  Unified path R2-E (owner 2026-11-22 round 2) — the test-phase runner of the SIMULATED AI and study rows: AI-14,
//  AI-16, ADAPT-07, ADAPT-10, BENEFIT-02..09, HELP-12, QA-18. Written now, run in the test phase. Every report is
//  labelled simulated; agent participants are not human.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("SIMULATED AI provider, held-out sets, enrichment and agent-participant study (R2-E)")
struct SimulatedAIAndStudyTests {

    // MARK: AI-16

    @Test("SIMULATED second provider: own disclosure and consent, typed failures, usage recorded, replies labelled")
    func secondProvider() async throws {
        let p = SimulatedSecondProvider(script: [.reply("The invoice was paid on 3 May."), .fail(.rateLimited(retryAfterSeconds: 30)), .fail(.timeout)],
                                        consent: { $0.host == SimulatedSecondProvider.host })
        let r = try await p.generate(prompt: "When was the invoice paid?", options: GenerationOptions())
        #expect(r.hasPrefix("[SIMULATED]"))
        await #expect(throws: SimulatedSecondProvider.Failure.rateLimited(retryAfterSeconds: 30)) { _ = try await p.generate(prompt: "again", options: GenerationOptions()) }
        await #expect(throws: SimulatedSecondProvider.Failure.timeout) { _ = try await p.generate(prompt: "again", options: GenerationOptions()) }
        #expect(await p.usage.count == 3)
        #expect(await p.disclosures.allSatisfy { $0.text.hasPrefix("SIMULATED send to") })
        let declined = SimulatedSecondProvider(script: [.reply("x")], consent: { _ in false })
        await #expect(throws: SimulatedSecondProvider.Failure.declined) { _ = try await declined.generate(prompt: "q", options: GenerationOptions()) }
        #expect(await declined.usage.first?.costMicros == 0)
    }

    @Test("SIMULATED second provider sits behind the resolver: Fully private refuses it")
    func behindResolver() async throws {
        let hw = HardwareProfile(totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824, processorCount: 8,
                                 isAppleSilicon: true, chipName: "TestChip", hasNeuralEngine: true)
        let registry = CapabilityRegistry(hardware: hw, benchmark: PerformanceBenchmark(hardwareProfile: hw))
        await registry.register(SimulatedSecondProvider(script: [], consent: { _ in true }))
        await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            await #expect(throws: (any Error).self) { _ = try await registry.resolve(.textGeneration(purpose: "sim")) }
        }
    }

    // MARK: AI-14 / BENEFIT-09

    @Test("SIMULATED held-out set: disjoint from development, deterministic, scorer frozen; refusal and correction burden recorded")
    func heldOutSets() async throws {
        let dev = SimulatedHeldOutEvalSets.generate(split: .development)
        let held = SimulatedHeldOutEvalSets.generate(split: .heldOut)
        #expect(dev == SimulatedHeldOutEvalSets.generate(split: .development), "deterministic")
        #expect(SimulatedHeldOutEvalSets.overlap(dev, held).isEmpty, "no shared names, organisations or documents")
        #expect(Set(held.map(\.family)) == Set(SimEvalFamily.allCases))
        let d = await SimulatedHeldOutEvalSets.score(dev) { SimulatedHeldOutEvalSets.corpusBaseline($0) }
        let h = await SimulatedHeldOutEvalSets.score(held) { SimulatedHeldOutEvalSets.corpusBaseline($0) }
        #expect(d.scorerFingerprint == h.scorerFingerprint)
        #expect(h.label.hasPrefix("SIMULATED"))
        let cmp = await SimulatedHeldOutEvalSets.compare(answerers: SimulatedHeldOutEvalSets.Mode.allCases.map { m in
            (m.rawValue, { @Sendable c in SimulatedHeldOutEvalSets.corpusBaseline(c) })
        } + [("16-method review", { @Sendable c in SimulatedHeldOutEvalSets.corpusBaseline(c) }),
             ("ordinary follow-ups", { @Sendable c in SimulatedHeldOutEvalSets.corpusBaseline(c) })])
        #expect(cmp.rows.count == 6)
        try SimulationArtifacts.write(cmp.markdown + "\n\nDevelopment accuracy \(d.accuracy), held-out \(h.accuracy), scorer \(d.scorerVersion) \(d.scorerFingerprint).\n",
                                      name: "ai-heldout-and-modes.md")
    }

    // MARK: ADAPT-07 / ADAPT-10

    @Test("SIMULATED typed adapters and recipes: no match, denied, failed and partial stay distinct; only authorised adapters run")
    func enrichmentRecipes() async {
        let data = ["Quayside Metals Ltd": ["REG-1"], "Quayside Metals Holdings": ["REG-2"], "Quayside Metals Trading": ["REG-3"]]
        let ok = SimulatedCommercialRegistryAdapter(dataset: data)
        let recipe = EnrichmentRecipe(name: "company check", steps: [.init(adapterID: "sim.commercial-registry", maxPages: 5), .init(adapterID: "unconfigured", maxPages: 1)])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let r = await recipe.run(query: "Quayside", configured: [ok], authorized: ["sim.commercial-registry"], at: date)
        #expect(r.first?.status == .matches && r.first?.candidates.count == 3)
        #expect(r.last?.status == .denied)
        let none = await recipe.run(query: "Nobody", configured: [ok], authorized: ["sim.commercial-registry"], at: date)
        #expect(none.first?.status == .noMatch)
        let unauth = await recipe.run(query: "Quayside", configured: [ok], authorized: [], at: date)
        #expect(unauth.first?.status == .denied)
        let flaky = await recipe.run(query: "Quayside", configured: [SimulatedCommercialRegistryAdapter(dataset: data, failPages: [2])],
                                     authorized: ["sim.commercial-registry"], at: date)
        #expect(flaky.first?.status == .partial)
        let capped = await EnrichmentRecipe(name: "one page", steps: [.init(adapterID: "sim.commercial-registry", maxPages: 1)])
            .run(query: "Quayside", configured: [ok], authorized: ["sim.commercial-registry"], at: date)
        #expect(capped.first?.status == .partial, "stopping at the page limit is not a complete result")
    }

    @Test("SIMULATED sending: modes are distinct, consent is per recipient and mode, the preview names recipient, fields and cost")
    func evidenceSending() async {
        let s = SimulatedEvidenceSender()
        await s.grantConsent(mode: .aiOnly, recipient: "Claude")
        let noTransfer = await s.send(mode: .networkOnly, recipient: "Specialist lab", fields: ["exhibit 4"], usesAI: false, usesEnrichment: false,
                                      costMicros: 0, confirm: { _ in true })
        if case .refused = noTransfer {} else { Issue.record("consent transferred: \(noTransfer)") }
        let mixed = await s.send(mode: .aiOnly, recipient: "Claude", fields: ["passages"], usesAI: true, usesEnrichment: true, costMicros: 10, confirm: { _ in true })
        if case .refused = mixed {} else { Issue.record("AI-only carried enrichment: \(mixed)") }
        let ok = await s.send(mode: .aiOnly, recipient: "Claude", fields: ["passages 1–3"], usesAI: true, usesEnrichment: false, costMicros: 20_000,
                              confirm: { $0.text.contains("Claude") && $0.text.contains("passages 1–3") && $0.text.contains("$0.02") })
        if case .sent(let p) = ok { #expect(p.label.hasPrefix("SIMULATED")) } else { Issue.record("not sent: \(ok)") }
    }

    // MARK: BENEFIT-02..08, HELP-12, QA-18

    @Test("Agent-participant study: ≥ 5 agents (new and experienced), counterbalanced, all efforts and qualities recorded, labelled not human")
    func agentStudy() async throws {
        let report = await AgentParticipantStudy.run()
        #expect(report.markdown.hasPrefix("# Agent participants (simulated), not human"))
        #expect(Set(report.outcomes.map(\.persona)).count >= 5)
        // Every participant works both conditions on different packs.
        for p in report.schedule {
            #expect(Set(p.sessions.map(\.condition)).count == 2 && Set(p.sessions.map(\.pack)).count == 2)
        }
        let orders = Set(report.schedule.map { $0.sessions.map { "\($0.condition)\($0.pack)" }.joined() })
        #expect(orders.count == 4, "all four orders are used")
        for task in AgentParticipantStudy.learnabilityTasks + AgentParticipantStudy.capabilityTasks {
            #expect(report.outcomes.contains { $0.task == task }, "\(task)")
        }
        #expect(report.outcomes.contains { $0.aiOn } && report.outcomes.contains { !$0.aiOn })
        #expect(!report.claimAllowed("The app is 30% faster for every investigator").allowed)
        #expect(!report.claimAllowed("30% faster").allowed, "must say it comes from simulated agents")
        try SimulationArtifacts.write(report.markdown, name: "agent-participant-study.md")
    }
}
