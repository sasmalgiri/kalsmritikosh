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
    /// Unified path MAP-14 (owner 2026-11-22) — not tested yet: the link explorer.
    @State private var showGraphExplorer = false
    @State private var entityA: EntitySummaryRow?
    @State private var entityB: EntitySummaryRow?
    @State private var connection: ResolvedConnection?
    @State private var comparison: EntityComparison?
    @State private var searching = false
    @State private var didRun = false
    /// Unified path GRAPH-13 (owner 2026-11-22) — not tested yet. The first search looks two steps out;
    /// "Search deeper" looks further, within a stated limit, and says how far it looked.
    @State private var searchedDeeper = false
    @State private var lastSearch: AppState.ConnectionSearchOutcome?
    static let quickHops = 2
    static let deepHops = 8
    static let deepNodeCap = 3_000
    /// S14 (SRC-01) — sources open through the pinned path (their read version, checked), never the current file.
    @State private var openTarget: CitationOpenTarget?
    @State private var openedPassage: OpenedSource?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect two entities")
                    .font(.title3.bold())
                Spacer()
                Button("Browse all links…") { showGraphExplorer = true }
                    .help("Every recorded link between people and organisations, with its evidence.")
            }
            .sheet(isPresented: $showGraphExplorer) {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button("Done") { showGraphExplorer = false }.keyboardShortcut(.cancelAction) }.padding(8)
                    GraphExplorerView()
                }
                .frame(minWidth: 720, minHeight: 520)
            }
            Text("Pick two people or organizations. See the shortest chain of relationships that links them, or the documents where they both appear — evidence either way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in connection = nil; comparison = nil; didRun = false; searchedDeeper = false }

            EntityPickerField(label: "First entity", selection: $entityA)
            EntityPickerField(label: "Second entity", selection: $entityB)

            if entityA == nil && entityB == nil {
                FirstRunHint(message: "People and organizations appear in these pickers as your files are read. Nothing to pick yet?")
            }

            Button {
                run()
            } label: {
                Label(mode == .path ? "Find the connection" : "Show shared documents",
                      systemImage: mode == .path ? "point.topleft.down.to.point.bottomright.curvepath" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(entityA == nil || entityB == nil || entityA?.id == entityB?.id || searching)
            .guidance(GuidanceTip("Find the connection",
                                  what: "Finds the shortest chain of relationships linking the two parties, drawn from your evidence — or the documents they share.",
                                  enabledWhen: "Pick two different people or organizations first."),
                      enabled: !(entityA == nil || entityB == nil || entityA?.id == entityB?.id || searching))

            Divider()

            if searching {
                ProgressView(mode == .path ? "Tracing the graph…" : "Intersecting the evidence…")
                    .frame(maxWidth: .infinity)
            } else if mode == .path, let connection {
                chain(connection)
            } else if mode == .overlap, let comparison {
                overlapView(comparison)
            } else if didRun, mode == .path {
                noPathView
            } else if didRun {
                Label("No document mentions both — they don't co-appear in the archive yet.",
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle("Connections")
        .sheet(item: $openTarget) { target in CitationSourceSheet(target: target) { openTarget = nil } }
        .sheet(item: $openedPassage) { opened in CitedPassageSheet(opened: opened) { openedPassage = nil } }
    }

    // MARK: - Search deeper (Unified path GRAPH-13, owner 2026-11-22 — not tested yet)

    @ViewBuilder private var noPathView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searchedDeeper {
                Label("No connection found within \(Self.deepHops) steps.", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                if let s = lastSearch {
                    Text(s.stoppedAtCap
                         ? "The search stopped at its limit of \(s.nodeCap) people and organisations, so a longer link may still exist."
                         : "Looked at \(s.nodesReached) people and organisations (limit \(s.nodeCap)). They may be linked only through documents not yet read.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("No direct link, and no link through one other person or organisation.", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    run(deeper: true)
                } label: {
                    Label("Search deeper", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Look for longer chains, up to \(Self.deepHops) steps and \(Self.deepNodeCap) people and organisations. The full path is shown.")
                Text("Searches up to \(Self.deepHops) steps away, looking at no more than \(Self.deepNodeCap) people and organisations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
                    Button {
                        openPinned(objectID: doc.objectID)
                    } label: { Label("Open", systemImage: "arrow.up.forward.square").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Open the version this document was read from")
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
                Text(c.hops.count > Self.quickHops
                     ? "\(c.hops.count) steps — a longer link, found by searching deeper. Check each step's document."
                     : "\(c.hops.count) hop(s)")
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

    private func run(deeper: Bool = false) {
        guard let a = entityA?.id, let b = entityB?.id else { return }
        searching = true
        searchedDeeper = deeper
        Task {
            if mode == .path {
                // Unified path GRAPH-13 (owner 2026-11-22) — not tested yet: two steps first; deeper on request.
                let result = await appState.connectionSearch(
                    from: a, to: b,
                    maxHops: deeper ? Self.deepHops : Self.quickHops,
                    nodeCap: deeper ? Self.deepNodeCap : 800)
                await MainActor.run {
                    self.lastSearch = result; self.connection = result.connection
                    self.searching = false; self.didRun = true
                }
            } else {
                let result = await appState.compareEntities(a: a, b: b)
                await MainActor.run { self.comparison = result; self.searching = false; self.didRun = true }
            }
        }
    }

    private func openEvidence(_ hop: ResolvedConnectionHop) {
        guard let object = hop.evidenceObjectID else { return }
        openPinned(objectID: object)
    }

    private func openPinned(objectID: UUID) {
        Task { @MainActor in
            switch await CitedSourceOpening.resolve(appState, objectID: objectID, quote: nil) {
            case .viewer(let target): openTarget = target
            case .passage(let opened): openedPassage = opened
            }
        }
    }
}
