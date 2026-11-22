//
//  EVTXBinXML.swift
//  Kalsmritikosh
//
//  Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
//  BinXML template resolution for Windows event-log records, so a record's EventID, Provider,
//  Channel, Computer, Level, TimeCreated and its named Data values are recovered (and a log can
//  be filtered by event id). Tokens per the public BinXML description (libevtx / python-evtx
//  documentation): fragment header 0x0F, template instance 0x0C (template definition inline or at
//  a chunk offset: next u32, GUID 16, size u32, fragment), open element 0x01/0x41 (dependency u16,
//  size u32, name offset u32, [inline name], [attribute list size u32 + attributes 0x06/0x46]),
//  close-start 0x02, close-empty 0x03, end 0x04, value 0x05, substitutions 0x0D/0x0E, char ref
//  0x08, entity ref 0x09, CDATA 0x07, PI 0x0A/0x0B, EOF 0x00. Names are chunk-relative
//  (next u32, hash u16, count u16, UTF-16, NUL). Nested BinXML (value type 0x21) is resolved in place.
//
//  Checked (2026-11-22, python prototype of this same walk) against plaso's Apache-2.0 samples:
//  System2.evtx 194/194 records resolved (Security log: 4624 ×47, 4672 ×36, 4735 ×34 …, named
//  Data such as SubjectUserSid/SubjectUserName/TargetUserSid), System.evtx 5,009/5,009 records
//  (7036 ×3,434, 7040 ×1,018; record 1 = 7036 "Service Control Manager", param1 "Windows Event
//  Log", param2 "stopped"). A record that does not resolve keeps the string harvest.
//

import Foundation
import OSLog

public nonisolated struct EVTXEvent: Sendable, Equatable {
    public var eventID: Int?
    public var provider: String?
    public var channel: String?
    public var computer: String?
    public var level: Int?
    public var timeCreated: String?
    /// Named data values in document order (EventData/Data Name=…, or UserData leaf elements).
    public var data: [(name: String, value: String)] = []

    public static func == (a: EVTXEvent, b: EVTXEvent) -> Bool {
        a.eventID == b.eventID && a.provider == b.provider && a.channel == b.channel && a.computer == b.computer
            && a.level == b.level && a.timeCreated == b.timeCreated
            && a.data.map(\.name) == b.data.map(\.name) && a.data.map(\.value) == b.data.map(\.value)
    }
}

/// One chunk's resolver (template definitions are cached per chunk).
nonisolated final class EVTXBinXMLResolver {
    enum Failure: Error { case outOfBounds, badToken(UInt8), tooDeep }

    private indirect enum Part { case literal(String), substitution(Int) }
    private indirect enum Node {
        case element(name: String, attributes: [(String, [Part])], children: [Node])
        case text([Part])
        case template(nodes: [Node], values: [(type: UInt8, start: Int, size: Int)])
    }

    private let d: [UInt8]
    private let chunkBase: Int
    private var templates: [Int: [Node]] = [:]
    private var depth = 0

    init(bytes: [UInt8], chunkBase: Int) {
        self.d = bytes
        self.chunkBase = chunkBase
    }

    /// Resolve one record's BinXML (absolute byte range). Nil when it does not parse.
    func event(from start: Int, to end: Int) -> EVTXEvent? {
        do {
            let (nodes, _) = try fragment(start, end)
            var ev = EVTXEvent()
            try collect(nodes, values: [], path: [], into: &ev)
            return ev.eventID == nil && ev.provider == nil ? nil : ev
        } catch {
            KalsmritikoshLog.ingestion.debug("EVTXBinXMLResolver: record not resolved — \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Primitives

    private func u8(_ o: Int) throws -> UInt8 { guard o >= 0, o < d.count else { throw Failure.outOfBounds }; return d[o] }
    private func u16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= d.count else { throw Failure.outOfBounds }
        return Int(d[o]) | Int(d[o + 1]) << 8
    }
    private func u32(_ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= d.count else { throw Failure.outOfBounds }
        return Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
    }
    private func utf16(_ o: Int, chars: Int) throws -> String {
        guard chars >= 0, o >= 0, o + chars * 2 <= d.count else { throw Failure.outOfBounds }
        var units = [UInt16](); units.reserveCapacity(chars)
        for i in 0..<chars { units.append(UInt16(d[o + 2 * i]) | UInt16(d[o + 2 * i + 1]) << 8) }
        return String(decoding: units, as: UTF16.self)
    }
    private func name(atChunkOffset off: Int) throws -> String {
        let o = chunkBase + off
        return try utf16(o + 8, chars: try u16(o + 6))
    }
    /// Reads a name-offset field at `p`; skips an inline name. Returns (name, next position).
    private func readName(_ p: Int) throws -> (String, Int) {
        let off = try u32(p)
        var q = p + 4
        let n = try name(atChunkOffset: off)
        if off == q - chunkBase { q += 8 + 2 * (try u16(q + 6)) + 2 }
        return (n, q)
    }

    // MARK: Fragment walk

    private func fragment(_ start: Int, _ end: Int) throws -> ([Node], Int) {
        depth += 1; defer { depth -= 1 }
        guard depth < 24 else { throw Failure.tooDeep }
        // A stack of open elements: (name, attributes, children-so-far).
        var root: [Node] = []
        var open: [(String, [(String, [Part])], [Node])] = []
        func append(_ n: Node) {
            if open.isEmpty { root.append(n) } else { open[open.count - 1].2.append(n) }
        }
        var p = start
        while p < end {
            let t = try u8(p)
            let base = t & 0x0F
            let more = (t & 0x40) != 0
            switch base {
            case 0x00:
                p += 1
                while let top = open.popLast() { append(.element(name: top.0, attributes: top.1, children: top.2)) }
                return (root, p)
            case 0x0F:
                p += 4
            case 0x0C:
                let defOffset = try u32(p + 6)
                p += 10
                if defOffset == p - chunkBase {
                    let size = try u32(p + 20)
                    let body = p + 24
                    templates[defOffset] = try fragment(body, body + size).0
                    p = body + size
                } else if templates[defOffset] == nil {
                    let o = chunkBase + defOffset
                    let size = try u32(o + 20)
                    templates[defOffset] = try fragment(o + 24, o + 24 + size).0
                }
                let count = try u32(p); p += 4
                guard count < 4096 else { throw Failure.outOfBounds }
                var sizes: [(Int, UInt8)] = []
                for i in 0..<count { sizes.append((try u16(p + 4 * i), try u8(p + 4 * i + 2))) }
                p += 4 * count
                var values: [(type: UInt8, start: Int, size: Int)] = []
                for (size, type) in sizes {
                    guard p + size <= d.count else { throw Failure.outOfBounds }
                    values.append((type, p, size)); p += size
                }
                append(.template(nodes: templates[defOffset] ?? [], values: values))
            case 0x01:
                p += 1 + 2 + 4
                let (n, q) = try readName(p); p = q
                var attributes: [(String, [Part])] = []
                if more {
                    p += 4
                    while true {
                        let at = try u8(p); p += 1
                        let (an, q2) = try readName(p); p = q2
                        let (parts, q3) = try values(p); p = q3
                        attributes.append((an, parts))
                        if (at & 0x40) == 0 { break }
                    }
                }
                let close = try u8(p); p += 1
                if close == 0x02 { open.append((n, attributes, [])) }
                else if close == 0x03 { append(.element(name: n, attributes: attributes, children: [])) }
                else { throw Failure.badToken(close) }
            case 0x04:
                p += 1
                if let top = open.popLast() { append(.element(name: top.0, attributes: top.1, children: top.2)) }
            case 0x05, 0x0D, 0x0E, 0x08, 0x09, 0x07:
                let (parts, q) = try values(p); p = q
                append(.text(parts))
            case 0x0A:
                p = try readName(p + 1).1
            case 0x0B:
                p += 3 + 2 * (try u16(p + 1))
            default:
                throw Failure.badToken(t)
            }
        }
        while let top = open.popLast() { append(.element(name: top.0, attributes: top.1, children: top.2)) }
        return (root, p)
    }

    /// A run of value tokens (text, substitutions, character/entity references, CDATA).
    private func values(_ start: Int) throws -> ([Part], Int) {
        var parts: [Part] = []
        var p = start
        while p < d.count {
            let base = d[p] & 0x0F
            switch base {
            case 0x05:
                let n = try u16(p + 2); parts.append(.literal(try utf16(p + 4, chars: n))); p += 4 + 2 * n
            case 0x0D, 0x0E:
                parts.append(.substitution(try u16(p + 1))); p += 4
            case 0x08:
                parts.append(.literal(String(UnicodeScalar(UInt16(try u16(p + 1))).map(Character.init) ?? " "))); p += 3
            case 0x09:
                let (n, q) = try readName(p + 1); p = q
                parts.append(.literal(["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"][n] ?? ""))
            case 0x07:
                let n = try u16(p + 1); parts.append(.literal(try utf16(p + 3, chars: n))); p += 3 + 2 * n
            default:
                return (parts, p)
            }
        }
        return (parts, p)
    }

    // MARK: Collect the fields

    private func collect(_ nodes: [Node], values: [(type: UInt8, start: Int, size: Int)], path: [String],
                         into ev: inout EVTXEvent) throws {
        for node in nodes {
            switch node {
            case .template(let inner, let vals):
                try collect(inner, values: vals, path: path, into: &ev)
            case .element(let n, let attributes, let children):
                let here = path + [n]
                let attrs = Dictionary(attributes.map { ($0.0, render($0.1, values)) }, uniquingKeysWith: { a, _ in a })
                switch here.joined(separator: "/") {
                case "Event/System/Provider": ev.provider = attrs["Name"] ?? attrs["EventSourceName"]
                case "Event/System/TimeCreated": ev.timeCreated = attrs["SystemTime"]
                default: break
                }
                // Nested BinXML in a child substitution is resolved under this element.
                var plain: [Node] = []
                for child in children {
                    if case .text(let parts) = child, let nested = try nestedFragment(parts, values) {
                        try collect(nested, values: [], path: here, into: &ev)
                    } else {
                        plain.append(child)
                    }
                }
                let text = plain.compactMap { c -> String? in if case .text(let parts) = c { return render(parts, values) }; return nil }
                    .joined()
                let leafHasText = !text.isEmpty
                switch here.joined(separator: "/") {
                case "Event/System/EventID": ev.eventID = Int(text.trimmingCharacters(in: .whitespaces))
                case "Event/System/Channel": ev.channel = text
                case "Event/System/Computer": ev.computer = text
                case "Event/System/Level": ev.level = Int(text)
                default:
                    if here.count >= 3, here[1] == "EventData" || here[1] == "UserData" {
                        let isLeaf = !plain.contains { if case .element = $0 { return true }; return false }
                        if isLeaf, leafHasText || attrs["Name"] != nil {
                            ev.data.append((attrs["Name"] ?? n, text))
                        }
                    }
                }
                try collect(plain.filter { if case .element = $0 { return true }; if case .template = $0 { return true }; return false },
                            values: values, path: here, into: &ev)
            case .text:
                break
            }
        }
    }

    private func nestedFragment(_ parts: [Part], _ values: [(type: UInt8, start: Int, size: Int)]) throws -> [Node]? {
        for part in parts {
            if case .substitution(let i) = part, i < values.count, values[i].type == 0x21 {
                return try fragment(values[i].start, values[i].start + values[i].size).0
            }
        }
        return nil
    }

    private func render(_ parts: [Part], _ values: [(type: UInt8, start: Int, size: Int)]) -> String {
        var s = ""
        for part in parts {
            switch part {
            case .literal(let l): s += l
            case .substitution(let i): if i < values.count { s += renderValue(values[i]) }
            }
        }
        return s
    }

    private func renderValue(_ v: (type: UInt8, start: Int, size: Int)) -> String {
        let b = Array(d[v.start..<(v.start + v.size)])
        func le(_ n: Int) -> UInt64 { (0..<min(n, b.count)).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) } }
        switch v.type {
        case 0x00: return ""
        case 0x01:
            var units = [UInt16]()
            for i in stride(from: 0, to: b.count - 1, by: 2) { units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8) }
            while units.last == 0 { units.removeLast() }
            return String(decoding: units, as: UTF16.self)
        case 0x02: return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
        case 0x03: return String(Int8(bitPattern: UInt8(le(1))))
        case 0x04: return String(le(1))
        case 0x05: return String(Int16(bitPattern: UInt16(le(2))))
        case 0x06: return String(le(2))
        case 0x07: return String(Int32(bitPattern: UInt32(le(4))))
        case 0x08: return String(le(4))
        case 0x09: return String(Int64(bitPattern: le(8)))
        case 0x0A: return String(le(8))
        case 0x0D: return le(4) != 0 ? "true" : "false"
        case 0x14: return "0x" + String(le(4), radix: 16)
        case 0x15: return "0x" + String(le(8), radix: 16)
        case 0x11:
            let ticks = le(8)
            guard ticks > 0 else { return "" }
            let date = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
            return ISO8601DateFormatter().string(from: date)
        case 0x13:
            // SID: revision, sub-authority count, 6-byte big-endian authority, sub-authorities (u32 LE).
            guard b.count >= 8 else { return "" }
            let count = Int(b[1])
            let authority = b[2..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var parts = ["S", String(b[0]), String(authority)]
            for i in 0..<count where 8 + 4 * i + 4 <= b.count {
                let o = 8 + 4 * i
                parts.append(String(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
            }
            return parts.joined(separator: "-")
        case 0x0F:
            guard b.count == 16 else { return "" }
            let h = b.map { String(format: "%02x", $0) }
            let p1 = [h[3], h[2], h[1], h[0]].joined(), p2 = [h[5], h[4]].joined(), p3 = [h[7], h[6]].joined()
            return "{\(p1)-\(p2)-\(p3)-\(h[8...9].joined())-\(h[10...15].joined())}"
        case 0x81:
            var units = [UInt16]()
            for i in stride(from: 0, to: b.count - 1, by: 2) { units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8) }
            return String(decoding: units, as: UTF16.self).split(separator: "\u{0}").joined(separator: ", ")
        default:
            return b.prefix(64).map { String(format: "%02x", $0) }.joined()
        }
    }
}
