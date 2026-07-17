//
//  ConnectionFinderView.swift
//  Kalsmritikosh
//
//  "How are these two connected?" Pick two people/organizations and see the
//  shortest chain of relationships linking them — each hop with the document it
//  came from. Deterministic path over the evidence-backed graph; no model.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct ConnectionFinderView: View {
    @Environment(AppState.self) private var appState

    enum Mode: String, CaseIterable, Identifiable {
        case path = "How they link"
        case overlap = "Where they overlap"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .path
    @State private var entityA: EntitySummaryRow?
    @State private var entityB: EntitySummaryRow?
    @State private var connection: ResolvedConnection?
    @State private var comparison: EntityComparison?
    @State private var searching = false
    @State private var didRun = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect two entities")
                .font(.title3.bold())
            Text("Pick two people or organizations. See the shortest chain of relationships that links them, or the documents where they both appear — evidence either way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in connection = nil; comparison = nil; didRun = false }

            EntityPickerField(label: "First entity", selection: $entityA)
            EntityPickerField(label: "Second entity", selection: $entityB)

            Button {
                run()
            } label: {
                Label(mode == .path ? "Find the connection" : "Show shared documents",
                      systemImage: mode == .path ? "point.topleft.down.to.point.bottomright.curvepath" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(entityA == nil || entityB == nil || entityA?.id == entityB?.id || searching)

            Divider()

            if searching {
                ProgressView(mode == .path ? "Tracing the graph…" : "Intersecting the evidence…")
                    .frame(maxWidth: .infinity)
            } else if mode == .path, let connection {
                chain(connection)
            } else if mode == .overlap, let comparison {
                overlapView(comparison)
            } else if didRun {
                Label(mode == .path
                        ? "No connection found within 5 hops. They may be linked only through documents not yet ingested."
                        : "No document mentions both — they don't co-appear in the archive yet.",
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle("Connections")
    }

    // MARK: - Overlap mode

    private func overlapView(_ c: EntityComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                footprintCard(c.a)
                footprintCard(c.b)
            }
            Text(c.shared.isEmpty ? "No shared documents" : "\(c.shared.count) shared document(s) — both appear here")
                .font(.subheadline.weight(.semibold))
            List(c.shared) { doc in
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").foregroundStyle(Theme.brand)
                    Text(doc.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let date = doc.date {
                        Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                    if doc.url != nil {
                        Button {
                            #if canImport(AppKit)
                            if let u = doc.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            #endif
                        } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func footprintCard(_ f: EntityFootprint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(f.name).font(.headline).lineLimit(1)
            Text("\(f.mentionCount) mention(s)").font(.caption).foregroundStyle(.secondary)
            Text("\(f.documentCount) document(s)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }

    private func chain(_ c: ResolvedConnection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(c.hops.count) hop(s)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                ForEach(Array(c.nodes.enumerated()), id: \.offset) { idx, node in
                    nodeRow(node)
                    if idx < c.hops.count {
                        hopRow(c.hops[idx])
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func nodeRow(_ node: ConnectionNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: node.kind))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 7))
            Text(node.name).font(.headline)
            Spacer()
        }
    }

    private func hopRow(_ hop: ResolvedConnectionHop) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down")
                .foregroundStyle(Theme.brand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(hop.label).font(.subheadline.weight(.medium))
                if let file = hop.evidenceFilename {
                    Button {
                        openEvidence(hop)
                    } label: {
                        Label(file, systemImage: "doc.text")
                            .font(.caption).foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                    .help("Open the source document for this link")
                } else {
                    Text("evidence in the ledger").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.leading, 6)
        .padding(.vertical, 4)
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "person":                     return "person.fill"
        case "organization", "vendor", "client": return "building.2.fill"
        case "project":                    return "shippingbox.fill"
        default:                            return "circle.fill"
        }
    }

    private func run() {
        guard let a = entityA?.id, let b = entityB?.id else { return }
        searching = true
        Task {
            if mode == .path {
                let result = await appState.connectionPath(from: a, to: b)
                await MainActor.run { self.connection = result; self.searching = false; self.didRun = true }
            } else {
                let result = await appState.compareEntities(a: a, b: b)
                await MainActor.run { self.comparison = result; self.searching = false; self.didRun = true }
            }
        }
    }

    private func openEvidence(_ hop: ResolvedConnectionHop) {
        #if canImport(AppKit)
        guard let url = hop.evidenceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
