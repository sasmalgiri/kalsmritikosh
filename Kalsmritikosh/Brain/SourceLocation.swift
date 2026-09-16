//
//  CitedSourceLocation.swift
//  Kalsmritikosh
//
//  G2/Stage-3 — resolve a citation to an EXACT display location when the
//  format supports one (a character range, a page, a spreadsheet cell, an
//  email message), with an explicit, tested FALLBACK (.wholeDocument) for
//  formats that have no exact visual location. `locate` never returns nil —
//  every citation gets a usable open target. The actual location lookup is
//  injected, so this stays pure and testable.
//

import Foundation

public enum CitedSourceLocation: Sendable, Equatable {
    case charRange(start: Int, end: Int)
    case page(Int)
    case cell(row: Int, col: Int)
    case message(id: String)
    /// The tested fallback: no exact visual location — open the whole file.
    case wholeDocument
}

public struct SourceLocationResolver: Sendable {
    /// The exact location for a cited object, or nil when the format has none.
    public let blockLocation: @Sendable (_ objectID: UUID) async -> CitedSourceLocation?

    public init(blockLocation: @escaping @Sendable (_ objectID: UUID) async -> CitedSourceLocation?) {
        self.blockLocation = blockLocation
    }

    /// Resolve a citation to a location, falling back to `.wholeDocument`
    /// when no exact location is known — always a usable target, never nil.
    public func locate(citation: VerifiedAnswer.Citation) async -> CitedSourceLocation {
        await blockLocation(citation.objectID) ?? .wholeDocument
    }
}

extension CitedSourceLocation {
    /// Map a rich `SourceLocator` to the single most precise exact location the
    /// viewer can open at, or nil when the locator carries no positional anchor
    /// (the resolver then falls back to `.wholeDocument`). Priority: an explicit
    /// character range → a page → a table cell → an email message. Deterministic.
    public nonisolated static func from(_ locator: SourceLocator) -> CitedSourceLocation? {
        if let lo = locator.characterLower, let hi = locator.characterUpper, hi >= lo {
            return .charRange(start: lo, end: hi)
        }
        if let page = locator.page {
            return .page(page)
        }
        if let row = locator.row {
            return .cell(row: row, col: columnIndex(locator.column) ?? 0)
        }
        if let msg = locator.messageID {
            return .message(id: msg)
        }
        return nil
    }

    /// Convert a spreadsheet column label ("A", "B", "AA") to a 1-based index.
    /// Returns nil for an empty/non-letter label so the caller can default.
    nonisolated static func columnIndex(_ label: String?) -> Int? {
        guard let label, !label.isEmpty else { return nil }
        let upper = label.uppercased()
        var value = 0
        for ch in upper {
            guard let scalar = ch.asciiValue, scalar >= 65, scalar <= 90 else { return nil }
            value = value * 26 + (Int(scalar) - 64)
        }
        return value > 0 ? value : nil
    }

    /// A human-readable label for the location — used by the source viewer's
    /// "opens at …" affordance. Covers every case, including the fallback.
    public nonisolated static func describe(_ loc: CitedSourceLocation) -> String {
        switch loc {
        case let .charRange(start, end): return "characters \(start)–\(end)"
        case let .page(n):               return "page \(n)"
        case let .cell(row, col):        return "row \(row), col \(col)"
        case let .message(id):           return "message \(id)"
        case .wholeDocument:             return "whole document"
        }
    }
}
