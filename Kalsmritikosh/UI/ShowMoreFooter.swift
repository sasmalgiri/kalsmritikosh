//
//  ShowMoreFooter.swift
//  Kalsmritikosh
//
//  Speed PERF-31 (owner 2026-11-23) — not tested yet. Long lists on the Insights, Fact status and Highlights screens
//  draw a page of rows at a time; this footer says how many are shown of how many and shows the next page. Nothing is
//  hidden silently: the count of the rest is always on screen.
//

import SwiftUI

struct ShowMoreFooter: View {
    let total: Int
    @Binding var shown: Int
    var page: Int = ShowMoreFooter.pageSize

    nonisolated static let pageSize = 200

    var body: some View {
        if total > shown {
            HStack(spacing: 8) {
                Text("Showing \(shown) of \(total).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show \(min(page, total - shown)) more") { shown += page }
                    .buttonStyle(.borderless).font(.caption)
                Button("Show all") { shown = total }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.vertical, 4)
        }
    }
}
