//
//  CustomTypesView.swift
//  Kalsmritikosh
//
//  N-12 — your own record types ("Contract: parties, value, start date"). Each
//  field fills from facts the ledger's open-field extraction already read from
//  your documents (only where the value is written in a source); a filled cell
//  shows how many sources say it. Nothing is invented: an empty cell means no
//  document states that field for that subject.
//

import SwiftUI
import os

struct CustomTypeRow: Identifiable, Sendable {
    var id: String { subject }
    let subject: String
    let values: [String: (value: String, sources: Int)]
}

extension AppState {
    public var customTypes: CustomRecordTypesRepository? {
        guard ProductModuleFlags.isEnabled(.customEntityTypes), let database else { return nil }
        return CustomRecordTypesRepository(database: database)
    }

    func fill(_ type: CustomRecordType, limit: Int = 300) async -> [CustomTypeRow] {
        guard let database else { return [] }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) }
        var rows: [String: [String: (String, Int)]] = [:]
        for field in type.fields {
            let f = norm(field)
            let res = (try? await database.query("""
                SELECT subject_label, value, COALESCE(source_count, 1) FROM generic_facts
                WHERE REPLACE(LOWER(field), '_', ' ') = ? OR REPLACE(LOWER(field), '_', ' ') LIKE ?
                ORDER BY COALESCE(source_count, 1) DESC LIMIT ?;
                """, [.text(f), .text("%" + f + "%"), .integer(Int64(limit))])) ?? []
            for r in res {
                guard let subject = r.string(0), let value = r.string(1) else { continue }
                if rows[subject]?[field] == nil {
                    rows[subject, default: [:]][field] = (value, Int(r.int(2) ?? 1))
                }
            }
        }
        return rows.map { CustomTypeRow(subject: $0.key, values: $0.value.mapValues { (value: $0.0, sources: $0.1) }) }
            .sorted { $0.values.count > $1.values.count }
    }
}

struct CustomTypesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var types: [CustomRecordType] = []
    @State private var selected: CustomRecordType?
    @State private var rows: [CustomTypeRow] = []
    @State private var name = ""
    @State private var fields = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own record types").font(.title3.bold())
            Text("Define a type and its fields. Values fill in from your documents only where they are written; empty means no document says it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Type name (e.g. Contract)", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("Fields, comma-separated (parties, value, start date)", text: $fields).textFieldStyle(.roundedBorder)
                Button("Create") {
                    let list = fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task { _ = try? await appState.customTypes?.create(name: name, fields: list); name = ""; fields = ""; await load() }
                }
                .disabled(name.isEmpty || fields.isEmpty)
            }
            Picker("Type", selection: $selected) {
                Text("Choose…").tag(CustomRecordType?.none)
                ForEach(types) { Text($0.name).tag(CustomRecordType?.some($0)) }
            }
            .onChange(of: selected) { _, t in Task { rows = t.map { _ in [] } ?? []; if let t { rows = await appState.fill(t) } } }
            if let t = selected {
                Table(rows) {
                    TableColumn("Subject") { Text($0.subject) }
                    TableColumnForEach(t.fields, id: \.self) { field in
                        TableColumn(field) { row in
                            if let v = row.values[field] {
                                Text("\(v.value)" + (v.sources > 1 ? "  (\(v.sources) sources)" : ""))
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(minHeight: 300)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 500)
        .task { await load() }
    }

    private func load() async { types = (try? await appState.customTypes?.all()) ?? [] }
}
