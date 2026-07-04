//
//  SourceRange.swift
//  Kalsmritikosh
//
//  Points into a source file for evidence-backed answers. The Verifier
//  refuses to answer without at least one SourceRange backing the claim,
//  and the UI uses it to highlight the cited passage in the original file.
//
//  G2-SWIFT6 — the previous `extension Range: @retroactive Codable` was
//  removed: a retroactive conformance on a standard-library type is a
//  future-SDK breakage waiting to happen (Apple is free to add their own
//  conditional Codable conformance to Range<Bound> in a future Foundation
//  release, at which point the project would fail to compile). The public
//  API still exposes `characterRange: Range<Int>?` — we now write the
//  Codable bounds manually here and in Chunk, with no retroactive scope.
//

import Foundation

public nonisolated struct SourceRange: Codable, Hashable, Sendable {
    public let chunkID: UUID?
    public let characterRange: Range<Int>?
    public let pageNumber: Int?
    public let line: Int?

    public init(
        chunkID: UUID? = nil,
        characterRange: Range<Int>? = nil,
        pageNumber: Int? = nil,
        line: Int? = nil
    ) {
        self.chunkID = chunkID
        self.characterRange = characterRange
        self.pageNumber = pageNumber
        self.line = line
    }

    private enum CodingKeys: String, CodingKey {
        case chunkID
        case characterRangeLower
        case characterRangeUpper
        case pageNumber
        case line
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chunkID = try c.decodeIfPresent(UUID.self, forKey: .chunkID)
        let lower = try c.decodeIfPresent(Int.self, forKey: .characterRangeLower)
        let upper = try c.decodeIfPresent(Int.self, forKey: .characterRangeUpper)
        if let lower, let upper, lower <= upper {
            self.characterRange = lower..<upper
        } else {
            self.characterRange = nil
        }
        self.pageNumber = try c.decodeIfPresent(Int.self, forKey: .pageNumber)
        self.line = try c.decodeIfPresent(Int.self, forKey: .line)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(chunkID, forKey: .chunkID)
        if let r = characterRange {
            try c.encode(r.lowerBound, forKey: .characterRangeLower)
            try c.encode(r.upperBound, forKey: .characterRangeUpper)
        }
        try c.encodeIfPresent(pageNumber, forKey: .pageNumber)
        try c.encodeIfPresent(line, forKey: .line)
    }
}
