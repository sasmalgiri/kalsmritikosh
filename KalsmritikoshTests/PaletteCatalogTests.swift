//
//  PaletteCatalogTests.swift
//  KalsmritikoshTests
//
//  D-10 (§1.8b) — the ⌘K palette must find every feature by real-life words,
//  rank the intended entry first, and NEVER execute a destructive action
//  directly: the Delete-all-my-data entry may only navigate to the Settings
//  anchor whose type-to-confirm sheet is the sole erase trigger.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Palette catalog (D-10 universal feature search)")
struct PaletteCatalogTests {

    private let entries = PaletteCatalog.entries()

    // MARK: Coverage

    @Test("Every Destination screen has a palette entry")
    func everyScreenCovered() {
        for dest in Destination.allCases {
            #expect(entries.contains { $0.id == "go.\(dest.rawValue)" },
                    "screen \(dest.rawValue) missing from the palette catalog")
        }
    }

    @Test("Every registered action has a palette entry")
    func everyActionCovered() {
        for action in PaletteActionID.allCases {
            #expect(entries.contains { $0.id == "act.\(action.rawValue)" },
                    "action \(action.rawValue) missing from the palette catalog")
        }
    }

    @Test("Every Settings group is reachable through some entry")
    func everySettingsAnchorReachable() {
        for anchor in SettingsAnchor.allCases {
            #expect(entries.contains { $0.target == .settingsAnchor(anchor) },
                    "settings group \(anchor.rawValue) unreachable from the palette")
        }
    }

    @Test("Entry ids are unique")
    func uniqueIDs() {
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    // MARK: Safety — destructive entries navigate, never execute

    @Test("Destructive entries may only navigate + anchor, never run an action")
    func destructiveEntriesNavigateOnly() {
        for action in PaletteCatalog.destructive {
            // No entry may EXECUTE a destructive action…
            #expect(!entries.contains { $0.target == .action(action) },
                    "\(action.rawValue) is wired as an executable palette action")
            // …and its entry must exist, targeting a screen or Settings anchor.
            let entry = entries.first { $0.id == "act.\(action.rawValue)" }
            #expect(entry != nil)
            if let entry {
                switch entry.target {
                case .screen, .settingsAnchor: break
                case .action: Issue.record("\(action.rawValue) entry has an executable target")
                }
            }
        }
        #expect(PaletteCatalog.destructive.contains(.deleteAllData))
    }

    // MARK: Real-life words find the feature (top hit)

    @Test("delete / erase / wipe surface Delete-all-my-data first, navigating to Your data")
    func eraseWordsFindYourData() {
        for word in ["delete", "erase", "wipe", "clear", "reset"] {
            let top = PaletteCatalog.matches(query: word).first
            #expect(top?.id == "act.deleteAllData", "'\(word)' top hit was \(top?.id ?? "nothing")")
            #expect(top?.target == .settingsAnchor(.yourData))
        }
    }

    @Test("fingerprint finds the signer-fingerprint entry")
    func fingerprintFindsSigner() {
        #expect(PaletteCatalog.matches(query: "fingerprint").first?.id == "act.copySignerFingerprint")
    }

    @Test("sop finds the SOP register / Constitution")
    func sopFindsRegister() {
        #expect(PaletteCatalog.matches(query: "sop").first?.target == .screen(.sutra))
    }

    @Test("subtitles finds Transcripts")
    func subtitlesFindsTranscripts() {
        #expect(PaletteCatalog.matches(query: "subtitles").first?.target == .screen(.transcripts))
    }

    // MARK: Ranking mechanics

    @Test("Ranking is deterministic and ordered by score then title")
    func stableRanking() {
        let a = PaletteCatalog.matches(query: "re").map(\.id)
        let b = PaletteCatalog.matches(query: "re").map(\.id)
        #expect(a == b)
        let scored = PaletteCatalog.matches(query: "re")
            .map { PaletteCatalog.score(query: "re", entry: $0) }
        #expect(scored == scored.sorted(by: >), "results not in descending score order")
    }

    @Test("Empty query returns the full catalog; junk returns nothing")
    func emptyAndJunkQueries() {
        #expect(PaletteCatalog.matches(query: "").count == entries.count)
        #expect(PaletteCatalog.matches(query: "zqxjkvv").isEmpty)
    }

    @Test("Subsequence matching still works for abbreviations (cvt → Convert)")
    func fuzzyAbbreviation() {
        #expect(PaletteCatalog.matches(query: "cvt").contains { $0.target == .screen(.convert) })
        #expect(PaletteCatalog.fuzzySubsequence("cvt", "Convert"))
        #expect(!PaletteCatalog.fuzzySubsequence("tvc", "Convert"))
    }
}
