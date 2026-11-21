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
import os

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

    /// Unified path AI-33 (owner 2026-11-22) — not tested yet. The block of a cited document that
    /// holds the quoted passage (first in reading order), so a citation that carries only a
    /// document and a quote still opens at its exact place. nil when no block holds the quote.
    public func quotedBlockID(objectID: UUID, quote: String?) async -> UUID? {
        guard let evidenceStore, let quote else { return nil }
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 8 else { return nil }
        let probe = String(needle.prefix(120))
        do {
            return try await evidenceStore.blocks(forObject: objectID)
                .first { $0.rawText.lowercased().contains(probe) || $0.normalizedText.lowercased().contains(probe) }?.id
        } catch {
            KalsmritikoshLog.ui.error("Cited source: quoted block not read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Unified path AI-33 (owner 2026-11-22) — not tested yet. The live SourceLocationResolver
    /// every citation opening goes through: the quoted block's exact location, else the whole
    /// document (never nil).
    public func sourceLocationResolver(quote: String?) -> SourceLocationResolver {
        SourceLocationResolver { [weak self] objectID in
            guard let self, let block = await self.quotedBlockID(objectID: objectID, quote: quote) else { return nil }
            let exact = await self.exactLocation(forBlock: block)
            return exact == .wholeDocument ? nil : exact
        }
    }
}
