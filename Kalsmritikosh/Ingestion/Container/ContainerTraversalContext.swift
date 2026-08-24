//
//  ContainerTraversalContext.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §13/§14) — the explicit context threaded through recursive container ingestion.
//  It carries the ROOT identity + current depth + the ancestor-container hash chain (for cycle
//  detection) + a SHARED root budget. Budgets are NOT reset per nested container: without a shared
//  root budget, a chain of individually-legal nested archives could collectively exhaust resources.
//  The ancestor hash set is threaded by value (a nested level gets a copy with its parent's hash
//  inserted); the numeric budget is a reference shared across the whole root traversal.
//

import Foundation

/// The verdict of asking the shared root budget to admit one more member.
public nonisolated enum ContainerRootBudgetVerdict: Sendable, Equatable {
    case ok
    case rootMemberLimit
    case rootByteLimit
    case nestedContainerLimit
}

/// Shared, root-wide budget accumulator. A reference type so sibling + nested containers draw from
/// ONE pool. Guarded by a lock so it is safe to hand across the ingestion actor boundary.
public final class ContainerRootBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: ContainerSafetyPolicy
    private var membersConsumed = 0
    private var bytesConsumed: Int64 = 0
    private var nestedContainers = 0

    public nonisolated init(policy: ContainerSafetyPolicy) { self.policy = policy }

    /// Reserve one member + its uncompressed bytes against the whole-root budget. Only reserves when
    /// the reservation FITS — an over-budget request consumes nothing and reports which ceiling hit.
    public func reserveMember(uncompressedBytes: Int64) -> ContainerRootBudgetVerdict {
        lock.lock(); defer { lock.unlock() }
        if membersConsumed + 1 > policy.maxRootTotalMembers { return .rootMemberLimit }
        if bytesConsumed + max(0, uncompressedBytes) > policy.maxRootExpandedBytes { return .rootByteLimit }
        membersConsumed += 1
        bytesConsumed += max(0, uncompressedBytes)
        return .ok
    }

    /// Register that a nested container is about to be traversed. Fails when the root's nested-
    /// container ceiling is reached.
    public func registerNestedContainer() -> ContainerRootBudgetVerdict {
        lock.lock(); defer { lock.unlock() }
        if nestedContainers + 1 > policy.maxNestedContainerCount { return .nestedContainerLimit }
        nestedContainers += 1
        return .ok
    }

    /// Snapshot for tests / diagnostics.
    public var consumed: (members: Int, bytes: Int64, nestedContainers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (membersConsumed, bytesConsumed, nestedContainers)
    }
}

public nonisolated struct ContainerTraversalContext: Sendable {
    public let rootSourceVersionID: UUID
    public let currentDepth: Int
    /// Content hashes of every container on the path from the root to (and including) the current
    /// container. A child whose hash is already here is a cycle → blockedCycle.
    public let ancestorContainerHashes: Set<String>
    public let budget: ContainerRootBudget
    public let policy: ContainerSafetyPolicy

    public nonisolated init(rootSourceVersionID: UUID, currentDepth: Int,
                            ancestorContainerHashes: Set<String>, budget: ContainerRootBudget,
                            policy: ContainerSafetyPolicy) {
        self.rootSourceVersionID = rootSourceVersionID
        self.currentDepth = currentDepth
        self.ancestorContainerHashes = ancestorContainerHashes
        self.budget = budget
        self.policy = policy
    }

    /// The root-level context for a freshly-encountered top-level container.
    public nonisolated static func root(sourceVersionID: UUID, containerHash: String,
                                        policy: ContainerSafetyPolicy = .standard) -> ContainerTraversalContext {
        ContainerTraversalContext(rootSourceVersionID: sourceVersionID, currentDepth: 0,
                                  ancestorContainerHashes: [containerHash.lowercased()],
                                  budget: ContainerRootBudget(policy: policy), policy: policy)
    }

    /// True when descending into a nested container of `childHash` would exceed the depth ceiling.
    public var wouldExceedDepth: Bool { currentDepth + 1 > policy.maxNestingDepth }

    /// True when `childHash` already appears on the ancestor path (a cycle).
    public func isCycle(childHash: String) -> Bool {
        ancestorContainerHashes.contains(childHash.lowercased())
    }

    /// A child context one level deeper, sharing the SAME root budget, with `childHash` added to the
    /// ancestor chain. Callers must check `wouldExceedDepth` / `isCycle` first.
    public func descending(intoContainerHash childHash: String) -> ContainerTraversalContext {
        var ancestors = ancestorContainerHashes
        ancestors.insert(childHash.lowercased())
        return ContainerTraversalContext(rootSourceVersionID: rootSourceVersionID, currentDepth: currentDepth + 1,
                                         ancestorContainerHashes: ancestors, budget: budget, policy: policy)
    }
}
