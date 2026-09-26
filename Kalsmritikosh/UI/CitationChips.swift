//
//  CitationChips.swift
//  Kalsmritikosh
//
//  §1.3 (owner decision 2026-09-27) — citation chips that OPEN AT THE QUOTED
//  PASSAGE. One numbered chip per cited source under an answer; tapping it
//  opens the in-app SourceViewer with the quoted words highlighted.
//
//  Why the viewer searches for the quote instead of trusting offsets: a
//  chunk's character range points into the NORMALISED text of the knowledge
//  object, not into the raw file bytes (an .eml's headers, HTML markup, a
//  PDF's text layer all shift it). The quote is the one anchor every format
//  shares, so `CitedPassageLocator` finds it whitespace- and case-insensitively
//  in whatever text the viewer renders — universal, and it fails honestly
//  (no highlight, the whole document opens) when the quote is not present.
//

import SwiftUI

/// What the source sheet opens: a file, its knowledge object (the screen
/// authorizer's key), and the quoted words to find and highlight.
public struct CitationOpenTarget: Identifiable, Hashable {
    public let id = UUID()
    public let url: URL
    public let objectID: UUID
    public let quote: String?
}

/// One chip per distinct cited source, numbered in first-citation order.
public struct CitationChips: View {
    let citations: [VerifiedAnswer.Citation]
    let onOpen: @MainActor (VerifiedAnswer.Citation) -> Void

    @Environment(AppState.self) private var appState
    @State private var names: [UUID: String] = [:]

    public init(citations: [VerifiedAnswer.Citation],
                onOpen: @escaping @MainActor (VerifiedAnswer.Citation) -> Void) {
        self.citations = citations
        self.onOpen = onOpen
    }

    /// The first citation of each source, in order — the chip opens at that
    /// source's first quoted passage.
    static func distinctSources(_ citations: [VerifiedAnswer.Citation]) -> [VerifiedAnswer.Citation] {
        var seen = Set<UUID>()
        return citations.filter { seen.insert($0.objectID).inserted }
    }

    public var body: some View {
        let sources = Self.distinctSources(citations)
        if !sources.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, citation in
                        let name = names[citation.objectID] ?? "Source"
                        Button {
                            onOpen(citation)
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(index + 1)")
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                Text(name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(.tint.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 220)
                        .help(citation.snippet.isEmpty ? name : String(citation.snippet.prefix(200)))
                        .accessibilityLabel("Source \(index + 1): \(name). Opens at the quoted passage.")
                    }
                }
            }
            .task(id: sources.map(\.objectID)) {
                let ids = Set(sources.map(\.objectID))
                names = (try? await appState.objects?.sourceFilenames(for: ids)) ?? [:]
            }
        }
    }
}

/// Finds a quoted passage inside rendered source text, tolerant of the
/// whitespace and case differences between a normalised snippet and the raw
/// file. Returns an NSRange in the haystack's UTF-16 space, or nil.
public enum CitedPassageLocator {
    /// Shortest probe worth trusting — below this a match is likely a
    /// coincidence (a common word), so the viewer opens un-highlighted.
    static let minimumProbe = 12

    public nonisolated static func locate(_ quote: String, in haystack: String) -> NSRange? {
        let (normHay, map) = normalizeWithMap(haystack)
        guard !normHay.isEmpty else { return nil }
        // A snippet may be an excerpt stitched with ellipses — try its
        // longest segment first, then shorter prefixes of it.
        let segments = quote
            .components(separatedBy: CharacterSet(charactersIn: "…"))
            .map { normalize($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minimumProbe }
            .sorted { $0.count > $1.count }
        for segment in segments {
            for length in [segment.count, 160, 80, 40, 20] where length <= segment.count && length >= minimumProbe {
                let probe = String(segment.prefix(length)).trimmingCharacters(in: .whitespaces)
                guard probe.count >= minimumProbe,
                      let r = normHay.range(of: probe) else { continue }
                let lo = normHay.distance(from: normHay.startIndex, to: r.lowerBound)
                let hi = normHay.distance(from: normHay.startIndex, to: r.upperBound)
                guard lo < map.count, hi - 1 < map.count, hi > lo else { continue }
                let start = map[lo].lowerBound
                let end = map[hi - 1].upperBound
                return NSRange(location: start, length: end - start)
            }
        }
        return nil
    }

    /// Lower-cased, whitespace runs collapsed to one space.
    nonisolated static func normalize(_ s: String) -> String {
        normalizeWithMap(s).text
    }

    /// The normalised text plus, per normalised Character, the UTF-16 range
    /// it came from in the original — so a match maps back exactly.
    nonisolated static func normalizeWithMap(_ s: String) -> (text: String, map: [Range<Int>]) {
        var out = ""
        var map: [Range<Int>] = []
        var utf16Offset = 0
        var lastWasSpace = true   // drops leading whitespace
        for ch in s {
            let width = ch.utf16.count
            defer { utf16Offset += width }
            if ch.isWhitespace || ch.isNewline {
                if !lastWasSpace {
                    out.append(" ")
                    map.append(utf16Offset..<(utf16Offset + width))
                    lastWasSpace = true
                }
                continue
            }
            for lower in ch.lowercased() {
                out.append(lower)
                map.append(utf16Offset..<(utf16Offset + width))
            }
            lastWasSpace = false
        }
        return (out, map)
    }
}
