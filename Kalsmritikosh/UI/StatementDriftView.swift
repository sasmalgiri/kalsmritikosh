//
//  StatementDriftView.swift
//  Kalsmritikosh
//
//  I-9 — pick a person and a topic; see everything said about it in date order,
//  with the places where the account changed flagged and both quotes shown.
//

import SwiftUI
import os

extension AppState {
    public func statementDrift(person: String, topic: String) async -> DriftReport? {
        guard ProductModuleFlags.isEnabled(.statementDrift), let chunks, let database else { return nil }
        let query = person + " " + topic
        do {
            let hits = try await chunks.searchFTS(query, limit: 120)
            let visible = await screenAuthorizer?.filterChunks(hits, boundary: .globalOwner) ?? []
            let ids = Set(visible.map(\.objectID))
            var dates: [UUID: Date] = [:]
            if !ids.isEmpty {
                let marks = ids.map { _ in "?" }.joined(separator: ",")
                let rows = try await database.query("""
                    SELECT ko.id, f.modified_at FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                    WHERE ko.id IN (\(marks));
                    """, ids.map { .uuid($0) })
                for r in rows { if let id = r.uuid(0), let t = r.double(1) { dates[id] = Date(timeIntervalSince1970: t) } }
            }
            return StatementDrift.analyze(person: person, topic: topic, passages: visible.map {
                .init(objectID: $0.objectID, date: dates[$0.objectID], text: $0.text)
            })
        } catch {
            KalsmritikoshLog.app.error("Statement drift failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct StatementDriftView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var person = ""
    @State private var topic = ""
    @State private var report: DriftReport?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How an account changed").font(.title3.bold())
            Text("Everything your documents record a person saying or being described as saying about a topic, in date order. Changes are leads to read, not findings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Person", text: $person).textFieldStyle(.roundedBorder)
                TextField("Topic (e.g. the meeting, the payment)", text: $topic).textFieldStyle(.roundedBorder)
                Button(running ? "Looking…" : "Show") { Task { await run() } }
                    .disabled(running || person.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let r = report {
                List {
                    if !r.shifts.isEmpty {
                        Section("Where the account changed (\(r.shifts.count))") {
                            ForEach(r.shifts) { s in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.what).font(.callout.weight(.semibold)).foregroundStyle(.orange)
                                    quote(s.earlier)
                                    quote(s.later)
                                }
                            }
                        }
                    }
                    Section("All statements (\(r.statements.count))") {
                        ForEach(r.statements) { quote($0) }
                    }
                }
                .frame(minHeight: 320)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 640)
    }

    private func run() async {
        running = true
        report = await appState.statementDrift(person: person, topic: topic)
        running = false
    }

    private func quote(_ s: PersonStatement) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Undated")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\u{201C}\(s.sentence)\u{201D}").font(.caption).textSelection(.enabled)
        }
    }
}
