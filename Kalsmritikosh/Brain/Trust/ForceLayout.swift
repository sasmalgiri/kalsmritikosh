//
//  ForceLayout.swift
//  Kalsmritikosh
//
//  W3-3 — a small, deterministic force-directed layout (Fruchterman–Reingold)
//  for the relationship view. Deterministic: initial positions come from each
//  node's index on a circle, so the same graph always draws the same picture.
//

import Foundation
import CoreGraphics

public nonisolated enum ForceLayout {

    public static func layout(nodeCount n: Int, edges: [(Int, Int)], size: CGSize, iterations: Int = 200) -> [CGPoint] {
        guard n > 0 else { return [] }
        let w = Double(size.width), h = Double(size.height)
        let area = w * h
        let k = sqrt(area / Double(n))
        var pos = (0..<n).map { i -> (Double, Double) in
            let a = 2 * Double.pi * Double(i) / Double(n)
            return (w / 2 + cos(a) * w / 3, h / 2 + sin(a) * h / 3)
        }
        var temperature = w / 10
        for _ in 0..<iterations {
            var disp = Array(repeating: (0.0, 0.0), count: n)
            // Speed PERF-31 (owner 2026-11-23) — not tested yet. Above 200 nodes the repulsion is approximated with a
            // Barnes–Hut quadtree (θ = 0.8): O(n log n) a step instead of O(n²). Small graphs keep the exact sum, so
            // they draw the same picture as before.
            if n > barnesHutThreshold {
                let tree = QuadTree(points: pos)
                for i in 0..<n {
                    let f = tree.repulsion(on: pos[i], index: i, k2: k * k, theta: 0.8)
                    disp[i].0 += f.0; disp[i].1 += f.1
                }
            } else {
            for i in 0..<n {
                for j in (i + 1)..<max(i + 1, n) where j < n {
                    let dx = pos[i].0 - pos[j].0, dy = pos[i].1 - pos[j].1
                    let d = max(0.01, sqrt(dx * dx + dy * dy))
                    let f = k * k / d
                    disp[i].0 += dx / d * f; disp[i].1 += dy / d * f
                    disp[j].0 -= dx / d * f; disp[j].1 -= dy / d * f
                }
            }
            }
            for (a, b) in edges where a < n && b < n && a != b {
                let dx = pos[a].0 - pos[b].0, dy = pos[a].1 - pos[b].1
                let d = max(0.01, sqrt(dx * dx + dy * dy))
                let f = d * d / k
                disp[a].0 -= dx / d * f; disp[a].1 -= dy / d * f
                disp[b].0 += dx / d * f; disp[b].1 += dy / d * f
            }
            for i in 0..<n {
                let d = max(0.01, sqrt(disp[i].0 * disp[i].0 + disp[i].1 * disp[i].1))
                pos[i].0 += disp[i].0 / d * min(d, temperature)
                pos[i].1 += disp[i].1 / d * min(d, temperature)
                pos[i].0 = min(w - 20, max(20, pos[i].0))
                pos[i].1 = min(h - 20, max(20, pos[i].1))
            }
            temperature *= 0.97
        }
        return pos.map { CGPoint(x: $0.0, y: $0.1) }
    }

    /// Node count above which the repulsion uses the quadtree.
    static let barnesHutThreshold = 200

    /// Speed PERF-31 (owner 2026-11-23) — not tested yet. A point quadtree with each cell's count and centre of mass,
    /// in flat arrays (no per-node allocation). A cell far enough away (size / distance < θ) acts as one body.
    struct QuadTree {
        private var minX: [Double] = [], minY: [Double] = [], size: [Double] = []
        private var count: [Int] = [], cx: [Double] = [], cy: [Double] = []
        private var child: [Int] = []      // 4 per cell; -1 none
        private var point: [Int] = []      // the one point of a leaf (-1 none)
        private let pts: [(Double, Double)]

        init(points: [(Double, Double)]) {
            pts = points
            var lo = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude), hi = (-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            for p in points { lo = (min(lo.0, p.0), min(lo.1, p.1)); hi = (max(hi.0, p.0), max(hi.1, p.1)) }
            let side = max(1, max(hi.0 - lo.0, hi.1 - lo.1)) * 1.0001
            _ = newCell(lo.0, lo.1, side)
            for i in points.indices { insert(i, cell: 0, depth: 0) }
        }

        private mutating func newCell(_ x: Double, _ y: Double, _ s: Double) -> Int {
            minX.append(x); minY.append(y); size.append(s); count.append(0); cx.append(0); cy.append(0)
            child.append(contentsOf: [-1, -1, -1, -1]); point.append(-1)
            return size.count - 1
        }

        private func quadrant(_ cell: Int, _ p: (Double, Double)) -> Int {
            let half = size[cell] / 2
            return (p.0 >= minX[cell] + half ? 1 : 0) + (p.1 >= minY[cell] + half ? 2 : 0)
        }

        private mutating func childCell(_ cell: Int, _ q: Int) -> Int {
            if child[cell * 4 + q] >= 0 { return child[cell * 4 + q] }
            let half = size[cell] / 2
            let c = newCell(minX[cell] + (q & 1 == 1 ? half : 0), minY[cell] + (q & 2 == 2 ? half : 0), half)
            child[cell * 4 + q] = c
            return c
        }

        private mutating func insert(_ i: Int, cell: Int, depth: Int) {
            let p = pts[i]
            let n = Double(count[cell])
            cx[cell] = (cx[cell] * n + p.0) / (n + 1); cy[cell] = (cy[cell] * n + p.1) / (n + 1)
            count[cell] += 1
            if count[cell] == 1 { point[cell] = i; return }
            // Coincident points (or very deep cells) stay together as one body.
            guard depth < 40 else { return }
            if point[cell] >= 0 {
                let old = point[cell]; point[cell] = -1
                let oc = childCell(cell, quadrant(cell, pts[old]))
                insert(old, cell: oc, depth: depth + 1)
            }
            let c = childCell(cell, quadrant(cell, p))
            insert(i, cell: c, depth: depth + 1)
        }

        /// The repulsive displacement on `p` (node `index`) from every other node, k²/d along the line between them.
        func repulsion(on p: (Double, Double), index: Int, k2: Double, theta: Double) -> (Double, Double) {
            var fx = 0.0, fy = 0.0
            var stack = [0]
            while let cell = stack.popLast() {
                guard count[cell] > 0 else { continue }
                if count[cell] == 1 && point[cell] == index { continue }
                let dx = p.0 - cx[cell], dy = p.1 - cy[cell]
                let d = max(0.01, sqrt(dx * dx + dy * dy))
                let leaf = point[cell] >= 0 || (child[cell * 4] < 0 && child[cell * 4 + 1] < 0 && child[cell * 4 + 2] < 0 && child[cell * 4 + 3] < 0)
                if leaf || size[cell] / d < theta {
                    // A leaf holding this node among coincident ones counts the others only.
                    var m = Double(count[cell])
                    if leaf, point[cell] == index { m -= 1 }
                    let f = k2 / d * m
                    fx += dx / d * f; fy += dy / d * f
                } else {
                    for q in 0..<4 where child[cell * 4 + q] >= 0 { stack.append(child[cell * 4 + q]) }
                }
            }
            return (fx, fy)
        }
    }
}
