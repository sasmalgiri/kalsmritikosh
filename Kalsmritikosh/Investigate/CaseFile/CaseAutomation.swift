//
//  CaseAutomation.swift
//  Kalsmritikosh
//
//  Smart-map S8 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §18 AUTO; plan §10, §17.4–§17.6; schema v184).
//  Durable, bounded case-work orchestration over the EXISTING automation engine (PersonaAutomationRuntimeCoordinator and
//  its receipts in workflow_automation_executions — before this slice it was built only in tests) and the case file's one
//  savepoint. Deterministic: nothing here calls a model or the network, and it works with AI off.
//
//  • Policy (AUTO-01 / AUTO-02): per case, versioned and append-only — mode (manual / suggest / execute), allowed triggers
//    and recipes, routing, review requirement and budgets. Recipes are versioned, typed (inputs, outputs), with
//    sequential/parallel steps and review checkpoints. The mode is NOT permission to send anything to an AI provider:
//    that is the case's AI permission (CaseReadPermissionStore), read but never written here — changing one never
//    changes the other.
//  • Outbox (AUTO-03): a trigger is written in the SAME savepoint as the case change that caused it (its case-log row).
//    Dispatch claims a row, rechecks authority, makes the effect through the engine (whose task output has an identity
//    derived from its receipt) and finishes the row — link, contract, usage and state — in one savepoint. A crash at any
//    point leaves either a queued/running row that is resumed, or a finished one; never a lost trigger or a second output.
//  • Identity (AUTO-04): the engine's idempotency key is the outbox row; the row's LOGICAL key is purpose + context +
//    input revisions, so repeated delivery, a reconnect or a new policy version does not recreate unchanged work.
//  • Storms (AUTO-05): every row records what caused it (causation) and its root (correlation). Work caused by
//    automation output needs a material new condition — inputs not already seen up its causation chain — or it is
//    recorded as suppressed (once per logical key). There is no depth cap on manual work.
//  • Budgets (AUTO-06): new actions and compute per run; new actions, provider spend and external requests per policy
//    version. A budget stop leaves the row held with the reason; resuming continues it. Manual work never counts.
//  • Debounce and scope (AUTO-07): cosmetic case actions (layout, views, briefs about the case) never enqueue; triggers for
//    the same logical work coalesce into one row; a recipe works on its own branch (its context and inputs).
//  • Authority at execution (AUTO-08): the case still exists and is open, the requester is still on the team, every input
//    revision is still current and in the case, no person erasure happened since queuing, the current policy still
//    allows it, and (for a recipe that would send content) the case's AI permission is in force. Otherwise: refused.
//  • Failure (AUTO-09): queued, running, retrying, held, done, failed (transient / impossible), cancelled, refused,
//    suppressed — all listed; retry, cancel and resume are explicit; an interrupted run is recovered after its lease.
//  • External effects (AUTO-10): only to configured recipients for their channel and content scope; prepared once per
//    idempotency key; a hand-over whose outcome is unknown must be reconciled before another. Internal assignment never
//    contacts anyone.
//  • Compensation (AUTO-11): undoing an automation's organisational effect cancels its untouched proposal/action and
//    releases its assignment, recorded against the original run; performed work and external hand-overs are kept and
//    the record says so.
//

import Foundation
import CryptoKit
import os

// MARK: - Policy

public nonisolated enum CaseAutomationMode: String, Sendable, CaseIterable, Codable {
    case manual, suggest, execute
    public var label: String {
        switch self {
        case .manual: return "Manual — nothing runs by itself (queued work waits)"
        case .suggest: return "Suggestions — rules propose actions for you to accept"
        case .execute: return "Configured execution — allowed rules create and route actions"
        }
    }
}

public nonisolated struct CaseAutomationBudgets: Codable, Sendable, Equatable {
    public var newActionsPerRun: Int = 5
    public var computeStepsPerRun: Int = 200
    public var newActionsPerPolicy: Int = 50
    public var providerSpendCentsPerPolicy: Int = 0
    public var externalRequestsPerPolicy: Int = 0
    public init(newActionsPerRun: Int = 5, computeStepsPerRun: Int = 200, newActionsPerPolicy: Int = 50, providerSpendCentsPerPolicy: Int = 0,
                externalRequestsPerPolicy: Int = 0) {
        self.newActionsPerRun = newActionsPerRun; self.computeStepsPerRun = computeStepsPerRun; self.newActionsPerPolicy = newActionsPerPolicy
        self.providerSpendCentsPerPolicy = providerSpendCentsPerPolicy; self.externalRequestsPerPolicy = externalRequestsPerPolicy
    }
}

/// A case's automation policy (one version of it).
public nonisolated struct CaseAutomationPolicy: Codable, Sendable, Equatable {
    public var mode: CaseAutomationMode
    /// Case actions that may start automation (the cause of a trigger).
    public var allowedTriggers: [String]
    public var allowedRecipes: [String]
    /// Execute mode: route created actions to an owner by rule.
    public var routeAutomatically: Bool
    /// Results must be reviewed by someone other than the person who did the work.
    public var requireIndependentReview: Bool
    public var budgets: CaseAutomationBudgets
    public init(mode: CaseAutomationMode = .suggest, allowedTriggers: [String] = CaseAutomationRecipe.builtIn.flatMap(\.triggers),
                allowedRecipes: [String] = CaseAutomationRecipe.builtIn.map(\.id), routeAutomatically: Bool = true, requireIndependentReview: Bool = false,
                budgets: CaseAutomationBudgets = CaseAutomationBudgets()) {
        self.mode = mode; self.allowedTriggers = allowedTriggers; self.allowedRecipes = allowedRecipes; self.routeAutomatically = routeAutomatically
        self.requireIndependentReview = requireIndependentReview; self.budgets = budgets
    }
    /// The policy a case has before anyone saves one (version 0): suggestions only, default budgets.
    public static let standard = CaseAutomationPolicy()
}

public nonisolated struct CaseAutomationPolicyVersion: Sendable, Equatable {
    public let version: Int
    public let policy: CaseAutomationPolicy
    public let setBy: String?
    public let setAt: Date?
}

/// A reusable, versioned investigation recipe (AUTO-01): typed inputs and outputs, steps in sequential groups (steps of
/// one group may run in parallel), review checkpoints, and the ONE proposal the engine makes for it.
public nonisolated struct CaseAutomationRecipe: Sendable, Equatable, Identifiable {
    public enum StepKind: String, Sendable { case check, propose, reviewCheckpoint }
    public struct Step: Sendable, Equatable { public let id: String; public let label: String; public let kind: StepKind; public let group: Int }
    public struct Field: Sendable, Equatable { public let name: String; public let kind: String }
    public let id: String
    public let version: Int
    public let label: String
    public let triggers: [String]
    public let inputs: [Field]
    public let outputs: [Field]
    public let steps: [Step]
    public let action: PersonaAutomationActionKind
    public let actionType: CaseActionType
    public let deliverable: String
    /// True when running it would send case content to an AI provider (needs the case's AI permission at execution).
    public let sendsContent: Bool
    public let estimatedSpendCents: Int
    public let externalRequests: Int

    public var definition: PersonaAutomationDefinition {
        PersonaAutomationDefinition(id: AutomationDefinitionID(rawValue: "case.recipe.\(id)"), version: version, label: label, trigger: .workflowEvent, action: action)
    }
    /// The step groups in order; the steps of one group are independent of each other.
    public var stages: [[Step]] { Dictionary(grouping: steps, by: \.group).sorted { $0.key < $1.key }.map(\.value) }

    public static let changedEvidenceReview = CaseAutomationRecipe(
        id: "changed-evidence-review", version: 1, label: "Review work after its source changed", triggers: ["sourceRevisionObserved"],
        inputs: [Field(name: "finished action", kind: "task"), Field(name: "new source version", kind: "sourceVersion")],
        outputs: [Field(name: "review action", kind: "task")],
        steps: [Step(id: "compare", label: "Compare the examined version with the current one", kind: .check, group: 0),
                Step(id: "scope", label: "Check the new version is in the case", kind: .check, group: 0),
                Step(id: "propose", label: "Propose a review of the earlier result", kind: .propose, group: 1),
                Step(id: "review", label: "A person decides: still holds, redo, or supersede", kind: .reviewCheckpoint, group: 2)],
        action: .createCandidateTask, actionType: .changedEvidenceReview,
        deliverable: "The earlier result checked against the new version: still holds, needs redoing, or superseded.",
        sendsContent: false, estimatedSpendCents: 0, externalRequests: 0)

    public static let missingRecords = CaseAutomationRecipe(
        id: "missing-records-request", version: 1, label: "Request records a reconciliation found missing", triggers: ["gapFound"],
        inputs: [Field(name: "account or statement gap", kind: "record")], outputs: [Field(name: "evidence request action", kind: "task")],
        steps: [Step(id: "gap", label: "Confirm the period is not covered", kind: .check, group: 0),
                Step(id: "propose", label: "Propose a request for the missing period", kind: .propose, group: 1),
                Step(id: "review", label: "A person sends or drops the request", kind: .reviewCheckpoint, group: 2)],
        action: .createMissingEvidenceRequest, actionType: .missingEvidence,
        deliverable: "The missing records received, or the holder's refusal, or a statement that they do not exist.",
        sendsContent: false, estimatedSpendCents: 0, externalRequests: 0)

    public static let resultFollowUp = CaseAutomationRecipe(
        id: "result-follow-up", version: 1, label: "Review a returned result against its question", triggers: ["actionResultRecorded"],
        inputs: [Field(name: "result", kind: "task")], outputs: [Field(name: "follow-up review", kind: "task")],
        steps: [Step(id: "branches", label: "Find the branches the result returns to", kind: .check, group: 0),
                Step(id: "propose", label: "Propose a follow-up review", kind: .propose, group: 1),
                Step(id: "review", label: "A person decides whether more work is justified", kind: .reviewCheckpoint, group: 2)],
        action: .createCandidateTask, actionType: .other, deliverable: "A decision whether the result answers its question, with any further work it justifies.",
        sendsContent: false, estimatedSpendCents: 0, externalRequests: 0)

    public static let builtIn: [CaseAutomationRecipe] = [changedEvidenceReview, missingRecords, resultFollowUp]
}

/// One delivered trigger (AUTO-03 / AUTO-04 / AUTO-05 / AUTO-07).
public nonisolated struct CaseAutomationTrigger: Sendable, Equatable {
    public var recipeID: String
    /// The case action that caused it (a cosmetic one never enqueues).
    public var causeAction: String
    /// Stable identity of the delivered event (repeated delivery carries the same key).
    public var eventKey: String
    public var title: String
    public var purpose: String
    public var contextKind: String?
    public var contextID: String?
    /// The revisions/records the work is about (part of its logical identity; the material condition).
    public var inputs: [CaseExaminedInput]
    /// The outbox row whose output caused this trigger, if any.
    public var causationID: UUID?
    public var requestedBy: String
    public init(recipeID: String, causeAction: String, eventKey: String, title: String, purpose: String, contextKind: String? = nil, contextID: String? = nil,
                inputs: [CaseExaminedInput], causationID: UUID? = nil, requestedBy: String) {
        self.recipeID = recipeID; self.causeAction = causeAction; self.eventKey = eventKey; self.title = title; self.purpose = purpose
        self.contextKind = contextKind; self.contextID = contextID; self.inputs = inputs; self.causationID = causationID; self.requestedBy = requestedBy
    }
}

public nonisolated enum CaseEnqueueOutcome: Sendable, Equatable {
    case queued(UUID)
    /// The same logical work was already waiting: this delivery was folded into it.
    case coalesced(UUID)
    /// The same unchanged work was already done.
    case alreadyDone(UUID)
    /// The same work exists in another state (failed, cancelled, refused): retry that instead of recreating it.
    case existing(UUID, String)
    case suppressed(UUID, String)
    case ignoredCosmetic
    case ignoredManual
    case notAllowed(String)
}

public nonisolated enum CaseOutboxState: String, Sendable, CaseIterable {
    case queued, running, retrying, held, done, failed, cancelled, refused, suppressed
    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .retrying: return "Will retry"
        case .held: return "Held (budget)"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .refused: return "Refused at execution"
        case .suppressed: return "Not run (no new condition)"
        }
    }
}

public nonisolated struct CaseOutboxItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let logicalKey: String
    public let eventKey: String
    public let recipeID: String
    public let recipeVersion: Int
    public let policyVersion: Int
    public let executedPolicyVersion: Int?
    public let purpose: String
    public let contextKind: String?
    public let contextID: String?
    public let inputs: [CaseExaminedInput]
    public let effects: [String]
    public let causeAction: String
    public let causationID: UUID?
    public let correlationID: UUID
    public let depth: Int
    public let state: CaseOutboxState
    public let stateReason: String?
    public let failureClass: String?
    public let attempts: Int
    public let coalescedCount: Int
    public let requestedBy: String
    public let executionID: UUID?
    public let outputTaskID: UUID?
    public let createdAt: Date
}

public nonisolated struct CaseDispatchReport: Sendable, Equatable {
    public let runID: UUID
    public var paused = false
    public var done: [UUID] = []
    public var held: [UUID] = []
    public var refused: [UUID] = []
    public var failed: [UUID] = []
    public var recovered: [UUID] = []
}

public nonisolated struct CaseAutomationBudgetStatus: Sendable, Equatable {
    public let policyVersion: Int
    public let budgets: CaseAutomationBudgets
    public let newActionsUsed: Int
    public let providerSpendCentsUsed: Int
    public let externalRequestsUsed: Int
    public let held: Int
    public var lines: [String] {
        ["New actions: \(newActionsUsed) of \(budgets.newActionsPerPolicy) for this policy (at most \(budgets.newActionsPerRun) per run)",
         "Provider spend: \(providerSpendCentsUsed)¢ of \(budgets.providerSpendCentsPerPolicy)¢",
         "External requests: \(externalRequestsUsed) of \(budgets.externalRequestsPerPolicy)",
         "Compute: at most \(budgets.computeStepsPerRun) steps per run",
         held > 0 ? "\(held) held by a budget — resume to continue" : "Nothing held by a budget"]
    }
}

public nonisolated struct CaseExternalRecipient: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let recipient: String
    public let channel: String
    public let contentScope: String
    public let isActive: Bool
}

public nonisolated struct CaseExternalEffect: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable { case prepared, handedOver, confirmedSent, confirmedNotSent
        public var label: String {
            switch self {
            case .prepared: return "Prepared (not handed over)"
            case .handedOver: return "Handed over — outcome not yet known"
            case .confirmedSent: return "Confirmed sent"
            case .confirmedNotSent: return "Confirmed not sent"
            }
        }
    }
    public let id: UUID
    public let recipientID: UUID
    public let channel: String
    public let purpose: String
    public let idempotencyKey: String
    public let state: State
    public let handovers: Int
    public let providerRef: String?
}

public nonisolated struct CaseCompensation: Sendable, Equatable {
    public let effectKind: String
    public let effectID: String
    public let outcome: String
    public let explanation: String
}

public nonisolated enum CaseAutomationError: Error, Equatable, LocalizedError {
    case notFound(String)
    case wrongState(String)
    case recipientNotAuthorized
    case outcomeUnknown
    case alreadySent
    case unknownRecipe(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "The \(what) was not found in this case."
        case .wrongState(let why): return why
        case .recipientNotAuthorized: return "That recipient is not configured for this channel in this case. Add them (with what may be sent) first."
        case .outcomeUnknown: return "The earlier hand-over's outcome is not known. Confirm whether it was sent before handing it over again."
        case .alreadySent: return "It was already sent. Record a follow-up instead of sending it again."
        case .unknownRecipe(let id): return "No recipe “\(id)” is available."
        }
    }
}

// MARK: - Policy store (read inside any savepoint)

public nonisolated enum CaseAutomationPolicyStore {
    static func current(_ db: isolated Database, caseID: UUID) throws -> CaseAutomationPolicyVersion {
        guard let r = try db.query("SELECT version, policy_json, set_by, set_at FROM case_automation_policies WHERE case_id = ? ORDER BY version DESC LIMIT 1;",
                                   [.uuid(caseID)]).first, let v = r.int(0), let json = r.string(1)?.data(using: .utf8) else {
            return CaseAutomationPolicyVersion(version: 0, policy: .standard, setBy: nil, setAt: nil)
        }
        do {
            return CaseAutomationPolicyVersion(version: Int(v), policy: try JSONDecoder().decode(CaseAutomationPolicy.self, from: json), setBy: r.string(2), setAt: r.date(3))
        } catch {
            // An unreadable policy fails closed: manual (nothing runs), with the default review requirement.
            KalsmritikoshLog.app.error("Case automation policy unreadable; treating as manual: \(String(describing: error), privacy: .public)")
            var p = CaseAutomationPolicy.standard; p.mode = .manual
            return CaseAutomationPolicyVersion(version: Int(v), policy: p, setBy: r.string(2), setAt: r.date(3))
        }
    }

    static func requiresIndependentReview(_ db: isolated Database, caseID: UUID) throws -> Bool {
        try current(db, caseID: caseID).policy.requireIndependentReview
    }

    /// Person erasures so far: queued work from before one is re-checked by queuing it again (AUTO-08).
    static func erasureGeneration(_ db: isolated Database) throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM case_erasures WHERE scope = 'person';", []).first?.int(0) ?? 0)
    }
}

extension CaseFileRepository {
    public func requiresIndependentReview(caseID: UUID) async throws -> Bool {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.withSavepoint("cf_pol_\(UUID().uuidString.prefix(8))") { db in try CaseAutomationPolicyStore.requiresIndependentReview(db, caseID: caseID) }
    }
}

// MARK: - Outbox (written inside the case change's own savepoint)

public nonisolated enum CaseAutomationOutbox {

    static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Purpose + context + input revisions: what makes two triggers the same work (never the event key or policy version).
    static func logicalKey(caseID: UUID, _ t: CaseAutomationTrigger) -> String {
        let inputs = t.inputs.map { "\($0.kind):\($0.id.lowercased())" }.sorted().joined(separator: ",")
        let purpose = t.purpose.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return digest([caseID.uuidString.lowercased(), t.recipeID, purpose, t.contextKind ?? "-", (t.contextID ?? "-").lowercased(), inputs].joined(separator: "|"))
    }

    static func inputsFingerprint(_ inputs: [CaseExaminedInput]) -> String {
        digest(inputs.map { "\($0.kind):\($0.id.lowercased())" }.sorted().joined(separator: ","))
    }

    /// Write a trigger into the outbox — call INSIDE the savepoint of the change that caused it.
    static func enqueue(_ db: isolated Database, caseID: UUID, trigger t: CaseAutomationTrigger, recipes: [CaseAutomationRecipe], at date: Date) throws -> CaseEnqueueOutcome {
        if case .cosmetic = CaseChangeClassifier.classify(action: t.causeAction) { return .ignoredCosmetic }
        let pv = try CaseAutomationPolicyStore.current(db, caseID: caseID)
        if pv.policy.mode == .manual { return .ignoredManual }
        guard let recipe = recipes.first(where: { $0.id == t.recipeID }) else { return .notAllowed("No recipe “\(t.recipeID)”.") }
        guard pv.policy.allowedRecipes.contains(recipe.id) else { return .notAllowed("The case's automation policy (version \(pv.version)) does not allow “\(recipe.label)”.") }
        guard pv.policy.allowedTriggers.contains(t.causeAction), recipe.triggers.contains(t.causeAction) else {
            return .notAllowed("“\(t.causeAction)” does not start “\(recipe.label)” under the case's policy.")
        }
        let key = logicalKey(caseID: caseID, t)
        if let r = try db.query("SELECT id, state, state_reason FROM case_automation_outbox WHERE case_id = ? AND logical_key = ? ORDER BY created_at DESC LIMIT 1;",
                                [.uuid(caseID), .text(key)]).first, let id = r.uuid(0), let st = r.string(1).flatMap(CaseOutboxState.init(rawValue:)) {
            switch st {
            case .queued, .running, .retrying, .held:
                try db.exec("UPDATE case_automation_outbox SET coalesced_count = coalesced_count + 1, updated_at = ? WHERE id = ?;", [.date(date), .uuid(id)])
                return .coalesced(id)
            case .done: return .alreadyDone(id)
            case .suppressed: return .suppressed(id, r.string(2) ?? "")
            case .failed, .cancelled, .refused: return .existing(id, st.rawValue)
            }
        }
        // Causation: the root and depth; work caused by automation output needs inputs not already seen up the chain.
        var correlation = UUID(), depth = 0, suppressReason: String?
        if let cause = t.causationID {
            var seen = Set<UUID>(), current: UUID? = cause
            let mine = inputsFingerprint(t.inputs)
            while let c = current, seen.insert(c).inserted {
                guard let r = try db.query("SELECT causation_id, correlation_id, inputs_json, depth FROM case_automation_outbox WHERE id = ? AND case_id = ?;",
                                           [.uuid(c), .uuid(caseID)]).first else { break }
                if c == cause { correlation = r.uuid(1) ?? correlation; depth = Int(r.int(3) ?? 0) + 1 }
                let theirs = (r.string(2)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CaseExaminedInput].self, from: $0) } ?? []
                if inputsFingerprint(theirs) == mine {
                    suppressReason = "No material new condition: the same inputs as the automated work that caused it (\(c.uuidString.prefix(8))). New work needs a changed input."
                    break
                }
                current = r.uuid(0)
            }
        }
        let id = UUID()
        let effects = ["\(recipe.action.rawValue) (\(recipe.actionType.label))"] + (pv.policy.mode == .execute ? ["confirm under policy v\(pv.version)"] : ["proposal only"])
            + (pv.policy.mode == .execute && pv.policy.routeAutomatically ? ["route to an eligible owner"] : [])
        try db.exec("""
            INSERT INTO case_automation_outbox (id, case_id, logical_key, event_key, recipe_id, recipe_version, policy_version, purpose, context_kind, context_id,
                inputs_json, effects_json, cause_action, causation_id, correlation_id, depth, state, state_reason, requested_by, erasure_generation, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(caseID), .text(key), .text(t.eventKey), .text(recipe.id), .integer(Int64(recipe.version)), .integer(Int64(pv.version)),
                  .text(t.purpose), .optionalText(t.contextKind), .optionalText(t.contextID?.lowercased()), .text(CaseFileRepository.jsonText(t.inputs)),
                  .text(CaseFileRepository.jsonText(effects)), .text(t.causeAction), t.causationID.map { .uuid($0) } ?? .null, .uuid(correlation),
                  .integer(Int64(depth)), .text(suppressReason == nil ? "queued" : "suppressed"), .optionalText(suppressReason),
                  .text(t.requestedBy), .integer(Int64(try CaseAutomationPolicyStore.erasureGeneration(db))), .date(date), .date(date)])
        // The title travels in the row's purpose context for dispatch.
        try db.exec("UPDATE case_automation_outbox SET effects_json = ? WHERE id = ?;",
                    [.text(CaseFileRepository.jsonText(effects + ["title: \(t.title)"])), .uuid(id)])
        return suppressReason.map { .suppressed(id, $0) } ?? .queued(id)
    }

    static let columns = """
        id, case_id, logical_key, event_key, recipe_id, recipe_version, policy_version, executed_policy_version, purpose, context_kind, context_id,
        inputs_json, effects_json, cause_action, causation_id, correlation_id, depth, state, state_reason, failure_class, attempts, coalesced_count,
        requested_by, execution_id, output_task_id, created_at, erasure_generation, lease_until
        """

    static func decode(_ r: SQLRow) -> CaseOutboxItem? {
        guard let id = r.uuid(0), let c = r.uuid(1), let lk = r.string(2), let ek = r.string(3), let rid = r.string(4), let p = r.string(8),
              let st = r.string(17).flatMap(CaseOutboxState.init(rawValue:)), let corr = r.uuid(15), let by = r.string(22), let at = r.date(25) else { return nil }
        let inputs = (r.string(11)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CaseExaminedInput].self, from: $0) } ?? []
        let effects = (r.string(12)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return CaseOutboxItem(id: id, caseID: c, logicalKey: lk, eventKey: ek, recipeID: rid, recipeVersion: Int(r.int(5) ?? 1), policyVersion: Int(r.int(6) ?? 0),
                              executedPolicyVersion: r.int(7).map(Int.init), purpose: p, contextKind: r.string(9), contextID: r.string(10), inputs: inputs,
                              effects: effects, causeAction: r.string(13) ?? "", causationID: r.uuid(14), correlationID: corr, depth: Int(r.int(16) ?? 0),
                              state: st, stateReason: r.string(18), failureClass: r.string(19), attempts: Int(r.int(20) ?? 0), coalescedCount: Int(r.int(21) ?? 0),
                              requestedBy: by, executionID: r.uuid(23), outputTaskID: r.uuid(24), createdAt: at)
    }
}

// MARK: - Service

public actor CaseAutomationService {
    public static let actorName = "Case automation"
    public static let applicationID = ApplicationDefinitionID(rawValue: "com.kalsmritikosh.investigations.case-automation")

    private let database: Database
    private let caseFiles: CaseFileService
    private let coordinator: PersonaAutomationRuntimeCoordinator
    private let executions: WorkflowAutomationExecutionRepository
    private let tasks: ProfessionalTaskRepository
    public let recipes: [CaseAutomationRecipe]
    /// Whether the case's AI permission is in force (read only; automation never grants or withdraws it).
    private let aiPermitted: @Sendable (UUID) -> Bool
    private let lease: TimeInterval

    /// Test-only fault injection at the outbox's write boundaries (AUTO-12).
    enum Fault: Sendable { case afterClaim, afterEffect }
    private var fault: Fault?
    func setFault(_ f: Fault?) { fault = f }
    struct InjectedCrash: Error {}

    public init(database: Database, caseFiles: CaseFileService, recipes: [CaseAutomationRecipe] = CaseAutomationRecipe.builtIn,
                aiPermitted: @escaping @Sendable (UUID) -> Bool = { CaseReadPermissionStore.live.permission(caseID: $0) != nil },
                lease: TimeInterval = 300) {
        self.database = database
        self.caseFiles = caseFiles
        let executions = WorkflowAutomationExecutionRepository(database: database)
        let tasks = ProfessionalTaskRepository(database: database)
        self.executions = executions
        self.tasks = tasks
        // The existing engine, now built by the app (it was built only in tests before this slice).
        self.coordinator = PersonaAutomationRuntimeCoordinator(executions: executions, workflowRuns: WorkflowRunRepository(database: database),
                                                               tasks: tasks, deadlines: DeadlineRepository(database: database))
        self.recipes = recipes
        self.aiPermitted = aiPermitted
        self.lease = lease
    }

    private var file: CaseFileRepository { caseFiles.file }

    // MARK: AUTO-01 / AUTO-02 policy

    public func policy(caseID: UUID) async throws -> CaseAutomationPolicyVersion {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.withSavepoint("ca_pol_\(UUID().uuidString.prefix(8))") { db in try CaseAutomationPolicyStore.current(db, caseID: caseID) }
    }

    /// Save a new version of the case's policy (the earlier versions stay). Touches nothing else — in particular not the
    /// case's AI permission.
    @discardableResult
    public func setPolicy(caseID: UUID, _ p: CaseAutomationPolicy, actor: String, at date: Date = Date()) async throws -> Int {
        let json = CaseFileRepository.jsonText(p)
        let box = VersionBox()
        try await file.write("ca_setpol", caseID: caseID, actor: actor, action: "automationPolicySet", detail: p.mode.rawValue, at: date, allowedWhenClosed: true) { db in
            let next = Int(try db.query("SELECT coalesce(MAX(version), 0) + 1 FROM case_automation_policies WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 1)
            box.value = next
            try db.exec("INSERT INTO case_automation_policies (id, case_id, version, mode, policy_json, set_by, set_at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(UUID()), .uuid(caseID), .integer(Int64(next)), .text(p.mode.rawValue), .text(json), .text(actor), .date(date)])
        }
        return box.value
    }

    /// Change only the mode (a new policy version).
    @discardableResult
    public func setMode(caseID: UUID, _ mode: CaseAutomationMode, actor: String, at date: Date = Date()) async throws -> Int {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .administer)
        var p = try await policy(caseID: caseID).policy
        p.mode = mode
        return try await setPolicy(caseID: caseID, p, actor: actor, at: date)
    }

    // MARK: AUTO-03 enqueue (with the case change, in one savepoint)

    /// Record the case change `trigger.causeAction` (its case-log row) and its trigger in ONE savepoint.
    @discardableResult
    public func observe(caseID: UUID, _ trigger: CaseAutomationTrigger, at date: Date = Date()) async throws -> CaseEnqueueOutcome {
        let box = OutcomeBox()
        let recipes = self.recipes
        if case .cosmetic = CaseChangeClassifier.classify(action: trigger.causeAction) { return .ignoredCosmetic }
        try await file.write("ca_obs", caseID: caseID, actor: trigger.requestedBy, action: trigger.causeAction, detail: trigger.purpose, at: date) { db in
            box.value = try CaseAutomationOutbox.enqueue(db, caseID: caseID, trigger: trigger, recipes: recipes, at: date)
        }
        return box.value
    }

    /// The app path: a source version became current (a new version, or a new reading of one). For every case where
    /// finished work examined an EARLIER version of the same source, a changed-evidence review is triggered — once per
    /// action and version — and the case's queue is dispatched. A new reading of the same version triggers nothing.
    @discardableResult
    public func observeSourceVersion(_ svid: UUID, at date: Date = Date()) async -> [CaseEnqueueOutcome] {
        var out: [CaseEnqueueOutcome] = []
        do {
            guard let logical = try await database.query("SELECT logical_source_id FROM source_versions WHERE id IN (?, ?);",
                                                         [.text(svid.uuidString), .text(svid.uuidString.lowercased())]).first?.string(0),
                  let current = try await database.query("SELECT id, coalesce(filename, '') FROM source_versions WHERE logical_source_id = ? AND is_current = 1 LIMIT 1;",
                                                         [.text(logical)]).first, let currentID = current.uuid(0) else { return [] }
            let rows = try await database.query("""
                SELECT r.case_id, r.task_id, r.inputs_json, t.title FROM case_action_results r JOIN professional_tasks t ON upper(t.id) = upper(r.task_id)
                WHERE t.status = 'completed';
                """, [])
            var seen = Set<String>()
            for r in rows {
                guard let caseID = r.uuid(0), let task = r.uuid(1) else { continue }
                let inputs = (r.string(2)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CaseExaminedInput].self, from: $0) } ?? []
                for i in inputs where i.kind == "sourceVersion" {
                    guard let v = UUID(uuidString: i.id), v != currentID,
                          try await database.query("SELECT 1 FROM source_versions WHERE id IN (?, ?) AND logical_source_id = ?;",
                                                   [.text(v.uuidString), .text(v.uuidString.lowercased()), .text(logical)]).first != nil,
                          seen.insert("\(caseID)|\(task)").inserted else { continue }
                    let name = (current.string(1) ?? "").isEmpty ? "its source" : "“\(current.string(1) ?? "")”"
                    let o = try await observe(caseID: caseID, CaseAutomationTrigger(
                        recipeID: CaseAutomationRecipe.changedEvidenceReview.id, causeAction: "sourceRevisionObserved",
                        eventKey: "source-current:\(currentID.uuidString.lowercased())|task:\(task.uuidString.lowercased())",
                        title: "Review changed evidence: \(r.string(3) ?? "earlier work")",
                        purpose: "Check whether “\(r.string(3) ?? "earlier work")” still holds now that \(name) has a newer version.",
                        contextKind: "task", contextID: task.uuidString, inputs: [.source(currentID), CaseExaminedInput(kind: "task", id: task.uuidString)],
                        requestedBy: Self.actorName), at: date)
                    out.append(o)
                    if case .queued = o { _ = try await dispatch(caseID: caseID, actor: Self.actorName, now: date) }
                }
            }
        } catch {
            KalsmritikoshLog.app.error("Changed-source automation could not run: \(error.localizedDescription, privacy: .public)")
        }
        return out
    }

    // MARK: AUTO-03 … AUTO-09 dispatch

    /// One run over the case's queue. Manual mode pauses it (nothing changes). Interrupted rows are recovered first.
    @discardableResult
    public func dispatch(caseID: UUID, actor: String, now: Date = Date()) async throws -> CaseDispatchReport {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        var report = CaseDispatchReport(runID: UUID())
        let pv = try await policy(caseID: caseID)
        if pv.policy.mode == .manual { report.paused = true; return report }
        report.recovered = try await recoverInterrupted(caseID: caseID, now: now)
        let rows = try await queue(caseID: caseID).filter { $0.state == .queued || $0.state == .retrying }
        var newActions = 0, steps = 0
        for row in rows {
            guard let recipe = recipes.first(where: { $0.id == row.recipeID }) else {
                try await finish(row.id, state: .failed, reason: "No recipe “\(row.recipeID)” in this build.", failureClass: "impossible", now: now)
                report.failed.append(row.id); continue
            }
            // AUTO-06 — budgets, before any effect.
            let used = try await usage(caseID: caseID, policyVersion: pv.version)
            var stop: String?
            if newActions + 1 > pv.policy.budgets.newActionsPerRun { stop = "Budget: \(pv.policy.budgets.newActionsPerRun) new actions per run reached." }
            else if steps + recipe.steps.count > pv.policy.budgets.computeStepsPerRun { stop = "Budget: \(pv.policy.budgets.computeStepsPerRun) compute steps per run reached." }
            else if used.actions + 1 > pv.policy.budgets.newActionsPerPolicy { stop = "Budget: \(pv.policy.budgets.newActionsPerPolicy) new actions under policy version \(pv.version) reached." }
            else if recipe.estimatedSpendCents > 0, used.spend + recipe.estimatedSpendCents > pv.policy.budgets.providerSpendCentsPerPolicy {
                stop = "Budget: provider spend \(used.spend)¢ + \(recipe.estimatedSpendCents)¢ would pass \(pv.policy.budgets.providerSpendCentsPerPolicy)¢."
            } else if recipe.externalRequests > 0, used.external + recipe.externalRequests > pv.policy.budgets.externalRequestsPerPolicy {
                stop = "Budget: \(pv.policy.budgets.externalRequestsPerPolicy) external requests reached."
            }
            if let stop {
                try await finish(row.id, state: .held, reason: stop + " The work stays queued; resume it (or raise the budget) to continue.", failureClass: nil, now: now)
                report.held.append(row.id); continue
            }
            switch try await execute(row, recipe: recipe, runID: report.runID, now: now) {
            case .done: newActions += 1; steps += recipe.steps.count; report.done.append(row.id)
            case .refused: report.refused.append(row.id)
            case .failed: report.failed.append(row.id)
            }
        }
        return report
    }

    private enum ExecOutcome { case done, refused, failed }

    private func execute(_ row: CaseOutboxItem, recipe: CaseAutomationRecipe, runID: UUID, now: Date) async throws -> ExecOutcome {
        // Claim (running, with a lease): a crash from here on is recovered after the lease.
        try await database.withSavepoint("ca_claim_\(UUID().uuidString.prefix(8))") { db in
            try db.exec("UPDATE case_automation_outbox SET state = 'running', attempts = attempts + 1, lease_until = ?, updated_at = ? WHERE id = ? AND state IN ('queued','retrying');",
                        [.date(now.addingTimeInterval(lease)), .date(now), .uuid(row.id)])
        }
        if fault == .afterClaim { throw InjectedCrash() }
        // AUTO-08 — authority, immediately before the effect.
        if let why = try await authorityProblem(row, recipe: recipe) {
            try await finish(row.id, state: .refused, reason: why, failureClass: nil, now: now)
            return .refused
        }
        guard let ws = try await database.query("SELECT workspace_id FROM investigation_cases WHERE id = ?;", [.uuid(row.caseID)]).first?.uuid(0) else {
            try await finish(row.id, state: .refused, reason: "The case was erased.", failureClass: nil, now: now); return .refused
        }
        let title = row.effects.first { $0.hasPrefix("title: ") }.map { String($0.dropFirst(7)) } ?? recipe.label
        let outputTask: UUID, executionID: UUID
        do {
            let outcome = try await coordinator.run(
                definition: recipe.definition, applicationID: Self.applicationID,
                request: PersonaAutomationRequest(workspaceID: ws, title: title, detail: row.purpose,
                                                  taskType: recipe.action == .createMissingEvidenceRequest ? .evidenceRequest : .action),
                trigger: PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "case-outbox:\(row.id.uuidString.lowercased())"),
                now: now, recovery: .retryFailed)
            let execution: WorkflowAutomationExecution
            switch outcome {
            case .produced(let e), .skippedDuplicate(let e): execution = e
            case .suppressedRecursion:
                try await finish(row.id, state: .suppressed, reason: "The engine suppressed it as recursive.", failureClass: nil, now: now); return .refused
            }
            guard execution.status == .succeeded, let out = execution.outputID else {
                throw CaseAutomationError.wrongState("The engine's receipt is \(execution.status.rawValue).")
            }
            outputTask = out; executionID = execution.id
        } catch {
            let impossible = error is PersonaAutomationRuntimeError || (error as? ProfessionalTaskError).map {
                if case .workspaceNotFound = $0 { return true }; if case .blankTitle = $0 { return true }; return false } == true
            KalsmritikoshLog.app.error("Case automation run failed: \(String(describing: error), privacy: .public)")
            try await finish(row.id, state: .failed, reason: "\(error.localizedDescription)", failureClass: impossible ? "impossible" : "transient", now: now)
            return .failed
        }
        if fault == .afterEffect { throw InjectedCrash() }
        try await finalize(row, recipe: recipe, task: outputTask, executionID: executionID, runID: runID, now: now)
        // Execute mode: route by rule (a failure here leaves the action unassigned, visibly, and does not undo it).
        let pv = try await policy(caseID: row.caseID)
        if pv.policy.mode == .execute && pv.policy.routeAutomatically {
            do { _ = try await caseFiles.routeAction(caseID: row.caseID, taskID: outputTask, policyVersion: pv.version, actor: Self.actorName, at: now) } catch {
                KalsmritikoshLog.app.error("Automatic routing failed; the action stays unassigned: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .done
    }

    /// The output joins the case — link, contract, details, links to its context, (execute) confirmation under the policy,
    /// usage, and the row done — as ONE unit.
    private func finalize(_ row: CaseOutboxItem, recipe: CaseAutomationRecipe, task: UUID, executionID: UUID, runID: UUID, now: Date) async throws {
        let caseID = row.caseID
        let actor = Self.actorName
        let trigger = CaseActionTrigger(kind: .automation, records: row.contextID.map { ["\(row.contextKind ?? "record"):\($0)"] } ?? [],
                                        sourceRevisions: row.inputs.filter { $0.kind == "sourceVersion" }.compactMap { UUID(uuidString: $0.id) },
                                        note: "\(recipe.label) v\(recipe.version)", outboxID: row.id)
        try await file.write("ca_fin", caseID: caseID, actor: actor, action: "automationApplied", detail: "\(recipe.id) v\(recipe.version)", at: now,
                             capture: .actionContract(task)) { db in
            try db.exec("INSERT OR IGNORE INTO case_task_links (case_id, task_id, created_at) VALUES (?,?,?);", [.uuid(caseID), .uuid(task), .date(now)])
            try db.exec("""
                INSERT OR IGNORE INTO case_action_contracts (task_id, case_id, parent_task_id, purpose, deliverable, created_by, created_at, updated_at,
                    action_type, trigger_json, helpers_json, required_for_parent)
                VALUES (?,?,NULL,?,?,?,?,?,?,?, '[]', 1);
                """, [.uuid(task), .uuid(caseID), .text(row.purpose), .text(recipe.deliverable), .text(actor), .date(now), .date(now),
                      .text(recipe.actionType.rawValue), .text(CaseFileRepository.jsonText(trigger))])
            if row.contextKind == "task", let ctx = row.contextID.flatMap(UUID.init(uuidString:)), try CaseFileRepository.taskInCase(db, ctx, caseID: caseID) {
                try db.exec("""
                    INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at)
                    SELECT ?, ?, 'task', ?, 'task', ?, 'raisedFrom', ?, ?, ?
                    WHERE NOT EXISTS (SELECT 1 FROM case_work_links WHERE case_id = ? AND work_kind = 'task' AND upper(work_id) = ? AND target_kind = 'task' AND upper(target_id) = ? AND withdrawn_at IS NULL);
                    """, [.uuid(UUID()), .uuid(caseID), .uuid(task), .uuid(ctx), .text(row.purpose), .text(actor), .date(now),
                          .uuid(caseID), .text(task.uuidString), .text(ctx.uuidString)])
            }
            if row.contextKind == "allegation", let ctx = row.contextID.flatMap(UUID.init(uuidString:)), try CaseFileRepository.workEnd(db, "allegation", ctx, caseID: caseID) {
                try db.exec("INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(caseID), .text("task"), .uuid(task), .text("allegation"), .uuid(ctx), .text("serves"), .text(row.purpose), .text(actor), .date(now)])
            }
            let pv = try CaseAutomationPolicyStore.current(db, caseID: caseID)
            let status = try db.query("SELECT status FROM professional_tasks WHERE upper(id) = ?;", [.text(task.uuidString)]).first?.string(0)
            if pv.policy.mode == .execute, status == ProfessionalTaskStatus.candidate.rawValue {
                // Configured execution: the case policy (an identified rule with its version) opens the proposal.
                try db.exec("UPDATE professional_tasks SET status = 'open', updated_at = ? WHERE upper(id) = ?;", [.date(now), .text(task.uuidString)])
                try ProfessionalTaskRepository.insertReview(db, taskID: task, action: .candidateConfirmed, prior: .candidate, new: .open, reviewer: actor,
                                                            reason: "Opened under the case's automation policy v\(pv.version) (\(recipe.label))",
                                                            authority: .deterministicRule(ruleID: "case-automation-policy", version: "\(pv.version)", actor: actor), at: now)
            }
            for (kind, amount) in [("newAction", 1), ("computeStep", recipe.steps.count), ("providerSpendCents", recipe.estimatedSpendCents), ("externalRequest", recipe.externalRequests)]
            where amount > 0 {
                try db.exec("INSERT INTO case_automation_usage (id, case_id, outbox_id, policy_version, run_id, kind, amount, recorded_at) VALUES (?,?,?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(caseID), .uuid(row.id), .integer(Int64(pv.version)), .uuid(runID), .text(kind), .integer(Int64(amount)), .date(now)])
            }
            try db.exec("""
                UPDATE case_automation_outbox SET state = 'done', state_reason = NULL, failure_class = NULL, execution_id = ?, output_task_id = ?,
                    executed_policy_version = ?, lease_until = NULL, updated_at = ? WHERE id = ?;
                """, [.uuid(executionID), .uuid(task), .integer(Int64(pv.version)), .date(now), .uuid(row.id)])
        }
    }

    /// AUTO-08 — why the queued work may not take effect now, or nil.
    private func authorityProblem(_ row: CaseOutboxItem, recipe: CaseAutomationRecipe) async throws -> String? {
        let aiOK = recipe.sendsContent ? aiPermitted(row.caseID) : true
        return try await database.withSavepoint("ca_auth_\(UUID().uuidString.prefix(8))") { db -> String? in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(row.caseID)]).isEmpty else { return "The case was erased." }
            if try !db.query("SELECT 1 FROM case_profiles WHERE case_id = ? AND stage = 'closed';", [.uuid(row.caseID)]).isEmpty {
                return "The case is closed; queued work does not change it. Reopen the case, then retry."
            }
            if let who = try CaseMembershipGate.refusal(db, caseID: row.caseID, name: row.requestedBy) { return "The person who started it can no longer act: \(who)" }
            let gen = try CaseAutomationPolicyStore.erasureGeneration(db)
            let queuedGen = Int(try db.query("SELECT erasure_generation FROM case_automation_outbox WHERE id = ?;", [.uuid(row.id)]).first?.int(0) ?? 0)
            if gen != queuedGen { return "A person's data was erased after this was queued; it is not applied. Trigger it again so its inputs are read afresh." }
            for i in row.inputs where i.kind == "sourceVersion" {
                guard let v = UUID(uuidString: i.id) else { return "An input is unreadable." }
                guard try CaseFileRepository.versionInCase(db, v, caseID: row.caseID) else { return "Its input \(v.uuidString.prefix(8)) is no longer in the case." }
                let current = try db.query("SELECT is_current FROM source_versions WHERE id IN (?, ?);", [.text(v.uuidString), .text(v.uuidString.lowercased())]).first?.int(0)
                if current != 1 { return "Its input \(v.uuidString.prefix(8)) is no longer the current version (stale); the newer version starts its own work." }
            }
            for i in row.inputs where i.kind == "task" {
                guard let t = UUID(uuidString: i.id), try CaseFileRepository.taskInCase(db, t, caseID: row.caseID) else { return "The work it concerns is no longer in the case." }
            }
            let pv = try CaseAutomationPolicyStore.current(db, caseID: row.caseID)
            if pv.policy.mode == .manual { return "The case's automation is now manual (policy v\(pv.version))." }
            if !pv.policy.allowedRecipes.contains(row.recipeID) { return "The case's policy (version \(pv.version)) no longer allows “\(recipe.label)”." }
            if !aiOK { return "It would send case content to an AI provider and this case has no AI permission. Automation settings never grant it." }
            return nil
        }
    }

    private func finish(_ id: UUID, state: CaseOutboxState, reason: String?, failureClass: String?, now: Date) async throws {
        try await database.exec("UPDATE case_automation_outbox SET state = ?, state_reason = ?, failure_class = ?, lease_until = NULL, updated_at = ? WHERE id = ?;",
                                [.text(state.rawValue), .optionalText(reason), .optionalText(failureClass), .date(now), .uuid(id)])
    }

    /// Rows left running past their lease (the app stopped mid-run) go back to retrying.
    @discardableResult
    public func recoverInterrupted(caseID: UUID, now: Date = Date()) async throws -> [UUID] {
        try await database.withSavepoint("ca_rec_\(UUID().uuidString.prefix(8))") { db -> [UUID] in
            try CaseAccessPolicy.require(db, caseID: caseID, actor: nil, .read)
            let ids = try db.query("SELECT id FROM case_automation_outbox WHERE case_id = ? AND state = 'running' AND (lease_until IS NULL OR lease_until < ?);",
                                   [.uuid(caseID), .date(now)]).compactMap { $0.uuid(0) }
            for id in ids {
                try db.exec("UPDATE case_automation_outbox SET state = 'retrying', state_reason = 'Interrupted while running; resumed (its output, if made, is found — not made again).', lease_until = NULL, updated_at = ? WHERE id = ?;",
                            [.date(now), .uuid(id)])
            }
            return ids
        }
    }

    // MARK: AUTO-09 queue, retry, cancel, resume

    public func queue(caseID: UUID) async throws -> [CaseOutboxItem] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT \(CaseAutomationOutbox.columns) FROM case_automation_outbox WHERE case_id = ? ORDER BY created_at, rowid;", [.uuid(caseID)])
            .compactMap(CaseAutomationOutbox.decode)
    }

    public func retry(caseID: UUID, id: UUID, actor: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        try await control(caseID: caseID, id: id, from: [.failed, .refused], to: .retrying, reason: "Retry requested by \(actor)", action: "automationRetried", actor: actor, at: date)
    }

    public func cancel(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        let why = try CaseFileRepository.clean(reason, "The reason")
        try await control(caseID: caseID, id: id, from: [.queued, .retrying, .held, .failed, .refused], to: .cancelled, reason: why, action: "automationCancelled", actor: actor, at: date)
    }

    /// Continue work a budget stopped (after raising the budget, or in a new run).
    @discardableResult
    public func resumeHeld(caseID: UUID, actor: String, at date: Date = Date()) async throws -> Int {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        let held = try await queue(caseID: caseID).filter { $0.state == .held }
        for h in held { try await control(caseID: caseID, id: h.id, from: [.held], to: .queued, reason: "Resumed by \(actor)", action: "automationResumed", actor: actor, at: date) }
        return held.count
    }

    private func control(caseID: UUID, id: UUID, from: Set<CaseOutboxState>, to: CaseOutboxState, reason: String, action: String, actor: String, at date: Date) async throws {
        try await file.write("ca_ctl", caseID: caseID, actor: actor, action: action, detail: reason, at: date, allowedWhenClosed: to == .cancelled) { db in
            guard let st = try db.query("SELECT state FROM case_automation_outbox WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first?.string(0)
                    .flatMap(CaseOutboxState.init(rawValue:)) else { throw CaseAutomationError.notFound("queued work") }
            guard from.contains(st) else { throw CaseAutomationError.wrongState("It is \(st.label.lowercased()); that change does not apply.") }
            try db.exec("UPDATE case_automation_outbox SET state = ?, state_reason = ?, failure_class = CASE WHEN ? = 'retrying' THEN failure_class ELSE NULL END, updated_at = ? WHERE id = ?;",
                        [.text(to.rawValue), .text(reason), .text(to.rawValue), .date(date), .uuid(id)])
        }
    }

    // MARK: AUTO-06 budgets

    private func usage(caseID: UUID, policyVersion: Int) async throws -> (actions: Int, spend: Int, external: Int) {
        let rows = try await database.query("SELECT kind, coalesce(SUM(amount), 0) FROM case_automation_usage WHERE case_id = ? AND policy_version = ? GROUP BY kind;",
                                            [.uuid(caseID), .integer(Int64(policyVersion))])
        var d: [String: Int] = [:]
        for r in rows { if let k = r.string(0) { d[k] = Int(r.int(1) ?? 0) } }
        return (d["newAction"] ?? 0, d["providerSpendCents"] ?? 0, d["externalRequest"] ?? 0)
    }

    public func budgetStatus(caseID: UUID) async throws -> CaseAutomationBudgetStatus {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let pv = try await policy(caseID: caseID)
        let u = try await usage(caseID: caseID, policyVersion: pv.version)
        let held = try await queue(caseID: caseID).filter { $0.state == .held }.count
        return CaseAutomationBudgetStatus(policyVersion: pv.version, budgets: pv.policy.budgets, newActionsUsed: u.actions, providerSpendCentsUsed: u.spend,
                                          externalRequestsUsed: u.external, held: held)
    }

    // MARK: AUTO-10 external effects

    @discardableResult
    public func authorizeRecipient(caseID: UUID, recipient: String, channel: String, contentScope: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try CaseFileRepository.clean(recipient, "The recipient"), scope = try CaseFileRepository.clean(contentScope, "What may be sent")
        let id = UUID()
        try await file.write("ca_rcp", caseID: caseID, actor: actor, action: "recipientAuthorized", detail: "\(channel): \(who)", at: date) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: actor)
            try db.exec("INSERT INTO case_external_recipients (id, case_id, recipient, channel, content_scope, authorized_by, authorized_at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(who), .text(channel), .text(scope), .text(actor), .date(date)])
        }
        return id
    }

    /// Prepare a message or disclosure to a configured recipient. The same content to the same recipient for the same
    /// purpose is ONE effect, however often it is prepared.
    @discardableResult
    public func prepareExternalEffect(caseID: UUID, recipientID: UUID, purpose: String, content: String, taskID: UUID? = nil, outboxID: UUID? = nil,
                                      actor: String, at date: Date = Date()) async throws -> CaseExternalEffect {
        let why = try CaseFileRepository.clean(purpose, "The purpose")
        let contentDigest = CaseAutomationOutbox.digest(content)
        let box = UUIDBox()
        try await file.write("ca_xprep", caseID: caseID, actor: actor, action: "externalEffectPrepared", detail: why, at: date) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: actor)
            guard let r = try db.query("SELECT channel FROM case_external_recipients WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;",
                                       [.uuid(recipientID), .uuid(caseID)]).first, let channel = r.string(0) else { throw CaseAutomationError.recipientNotAuthorized }
            let key = CaseAutomationOutbox.digest([caseID.uuidString.lowercased(), recipientID.uuidString.lowercased(), channel, why.lowercased(), contentDigest].joined(separator: "|"))
            if let existing = try db.query("SELECT id FROM case_external_effects WHERE idempotency_key = ?;", [.text(key)]).first?.uuid(0) { box.value = existing; return }
            let id = UUID(); box.value = id
            try db.exec("""
                INSERT INTO case_external_effects (id, case_id, recipient_id, task_id, outbox_id, channel, purpose, content_digest, idempotency_key, state, created_by, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?, 'prepared', ?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(recipientID), taskID.map { .uuid($0) } ?? .null, outboxID.map { .uuid($0) } ?? .null, .text(channel), .text(why),
                      .text(contentDigest), .text(key), .text(actor), .date(date), .date(date)])
        }
        return try await externalEffect(caseID: caseID, id: box.value)
    }

    /// The person handed it over (posted, sent from their mail, uploaded). Refused while an earlier hand-over's outcome is
    /// unknown, and after it was confirmed sent.
    public func markHandedOver(caseID: UUID, effectID: UUID, providerRef: String?, actor: String, at date: Date = Date()) async throws {
        try await file.write("ca_xho", caseID: caseID, actor: actor, action: "externalEffectHandedOver", detail: providerRef, at: date) { db in
            guard let st = try db.query("SELECT state FROM case_external_effects WHERE id = ? AND case_id = ?;", [.uuid(effectID), .uuid(caseID)]).first?.string(0) else {
                throw CaseAutomationError.notFound("external effect")
            }
            switch st {
            case "handedOver": throw CaseAutomationError.outcomeUnknown
            case "confirmedSent": throw CaseAutomationError.alreadySent
            default: break
            }
            try db.exec("UPDATE case_external_effects SET state = 'handedOver', handovers = handovers + 1, provider_ref = coalesce(?, provider_ref), updated_at = ? WHERE id = ?;",
                        [.optionalText(providerRef), .date(date), .uuid(effectID)])
        }
    }

    /// Record what actually happened to a hand-over whose outcome was unknown.
    public func reconcileExternalEffect(caseID: UUID, effectID: UUID, sent: Bool, note: String, actor: String, at date: Date = Date()) async throws {
        let why = try CaseFileRepository.clean(note, "How it was confirmed")
        try await file.write("ca_xrec", caseID: caseID, actor: actor, action: "externalEffectReconciled", detail: "\(sent ? "sent" : "not sent"): \(why)", at: date) { db in
            guard let st = try db.query("SELECT state FROM case_external_effects WHERE id = ? AND case_id = ?;", [.uuid(effectID), .uuid(caseID)]).first?.string(0) else {
                throw CaseAutomationError.notFound("external effect")
            }
            guard st == "handedOver" else { throw CaseAutomationError.wrongState("Only a hand-over whose outcome is unknown is reconciled.") }
            try db.exec("UPDATE case_external_effects SET state = ?, state_note = ?, updated_at = ? WHERE id = ?;",
                        [.text(sent ? "confirmedSent" : "confirmedNotSent"), .text(why), .date(date), .uuid(effectID)])
        }
    }

    public func externalEffects(caseID: UUID) async throws -> [CaseExternalEffect] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, recipient_id, channel, purpose, idempotency_key, state, handovers, provider_ref FROM case_external_effects WHERE case_id = ? ORDER BY created_at, rowid;
            """, [.uuid(caseID)]).compactMap(Self.decodeEffect)
    }

    private func externalEffect(caseID: UUID, id: UUID) async throws -> CaseExternalEffect {
        guard let e = try await database.query("""
            SELECT id, recipient_id, channel, purpose, idempotency_key, state, handovers, provider_ref FROM case_external_effects WHERE id = ? AND case_id = ?;
            """, [.uuid(id), .uuid(caseID)]).first.flatMap(Self.decodeEffect) else { throw CaseAutomationError.notFound("external effect") }
        return e
    }

    private static func decodeEffect(_ r: SQLRow) -> CaseExternalEffect? {
        guard let id = r.uuid(0), let rid = r.uuid(1), let ch = r.string(2), let p = r.string(3), let k = r.string(4),
              let st = r.string(5).flatMap(CaseExternalEffect.State.init(rawValue:)) else { return nil }
        return CaseExternalEffect(id: id, recipientID: rid, channel: ch, purpose: p, idempotencyKey: k, state: st, handovers: Int(r.int(6) ?? 0), providerRef: r.string(7))
    }

    // MARK: AUTO-11 compensation

    /// Undo what an automation run did inside the case, against its recorded receipt: an untouched proposal or action is
    /// cancelled (kept, with the reason) and its assignment released; work somebody performed, results and anything handed
    /// over externally are KEPT, and the record says why. Nothing is deleted.
    @discardableResult
    public func compensate(caseID: UUID, outboxID: UUID, reason: String, actor: String, at date: Date = Date()) async throws -> [CaseCompensation] {
        let why = try CaseFileRepository.clean(reason, "The reason")
        let box = CompBox()
        try await file.write("ca_comp", caseID: caseID, actor: actor, action: "automationCompensated", detail: why, at: date) { db in
            try CaseMembershipGate.require(db, caseID: caseID, name: actor)
            guard let r = try db.query("SELECT state, output_task_id, execution_id FROM case_automation_outbox WHERE id = ? AND case_id = ?;",
                                       [.uuid(outboxID), .uuid(caseID)]).first else { throw CaseAutomationError.notFound("automation run") }
            guard r.string(0) == CaseOutboxState.done.rawValue, let task = r.uuid(1) else {
                throw CaseAutomationError.wrongState("Only a finished run has effects to undo; cancel queued work instead.")
            }
            var out: [CaseCompensation] = []
            func record(_ kind: String, _ id: String, _ outcome: String, _ text: String) {
                out.append(CaseCompensation(effectKind: kind, effectID: id, outcome: outcome, explanation: text))
            }
            let status = try db.query("SELECT status FROM professional_tasks WHERE upper(id) = ?;", [.text(task.uuidString)]).first?.string(0)
                .flatMap(ProfessionalTaskStatus.init(rawValue:))
            let results = Int(try db.query("SELECT COUNT(*) FROM case_action_results WHERE upper(task_id) = ?;", [.text(task.uuidString)]).first?.int(0) ?? 0)
            if let status, [.candidate, .open, .assigned].contains(status), results == 0 {
                try ProfessionalTaskRepository.applyStatusInWrite(db, taskID: task, to: .cancelled, reviewer: actor,
                                                                  reason: "Undone: \(why) (automation run \(outboxID.uuidString.prefix(8)))", at: date)
                record("action", task.uuidString, "compensated", "The action it created was cancelled (kept in the case with this reason): \(why)")
                for a in try db.query("SELECT id, assignee FROM case_work_assignments WHERE case_id = ? AND work_kind = 'task' AND work_id = ? AND ended_at IS NULL;",
                                      [.uuid(caseID), .text(task.uuidString.lowercased())]) {
                    guard let aid = a.string(0) else { continue }
                    try db.exec("UPDATE case_work_assignments SET ended_at = ?, ended_by = ?, end_reason = 'released' WHERE id = ?;", [.date(date), .text(actor), .text(aid)])
                    record("assignment", aid, "compensated", "The assignment to \(a.string(1) ?? "someone") was released.")
                }
            } else {
                let what = results > 0 ? "a result was recorded on it" : "work on it has started or finished (\(status?.rawValue ?? "unknown"))"
                record("action", task.uuidString, "kept", "Kept: \(what). Undoing it would hide work a person did; cancel or supersede it deliberately instead.")
            }
            for e in try db.query("SELECT id, state FROM case_external_effects WHERE case_id = ? AND (outbox_id = ? OR upper(coalesce(task_id, '')) = ?);",
                                  [.uuid(caseID), .uuid(outboxID), .text(task.uuidString)]) {
                guard let eid = e.string(0), let st = e.string(1) else { continue }
                if st == "prepared" {
                    try db.exec("UPDATE case_external_effects SET state = 'confirmedNotSent', state_note = ?, updated_at = ? WHERE id = ?;",
                                [.text("Withdrawn before hand-over: \(why)"), .date(date), .text(eid)])
                    record("externalEffect", eid, "compensated", "Prepared but never handed over: withdrawn.")
                } else {
                    record("externalEffect", eid, "kept", "It was handed over externally (\(st)); it cannot be unsent. Record a follow-up with the recipient instead.")
                }
            }
            for c in out {
                try db.exec("""
                    INSERT INTO case_automation_compensations (id, case_id, outbox_id, execution_id, effect_kind, effect_id, outcome, explanation, recorded_by, recorded_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .uuid(outboxID), .optionalText(r.string(2)), .text(c.effectKind), .text(c.effectID), .text(c.outcome),
                          .text(c.explanation), .text(actor), .date(date)])
            }
            box.value = out
        }
        return box.value
    }

    public func compensations(caseID: UUID) async throws -> [CaseCompensation] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT effect_kind, effect_id, outcome, explanation FROM case_automation_compensations WHERE case_id = ? ORDER BY recorded_at, rowid;",
                                 [.uuid(caseID)]).compactMap { r in
            guard let k = r.string(0), let id = r.string(1), let o = r.string(2), let e = r.string(3) else { return nil }
            return CaseCompensation(effectKind: k, effectID: id, outcome: o, explanation: e)
        }
    }
}

nonisolated private final class VersionBox: @unchecked Sendable { var value = 0 }
nonisolated private final class OutcomeBox: @unchecked Sendable { var value: CaseEnqueueOutcome = .ignoredManual }
nonisolated private final class UUIDBox: @unchecked Sendable { var value = UUID() }
nonisolated private final class CompBox: @unchecked Sendable { var value: [CaseCompensation] = [] }
