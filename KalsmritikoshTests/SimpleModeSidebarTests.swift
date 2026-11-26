//
//  SimpleModeSidebarTests.swift
//  KalsmritikoshTests
//
//  Simple mode (the only mode the app ships) shows a short sidebar. Since the navigation merge
//  (scope 2026-11-06 §3, 2026-11-07) that is the four areas — Cases, Evidence, Search, Outputs — then
//  More tools, Settings and Help. This guards the contract: each group's simple row is a real destination
//  shown in the sidebar, the rows are distinct, and every OTHER destination stays reachable (its area or
//  More tools lists it, and the ⌘K palette enumerates Destination.allCases). Pure enum checks — no UI.
//

import Testing
@testable import Kalsmritikosh

@Suite("Simple-mode sidebar (four areas, then the utilities)")
struct SimpleModeSidebarTests {

    @Test("The simple sidebar is Cases, Evidence, Search, Outputs, then More tools, Settings, Help")
    func sidebarRows() {
        #expect(Destination.primaries == [.cases, .evidence, .search, .outputs])
        #expect(Destination.utilities == [.moreTools, .settings, .guide])
        let rows = Destination.primaries + Destination.utilities
        #expect(Set(rows).count == rows.count, "sidebar rows must be distinct")
        #expect(Destination.primaries.map(\.home) == NavHome.primaries)
    }

    @Test("Each group's simple row is shown in the sidebar, and the four areas lead their own group")
    func primaryIsShown() {
        let rows = Set(Destination.primaries + Destination.utilities)
        for group in Destination.Group.allCases {
            #expect(rows.contains(group.simplePrimary), "\(group.rawValue)")
        }
        #expect(Destination.Group.cases.simplePrimary == .cases)
        #expect(Destination.Group.evidence.simplePrimary == .evidence)
        #expect(Destination.Group.search.simplePrimary == .search)
        #expect(Destination.Group.outputs.simplePrimary == .outputs)
        #expect(Destination.Group.system.simplePrimary == .settings)
        for group in [Destination.Group.caseViews, .professional, .records, .archive] {
            #expect(group.simplePrimary == .moreTools && group.inMoreTools)
        }
    }

    @Test("Every destination hidden in Simple stays reachable — its area or More tools lists it, and the palette has it")
    func nothingOrphaned() {
        let shown = Set(Destination.primaries + Destination.utilities)
        let hidden = Destination.allCases.filter { !shown.contains($0) }
        #expect(!hidden.isEmpty)
        let palette = Set(PaletteCatalog.entries().map(\.id))
        for dest in hidden {
            let group = Destination.Group.allCases.first { $0.allItems.contains(dest) }
            #expect(group != nil, "\(dest.rawValue) is in no group")
            #expect(palette.contains("go.\(dest.rawValue)"), "\(dest.rawValue) not in the palette")
            // Reached from its area's own screen, or from More tools.
            if let group { #expect(group.inMoreTools || dest.home == group.simplePrimary.home, "\(dest.rawValue)") }
        }
    }

    @Test("Every destination is in exactly one group")
    func oneGroupEach() {
        for dest in Destination.allCases {
            let n = Destination.Group.allCases.filter { $0.allItems.contains(dest) }.count
            #expect(n == 1, "\(dest.rawValue) is in \(n) groups")
        }
    }
}
