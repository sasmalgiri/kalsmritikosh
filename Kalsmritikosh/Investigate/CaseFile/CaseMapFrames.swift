//
//  CaseMapFrames.swift
//  Kalsmritikosh
//
//  Smart-map M1 (ARCH-03, GRAPH-01, GRAPH-02, GRAPH-03; plan 2026-11-08 §5.1–§5.2, SM-02): recursive frames.
//  A frame is a navigable focus on ANY canonical record of the case — a report, a point, a question, an action, a
//  person, an event, a document. Its members are the record's typed relationships in the case projection: what it is
//  read from, what was taken from it, the questions and work raised from it, the results returned to it. A frame is a
//  PROJECTION: it holds identities only, never a copy of a record, so an edit to a record shows in every frame that
//  holds it. Each frame keeps its own positions (case_map_layout.frame_key) — one record, several appearances.
//
//  • No depth limit: any member can be opened as the next frame, and so on.
//  • Cycle-safe: investigative relationships may form cycles; traversal never visits a record twice.
//  • Explicit budgets: a frame lists its members a page at a time, and a traversal stops at a stated budget with a
//    continuation (the records it reached but did not expand) — a limit never silently drops a record.
//

import Foundation

/// One member of a frame: a related record, how it relates to the anchor, and the link that says so.
public nonisolated struct CaseMapFrameMember: Hashable, Sendable {
    public let node: CaseMapNodeID
    /// The link this membership comes from (its provenance: origins, sources, who asserted it).
    public let linkID: String
    public let type: CaseMapLinkType
    /// True when the link runs from the anchor to the member.
    public let outgoing: Bool
    /// "Taken from it", "Raised from here", … — the relation as the person reads it.
    public let relation: String
}

/// A frame over one anchor record.
public nonisolated struct CaseMapFrame: Hashable, Sendable {
    public let anchor: CaseMapNodeID
    /// Members in a stable order (relation, then identity) — the same records in any read order give the same frame.
    public let members: [CaseMapFrameMember]
    /// The frame's key for its own positions: the anchor's identity key.
    public var key: String { CaseMapFrames.key(anchor) }
    /// Each related record once (a record related in two ways is one appearance), in member order.
    public var memberIDs: [CaseMapNodeID] {
        var seen = Set<CaseMapNodeID>()
        return members.map(\.node).filter { seen.insert($0).inserted }
    }
    public func contains(_ id: CaseMapNodeID) -> Bool { id == anchor || members.contains { $0.node == id } }

    /// One page of members and how many follow (the frame never drops a member; it pages them).
    public func page(offset: Int, limit: Int) -> (members: [CaseMapFrameMember], remaining: Int) {
        let start = max(0, min(offset, members.count))
        let end = min(members.count, start + max(0, limit))
        return (Array(members[start..<end]), members.count - end)
    }
}

/// The result of a budgeted traversal: every record reached (with its depth), and what was reached but not expanded.
public nonisolated struct CaseMapTraversal: Sendable, Equatable {
    public let depth: [CaseMapNodeID: Int]
    /// Records reached at the budget's edge, not yet expanded — continue from here; nothing was lost.
    public let continuation: [CaseMapNodeID]
    public var exhausted: Bool { continuation.isEmpty }
}

public nonisolated enum CaseMapFrames {
    /// Members of a frame shown before "Show more" (a page, not a cap).
    public static let pageSize = 200

    /// The frame key of an anchor (the root frame of the case map is "").
    public static func key(_ anchor: CaseMapNodeID) -> String { anchor.key }

    /// How a member reads from the anchor's side.
    static func relation(_ type: CaseMapLinkType, outgoing: Bool) -> String {
        switch (type, outgoing) {
        case (.derivedFrom, true): return "Taken from"
        case (.derivedFrom, false): return "Taken from this or raised from it"
        case (.receivedInResponseTo, true): return "Result of"
        case (.receivedInResponseTo, false): return "Results returned"
        case (.requestsEvidenceFor, true): return "Work for"
        case (.requestsEvidenceFor, false): return "Work serving this"
        case (.supersedes, true): return "Replaces"
        case (.supersedes, false): return "Replaced by"
        default: return (outgoing ? "→ " : "← ") + type.label
        }
    }

    /// The frame over `anchor`: its typed relationships in the projection. Nil when the record is not in the case.
    public static func frame(of anchor: CaseMapNodeID, in p: CaseMapProjection) -> CaseMapFrame? {
        guard p.node(anchor) != nil else { return nil }
        var seen = Set<String>()
        var members: [CaseMapFrameMember] = []
        for l in p.links(of: anchor) {
            let outgoing = l.from == anchor
            let other = outgoing ? l.to : l.from
            guard other != anchor, p.node(other) != nil else { continue }
            // One membership per record and relation (two links of the same type to one record are one appearance).
            let rel = relation(l.type, outgoing: outgoing)
            guard seen.insert("\(other.key)|\(rel)").inserted else { continue }
            members.append(CaseMapFrameMember(node: other, linkID: l.id, type: l.type, outgoing: outgoing, relation: rel))
        }
        members.sort { a, b in a.relation != b.relation ? a.relation < b.relation : (a.node != b.node ? a.node < b.node : a.linkID < b.linkID) }
        return CaseMapFrame(anchor: anchor, members: members)
    }

    /// Breadth-first through typed relationships from `start`, cycle-safe (each record once), with no depth limit and an
    /// explicit budget of records expanded. What the budget did not reach is returned as the continuation.
    public static func traverse(from start: CaseMapNodeID, in p: CaseMapProjection, budget: Int) -> CaseMapTraversal {
        guard p.node(start) != nil else { return CaseMapTraversal(depth: [:], continuation: []) }
        var depth: [CaseMapNodeID: Int] = [start: 0]
        var queue: [CaseMapNodeID] = [start]
        var head = 0
        var expanded = 0
        while head < queue.count, expanded < max(0, budget) {
            let id = queue[head]; head += 1
            expanded += 1
            let d = depth[id] ?? 0
            let next = p.links(of: id).map { $0.from == id ? $0.to : $0.from }.filter { p.node($0) != nil }.sorted()
            for n in next where depth[n] == nil {
                depth[n] = d + 1
                queue.append(n)
            }
        }
        return CaseMapTraversal(depth: depth, continuation: Array(queue[head...]))
    }

    /// What a frame view shows: the anchor and its members (that match the Find words), the links among them, and the
    /// same honest counts as every view (shown + filtered = the frame).
    public static func viewResult(_ frame: CaseMapFrame, in p: CaseMapProjection, search: String, hidden: Set<CaseMapNodeID> = []) -> CaseMapViewResult {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var shown: [CaseMapNodeID] = []
        var filtered = 0, hiddenCount = 0
        for id in [frame.anchor] + frame.memberIDs {
            guard let n = p.node(id) else { continue }
            if id != frame.anchor, !words.isEmpty {
                let hay = (n.title + " " + (n.wording ?? "") + " " + n.status.text).lowercased()
                if !words.allSatisfy({ hay.contains($0) }) { filtered += 1; continue }
            }
            if id != frame.anchor, hidden.contains(id) { hiddenCount += 1; continue }
            shown.append(id)
        }
        let set = Set(shown)
        let links = p.links.filter { set.contains($0.from) && set.contains($0.to) }.map(\.id)
        return CaseMapViewResult(shown: shown, collapsedGroups: [], links: links,
                                 counts: CaseMapCounts(total: 1 + frame.memberIDs.count, shown: shown.count, collapsed: 0, filtered: filtered,
                                                       hidden: hiddenCount, notLoaded: p.failedParts))
    }
}

nonisolated extension CaseMapLayout {
    /// Positions for a frame: the anchor at the centre, members in rings around it grouped by relation, each from the
    /// member's stable seed. Stored positions (and pins) are kept; only members without one are placed.
    public static func placeFrame(_ frame: CaseMapFrame, existing: [CaseMapNodeID: CaseMapPlacement]) -> [CaseMapNodeID: CaseMapPlacement] {
        var out = existing
        if out[frame.anchor] == nil { out[frame.anchor] = CaseMapPlacement(point: CaseMapPoint(x: 0, y: 0)) }
        let centre = out[frame.anchor]?.point ?? CaseMapPoint(x: 0, y: 0)
        var taken = OccupancyGrid(out.values.map(\.point))
        let missing = frame.memberIDs.filter { out[$0] == nil }
        var ringIndex = 0
        var placed = 0
        while placed < missing.count, ringIndex < 400 {
            let radius = ring + Double(ringIndex) * 115
            let slots = max(6, Int((2 * .pi * radius) / (nodeWidth * 0.75)))
            let start = angle(frame.anchor)
            for k in 0..<slots where placed < missing.count {
                let t = start + Double(k) / Double(slots) * 2 * .pi
                let c = CaseMapPoint(x: (centre.x + cos(t) * radius * 1.3).rounded(), y: (centre.y + sin(t) * radius).rounded())
                if taken.isFree(c) { out[missing[placed]] = CaseMapPlacement(point: c); taken.insert(c); placed += 1 }
            }
            ringIndex += 1
        }
        // Anything the rings could not hold goes in a column beside them (never dropped).
        var y = centre.y
        let x = (out.values.map(\.point.x).max() ?? centre.x) + nodeWidth + 120
        for id in missing where out[id] == nil {
            var c = CaseMapPoint(x: x, y: y)
            while !taken.isFree(c) { c.y += nodeHeight + 30 }
            out[id] = CaseMapPlacement(point: c); taken.insert(c); y = c.y + nodeHeight + 30
        }
        return out
    }

    /// The viewport at the same zoom that puts `point` in the middle of a view of this size.
    public static func centred(on point: CaseMapPoint, current: CaseMapViewport, width: Double, height: Double) -> CaseMapViewport {
        let s = max(current.scale, 0.01)
        return CaseMapViewport(scale: current.scale, originX: point.x - width / s / 2, originY: point.y - height / s / 2)
    }
}
