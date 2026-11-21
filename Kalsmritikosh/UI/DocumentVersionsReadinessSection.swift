//
//  DocumentVersionsReadinessSection.swift
//  Kalsmritikosh
//
//  Unified path IN-19 (owner 2026-11-22) — not tested yet. In the document inspector (the expanded
//  row in Sources): the document's versions (canonical and legacy, one list) and the readiness
//  history of its current version.
//

import SwiftUI

struct DocumentVersionsReadinessSection: View {
    @Environment(AppState.self) private var appState
    let objectID: KnowledgeObject.ID
    @State private var versions: [SourceVersionView] = []
    @State private var events: [SourceReadinessLedgerInspector.EventRow] = []
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !versions.isEmpty {
                Text("VERSIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(versions.prefix(8)) { v in
                    HStack(spacing: 6) {
                        Text(v.validFrom.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit())
                        if v.isCurrent { Text("current").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                        if v.origin == .legacy {
                            Text("older record, less certain").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(v.contentHash.prefix(10))).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            .help("The start of this version's content fingerprint")
                    }
                }
            }
            if !events.isEmpty {
                DisclosureGroup("Readiness history (\(events.count) step\(events.count == 1 ? "" : "s"))", isExpanded: $showHistory) {
                    ForEach(events, id: \.sequence) { e in
                        Text("\(e.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(e.dimension.rawValue): \(e.fromState.map { "\($0.rawValue) → " } ?? "")\(e.toState.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .task(id: objectID) {
            versions = await appState.documentVersions(objectID: objectID)
            events = await appState.readinessHistory(objectID: objectID)
        }
    }
}
