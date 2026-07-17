//
//  EntityPickerField.swift
//  Kalsmritikosh
//
//  A small type-to-search entity picker: shows matches as you type; picking one
//  collapses to a chip you can clear. Shared by the connection finder and the
//  entity-comparison view.
//

import SwiftUI

struct EntityPickerField: View {
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
