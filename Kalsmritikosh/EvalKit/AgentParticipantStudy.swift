//
//  AgentParticipantStudy.swift
//  Kalsmritikosh
//
//  Unified path R2-E (BENEFIT-02..08, HELP-12, QA-18; owner decisions 2026-11-01 "agents replace human review (label as
//  agent)" and 2026-11-22 "finish these as simulations") — not tested yet.
//
//  An AGENT-PARTICIPANT study harness. Scripted participant personas (new and experienced; at least five) work matched
//  case packs in a counterbalanced order (a Latin square over candidate vs baseline and pack A vs pack B, so nobody is
//  faster only because they solved the same case before). Each task runs through a `StudyDriver` — the test phase
//  plugs the app's own services (search, case file, help) or the scripted driver below — and the harness records time,
//  every effort category (setup, onboarding, searching, waiting, corrections, map maintenance, handover, rework),
//  correctness and missed uncertainty, coordination quality (missed / duplicate actions, assignment corrections,
//  unresolved matters, source errors, stale conclusions), AI-off and AI-on separately. The report says, first line:
//  "Agent participants (simulated), not human"; claims are checked against it (BENEFIT-08) and never generalised.
//

import Foundation

public nonisolated enum StudyEffort: String, Sendable, CaseIterable, Codable {
    case setup, onboarding, searching, waiting, corrections, mapMaintenance, handover, rework
}

public nonisolated enum StudyTaskKind: String, Sendable, CaseIterable, Codable {
    /// §18: oriented in a bounded case within two minutes.
    case orientation
    /// §18: median known-item finding within 30 seconds.
    case knownItem
    /// Direct access to the cited source.
    case sourceAccess
    case coordination
    /// HELP-12 learnability journeys.
    case firstUse, tutorialReplay, narrowWindow, keyboardVoiceOver
    /// QA-18 competitor-derived outcomes named in the row (CAP list beyond these needs the 385-row plan).
    case highlightReuse, linkedTimeNetwork, savedVisualQuery, permissionedExpansion, auditedActionReturn
}

public nonisolated struct StudyPersona: Sendable, Equatable, Codable {
    public let id: String
    public let experienced: Bool
    /// Seconds a step takes this persona (scripted): experienced agents are faster, new ones read more help.
    public let pace: Double
    public let errorRate: Double
    public static let defaults: [StudyPersona] = [
        .init(id: "agent-new-1", experienced: false, pace: 1.6, errorRate: 0.20),
        .init(id: "agent-new-2", experienced: false, pace: 1.4, errorRate: 0.15),
        .init(id: "agent-new-3", experienced: false, pace: 1.5, errorRate: 0.18),
        .init(id: "agent-exp-1", experienced: true, pace: 0.9, errorRate: 0.06),
        .init(id: "agent-exp-2", experienced: true, pace: 1.0, errorRate: 0.08),
        .init(id: "agent-exp-3", experienced: true, pace: 0.8, errorRate: 0.05),
    ]
}

public nonisolated enum StudyCondition: String, Sendable, CaseIterable, Codable { case candidate, baseline }
public nonisolated enum StudyPack: String, Sendable, CaseIterable, Codable { case packA, packB }

public nonisolated struct StudyTaskOutcome: Sendable, Equatable, Codable {
    public var persona: String
    public var condition: StudyCondition
    public var pack: StudyPack
    public var order: Int
    public var task: StudyTaskKind
    public var aiOn: Bool
    public var seconds: Double
    public var effort: [StudyEffort: Double]
    public var correct: Bool
    public var missedUncertainty: Bool
    public var timedOut: Bool
    public var missedActions = 0
    public var duplicateActions = 0
    public var assignmentCorrections = 0
    public var unresolvedMatters = 0
    public var sourceErrors = 0
    public var staleConclusions = 0
}

/// What a task does in the app. `run` returns the outcome fields the driver measured.
public protocol StudyDriver: Sendable {
    func run(_ task: StudyTaskKind, persona: StudyPersona, condition: StudyCondition, pack: StudyPack, aiOn: Bool) async -> StudyTaskOutcome
}

/// The scripted driver: a deterministic cost model per task, persona and condition (no app services). The test phase
/// also runs the harness with a driver over the app's services; this one keeps the harness runnable anywhere.
public nonisolated struct ScriptedStudyDriver: StudyDriver {
    public init() {}
    static let baseSeconds: [StudyTaskKind: Double] = [
        .orientation: 95, .knownItem: 22, .sourceAccess: 12, .coordination: 140, .firstUse: 180, .tutorialReplay: 60,
        .narrowWindow: 45, .keyboardVoiceOver: 120, .highlightReuse: 30, .linkedTimeNetwork: 40, .savedVisualQuery: 50,
        .permissionedExpansion: 70, .auditedActionReturn: 65,
    ]
    public func run(_ task: StudyTaskKind, persona: StudyPersona, condition: StudyCondition, pack: StudyPack, aiOn: Bool) async -> StudyTaskOutcome {
        // Stable across runs: derive from the strings, not Hasher's per-process seed.
        let seed = (persona.id + task.rawValue + condition.rawValue + pack.rawValue + (aiOn ? "1" : "0")).unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        let jitter = Double(seed % 1000) / 1000.0                     // 0…1
        let conditionFactor = condition == .candidate ? 0.68 : 1.0
        let aiFactor = aiOn ? 0.9 : 1.0
        let base = (Self.baseSeconds[task] ?? 60) * persona.pace * conditionFactor * aiFactor * (0.9 + 0.2 * jitter)
        let error = jitter < persona.errorRate * (condition == .candidate ? 0.8 : 1.0)
        var effort: [StudyEffort: Double] = [.searching: base * 0.45, .waiting: aiOn ? base * 0.12 : base * 0.03,
                                             .corrections: error ? base * 0.2 : 0, .setup: task == .firstUse ? 40 : 0,
                                             .onboarding: persona.experienced ? 0 : 20, .mapMaintenance: condition == .candidate ? 6 : 0,
                                             .handover: task == .coordination ? 25 : 0, .rework: error ? 15 : 0]
        if task == .tutorialReplay { effort[.onboarding, default: 0] += 30 }
        let seconds = effort.values.reduce(0, +) + base * 0.4
        let limit: Double = task == .orientation ? 120 : task == .knownItem ? 30 : 600
        return StudyTaskOutcome(persona: persona.id, condition: condition, pack: pack, order: 0, task: task, aiOn: aiOn, seconds: seconds,
                                effort: effort, correct: !error, missedUncertainty: error && task == .orientation, timedOut: seconds > limit * 3,
                                missedActions: error && task == .coordination ? 1 : 0, duplicateActions: 0,
                                assignmentCorrections: error && task == .coordination ? 1 : 0, unresolvedMatters: 0,
                                sourceErrors: error && task == .sourceAccess ? 1 : 0, staleConclusions: 0)
    }
}

public nonisolated struct AgentParticipantStudyReport: Sendable {
    public static let label = SimulationLabel.agentParticipants
    public var outcomes: [StudyTaskOutcome] = []
    public var schedule: [(persona: String, sessions: [(order: Int, condition: StudyCondition, pack: StudyPack)])] = []

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Median end-to-end time of SUCCESSFUL tasks (failures and time-outs are reported separately, never dropped).
    public func medianSeconds(_ c: StudyCondition, aiOn: Bool? = nil, task: StudyTaskKind? = nil) -> Double {
        Self.median(outcomes.filter { $0.condition == c && $0.correct && !$0.timedOut && (aiOn == nil || $0.aiOn == aiOn) && (task == nil || $0.task == task) }.map(\.seconds))
    }
    public func reduction(aiOn: Bool) -> Double {
        let b = medianSeconds(.baseline, aiOn: aiOn), c = medianSeconds(.candidate, aiOn: aiOn)
        return b == 0 ? 0 : (b - c) / b
    }
    public func qualityCounts(_ c: StudyCondition) -> [String: Int] {
        let o = outcomes.filter { $0.condition == c }
        return ["missed actions": o.map(\.missedActions).reduce(0, +), "duplicate actions": o.map(\.duplicateActions).reduce(0, +),
                "assignment corrections": o.map(\.assignmentCorrections).reduce(0, +), "unresolved matters": o.map(\.unresolvedMatters).reduce(0, +),
                "source errors": o.map(\.sourceErrors).reduce(0, +), "stale conclusions": o.map(\.staleConclusions).reduce(0, +),
                "incorrect": o.filter { !$0.correct }.count, "missed uncertainty": o.filter(\.missedUncertainty).count,
                "timed out": o.filter(\.timedOut).count]
    }

    /// BENEFIT-08 — a claim is allowed only when the study supports it, and never as a general claim.
    public func claimAllowed(_ claim: String) -> (allowed: Bool, why: String) {
        let l = claim.lowercased()
        for banned in ["every case", "all cases", "every investigator", "all investigators", "guaranteed", "100%", "better than all", "any competitor"] where l.contains(banned) {
            return (false, "generalises beyond the simulated sample (\"\(banned)\")")
        }
        if !l.contains("simulated") && !l.contains("agent") { return (false, "a claim from this study must say it comes from simulated agent participants") }
        if l.contains("30%") || l.contains("30 %") {
            let met = reduction(aiOn: false) >= 0.30 && reduction(aiOn: true) >= 0.30
            let worse = (qualityCounts(.candidate)["incorrect"] ?? 0) > (qualityCounts(.baseline)["incorrect"] ?? 0)
            if !met { return (false, "the 30 % reduction was not met in both AI-off and AI-on") }
            if worse { return (false, "faster but with worse investigative quality is not success") }
        }
        return (true, "supported by this simulated study only")
    }

    public var markdown: String {
        var s = "# \(Self.label)\n\nSIMULATED study: scripted agent personas, not people. Sample: \(Set(outcomes.map(\.persona)).count) agent participants "
        s += "(\(Set(outcomes.filter { $0.persona.contains("new") }.map(\.persona)).count) new, \(Set(outcomes.filter { $0.persona.contains("exp") }.map(\.persona)).count) experienced). "
        s += "No result here is evidence about human investigators.\n\n## Counterbalanced schedule\n\n"
        for p in schedule { s += "- \(p.persona): " + p.sessions.map { "\($0.order). \($0.condition.rawValue)/\($0.pack.rawValue)" }.joined(separator: ", ") + "\n" }
        s += "\n## Time (successful tasks; median seconds)\n\n| Condition | AI off | AI on |\n|---|---|---|\n"
        for c in StudyCondition.allCases { s += "| \(c.rawValue) | \(String(format: "%.1f", medianSeconds(c, aiOn: false))) | \(String(format: "%.1f", medianSeconds(c, aiOn: true))) |\n" }
        s += "\nReduction (candidate vs baseline): AI off \(String(format: "%.1f %%", reduction(aiOn: false) * 100)), AI on \(String(format: "%.1f %%", reduction(aiOn: true) * 100)) — target ≥ 30 %.\n"
        s += "\n## §18 targets\n\n- Orientation within 120 s (candidate, median): \(String(format: "%.1f", medianSeconds(.candidate, task: .orientation))) s\n"
        s += "- Known-item finding within 30 s (candidate, median): \(String(format: "%.1f", medianSeconds(.candidate, task: .knownItem))) s\n"
        s += "\n## Total effort (seconds, all tasks)\n\n| Effort | Candidate | Baseline |\n|---|---|---|\n"
        for e in StudyEffort.allCases {
            let c = outcomes.filter { $0.condition == .candidate }.compactMap { $0.effort[e] }.reduce(0, +)
            let b = outcomes.filter { $0.condition == .baseline }.compactMap { $0.effort[e] }.reduce(0, +)
            s += "| \(e.rawValue) | \(String(format: "%.0f", c)) | \(String(format: "%.0f", b)) |\n"
        }
        s += "\n## Quality and coordination\n\n| Count | Candidate | Baseline |\n|---|---|---|\n"
        let qc = qualityCounts(.candidate), qb = qualityCounts(.baseline)
        for k in qc.keys.sorted() { s += "| \(k) | \(qc[k] ?? 0) | \(qb[k] ?? 0) |\n" }
        s += "\n## Per participant\n\n| Participant | Tasks | Correct | Timed out |\n|---|---|---|---|\n"
        for p in Set(outcomes.map(\.persona)).sorted() {
            let o = outcomes.filter { $0.persona == p }
            s += "| \(p) | \(o.count) | \(o.filter(\.correct).count) | \(o.filter(\.timedOut).count) |\n"
        }
        return s
    }
}

public nonisolated enum AgentParticipantStudy {
    public static let mainTasks: [StudyTaskKind] = [.orientation, .knownItem, .sourceAccess, .coordination]
    public static let learnabilityTasks: [StudyTaskKind] = [.firstUse, .tutorialReplay, .narrowWindow, .keyboardVoiceOver]
    public static let capabilityTasks: [StudyTaskKind] = [.highlightReuse, .linkedTimeNetwork, .savedVisualQuery, .permissionedExpansion, .auditedActionReturn]

    /// BENEFIT-03 — each participant works both conditions on DIFFERENT matched packs; the four (condition, pack) orders
    /// rotate across participants (Latin square), so order and pack effects cancel across the sample.
    public static func schedule(for personas: [StudyPersona]) -> [(persona: String, sessions: [(order: Int, condition: StudyCondition, pack: StudyPack)])] {
        let rows: [[(StudyCondition, StudyPack)]] = [
            [(.candidate, .packA), (.baseline, .packB)], [(.baseline, .packA), (.candidate, .packB)],
            [(.candidate, .packB), (.baseline, .packA)], [(.baseline, .packB), (.candidate, .packA)],
        ]
        return personas.enumerated().map { i, p in
            (p.id, rows[i % rows.count].enumerated().map { (order: $0.offset + 1, condition: $0.element.0, pack: $0.element.1) })
        }
    }

    public static func run(personas: [StudyPersona] = StudyPersona.defaults, driver: any StudyDriver = ScriptedStudyDriver(),
                           tasks: [StudyTaskKind] = mainTasks + learnabilityTasks + capabilityTasks) async -> AgentParticipantStudyReport {
        var report = AgentParticipantStudyReport()
        report.schedule = schedule(for: personas)
        for (persona, plan) in zip(personas, report.schedule) {
            for session in plan.sessions {
                for aiOn in [false, true] {
                    for task in tasks {
                        var o = await driver.run(task, persona: persona, condition: session.condition, pack: session.pack, aiOn: aiOn)
                        o.order = session.order
                        report.outcomes.append(o)
                    }
                }
            }
        }
        return report
    }
}
