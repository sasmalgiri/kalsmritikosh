//
//  ContainerSafetyPolicy.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §7) — the ONE immutable safety policy for container expansion. It preserves the
//  existing per-container protections (entry flood, zip-bomb, single-member cap) and ADDS root-
//  recursion protections (nesting depth, root-wide member + byte budgets, nested-container count,
//  compression ratio) so a chain of individually-legal nested archives cannot collectively exhaust
//  resources. All constants live here — never scattered as magic numbers across loaders. The
//  `version` string is recorded in every container manifest so past behaviour stays explainable.
//

import Foundation

public nonisolated struct ContainerSafetyPolicy: Sendable, Hashable {
    /// Recorded in `container_manifests.policy_version`. Bump when any constant below changes.
    public let version: String

    // Per-container protections (carried forward from the P4.11 ArchiveLoader limits).
    public let maxEntriesPerContainer: Int
    public let maxExpandedBytesPerContainer: Int64
    public let maxSingleMemberBytes: Int64

    // Root-recursion protections (new in USF-M2 — shared across the WHOLE root traversal).
    public let maxNestingDepth: Int
    public let maxRootTotalMembers: Int
    public let maxRootExpandedBytes: Int64
    public let maxNestedContainerCount: Int
    /// Max uncompressed:compressed ratio for a single member before it is treated as a bomb.
    public let maxCompressionRatio: Int

    public nonisolated init(version: String, maxEntriesPerContainer: Int, maxExpandedBytesPerContainer: Int64,
                            maxSingleMemberBytes: Int64, maxNestingDepth: Int, maxRootTotalMembers: Int,
                            maxRootExpandedBytes: Int64, maxNestedContainerCount: Int, maxCompressionRatio: Int) {
        self.version = version
        self.maxEntriesPerContainer = maxEntriesPerContainer
        self.maxExpandedBytesPerContainer = maxExpandedBytesPerContainer
        self.maxSingleMemberBytes = maxSingleMemberBytes
        self.maxNestingDepth = maxNestingDepth
        self.maxRootTotalMembers = maxRootTotalMembers
        self.maxRootExpandedBytes = maxRootExpandedBytes
        self.maxNestedContainerCount = maxNestedContainerCount
        self.maxCompressionRatio = maxCompressionRatio
    }

    /// The production policy. GiB/… expressed explicitly so the numbers read at a glance.
    public nonisolated static let standard = ContainerSafetyPolicy(
        version: "usf-m2-container-policy-1",
        maxEntriesPerContainer: 20_000,
        maxExpandedBytesPerContainer: 4 * 1024 * 1024 * 1024,   // 4 GiB per container
        maxSingleMemberBytes: 1 * 1024 * 1024 * 1024,           // 1 GiB per member
        maxNestingDepth: 8,
        maxRootTotalMembers: 200_000,                           // whole-root member ceiling
        maxRootExpandedBytes: 16 * 1024 * 1024 * 1024,          // 16 GiB across the whole root
        maxNestedContainerCount: 256,                           // nested containers per root
        maxCompressionRatio: 200)
}
