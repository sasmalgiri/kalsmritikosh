//
//  CaseMapPathSearch.swift
//  Kalsmritikosh
//
//  Smart-map S4 (SEARCH-09 / SEARCH-10) — typed relationship paths over ONE case's map: from a record, along links of
//  chosen types, in a chosen direction, with stated conditions (minimum stated certainty, record kinds allowed in the
//  middle, link periods in time order or inside an interval) and declared bounds (path length, number of steps
//  explored, number of paths returned). Every returned edge is explained (its type, which way it was followed, why it
//  exists, its certainty, its period, its sources). The coverage says what was explored and what the bounds and
//  conditions left out, so "no path within these bounds" never reads as "no connection", and a path never reads as
//  causation or as the same money moving.
//
//  The corpus is the case map's projection — the case's own records and links, already scope-checked. Patterns are
//  versioned (`CaseMapPathQuery.currentVersion`) and saved by name in versions (v180 case_saved_patterns): a live pattern
//  re-runs over the case as it is; a frozen receipt keeps one run's paths with the map fence it ran at, never changed.
//  Deterministic; nothing is sent anywhere.
//

import Foundation
import os

public nonisolated struct CaseMapPathQuery: Codable, Sendable, Equatable, Hashable {
    public static let currentVersion = 1
    public enum Direction: String, Codable, Sendable, CaseIterable, Hashable {
        /// Follow each directed link from its start to its end.
        case forward
        /// Follow each directed link from its end back to its start.
        case backward
        /// Either way (direction is still reported per edge).
        case either
        public var label: String {
            switch self {
            case .forward: return "following each link's direction"
            case .backward: return "against each link's direction"
            case .either: return "in either direction"
            }
        }
    }

    public var version: Int = CaseMapPathQuery.currentVersion
    public var from: CaseMapNodeID
    /// A specific end record, or any record of `toKind`, or (both nil) every record reached.
    public var to: CaseMapNodeID?
    public var toKind: CaseMapNodeKind?
    /// Link types allowed (empty: every type).
    public var linkTypes: [CaseMapLinkType] = []
    public var direction: Direction = .forward
    /// Links stated less certainly than this are not followed (nil: certainty is not a condition).
    public var minCertainty: CaseMapCertainty?
    /// Record kinds allowed between the ends (nil: any).
    public var throughKinds: [CaseMapNodeKind]?
    /// Each link's period must start no earlier than the previous link's (undated links are then not followed).
    public var timeOrdered: Bool = false
    /// Each link's period must overlap this interval (undated links are then not followed).
    public var intervalStart: Date?
    public var intervalEnd: Date?
    /// Declared bounds.
    public var maxLength: Int = 4
    public var maxSteps: Int = 20_000
    public var maxPaths: Int = 200

    public init(from: CaseMapNodeID, to: CaseMapNodeID? = nil, toKind: CaseMapNodeKind? = nil) { self.from = from; self.to = to; self.toKind = toKind }

    public var problems: [String] {
        var out: [String] = []
        if version != Self.currentVersion { out.append("This pattern was saved with version \(version); this app reads version \(Self.currentVersion). It is not reinterpreted.") }
        if !(1...12).contains(maxLength) { out.append("A path has 1 to 12 links.") }
        if !(1...1_000_000).contains(maxSteps) { out.append("The exploration limit is 1 to 1,000,000 steps.") }
        if !(1...5_000).contains(maxPaths) { out.append("Return 1 to 5,000 paths.") }
        if let a = intervalStart, let b = intervalEnd, b < a { out.append("The interval ends before it starts.") }
        if to == from { out.append("The start and the end are the same record.") }
        return out
    }

    /// The conditions as the person reads them (the receipt states exactly what ran).
    public var explanation: [String] {
        var out = ["Paths in this case's map from \(from.key)" + (to.map { " to \($0.key)" } ?? toKind.map { " to any \($0.label.lowercased())" } ?? " to every record reached")]
        out.append("• along " + (linkTypes.isEmpty ? "links of every type" : "links of type " + linkTypes.map { "“\($0.label)”" }.joined(separator: ", ")) + ", \(direction.label)")
        if let m = minCertainty { out.append("• only links stated at least as “\(m.label)” (links with no stated certainty are not followed)") }
        if let k = throughKinds { out.append("• passing only through " + (k.isEmpty ? "no intermediate records" : k.map { $0.plural.lowercased() }.joined(separator: ", "))) }
        if timeOrdered { out.append("• each link's period starting no earlier than the previous one's (undated links are not followed)") }
        if intervalStart != nil || intervalEnd != nil {
            out.append("• links whose period overlaps \(intervalStart?.formatted(date: .abbreviated, time: .omitted) ?? "any start") – \(intervalEnd?.formatted(date: .abbreviated, time: .omitted) ?? "any end") (undated links are not followed)")
        }
        out.append("• at most \(maxLength) link\(maxLength == 1 ? "" : "s") per path, \(maxSteps) steps explored, \(maxPaths) paths returned")
        return out
    }

    func encoded() -> String {
        guard let d = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
    static func decode(_ s: String?) -> CaseMapPathQuery? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(CaseMapPathQuery.self, from: d) } catch {
            KalsmritikoshLog.app.error("Saved relationship pattern unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

public nonisolated struct CaseMapPathEdge: Codable, Sendable, Equatable, Hashable {
    public let linkID: String
    public let from: CaseMapNodeID
    public let to: CaseMapNodeID
    public let type: CaseMapLinkType
    /// Followed in the link's own direction (false: against it; an undirected link is always true).
    public let followedForward: Bool
    public let basis: String
    public let certainty: CaseMapCertainty
    public let period: String?
    public let sources: Int
    public let assertedBy: String
    /// "supports (followed backwards) — Certainty: Possible — Period: from March — 2 sources — The report says so"
    public var explanation: String {
        var s = type.label + (type.directed ? (followedForward ? "" : " (followed against its direction)") : " (no direction)")
        s += " — certainty: \(certainty.label)"
        if let period { s += " — period: \(period)" }
        s += " — \(sources) source\(sources == 1 ? "" : "s") — asserted by \(assertedBy) — \(basis)"
        return s
    }
}

public nonisolated struct CaseMapPath: Codable, Sendable, Equatable, Hashable {
    public let nodes: [CaseMapNodeID]
    public let edges: [CaseMapPathEdge]
    public var length: Int { edges.count }
}

public nonisolated struct CaseMapPathResult: Codable, Sendable, Equatable {
    public let query: CaseMapPathQuery
    public let paths: [CaseMapPath]
    public let recordsReached: Int
    public let linksExamined: Int
    /// Why links were not followed: condition → count.
    public let notFollowed: [String: Int]
    public let stepLimitReached: Bool
    public let pathLimitReached: Bool
    public let lengthLimitStopped: Int
    /// Parts of the case that could not be read (their links were not explored).
    public let notLoaded: [String]

    public var complete: Bool { !stepLimitReached && !pathLimitReached && notLoaded.isEmpty }

    public static let caveat = "A path shows recorded links between records of this case. It does not prove that one thing caused another, that people are the same person, or that money moving along it is the same money."

    public var lines: [String] {
        var out: [String] = []
        out.append(paths.isEmpty ? "No path within these bounds and conditions." : "\(paths.count) path\(paths.count == 1 ? "" : "s") found\(pathLimitReached ? " — the path limit was reached; there may be more" : "").")
        out.append("Explored \(recordsReached) record\(recordsReached == 1 ? "" : "s") and \(linksExamined) link\(linksExamined == 1 ? "" : "s") of this case's map.")
        for (why, n) in notFollowed.sorted(by: { $0.key < $1.key }) where n > 0 { out.append("Not followed — \(why): \(n)") }
        if lengthLimitStopped > 0 { out.append("\(lengthLimitStopped) path\(lengthLimitStopped == 1 ? " was" : "s were") cut at the \(query.maxLength)-link limit.") }
        if stepLimitReached { out.append("The exploration limit of \(query.maxSteps) steps was reached: part of the map was not explored.") }
        for n in notLoaded { out.append("Not explored — could not be read: \(n)") }
        if paths.isEmpty {
            out.append("This says nothing about connections outside these bounds, outside this case's map, or not recorded in the case.")
        }
        out.append(Self.caveat)
        return out
    }
}

public nonisolated enum CaseMapPathSearch {

    static func rank(_ c: CaseMapCertainty) -> Int {
        switch c {
        case .statedBySource: return 4
        case .probable: return 3
        case .possible: return 2
        case .doubtful: return 1
        case .notStated: return 0
        }
    }

    /// Enumerate simple paths (no record twice) breadth-first, shortest first, within the declared bounds.
    public static func run(_ q: CaseMapPathQuery, in p: CaseMapProjection) -> Result<CaseMapPathResult, CaseMapPathError> {
        let problems = q.problems
        guard problems.isEmpty else { return .failure(.rejected(problems)) }
        guard p.node(q.from) != nil else { return .failure(.notInMap("start")) }
        if let to = q.to, p.node(to) == nil { return .failure(.notInMap("end")) }
        let types = Set(q.linkTypes)
        let through = q.throughKinds.map(Set.init)
        var notFollowed: [String: Int] = [:]
        var paths: [CaseMapPath] = []
        var reached = Set<CaseMapNodeID>([q.from])
        var examined = Set<String>()
        var steps = 0, cut = 0
        var stepLimit = false, pathLimit = false
        struct Partial { let nodes: [CaseMapNodeID]; let edges: [CaseMapPathEdge]; let lastStart: Date? }
        var frontier = [Partial(nodes: [q.from], edges: [], lastStart: nil)]
        func isTarget(_ n: CaseMapNodeID) -> Bool {
            if let to = q.to { return n == to }
            if let k = q.toKind { return p.node(n)?.kind == k }
            return true
        }
        outer: while !frontier.isEmpty {
            var next: [Partial] = []
            for path in frontier {
                guard let here = path.nodes.last else { continue }
                for l in p.links(of: here).sorted(by: { $0.id < $1.id }) {
                    steps += 1
                    if steps > q.maxSteps { stepLimit = true; break outer }
                    examined.insert(l.id)
                    // Which way the link is followed from here.
                    let forward: Bool, other: CaseMapNodeID
                    if l.from == here { forward = true; other = l.to } else if l.to == here { forward = false; other = l.from } else { continue }
                    if l.status.kind == .unavailable { notFollowed["withdrawn or unavailable", default: 0] += 1; continue }
                    if !types.isEmpty, !types.contains(l.type) { notFollowed["another link type", default: 0] += 1; continue }
                    if l.directed {
                        if q.direction == .forward && !forward { notFollowed["against the chosen direction", default: 0] += 1; continue }
                        if q.direction == .backward && forward { notFollowed["against the chosen direction", default: 0] += 1; continue }
                    }
                    if let m = q.minCertainty, rank(l.certainty) < rank(m) || l.certainty == .notStated {
                        notFollowed["stated less certainly than “\(m.label)”, or not stated", default: 0] += 1; continue
                    }
                    let start = l.validity?.from ?? l.validity?.to
                    if q.timeOrdered || q.intervalStart != nil || q.intervalEnd != nil {
                        guard l.validity?.from != nil || l.validity?.to != nil else { notFollowed["no recorded period (undated)", default: 0] += 1; continue }
                    }
                    if q.timeOrdered, let prev = path.lastStart, let s = start, s < prev { notFollowed["earlier than the previous link", default: 0] += 1; continue }
                    if q.intervalStart != nil || q.intervalEnd != nil {
                        let lf = l.validity?.from ?? .distantPast, lt = l.validity?.to ?? .distantFuture
                        if let a = q.intervalStart, lt < a { notFollowed["outside the interval", default: 0] += 1; continue }
                        if let b = q.intervalEnd, lf > b { notFollowed["outside the interval", default: 0] += 1; continue }
                    }
                    if path.nodes.contains(other) { continue }   // a simple path: no record twice (cycle-safe)
                    reached.insert(other)
                    let edge = CaseMapPathEdge(linkID: l.id, from: here, to: other, type: l.type, followedForward: !l.directed || forward, basis: l.basis,
                                               certainty: l.certainty, period: l.validity.flatMap { $0.isRecorded ? $0.label : nil },
                                               sources: l.sources.count, assertedBy: l.assertedBy.label)
                    let extended = Partial(nodes: path.nodes + [other], edges: path.edges + [edge], lastStart: start ?? path.lastStart)
                    if isTarget(other) && other != q.from {
                        paths.append(CaseMapPath(nodes: extended.nodes, edges: extended.edges))
                        if paths.count >= q.maxPaths { pathLimit = true; break outer }
                        if q.to != nil { continue }   // a path ends at its end record
                    }
                    // The middle of a path: only the allowed kinds.
                    if let through, let k = p.node(other)?.kind, !through.contains(k) { continue }
                    if extended.edges.count >= q.maxLength { cut += 1; continue }
                    next.append(extended)
                }
            }
            frontier = next
        }
        return .success(CaseMapPathResult(query: q, paths: paths, recordsReached: reached.count, linksExamined: examined.count, notFollowed: notFollowed,
                                          stepLimitReached: stepLimit, pathLimitReached: pathLimit, lengthLimitStopped: cut,
                                          notLoaded: p.failedParts.map(\.label)))
    }
}

public nonisolated enum CaseMapPathError: Error, Equatable, LocalizedError {
    case rejected([String])
    case notInMap(String)
    public var errorDescription: String? {
        switch self {
        case .rejected(let why): return why.joined(separator: " ")
        case .notInMap(let end): return "The \(end) record is not in this case's map. Nothing was searched."
        }
    }
}

// MARK: - Saved patterns (v180 case_saved_patterns)

public nonisolated struct CaseSavedPattern: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case live, receipt }
    public let id: UUID
    public let caseID: UUID
    public let name: String
    public let version: Int
    public let kind: Kind
    public let query: CaseMapPathQuery?
    public let result: CaseMapPathResult?
    public let fence: String?
    public let createdBy: String
    public let createdAt: Date
}

extension CaseSearchRepository {

    /// Save a pattern: saving under an existing name makes the next version (earlier versions are kept). A receipt keeps
    /// the run's paths and the map fence it ran at; nothing saved is ever edited.
    @discardableResult
    public func savePattern(caseID: UUID, name: String, kind: CaseSavedPattern.Kind, query: CaseMapPathQuery, result: CaseMapPathResult?, fence: String?,
                            actor: String, at date: Date = Date()) async throws -> (id: UUID, version: Int) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CaseSearchRepositoryError.blank("The pattern's name") }
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseSearchRepositoryError.blank("Who saved it") }
        if kind == .receipt, result == nil || fence == nil { throw CaseSearchRepositoryError.blank("The frozen result") }
        let id = UUID()
        let resultJSON: String? = try result.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let box = PatternVersionBox()
        try await patternWrite(id) { db in
            guard try db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first != nil else { throw CaseSearchRepositoryError.caseNotFound }
            let v = (try db.query("SELECT COALESCE(MAX(version), 0) + 1 FROM case_saved_patterns WHERE case_id = ? AND name = ?;", [.uuid(caseID), .text(clean)]).first?.int(0)) ?? 1
            box.version = Int(v)
            try db.exec("""
                INSERT INTO case_saved_patterns (id, case_id, name, version, kind, pattern_version, pattern_json, result_json, fence, created_by, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(clean), .integer(v), .text(kind.rawValue), .integer(Int64(query.version)), .text(query.encoded()),
                      .optionalText(resultJSON), .optionalText(fence), .text(who), .date(date)])
        }
        return (id, box.version)
    }

    public func savedPatterns(caseID: UUID) async throws -> [CaseSavedPattern] {
        try await patternRows(caseID: caseID)
    }
}

final nonisolated class PatternVersionBox: @unchecked Sendable { var version = 1 }
