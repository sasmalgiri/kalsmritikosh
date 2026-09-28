//
//  LocalFixtures.swift
//  KalsmritikoshTests
//
//  Tests that need material only the owner's machine has — the real archive
//  at ~/Downloads/Mail, the bundled BGE tokenizer (not in the repository) —
//  are gated with `.enabled(if:)` on these. On the hosted runner they report
//  as SKIPPED with the reason (visible, never a silent pass); on the owner's
//  machine they run exactly as before, and a missing file inside a running
//  test still records an issue.
//

import Foundation
import Testing
@testable import Kalsmritikosh

enum LocalFixtures {
    static let ownerArchive = URL(fileURLWithPath: NSString(string: "~/Downloads/Mail").expandingTildeInPath)

    /// The owner's archive folder exists and holds at least one file.
    static var ownerArchiveAvailable: Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: ownerArchive.path)) ?? []
        return !items.isEmpty
    }

    /// The BGE tokenizer resource is bundled with this build.
    static var bgeTokenizerBundled: Bool { BGETokenizer() != nil }

    static let archiveReason: Comment = "needs the owner's archive at ~/Downloads/Mail (local runs only)"
    static let tokenizerReason: Comment = "needs the bundled BGE tokenizer resource (not in the repository)"
}
