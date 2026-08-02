//
//  MissionEvidenceObligationTests.swift
//  KalsmritikoshTests
//
//  AEE-M1 — the per-lane obligations, the readiness floor, the mission evidence assessor,
//  and the adaptive planner. Proves: high-risk lanes require evidence-ready decisive
//  sources; low-risk lanes may ship a disclosed partial; a permanently-blocked decisive
//  source blocks (never answered around); duplicates never satisfy corroboration;
//  contradictions are reported not silently resolved; the planner upgrades ONLY decisive
//  versions that are below the floor AND upgradable. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M1 — mission evidence obligations, assessor & planner")
struct MissionEvidenceObligationTests {

    private func intent(_ q: String = "q?") -> UserIntent {
        UserIntent(kind: .factualLookup, scope: .global, rawQuestion: q)
    }
    private func plan(_ c: QueryCategory, _ k: LLMQueryClass) -> QueryPlan {
        QueryPlanCompiler().compile(intent: intent(), category: c, queryClass: k)
    }
    /// A mission on a chosen lane by driving the compiler with signals that select it.
    private func mission(lane: AEELane, class k: LLMQueryClass = .ordinary) -> QueryMission {
        let (i, c, det, wf): (UserIntent, QueryCategory, Bool, Bool)
        switch lane {
        case .deterministic:       (i, c, det, wf) = (intent(), .fact, true, false)
        case .focused:             (i, c, det, wf) = (intent(), .fact, false, false)
        case .analytical:          (i, c, det, wf) = (intent(), .comparison, false, false)
        case .reconstruction:      (i, c, det, wf) = (UserIntent(kind: .reconstructTimeline, scope: .global, rawQuestion: "trace"), .narrative, false, false)
        case .professionalWorkflow:(i, c, det, wf) = (intent(), .fact, false, true)
        }
        let p = QueryPlanCompiler().compile(intent: i, category: c, queryClass: k)
        return QueryMissionCompiler().compile(
            intent: i, category: c, queryClass: k, plan: p,
            context: AEERequestContext(workflowInvocationPresent: wf, deterministicHandlerAvailable: det))
    }
    private func sufficiency(covered: [RequestedField], missing: [RequestedField]) -> EvidenceSufficiency {
        EvidenceSufficiency(covered: covered, missing: missing, documentsSearched: covered.count + missing.count)
    }

    // MARK: - Obligations

    @Test("Focused obligations: search-ready floor, disclosed partial allowed, one corrective pass")
    func focusedObligations() {
        let o = MissionEvidenceObligations.forLane(.focused, plan: plan(.fact, .ordinary))
        #expect(o.minimumSourceReadiness == .searchReady)
        #expect(o.allowSearchablePartialWithDisclosure)
        #expect(o.maxCorrectivePasses == 1)
    }

    @Test("Analytical obligations: evidence-ready floor, no disclosed partial")
    func analyticalObligations() {
        let o = MissionEvidenceObligations.forLane(.analytical, plan: plan(.comparison, .complex))
        #expect(o.minimumSourceReadiness == .evidenceReady)
        #expect(!o.allowSearchablePartialWithDisclosure)
    }

    @Test("Deterministic obligations: search-ready floor, no corrective pass, no disclosed partial")
    func deterministicObligations() {
        let o = MissionEvidenceObligations.forLane(.deterministic, plan: plan(.fact, .deterministic))
        #expect(o.minimumSourceReadiness == .searchReady)
        #expect(o.maxCorrectivePasses == 0)
        #expect(!o.allowSearchablePartialWithDisclosure)
    }

    @Test("Reconstruction and professionalWorkflow require an evidence-ready floor")
    func evidenceReadyLanes() {
        #expect(MissionEvidenceObligations.forLane(.reconstruction, plan: plan(.narrative, .reconstruction)).minimumSourceReadiness == .evidenceReady)
        #expect(MissionEvidenceObligations.forLane(.professionalWorkflow, plan: plan(.fact, .moderate)).minimumSourceReadiness == .evidenceReady)
    }

    // MARK: - Readiness floor

    @Test("The readiness floor's isMet is monotone in the completion state")
    func floorIsMet() {
        #expect(MissionReadinessFloor.searchReady.isMet(by: .searchablePartial))
        #expect(MissionReadinessFloor.searchReady.isMet(by: .evidenceReady))
        #expect(!MissionReadinessFloor.evidenceReady.isMet(by: .searchablePartial))
        #expect(MissionReadinessFloor.evidenceReady.isMet(by: .evidenceReady))
    }

    @Test("Only preserved/searchable states are upgradable; encrypted/corrupt/unsupported/failed are not")
    func floorUpgradable() {
        let floor = MissionReadinessFloor.evidenceReady
        #expect(floor.isUpgradable(from: .searchablePartial))
        #expect(floor.isUpgradable(from: .preservedOnly))
        for s in [SourceCompletionState.encrypted, .corrupt, .unsupported, .failed] {
            #expect(!floor.isUpgradable(from: s), "\(s) must not be upgradable")
        }
    }

    // MARK: - Assessor

    @Test("Satisfied: all fields covered, decisive source evidence-ready, corroboration met")
    func satisfied() {
        let m = mission(lane: .analytical, class: .complex)
        let sv = UUID()
        let a = MissionEvidenceAssessor().assess(
            mission: m, sufficiency: sufficiency(covered: [.status], missing: []),
            decisiveReadiness: [sv: .evidenceReady], independentSourceCount: 2,
            contradictionCount: 0, correctivePassUsed: false)
        #expect(a.disposition == .satisfied)
        #expect(a.insufficientReadinessSourceVersionIDs.isEmpty)
    }

    @Test("Focused ships a disclosed partial when a field is missing")
    func focusedPartial() {
        let m = mission(lane: .focused)
        let sv = UUID()
        let a = MissionEvidenceAssessor().assess(
            mission: m, sufficiency: sufficiency(covered: [], missing: [.monetaryAmount]),
            decisiveReadiness: [sv: .searchablePartial], independentSourceCount: 1,
            contradictionCount: 0, correctivePassUsed: true)
        #expect(a.disposition == .partial)
        #expect(!a.limitations.isEmpty)          // the gap is disclosed
        #expect(a.correctivePassUsed)
    }

    @Test("A permanently-blocked decisive source blocks a high-risk mission (never answered around)")
    func analyticalBlocked() {
        let m = mission(lane: .analytical, class: .complex)
        let sv = UUID()
        let a = MissionEvidenceAssessor().assess(
            mission: m, sufficiency: sufficiency(covered: [.status], missing: []),
            decisiveReadiness: [sv: .corrupt], independentSourceCount: 2,
            contradictionCount: 0, correctivePassUsed: false)
        #expect(a.disposition == .blocked)
        #expect(!a.blockers.isEmpty)
    }

    @Test("An unsupported query class is unsupported regardless of evidence")
    func unsupported() {
        // Build an unsupported-class mission directly (compiler preserves the class).
        let i = intent(); let p = QueryPlanCompiler().compile(intent: i, category: .fact, queryClass: .unsupported)
        let m = QueryMissionCompiler().compile(intent: i, category: .fact, queryClass: .unsupported, plan: p,
                                               context: AEERequestContext())
        let a = MissionEvidenceAssessor().assess(
            mission: m, sufficiency: sufficiency(covered: [], missing: []),
            decisiveReadiness: [:], independentSourceCount: 0, contradictionCount: 0, correctivePassUsed: false)
        #expect(a.disposition == .unsupported)
    }

    @Test("Duplicates do not satisfy corroboration; contradictions are reported, not resolved")
    func corroborationAndContradictions() {
        // Analytical with a corroboration-required plan (complex class → requiresCorroboration).
        let m = mission(lane: .analytical, class: .complex)
        #expect(m.evidenceObligations.requiresCorroboration)
        let sv = UUID()
        // Two duplicate copies collapse to ONE independent source → corroboration unmet.
        let a = MissionEvidenceAssessor().assess(
            mission: m, sufficiency: sufficiency(covered: [.status], missing: []),
            decisiveReadiness: [sv: .evidenceReady], independentSourceCount: 1,
            contradictionCount: 2, correctivePassUsed: false)
        #expect(a.disposition != .satisfied)                 // corroboration not met
        #expect(a.contradictionCount == 2)                   // surfaced, not averaged away
        #expect(a.limitations.contains { $0.contains("independent") })
    }

    // MARK: - Planner

    @Test("The planner upgrades only decisive versions below the floor AND upgradable")
    func plannerMinimal() {
        let m = mission(lane: .analytical, class: .complex)   // evidence-ready floor
        let below = UUID()          // searchablePartial → needs upgrade
        let already = UUID()        // evidenceReady → no action (reuse satisfied work)
        let blocked = UUID()        // corrupt → not upgradable → no action (assessor blocks)
        let planned = AdaptiveEvidencePlanner().plan(mission: m, decisiveReadiness: [
            below: .searchablePartial, already: .evidenceReady, blocked: .corrupt])
        #expect(planned.upgradeActions.count == 1)
        #expect(planned.upgradeActions.first?.sourceVersionID == below)
        #expect(planned.upgradeActions.first?.goal == .evidenceReady)
        #expect(planned.requiresCorrectiveRetrieval)
    }
}
