//
//  PinnedDeveloperKeyTests.swift
//  KalsmritikoshTests
//
//  Release act 1.8 — the developer's release signing fingerprint is pinned at
//  build time, so packs and bundles signed by that key bind identity on every
//  install with no local trust decision. This test makes an UNPINNED release
//  build impossible to ship green: keyID must be present, well-formed (16
//  lowercase hex), and trusted by construction.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Pinned developer signing key (release act 1.8)")
struct PinnedDeveloperKeyTests {

    @Test("keyID is pinned, 16 lowercase hex, and trusted by construction")
    func pinnedAndTrusted() {
        let keyID = PinnedDeveloperKey.keyID
        #expect(keyID != nil, "PinnedDeveloperKey.keyID must be set before a release build")
        guard let keyID else { return }
        #expect(keyID.count == 16)
        #expect(keyID.allSatisfy { "0123456789abcdef".contains($0) },
                "fingerprint must be 16 LOWERCASE hex characters")
        #expect(TrustedSigners.isTrusted(keyID))
        // The published fingerprint (docs/verification) must be the same value —
        // guarded here by pinning the exact literal this release ships.
        #expect(keyID == "f760b04ce2d5030c")
    }
}
