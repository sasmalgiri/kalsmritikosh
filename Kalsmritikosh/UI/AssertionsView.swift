//
//  AssertionsView.swift
//  Kalsmritikosh
//
//  Phase J.23 — audit surface for the Vol 17 §A3 assertion
//  substrate. Lists the 100 most-recent non-retracted assertions
//  with filter chips for predicate / agent / subject kind. Read-
//  mostly; the only mutation is a Retract button per row so the
//  user can clean up bad assertions.
//
//  ExplorerView is the writer (per-entity inline form). This view
//  is the global reader so the user can see all substrate content
//  without first picking an entity.
//

import SwiftUI

public struct AssertionsView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [Assertion] = []
    @State private var totalCount: Int = 0
    @State private var loading: Bool = false
    @State private var filterAgent: String = ""
    @State private var filterPredicate: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            content
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "scroll")
                .foregroundStyle(.tint)
            Text("Assertions")
                .font(Theme.display(28, .bold))
            Spacer()
            Text("\(filtered.count) of \(items.count) shown · \(totalCount) total")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                Task { await reload() }
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            TextField("filter predicate", text: $filterPredicate)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            TextField("filter agent", text: $filterAgent)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Spacer()
            if !filterAgent.isEmpty || !filterPredicate.isEmpty {
                Button("Clear") {
                    filterAgent = ""
                    filterPredicate = ""
                }
                .controlSize(.small)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            empty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filtered, id: \.id) { a in
                        row(a)
                    }
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "scroll")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("No assertions yet")
                .font(.title3.weight(.medium))
            Text("User assertions land here when you add them in the Explore tab. Future LLM extractions will populate this substrate automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ a: Assertion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(a.subjectKind.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
                Text(a.subjectID.uuidString.prefix(8))
                    .font(.caption.monospaced())
                Text(a.predicate.uppercased())
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.purple)
                Text(formatObject(a.object))
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Button(role: .destructive) {
                    Task { await retract(a) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Retract this assertion")
            }
            HStack(spacing: 8) {
                Text("agent: \(a.agent)")
                Text("conf: \(String(format: "%.0f%%", a.confidence * 100))")
                Text(a.recordedAt.formatted(date: .abbreviated, time: .shortened))
                if let reason = a.reason {
                    Text("· \(reason)")
                        .italic()
                        .lineLimit(1)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: - I/O

    private var filtered: [Assertion] {
        var rows = items
        let predicateFilter = filterPredicate.trimmingCharacters(in: .whitespaces).lowercased()
        if !predicateFilter.isEmpty {
            rows = rows.filter { $0.predicate.contains(predicateFilter) }
        }
        let agentFilter = filterAgent.trimmingCharacters(in: .whitespaces).lowercased()
        if !agentFilter.isEmpty {
            rows = rows.filter { $0.agent.lowercased().contains(agentFilter) }
        }
        return rows
    }

    private func reload() async {
        guard let repo = appState.assertions else { return }
        await MainActor.run { self.loading = true }
        let list = (try? await repo.recent(limit: 200)) ?? []
        let total = (try? await repo.count()) ?? 0
        await MainActor.run {
            self.items = list
            self.totalCount = total
            self.loading = false
        }
    }

    private func retract(_ a: Assertion) async {
        guard let repo = appState.assertions else { return }
        try? await repo.retract(a.id)
        await reload()
    }

    private func formatObject(_ object: Assertion.Object) -> String {
        switch object {
        case .entity(let id):  return "entity:\(id.uuidString.prefix(8))"
        case .event(let id):   return "event:\(id.uuidString.prefix(8))"
        case .literal(let v):  return v
        }
    }
}
