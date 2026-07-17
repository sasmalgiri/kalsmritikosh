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

    @State private var entityA: EntitySummaryRow?
    @State private var entityB: EntitySummaryRow?
    @State private var connection: ResolvedConnection?
    @State private var searching = false
    @State private var didRun = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How are these connected?")
                .font(.title3.bold())
            Text("Pick two people or organizations. The app finds the shortest chain of relationships between them — every hop backed by a document.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            EntityPickerField(label: "First entity", selection: $entityA)
            EntityPickerField(label: "Second entity", selection: $entityB)

            Button {
                run()
            } label: {
                Label("Find the connection", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(entityA == nil || entityB == nil || entityA?.id == entityB?.id || searching)

            Divider()

            if searching {
                ProgressView("Tracing the graph…").frame(maxWidth: .infinity)
            } else if let connection {
                chain(connection)
            } else if didRun {
                Label("No connection found within 5 hops. They may be linked only through documents not yet ingested.",
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle("Connections")
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
            let result = await appState.connectionPath(from: a, to: b)
            await MainActor.run {
                self.connection = result
                self.searching = false
                self.didRun = true
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

/// A small type-to-search entity picker: shows matches as you type; picking one
/// collapses to a chip you can clear.
private struct EntityPickerField: View {
    @Environment(AppState.self) private var appState
    let label: String
    @Binding var selection: EntitySummaryRow?
    @State private var query = ""
    @State private var matches: [EntitySummaryRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let sel = selection {
                HStack(spacing: 8) {
                    Text(sel.value).font(.body.weight(.medium))
                    Spacer()
                    Button { selection = nil; query = ""; matches = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            } else {
                TextField("Search people or organizations…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, q in Task { await search(q) } }
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches.prefix(6)) { row in
                            Button {
                                selection = row; matches = []; query = ""
                            } label: {
                                HStack {
                                    Text(row.value).font(.callout)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func search(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let entities = appState.entities else { matches = []; return }
        let found = (try? await entities.search(value: trimmed, limit: 8)) ?? []
        await MainActor.run { matches = found }
    }
}
