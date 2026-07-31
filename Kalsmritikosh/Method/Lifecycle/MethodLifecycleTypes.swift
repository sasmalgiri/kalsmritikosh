//
//  MethodLifecycleTypes.swift
//  Kalsmritikosh
//
//  PM-004 — the lifecycle actor + closed state machine. Reuses the Stage-3
//  WorkflowDecisionActorKind; adds no new actor vocabulary.
//

import Foundation

// MARK: - Actor

/// A typed lifecycle actor. `.human` requires a non-blank identifier;
/// `.deterministicRule` and `.system` may omit one.
public nonisolated struct MethodLifecycleActor: Sendable, Equatable {
    public let kind: WorkflowDecisionActorKind
    public let identifier: String?

    public nonisolated init(kind: WorkflowDecisionActorKind, identifier: String?) {
        self.kind = kind
        self.identifier = identifier
    }

    public static func human(_ id: String) -> MethodLifecycleActor { .init(kind: .human, identifier: id) }
    public static let system = MethodLifecycleActor(kind: .system, identifier: nil)
    public static func rule(_ id: String? = nil) -> MethodLifecycleActor { .init(kind: .deterministicRule, identifier: id) }

    public var isHuman: Bool { kind == .human }

    /// Non-blank identifier for a human actor.
    public func validated() throws {
        if kind == .human {
            guard let id = identifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfessionalMethodLifecycleError.invalidActor("a human actor requires a non-blank identifier")
            }
        }
    }
}

// MARK: - User-facing lifecycle actions (closed)

public nonisolated enum MethodLifecycleUserAction: String, Sendable, CaseIterable {
    case start, pause, resume, requestHumanReview, continueAfterReview, block, unblock
    case complete, cancel, supersede, reopen

    /// The audit action recorded for this user action.
    public var eventAction: MethodLifecycleAction {
        switch self {
        case .start: return .start
        case .pause: return .pause
        case .resume: return .resume
        case .requestHumanReview: return .requestHumanReview
        case .continueAfterReview: return .continueAfterReview
        case .block: return .block
        case .unblock: return .unblock
        case .complete: return .complete
        case .cancel: return .cancel
        case .supersede: return .supersede
        case .reopen: return .reopen
        }
    }
}

// MARK: - Closed state machine

public enum MethodLifecycleStateMachine {

    /// The target status for a user action from a status, or nil if the transition
    /// is not declared (every undeclared transition fails closed).
    public static func target(
        from status: MethodRunStatus, action: MethodLifecycleUserAction
    ) -> MethodRunStatus? {
        switch (status, action) {
        case (.draft, .start):                     return .active
        case (.active, .pause):                    return .paused
        case (.active, .requestHumanReview):       return .waitingForHuman
        case (.active, .block):                    return .blocked
        case (.active, .complete):                 return .completed
        case (.paused, .resume):                   return .active
        case (.waitingForHuman, .continueAfterReview): return .active
        case (.waitingForHuman, .block):           return .blocked
        case (.blocked, .unblock):                 return .active
        case (.completed, .reopen):                return .active
        // cancel allowed from every non-terminal, non-completed status;
        // supersede allowed from every non-terminal status (including completed).
        case (_, .cancel) where status != .completed && !status.isTerminal:  return .cancelled
        case (_, .supersede) where !status.isTerminal:                        return .superseded
        default:                                   return nil
        }
    }
}

public extension MethodRunStatus {
    var isTerminal: Bool { self == .cancelled || self == .superseded }
}
