//
//  EvidenceCanvasView.swift
//  Kalsmritikosh
//
//  LAB-009 — Evidence Canvas. A free-form board of claim cards where EVERY claim must be
//  backed by either evidence (≥1 supporting block/source) or an explicit user note — a
//  claim with neither is flagged, enforcing the product's "no unsupported claim" contract
//  at the composition surface. Presentational + deterministic; the parent supplies cards.
//

import SwiftUI

public struct EvidenceCanvasView: View {
    public struct ClaimCard: Identifiable, Sendable, Hashable {
        public let id: UUID
        public var statement: String
        public var evidenceCount: Int
        public var userNote: String?
        public nonisolated init(id: UUID = UUID(), statement: String,
                                evidenceCount: Int, userNote: String? = nil) {
            self.id = id; self.statement = statement
            self.evidenceCount = evidenceCount; self.userNote = userNote
        }
        /// The LAB-009 invariant: supported ⇔ has evidence OR a user note.
        public var isSupported: Bool { evidenceCount > 0 || !(userNote ?? "").isEmpty }
    }

    private let cards: [ClaimCard]
    public init(cards: [ClaimCard]) { self.cards = cards }

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cards) { card in cardView(card) }
                }
                .padding(12)
            }
        }
    }

    /// The header line. A note is the person's own reasoning, not evidence, so a canvas resting on notes
    /// is never summarised as "supported" (scope decision 2026-11-06); counts are stated plainly instead.
    public nonisolated static func headerSummary(_ cards: [ClaimCard]) -> (text: String, warning: Bool) {
        let unsupported = cards.filter { !$0.isSupported }.count
        let noteOnly = cards.filter { $0.evidenceCount == 0 && !($0.userNote ?? "").isEmpty }.count
        let cited = cards.filter { $0.evidenceCount > 0 }.count
        if unsupported > 0 { return ("\(unsupported) need evidence or a note", true) }
        if noteOnly > 0 { return ("\(cited) cite evidence · \(noteOnly) rest on your note only", true) }
        return ("\(cited) of \(cards.count) cite evidence", false)
    }

    private var header: some View {
        let summary = Self.headerSummary(cards)
        return HStack {
            Text("Evidence Canvas").font(.headline)
            Spacer()
            Label(summary.text, systemImage: summary.warning ? "exclamationmark.triangle.fill" : "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold)).foregroundStyle(summary.warning ? Color.orange : Color.secondary)
        }
        .padding(12)
    }

    private func cardView(_ card: ClaimCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.statement).font(.callout).lineLimit(4)
            Divider()
            if card.evidenceCount > 0 {
                Label("\(card.evidenceCount) evidence", systemImage: "doc.text.magnifyingglass")
                    .font(.caption2).foregroundStyle(.green)
            }
            if let note = card.userNote, !note.isEmpty {
                Label(note, systemImage: "pencil").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if !card.isSupported {
                Label("Needs evidence or a note", systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(card.isSupported ? Color.clear : Color.orange.opacity(0.6), lineWidth: 1)))
    }
}
