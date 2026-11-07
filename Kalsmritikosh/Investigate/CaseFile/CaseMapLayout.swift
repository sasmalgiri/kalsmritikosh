//
//  CaseMapLayout.swift
//  Kalsmritikosh
//
//  Living case map, M3 (plan §6.2): stable positions in WORLD coordinates (independent of the window).
//  • The first layout groups items by question: each question (the case's own, each allegation) and each
//    hypothesis is an anchor; what links to an anchor sits in rings around it; the rest waits in bands below.
//    Every offset is seeded from the item's stable identity (FNV-1a of its key), never from row order.
//  • A refresh places ONLY new items — near an item they link to, else in an arrivals area beside the map.
//    Existing and pinned positions never move on refresh.
//  • "Arrange" re-lays a stated scope (the selection's branch or the whole view) around where it already
//    is; pinned items stay. The caller keeps the previous positions for Undo.
//  No force simulation runs here (the quadratic ForceLayout is not used on refresh).
//

import Foundation

public nonisolated struct CaseMapPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    func distance(to o: CaseMapPoint) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}

public nonisolated struct CaseMapRect: Equatable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) { self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: CaseMapPoint { CaseMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    public func contains(_ p: CaseMapPoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    public func insetBy(_ d: Double) -> CaseMapRect { CaseMapRect(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d) }
}

/// The visible window onto the world: scale and the world point at the view's top-left.
public nonisolated struct CaseMapViewport: Codable, Equatable, Sendable {
    public var scale: Double
    public var originX: Double
    public var originY: Double
    public init(scale: Double = 1, originX: Double = -60, originY: Double = -60) { self.scale = scale; self.originX = originX; self.originY = originY }
    public func toScreen(_ p: CaseMapPoint) -> (x: Double, y: Double) { ((p.x - originX) * scale, (p.y - originY) * scale) }
    public func toWorld(x: Double, y: Double) -> CaseMapPoint { CaseMapPoint(x: x / scale + originX, y: y / scale + originY) }
    public func worldRect(width: Double, height: Double) -> CaseMapRect {
        CaseMapRect(minX: originX, minY: originY, maxX: originX + width / max(scale, 0.01), maxY: originY + height / max(scale, 0.01))
    }
    public static let minScale = 0.15
    public static let maxScale = 3.0
}

public nonisolated enum CaseMapLayout {
    /// The size of one item on the map, in world units.
    public static let nodeWidth = 180.0
    public static let nodeHeight = 54.0
    static let anchorGap = 620.0
    static let ring = 150.0
    static let minGap = 80.0

    /// A deterministic seed from the item's stable identity (FNV-1a over its key; not Swift's hashValue).
    public static func seed(_ id: CaseMapNodeID) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.key.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
    static func angle(_ id: CaseMapNodeID) -> Double { Double(seed(id) % 3600) / 3600 * 2 * .pi }

    /// The anchors of the first layout: questions (the case first), then hypotheses.
    static func anchors(_ p: CaseMapProjection) -> [CaseMapNodeID] {
        let questions = p.nodes.filter { $0.kind == .question }.map(\.id).sorted { a, b in
            if (a.kind == .caseFile) != (b.kind == .caseFile) { return a.kind == .caseFile }
            return a < b
        }
        return questions + p.nodes.filter { $0.kind == .hypothesis }.map(\.id)
    }

    /// For each non-anchor item, the anchor it is placed around: the first anchor (in anchor order) it links
    /// to directly, else through one item. Nil: it waits in a band below.
    static func owners(_ p: CaseMapProjection, anchors: [CaseMapNodeID]) -> [CaseMapNodeID: CaseMapNodeID] {
        let rank = Dictionary(uniqueKeysWithValues: anchors.enumerated().map { ($1, $0) })
        var neighbours: [CaseMapNodeID: Set<CaseMapNodeID>] = [:]
        for l in p.links { neighbours[l.from, default: []].insert(l.to); neighbours[l.to, default: []].insert(l.from) }
        // The best (lowest-rank) anchor among each item's own neighbours, computed once; the second hop is then
        // the best of the neighbours' best (the same answer as scanning every neighbour's neighbours, M9 §13.3).
        var bestAnchorNeighbour: [CaseMapNodeID: CaseMapNodeID] = [:]
        for (id, set) in neighbours {
            if let best = set.filter({ rank[$0] != nil }).min(by: { rank[$0, default: .max] < rank[$1, default: .max] }) { bestAnchorNeighbour[id] = best }
        }
        var out: [CaseMapNodeID: CaseMapNodeID] = [:]
        for n in p.nodes where rank[n.id] == nil {
            if let direct = bestAnchorNeighbour[n.id] { out[n.id] = direct; continue }
            let second = (neighbours[n.id] ?? []).compactMap { bestAnchorNeighbour[$0] }.min { rank[$0, default: .max] < rank[$1, default: .max] }
            if let second { out[n.id] = second }
        }
        return out
    }

    /// The first layout of a case (nothing stored yet).
    public static func initial(_ p: CaseMapProjection) -> [CaseMapNodeID: CaseMapPoint] {
        arrange(Set(p.nodes.map(\.id)), in: p, around: CaseMapPoint(x: 0, y: 0), fixed: [:])
    }

    /// Lay out `scope` grouped by question, starting at `origin`, avoiding the `fixed` positions.
    static func arrange(_ scope: Set<CaseMapNodeID>, in p: CaseMapProjection, around origin: CaseMapPoint,
                        fixed: [CaseMapNodeID: CaseMapPoint]) -> [CaseMapNodeID: CaseMapPoint] {
        let allAnchors = anchors(p)
        let anchorList = allAnchors.filter { scope.contains($0) }
        let owner = owners(p, anchors: allAnchors)
        var out: [CaseMapNodeID: CaseMapPoint] = [:]
        var taken = OccupancyGrid(fixed.values)
        func free(_ c: CaseMapPoint) -> Bool { taken.isFree(c) }
        func put(_ id: CaseMapNodeID, _ c: CaseMapPoint) { out[id] = c; taken.insert(c) }
        for (i, a) in anchorList.enumerated() { put(a, CaseMapPoint(x: origin.x + Double(i) * anchorGap, y: origin.y)) }
        // Members around their anchor, in rings, ordered by identity; the angle comes from the anchor's seed.
        var members: [CaseMapNodeID: [CaseMapNodeID]] = [:]
        var loose: [CaseMapNodeID] = []
        for id in scope.sorted() where out[id] == nil {
            if let o = owner[id], out[o] != nil || fixed[o] != nil { members[o, default: []].append(id) } else { loose.append(id) }
        }
        for (a, list) in members.sorted(by: { $0.key < $1.key }) {
            guard let centre = out[a] ?? fixed[a] else { loose += list; continue }
            let start = angle(a)
            var placed = 0
            var ringIndex = 0
            while placed < list.count {
                let radius = ring + Double(ringIndex) * 115
                let slots = max(6, Int((2 * .pi * radius) / (nodeWidth * 0.75)))
                for k in 0..<slots where placed < list.count {
                    let t = start + Double(k) / Double(slots) * 2 * .pi
                    let c = CaseMapPoint(x: (centre.x + cos(t) * radius * 1.3).rounded(), y: (centre.y + sin(t) * radius).rounded())
                    if free(c) { put(list[placed], c); placed += 1 }
                }
                ringIndex += 1
                if ringIndex > 60 { break }
            }
            if placed < list.count { loose += list[placed...] }
        }
        // Everything else in bands below, one band per kind.
        let bandTop = (out.values.map(\.y) + fixed.values.map(\.y)).max().map { $0 + 260 } ?? origin.y + 260
        let byKind = Dictionary(grouping: loose) { id in p.node(id)?.kind ?? .evidence }
        var row = 0
        for kind in CaseMapNodeKind.allCases {
            guard let list = byKind[kind]?.sorted() else { continue }
            for (i, id) in list.enumerated() {
                var c = CaseMapPoint(x: origin.x + Double(i % 6) * (nodeWidth + 30), y: bandTop + Double(row + i / 6) * (nodeHeight + 46))
                while !free(c) { c.y += nodeHeight + 46 }
                put(id, c)
            }
            row += (list.count + 5) / 6 + 1
        }
        return out
    }

    /// Positions for items that have none yet. Existing (and pinned) positions are returned unchanged.
    public static func placeNew(_ p: CaseMapProjection, existing: [CaseMapNodeID: CaseMapPlacement]) -> [CaseMapNodeID: CaseMapPlacement] {
        var out = existing
        let missing = p.nodes.map(\.id).filter { existing[$0] == nil }
        guard !missing.isEmpty else { return out }
        if existing.isEmpty {
            for (id, point) in initial(p) { out[id] = CaseMapPlacement(point: point) }
            return out
        }
        var neighbours: [CaseMapNodeID: [CaseMapNodeID]] = [:]
        for l in p.links { neighbours[l.from, default: []].append(l.to); neighbours[l.to, default: []].append(l.from) }
        var taken = OccupancyGrid(out.values.map(\.point))
        func free(_ c: CaseMapPoint) -> Bool { taken.isFree(c) }
        let bounds = Self.bounds(of: out.values.map(\.point)) ?? CaseMapRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        var arrivals = 0
        for id in missing.sorted() {
            // Near a placed item it links to (the first by identity), else in the arrivals column.
            let anchor = (neighbours[id] ?? []).filter { out[$0] != nil }.min()
            var placed: CaseMapPoint?
            if let anchor, let centre = out[anchor]?.point {
                let start = angle(id)
                outer: for ringIndex in 0..<8 {
                    let radius = 130 + Double(ringIndex) * 90
                    for k in 0..<16 {
                        let t = start + Double(k) / 16 * 2 * .pi
                        let c = CaseMapPoint(x: (centre.x + cos(t) * radius * 1.3).rounded(), y: (centre.y + sin(t) * radius).rounded())
                        if free(c) { placed = c; break outer }
                    }
                }
            }
            if placed == nil {
                var c = CaseMapPoint(x: bounds.maxX + nodeWidth + 120, y: bounds.minY + Double(arrivals) * (nodeHeight + 30))
                while !free(c) { c.y += nodeHeight + 30 }
                placed = c
                arrivals += 1
            }
            if let c = placed { out[id] = CaseMapPlacement(point: c); taken.insert(c) }
        }
        return out
    }

    /// "Arrange": re-lay the scope (minus pinned items) around its current centre. Everything outside the
    /// scope, and every pinned item, keeps its position. Returns only the positions that change.
    public static func arrangeScope(_ scope: Set<CaseMapNodeID>, in p: CaseMapProjection,
                                    current: [CaseMapNodeID: CaseMapPlacement]) -> [CaseMapNodeID: CaseMapPoint] {
        let movable = scope.filter { current[$0]?.pinned != true && p.node($0) != nil }
        guard !movable.isEmpty else { return [:] }
        let fixed = current.filter { !movable.contains($0.key) }.mapValues(\.point)
        let pts = movable.compactMap { current[$0]?.point }
        let centre = bounds(of: pts).map { CaseMapPoint(x: $0.minX, y: $0.minY) } ?? CaseMapPoint(x: 0, y: 0)
        return arrange(movable, in: p, around: centre, fixed: fixed)
    }

    public static func bounds(of points: [CaseMapPoint]) -> CaseMapRect? {
        guard let first = points.first else { return nil }
        var r = CaseMapRect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points.dropFirst() { r.minX = min(r.minX, p.x); r.minY = min(r.minY, p.y); r.maxX = max(r.maxX, p.x); r.maxY = max(r.maxY, p.y) }
        return CaseMapRect(minX: r.minX - nodeWidth / 2, minY: r.minY - nodeHeight / 2, maxX: r.maxX + nodeWidth / 2, maxY: r.maxY + nodeHeight / 2)
    }

    /// Where a collapsed group's card is drawn: the slot of the member nearest the centre of the group. The centre
    /// itself can fall on a visible item of another group (UI walk 2026-11-07: "Events — 4 (collapsed)" drawn over a
    /// contradiction); a member's own slot is free while the group is collapsed, because the layout never puts two
    /// items on one slot and the members are not drawn.
    public static func groupCardPoint(_ memberPoints: [CaseMapPoint]) -> CaseMapPoint? {
        guard let b = bounds(of: memberPoints) else { return nil }
        let c = b.center
        return memberPoints.min { l, r in
            let dl = (l.x - c.x) * (l.x - c.x) + (l.y - c.y) * (l.y - c.y)
            let dr = (r.x - c.x) * (r.x - c.x) + (r.y - c.y) * (r.y - c.y)
            return dl != dr ? dl < dr : (l.x, l.y) < (r.x, r.y)
        }
    }

    /// The viewport that fits the given world bounds into a view of this size (fit = the actual bounds).
    public static func fit(_ rect: CaseMapRect, width: Double, height: Double, margin: Double = 40) -> CaseMapViewport {
        let r = rect.insetBy(margin)
        let wanted = min(width / max(r.width, 1), height / max(r.height, 1))
        let scale = min(CaseMapViewport.maxScale, max(CaseMapViewport.minScale, wanted))
        // Too large to fit even at the smallest zoom: centring would land on the empty middle of the grouped
        // layout (walk/perf 2026-11-07: 0 drawn at 50,000 records). Show the start of the map instead; the
        // off-screen count and the list still disclose and reach the rest.
        if wanted < CaseMapViewport.minScale {
            return CaseMapViewport(scale: scale, originX: r.minX, originY: r.minY)
        }
        let ox = r.center.x - width / scale / 2
        let oy = r.center.y - height / scale / 2
        return CaseMapViewport(scale: scale, originX: ox, originY: oy)
    }

    /// Bounded rendering: the items inside the visible world rectangle, at most `cap` of them (identity
    /// order), and how many visible items the cap held back. The caller says so on screen.
    public static func cull(_ ids: [CaseMapNodeID], positions: [CaseMapNodeID: CaseMapPlacement], in rect: CaseMapRect,
                            cap: Int) -> (drawn: [CaseMapNodeID], offScreen: Int, overCap: Int) {
        let margin = rect.insetBy(nodeWidth)
        var inside: [CaseMapNodeID] = []
        var off = 0
        for id in ids {
            guard let p = positions[id]?.point else { off += 1; continue }
            if margin.contains(p) { inside.append(id) } else { off += 1 }
        }
        if inside.count <= cap { return (inside, off, 0) }
        return (Array(inside.sorted().prefix(cap)), off, inside.count - cap)
    }

    /// M9 (§13.3) — the taken positions bucketed into cells of `minGap`, so "is this spot at least `minGap` from
    /// every taken position?" looks at the nine cells around it instead of every position (the same answer:
    /// a point closer than `minGap` is always in a neighbouring cell). Placement was quadratic without it.
    struct OccupancyGrid {
        private var cells: [Cell: [CaseMapPoint]] = [:]
        private struct Cell: Hashable { let x: Int; let y: Int }
        private static func cell(_ p: CaseMapPoint) -> Cell { Cell(x: Int((p.x / CaseMapLayout.minGap).rounded(.down)), y: Int((p.y / CaseMapLayout.minGap).rounded(.down))) }
        init<S: Sequence>(_ points: S) where S.Element == CaseMapPoint { for p in points { insert(p) } }
        mutating func insert(_ p: CaseMapPoint) { cells[Self.cell(p), default: []].append(p) }
        func isFree(_ c: CaseMapPoint) -> Bool {
            let k = Self.cell(c)
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let pts = cells[Cell(x: k.x + dx, y: k.y + dy)] else { continue }
                    for p in pts where p.distance(to: c) < CaseMapLayout.minGap { return false }
                }
            }
            return true
        }
    }

    /// The item under a world point (topmost = last in draw order), if any.
    public static func hit(_ point: CaseMapPoint, ids: [CaseMapNodeID], positions: [CaseMapNodeID: CaseMapPlacement]) -> CaseMapNodeID? {
        ids.reversed().first { id in
            guard let c = positions[id]?.point else { return false }
            return abs(point.x - c.x) <= nodeWidth / 2 && abs(point.y - c.y) <= nodeHeight / 2
        }
    }
}
