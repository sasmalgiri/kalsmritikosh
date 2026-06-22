//
//  AnyCodable.swift
//  Kalsmritikosh
//
//  Erased Codable value used as the leaf type for KnowledgeObject.metadata
//  and similar heterogeneous bags. Restricted to JSON-safe scalars + nested
//  arrays / dicts so it round-trips cleanly through SQLite TEXT columns.
//

import Foundation

public struct AnyCodable: Codable, Sendable, Hashable {
    public let value: AnySendable

    // G2-SWIFT6 — `nonisolated` so the encode(to:) closure-passed map
    // expression `a.map(AnyCodable.init)` doesn't trigger
    // "Call to main actor-isolated initializer in a synchronous
    // nonisolated context" under strict concurrency. AnyCodable is a
    // value type holding a Sendable enum; main-actor isolation isn't
    // needed for construction.
    public nonisolated init(_ value: AnySendable) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = .null
        } else if let b = try? c.decode(Bool.self) {
            value = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            value = .int(i)
        } else if let d = try? c.decode(Double.self) {
            value = .double(d)
        } else if let s = try? c.decode(String.self) {
            value = .string(s)
        } else if let arr = try? c.decode([AnyCodable].self) {
            value = .array(arr.map(\.value))
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            value = .object(dict.mapValues(\.value))
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported value in AnyCodable")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a.map(AnyCodable.init))
        case .object(let o): try c.encode(o.mapValues(AnyCodable.init))
        }
    }

    public enum AnySendable: Sendable, Hashable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        indirect case array([AnySendable])
        indirect case object([String: AnySendable])
    }
}
