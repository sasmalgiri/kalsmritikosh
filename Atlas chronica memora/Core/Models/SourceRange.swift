//
//  SourceRange.swift
//  Atlas chronica memora
//
//  Points into a source file for evidence-backed answers. The Verifier
//  refuses to answer without at least one SourceRange backing the claim,
//  and the UI uses it to highlight the cited passage in the original file.
//

import Foundation

public struct SourceRange: Codable, Hashable, Sendable {
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
}

extension Range: @retroactive Codable where Bound: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let lower = try c.decode(Bound.self)
        let upper = try c.decode(Bound.self)
        self = lower..<upper
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lowerBound)
        try c.encode(upperBound)
    }
}
