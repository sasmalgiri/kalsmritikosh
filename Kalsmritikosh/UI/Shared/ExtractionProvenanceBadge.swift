//
//  ExtractionProvenanceBadge.swift
//  Kalsmritikosh
//
//  Smart-map S2 / SRC-02 — the badge that tells an investigator what kind of text they are reading: the file's
//  original text, text recognised from an image (OCR), a transcription, a typed entry, an external service's output,
//  the investigator's own statement or generated text — with the reader, engine, version, coverage and extraction
//  time behind it. `ExtractionProvenanceBadgeLoader` reads the provenance of a cited passage from the ledger.
//

import SwiftUI
import os

/// The badge for a known provenance.
struct ExtractionProvenanceBadge: View {
    let provenance: ExtractionProvenance
    /// Show the detail lines (reader, engine, time, coverage) under the badge.
    var showsDetails = true

    init(provenance: ExtractionProvenance, showsDetails: Bool = true) {
        self.provenance = provenance; self.showsDetails = showsDetails
    }

    /// The badge for text that has no reader behind it: the investigator's statement, or generated text.
    init(kind: TextProvenanceKind, showsDetails: Bool = false) {
        self.provenance = .statement(kind); self.showsDetails = showsDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(provenance.kind.badge, systemImage: provenance.kind.symbol)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule())
                .foregroundStyle(tint)
                .help(provenance.kind.explanation)
                .accessibilityLabel("\(provenance.kind.badge). \(provenance.kind.explanation)")
            if showsDetails {
                ForEach(Array(provenance.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("source.provenance.badge")
    }

    private var tint: Color {
        switch provenance.kind {
        case .original: return .green
        case .recognized, .transcribed: return .orange
        case .entered, .external: return .blue
        case .interpretation, .generated: return .purple
        }
    }
}

/// Reads and shows the provenance of a cited passage (its block when known; else the passage of the version or
/// document that holds the quoted words; else the document as a whole). Shows nothing until it has read it; a
/// failed read says so instead of claiming original text.
struct ExtractionProvenanceBadgeLoader: View {
    @Environment(AppState.self) private var appState
    let objectID: UUID?
    var sourceVersionID: UUID? = nil
    var blockID: UUID? = nil
    var quote: String? = nil
    var showsDetails = true

    @State private var provenance: ExtractionProvenance?
    @State private var problem: String?

    private var key: String {
        [objectID?.uuidString, sourceVersionID?.uuidString, blockID?.uuidString, quote].map { $0 ?? "-" }.joined(separator: "|")
    }

    var body: some View {
        Group {
            if let provenance {
                ExtractionProvenanceBadge(provenance: provenance, showsDetails: showsDetails)
            } else if let problem {
                Label(problem, systemImage: "questionmark.diamond").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        guard let database = appState.database else { problem = "How these words were extracted is not available yet."; return }
        let repo = ExtractionProvenanceRepository(database: database)
        do {
            if let p = try await repo.provenance(objectID: objectID, sourceVersionID: sourceVersionID, blockID: blockID, quote: quote) {
                provenance = p; problem = nil
            } else {
                provenance = nil; problem = "How these words were extracted is not recorded."
            }
        } catch {
            KalsmritikoshLog.ui.error("Extraction provenance not read: \(error.localizedDescription, privacy: .public)")
            provenance = nil; problem = "How these words were extracted could not be read."
        }
    }
}
