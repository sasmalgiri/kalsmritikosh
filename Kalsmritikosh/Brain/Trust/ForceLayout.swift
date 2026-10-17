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
            for i in 0..<n {
                for j in (i + 1)..<max(i + 1, n) where j < n {
                    let dx = pos[i].0 - pos[j].0, dy = pos[i].1 - pos[j].1
                    let d = max(0.01, sqrt(dx * dx + dy * dy))
                    let f = k * k / d
                    disp[i].0 += dx / d * f; disp[i].1 += dy / d * f
                    disp[j].0 -= dx / d * f; disp[j].1 -= dy / d * f
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
}
