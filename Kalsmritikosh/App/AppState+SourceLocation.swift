//
//  AppState+SourceLocation.swift
//  Kalsmritikosh
//
//  G2/Stage-3 (AT-19) — the live wiring for "open the source at the right
//  spot". Given a citation's evidence block, it resolves the block's real
//  SourceLocator from the evidence store and maps it to the exact
//  CitedSourceLocation the source viewer opens at, with the tested
//  whole-document fallback when the format carries no positional anchor.
//

import Foundation

extension AppState {
    /// The exact display location for a cited evidence block — a character
    /// range, page, cell, or message when the locator has one; otherwise the
    /// honest whole-document fallback. Never throws to the caller.
    public func exactLocation(forBlock blockID: UUID) async -> CitedSourceLocation {
        guard let evidenceStore else { return .wholeDocument }
        guard let resolved = try? await evidenceStore.resolveEvidenceBlocks([blockID]),
              let ref = resolved.first,
              let locator = ref.locator,
              let exact = CitedSourceLocation.from(locator) else {
            return .wholeDocument
        }
        return exact
    }
}
