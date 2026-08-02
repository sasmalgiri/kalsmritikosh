//
//  AEEMasterBrainIntegrationTests.swift
//  KalsmritikoshTests
//
//  AEE-M1 — the seams MasterBrain uses to run a mission's adaptive evidence lane:
//  identifying the DECISIVE exact source versions of the retrieved chunks, upgrading ONLY
//  those that need it (never the whole archive), tolerating a byte-changed source without
//  fabricating around it, and keeping corrective retrieval at one pass. Exercised through
//  the same `nonisolated static` entry points MasterBrain calls, with a fake upgrade
//  bridge and synthetic retrieval. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M1 — MasterBrain adaptive-evidence integration")
struct AEEMasterBrainIntegrationTests {

    // A fake USF upgrade bridge that records which exact versions were asked to upgrade.
    private actor FakeBridge: AEEEvidenceUpgrading {
        let states: [UUID: SourceCompletionState]
        let throwOnEnsure: Bool
        private(set) var ensured: [UUID] = []
        init(states: [UUID: SourceCompletionState], throwOnEnsure: Bool = false) {
            self.states = states; self.throwOnEnsure = throwOnEnsure
        }
        func completionState(sourceVersionID: UUID) async -> SourceCompletionState? { states[sourceVersionID] }
        func ensureReady(sourceVersionID: UUID, goal: SourceUpgradeGoal) async throws {
            if throwOnEnsure { throw AEEError.unsatisfiableReadiness(sourceVersionID: sourceVersionID) }
            ensured.append(sourceVersionID)
        }
        func ensuredIDs() -> [UUID] { ensured }
    }

    private func intent(_ q: String = "why did A compare to B?") -> UserIntent {
        UserIntent(kind: .factualLookup, scope: .global, rawQuestion: q)
    }
    private func chunk(sv: UUID?, _ text: String = "body text about the matter") -> RetrievedChunk {
        let c = Chunk(objectID: UUID(), ordinal: 0, text: text, characterRange: 0..<text.count, sourceVersionID: sv)
        return RetrievedChunk(chunk: c, score: 1.0, viaLayer: .metadata)
    }
    private func mission(lane: AEELane, class k: LLMQueryClass = .complex) -> QueryMission {
        let (i, c, det, wf): (UserIntent, QueryCategory, Bool, Bool)
        switch lane {
        case .focused:        (i, c, det, wf) = (intent(), .fact, false, false)
        case .analytical:     (i, c, det, wf) = (intent(), .comparison, false, false)
        default:              (i, c, det, wf) = (intent(), .comparison, false, false)
        }
        let p = QueryPlanCompiler().compile(intent: i, category: c, queryClass: k)
        return QueryMissionCompiler().compile(intent: i, category: c, queryClass: k, plan: p,
            context: AEERequestContext(workflowInvocationPresent: wf, deterministicHandlerAvailable: det))
    }

    @Test("A search-ready mission requests no upgrades")
    func searchReadyNoUpgrade() async {
        let m = mission(lane: .focused, class: .ordinary)   // search-ready floor
        #expect(m.evidenceObligations.minimumSourceReadiness == .searchReady)
        let sv = UUID()
        let bridge = FakeBridge(states: [sv: .searchablePartial])
        let actions = await MasterBrain.runAdaptiveEvidenceUpgrades(
            mission: m, retrieval: RetrievalResult(chunks: [chunk(sv: sv)]), bridge: bridge)
        #expect(actions.isEmpty)
        #expect(await bridge.ensuredIDs().isEmpty)
    }

    @Test("An evidence-ready mission upgrades a decisive searchable-partial version")
    func evidenceReadyUpgrades() async {
        let m = mission(lane: .analytical)
        let sv = UUID()
        let bridge = FakeBridge(states: [sv: .searchablePartial])
        let actions = await MasterBrain.runAdaptiveEvidenceUpgrades(
            mission: m, retrieval: RetrievalResult(chunks: [chunk(sv: sv)]), bridge: bridge)
        #expect(actions.map(\.sourceVersionID) == [sv])
        #expect(actions.first?.goal == .evidenceReady)
        #expect(await bridge.ensuredIDs() == [sv])
    }

    @Test("Only the decisive retrieved versions are considered — not the whole archive")
    func onlyDecisiveVersions() async {
        let m = mission(lane: .analytical)
        let decisive = UUID(), unrelated = UUID()
        // `unrelated` is NOT in the retrieval, so it is never touched even though it is stale.
        let bridge = FakeBridge(states: [decisive: .searchablePartial, unrelated: .searchablePartial])
        let actions = await MasterBrain.runAdaptiveEvidenceUpgrades(
            mission: m, retrieval: RetrievalResult(chunks: [chunk(sv: decisive)]), bridge: bridge)
        #expect(actions.map(\.sourceVersionID) == [decisive])
        #expect(await bridge.ensuredIDs() == [decisive])   // unrelated never upgraded
    }

    @Test("A permanently-blocked decisive source yields no upgrade (not fabricated around)")
    func blockedNoUpgrade() async {
        let m = mission(lane: .analytical)
        let sv = UUID()
        let bridge = FakeBridge(states: [sv: .corrupt])
        let actions = await MasterBrain.runAdaptiveEvidenceUpgrades(
            mission: m, retrieval: RetrievalResult(chunks: [chunk(sv: sv)]), bridge: bridge)
        #expect(actions.isEmpty)
        #expect(await bridge.ensuredIDs().isEmpty)
    }

    @Test("A byte-changed/unavailable source throws in the bridge but never crashes the lane")
    func changedBytesTolerated() async {
        let m = mission(lane: .analytical)
        let sv = UUID()
        let bridge = FakeBridge(states: [sv: .searchablePartial], throwOnEnsure: true)
        let actions = await MasterBrain.runAdaptiveEvidenceUpgrades(
            mission: m, retrieval: RetrievalResult(chunks: [chunk(sv: sv)]), bridge: bridge)
        // The action was planned and attempted; the throw is swallowed (exact-byte protected).
        #expect(actions.map(\.sourceVersionID) == [sv])
    }

    @Test("Legacy chunks without an exact source version are skipped")
    func legacyChunksSkipped() {
        let sv = UUID()
        let r = RetrievalResult(chunks: [chunk(sv: nil), chunk(sv: sv), chunk(sv: nil)])
        #expect(MasterBrain.decisiveSourceVersionIDs(in: r) == [sv])
    }

    @Test("Decisive version extraction is distinct and bounded")
    func decisiveBounded() {
        var chunks: [RetrievedChunk] = []
        for _ in 0..<20 { chunks.append(chunk(sv: UUID())) }
        let dup = chunks[0]
        chunks.append(dup)   // duplicate version
        let ids = MasterBrain.decisiveSourceVersionIDs(in: RetrievalResult(chunks: chunks), limit: 8)
        #expect(ids.count == 8)                       // bounded
        #expect(Set(ids).count == ids.count)          // distinct
    }

    @Test("An evidence-ready decisive source needs no upgrade (satisfied work is reused)")
    func alreadyReadyNoUpgrade() async {
        let m = mission(lane: .analytical)
        let sv = UUID()
        let bridge = FakeBridge(states: [sv: .evidenceReady])
        let actions = await MasterBrain.runAdaptiveEvidenceUpgrades(
            mission: m, retrieval: RetrievalResult(chunks: [chunk(sv: sv)]), bridge: bridge)
        #expect(actions.isEmpty)
        #expect(await bridge.ensuredIDs().isEmpty)
    }

    @Test("Corrective retrieval with the real plan fires at most one pass")
    func correctiveOnePassRealPlan() async {
        actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
        let counter = Counter()
        let obj = UUID()
        let first = RetrievalResult(
            chunks: [RetrievedChunk(chunk: Chunk(objectID: obj, ordinal: 0, text: "notes with no amount",
                                                 characterRange: 0..<5), score: 1, viaLayer: .metadata)],
            layersUsed: [.metadata])
        let i = intent("how much was paid?")
        let realPlan = QueryPlanCompiler().compile(intent: i, category: .fact, queryClass: .complex)
        _ = await MasterBrain.applyCorrectiveRetrieval(
            first: first, intent: i, layers: [.metadata], plan: realPlan,
            retrieve: { _ in await counter.bump()
                return RetrievalResult(chunks: [RetrievedChunk(
                    chunk: Chunk(objectID: obj, ordinal: 1, text: "amount 500 paid", characterRange: 0..<5),
                    score: 1, viaLayer: .vector)], layersUsed: [.vector]) })
        #expect(await counter.value() <= 1)   // at most one corrective pass
    }

    @Test("The threaded real plan drives corrective retrieval (no reliance on the .fact/.ordinary fallback)")
    func realPlanThreaded() async {
        // A plan whose requested fields are already covered → no corrective pass at all.
        let obj = UUID()
        let first = RetrievalResult(
            chunks: [RetrievedChunk(chunk: Chunk(objectID: obj, ordinal: 0,
                        text: "the amount 500 was paid on 5 jan 2020", characterRange: 0..<5),
                        score: 1, viaLayer: .metadata)],
            layersUsed: [.metadata])
        actor Counter { var n = 0; func bump() { n += 1 }; func value() -> Int { n } }
        let counter = Counter()
        let i = intent("how much was paid?")
        let realPlan = QueryPlanCompiler().compile(intent: i, category: .fact, queryClass: .ordinary)
        _ = await MasterBrain.applyCorrectiveRetrieval(
            first: first, intent: i, layers: [.metadata], plan: realPlan,
            retrieve: { _ in await counter.bump(); return RetrievalResult() })
        #expect(await counter.value() == 0)   // amount already present → no pass
    }
}
