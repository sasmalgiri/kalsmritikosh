//
//  ContainerSafetyTests.swift
//  KalsmritikoshTests
//
//  USF-M2 (USF-006 §7/§13/§14) — the immutable safety policy, the SHARED root budget (not reset per
//  nested container), and the traversal context (depth ceiling + ancestor-hash cycle detection).
//  Path-normalization + streaming-extraction safety are covered in the extraction section below.
//  Synthetic bytes only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — container safety policy + traversal")
struct ContainerSafetyTests {

    private func tinyPolicy(members: Int = 3, bytes: Int64 = 100, nested: Int = 2, depth: Int = 2, ratio: Int = 10) -> ContainerSafetyPolicy {
        ContainerSafetyPolicy(version: "test", maxEntriesPerContainer: 10, maxExpandedBytesPerContainer: 1000,
                              maxSingleMemberBytes: 500, maxNestingDepth: depth, maxRootTotalMembers: members,
                              maxRootExpandedBytes: bytes, maxNestedContainerCount: nested, maxCompressionRatio: ratio)
    }

    // MARK: - Policy

    @Test("The standard policy preserves the per-container limits and adds root-recursion ceilings")
    func standardPolicyConstants() {
        let p = ContainerSafetyPolicy.standard
        #expect(p.maxEntriesPerContainer == 20_000)
        #expect(p.maxExpandedBytesPerContainer == 4 * 1024 * 1024 * 1024)
        #expect(p.maxSingleMemberBytes == 1 * 1024 * 1024 * 1024)
        #expect(p.maxNestingDepth == 8)
        #expect(p.maxRootTotalMembers > 0)
        #expect(p.maxRootExpandedBytes > p.maxExpandedBytesPerContainer)
        #expect(p.maxNestedContainerCount > 0)
        #expect(p.maxCompressionRatio == 200)
        #expect(!p.version.isEmpty)
    }

    // MARK: - Shared root budget

    @Test("The root budget admits members up to the root member ceiling, then blocks")
    func budgetMemberCeiling() {
        let b = ContainerRootBudget(policy: tinyPolicy(members: 2))
        #expect(b.reserveMember(uncompressedBytes: 1) == .ok)
        #expect(b.reserveMember(uncompressedBytes: 1) == .ok)
        #expect(b.reserveMember(uncompressedBytes: 1) == .rootMemberLimit)
        #expect(b.consumed.members == 2)
    }

    @Test("An over-budget byte reservation consumes nothing and reports the root byte limit")
    func budgetByteCeiling() {
        let b = ContainerRootBudget(policy: tinyPolicy(members: 100, bytes: 100))
        #expect(b.reserveMember(uncompressedBytes: 80) == .ok)
        #expect(b.reserveMember(uncompressedBytes: 80) == .rootByteLimit)   // 160 > 100
        #expect(b.consumed.bytes == 80)                                     // nothing consumed on failure
    }

    @Test("The root budget bounds the number of nested containers")
    func budgetNestedContainerCeiling() {
        let b = ContainerRootBudget(policy: tinyPolicy(nested: 1))
        #expect(b.registerNestedContainer() == .ok)
        #expect(b.registerNestedContainer() == .nestedContainerLimit)
    }

    // MARK: - Traversal context

    @Test("A root context starts at depth 0 with the root hash on the ancestor chain")
    func rootContext() {
        let ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "AABB", policy: tinyPolicy())
        #expect(ctx.currentDepth == 0)
        #expect(ctx.ancestorContainerHashes.contains("aabb"))   // normalized lowercase
    }

    @Test("Descending increments depth, extends the ancestor chain, and shares the root budget")
    func descending() {
        let ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "root", policy: tinyPolicy())
        let child = ctx.descending(intoContainerHash: "child")
        #expect(child.currentDepth == 1)
        #expect(child.ancestorContainerHashes.isSuperset(of: ["root", "child"]))
        #expect(child.budget === ctx.budget)   // ONE shared budget across the traversal
    }

    @Test("A child hash already on the ancestor chain is detected as a cycle")
    func cycleDetection() {
        let ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "H1", policy: tinyPolicy())
        #expect(ctx.isCycle(childHash: "h1"))       // same hash (case-insensitive) = cycle
        #expect(!ctx.isCycle(childHash: "h2"))
        let deeper = ctx.descending(intoContainerHash: "H2")
        #expect(deeper.isCycle(childHash: "h1"))    // ancestor still remembered deeper down
    }

    @Test("The depth ceiling is enforced independently of the byte/member budget")
    func depthCeiling() {
        var ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "d0", policy: tinyPolicy(depth: 2))
        #expect(!ctx.wouldExceedDepth)               // depth 0 → next is 1, allowed
        ctx = ctx.descending(intoContainerHash: "d1")
        #expect(!ctx.wouldExceedDepth)               // depth 1 → next is 2, allowed
        ctx = ctx.descending(intoContainerHash: "d2")
        #expect(ctx.wouldExceedDepth)                // depth 2 → next is 3 > 2, blocked
    }

    // MARK: - Manifest tally

    @Test("Tally derives count-consistent manifest numbers from the member list")
    func tallyConsistency() {
        let parent = UUID()
        func m(_ ord: Int, _ d: ContainerMemberDisposition, kind: ContainerEntryKind = .file, bytes: Int64 = 10) -> ContainerMember {
            ContainerMember(parentSourceVersionID: parent, ordinal: ord, memberPath: "p\(ord)", normalizedMemberPath: "p\(ord)",
                            entryKind: kind, compressedSize: 1, uncompressedSize: bytes, detectedType: .pdf, disposition: d,
                            childSourceVersionID: d == .admitted ? UUID() : nil, contentHash: d == .admitted ? "h" : nil)
        }
        let members = [m(0, .admitted), m(1, .encrypted), m(2, .unsupported), m(3, .failedExtraction),
                       m(4, .directory, kind: .directory, bytes: 0)]
        let t = ContainerInspectionResult.tally(members: members)
        #expect(t.total == 5)
        #expect(t.regular == 4)                       // directory excluded
        #expect(t.admitted == 1)
        #expect(t.blocked == 1)                       // encrypted counts as blocked
        #expect(t.unsupported == 1)
        #expect(t.failed == 1)
        #expect(t.admitted + t.blocked + t.unsupported + t.failed <= t.regular)   // the v87 CHECK invariant
        #expect(t.declaredBytes == 40)               // 4 files × 10 bytes
    }

    @Test("Disposition classification: only admitted admits; blocked family is stable")
    func dispositionClassification() {
        #expect(ContainerMemberDisposition.admitted.isAdmitted)
        #expect(!ContainerMemberDisposition.encrypted.isAdmitted)
        #expect(ContainerMemberDisposition.blockedCycle.isBlocked)
        #expect(ContainerMemberDisposition.encrypted.isBlocked)
        #expect(!ContainerMemberDisposition.unsupported.isBlocked)
        #expect(!ContainerMemberDisposition.failedExtraction.isBlocked)
        #expect(!ContainerMemberDisposition.directory.isBlocked)
    }
}
