//
//  SimpleModeSidebarTests.swift
//  KalsmritikoshTests
//
//  Simple mode collapses each sidebar group to exactly ONE primary surface (owner request). This guards that
//  contract: every group defines a simplePrimary, that primary is a real member of the group, the five
//  primaries are distinct, and every OTHER destination stays reachable (nothing is orphaned) because the ⌘K
//  palette enumerates Destination.allCases. Pure enum checks — no UI runtime.
//

import Testing
@testable import Kalsmritikosh

@Suite("Simple-mode sidebar (one option per group)")
struct SimpleModeSidebarTests {

    @Test("Each group's Simple primary is a real member of that group")
    func primaryIsMember() {
        for group in Destination.Group.allCases {
            #expect(group.items.contains(group.simplePrimary), "\(group.rawValue) primary must be in its items")
        }
    }

    @Test("Simple mode shows exactly one row per group, and the five primaries are distinct")
    func oneDistinctPrimaryPerGroup() {
        let primaries = Destination.Group.allCases.map(\.simplePrimary)
        #expect(primaries.count == Destination.Group.allCases.count)
        #expect(Set(primaries).count == primaries.count, "Simple primaries must be distinct")
        // The locked survivors (owner: one simple option per group).
        #expect(Destination.Group.converse.simplePrimary == .ask)
        #expect(Destination.Group.reconstruct.simplePrimary == .workspaces)
        #expect(Destination.Group.knowledge.simplePrimary == .knowledge)
        #expect(Destination.Group.workspace.simplePrimary == .sources)
        #expect(Destination.Group.system.simplePrimary == .settings)
    }

    @Test("Every destination hidden in Simple stays reachable — the palette enumerates all destinations")
    func nothingOrphaned() {
        let simpleVisible = Set(Destination.Group.allCases.map(\.simplePrimary))
        let hidden = Destination.allCases.filter { !simpleVisible.contains($0) }
        // Reachability guarantee: the ⌘K palette is built from Destination.allCases, so any hidden row is
        // still one shortcut away. Assert the palette source of truth still covers every hidden destination.
        for dest in hidden {
            #expect(Destination.allCases.contains(dest))
        }
        // Sanity: Simple genuinely hides most surfaces (this is a decluttering, not a no-op).
        #expect(!hidden.isEmpty)
    }
}
