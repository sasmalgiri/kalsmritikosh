//
//  SmartCollectionsView.swift
//  Kalsmritikosh
//
//  W3-5 — smart collections (saved searches in the W1-1 syntax that stay up to
//  date while open) and rules ("when a document matching this arrives → tag it
//  / alert me"). A rule is saved only after a dry run shows what it would match
//  today; after that it runs on every ingest batch, over new documents only.
//  Schema v145 `smart_collections` / `automation_rules`; removal stamps retired_at.
//

import SwiftUI
import os

// MARK: - Repositories

public nonisolated struct SmartCollection: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let query: String
}

public nonisolated struct AutomationRule: Sendable, Identifiable, Hashable {
    public enum Action: String, Sendable, CaseIterable { case tag, alert }
    public let id: UUID
    public let name: String
    public let query: String
    public let action: Action
    public let value: String
    public let enabled: Bool
}

public actor SmartCollectionsRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public func create(name: String, query: String) async throws {
        try await database.exec("INSERT INTO smart_collections (id, name, query, created_at) VALUES (?, ?, ?, ?);",
                                [.uuid(UUID()), .text(name), .text(query), .date(Date())])
    }

    public func all() async throws -> [SmartCollection] {
        try await database.query("SELECT id, name, query FROM smart_collections WHERE retired_at IS NULL ORDER BY name;", [])
            .compactMap { r in
                guard let id = r.uuid(0), let n = r.string(1), let q = r.string(2) else { return nil }
                return SmartCollection(id: id, name: n, query: q)
            }
    }

    public func retire(_ id: UUID) async throws {
        try await database.exec("UPDATE smart_collections SET retired_at = ? WHERE id = ?;", [.date(Date()), .uuid(id)])
    }

    public func createRule(name: String, query: String, action: AutomationRule.Action, value: String) async throws {
        try await database.exec("""
            INSERT INTO automation_rules (id, name, query, action, action_value, enabled, created_at) VALUES (?, ?, ?, ?, ?, 1, ?);
            """, [.uuid(UUID()), .text(name), .text(query), .text(action.rawValue), .text(value), .date(Date())])
    }

    public func rules() async throws -> [AutomationRule] {
        try await database.query("""
            SELECT id, name, query, action, action_value, enabled FROM automation_rules WHERE retired_at IS NULL ORDER BY name;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let n = r.string(1), let q = r.string(2),
                  let a = r.string(3).flatMap(AutomationRule.Action.init(rawValue:)), let v = r.string(4) else { return nil }
            return AutomationRule(id: id, name: n, query: q, action: a, value: v, enabled: (r.int(5) ?? 0) != 0)
        }
    }

    public func setRuleEnabled(_ id: UUID, _ enabled: Bool) async throws {
        try await database.exec("UPDATE automation_rules SET enabled = ? WHERE id = ?;", [.integer(enabled ? 1 : 0), .uuid(id)])
    }

    public func retireRule(_ id: UUID) async throws {
        try await database.exec("UPDATE automation_rules SET retired_at = ? WHERE id = ?;", [.date(Date()), .uuid(id)])
    }
}

// MARK: - Running

extension AppState {
    var smartCollections: SmartCollectionsRepository? {
        guard ProductModuleFlags.isEnabled(.smartCollections), let database else { return nil }
        return SmartCollectionsRepository(database: database)
    }

    /// Documents matching a saved query (all of them, or only those added since `since`).
    func documentsMatching(_ query: String, since: Date? = nil) async -> [UUID] {
        guard let chunks else { return [] }
        let compiled = AdvancedSearchCompiler.compile(query)
        do { return try await chunks.objectsMatchingAdvanced(compiled, since: since) }
        catch {
            KalsmritikoshLog.app.error("Saved query failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Run every enabled rule over documents added since `since`. Called after each ingest batch.
    func runAutomationRules(since: Date) async {
        guard let repo = smartCollections, let rules = try? await repo.rules() else { return }
        for rule in rules where rule.enabled {
            let hits = await documentsMatching(rule.query, since: since)
            guard !hits.isEmpty else { continue }
            do {
                switch rule.action {
                case .tag:
                    guard let tags = tagsRepository else {
                        // Never a silent no-op: say why the rule did not act.
                        try await alertsRepository?.add(kind: "rule", title: "\(rule.name) did not tag \(hits.count) new document\(hits.count == 1 ? "" : "s")",
                                                        detail: "Tags is switched off in Settings → Modules.", objectID: hits.first)
                        continue
                    }
                    let tag = try await tags.tag(named: rule.value)
                    for id in hits { try await tags.attach(tagID: tag, to: .object, id) }
                case .alert:
                    try await alertsRepository?.add(kind: "rule", title: "\(rule.name): \(hits.count) new document\(hits.count == 1 ? "" : "s")",
                                                    detail: rule.value.isEmpty ? nil : rule.value, objectID: hits.first)
                }
            } catch {
                KalsmritikoshLog.app.error("Rule \(rule.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - View

struct SmartCollectionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var collections: [SmartCollection] = []
    @State private var counts: [UUID: Int] = [:]
    @State private var selected: SmartCollection?
    @State private var members: [String] = []
    @State private var newName = ""
    @State private var newQuery = ""

    @State private var rules: [AutomationRule] = []
    @State private var ruleName = ""
    @State private var ruleQuery = ""
    @State private var ruleAction: AutomationRule.Action = .tag
    @State private var ruleValue = ""
    @State private var dryRun: (query: String, count: Int, sample: [String])?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart collections and rules").font(.title3.bold())
            Text("Use the search syntax, e.g. `type:email org:acme after:2024-01-01 \"invoice\"`.")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                collectionsPane.frame(minWidth: 320)
                rulesPane.frame(minWidth: 320)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 560)
        .task {
            // Live: counts refresh while the window is open, so new documents show up without reopening.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var collectionsPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections").font(.headline)
            List(collections, selection: Binding(get: { selected?.id }, set: { id in
                selected = collections.first { $0.id == id }
                Task { await loadMembers() }
            })) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(c.query).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(counts[c.id].map(String.init) ?? "…").monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(c.id)
                .contextMenu { Button("Remove collection") { Task { try? await appState.smartCollections?.retire(c.id); await reload() } } }
            }
            .frame(minHeight: 160)
            if !members.isEmpty {
                ScrollView { VStack(alignment: .leading) { ForEach(members, id: \.self) { Text("• \($0)").font(.caption) } } }
                    .frame(maxHeight: 120)
            }
            TextField("Name", text: $newName)
            TextField("Search", text: $newQuery)
            Button("Save collection") {
                Task {
                    try? await appState.smartCollections?.create(name: newName, query: newQuery)
                    newName = ""; newQuery = ""
                    await reload()
                }
            }
            .disabled(newName.isEmpty || AdvancedSearchCompiler.compile(newQuery).isEmpty)
        }
        .padding(.trailing, 6)
    }

    private var rulesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rules (run on every new batch)").font(.headline)
            List(rules) { r in
                HStack {
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { on in
                        Task { try? await appState.smartCollections?.setRuleEnabled(r.id, on); await reload() }
                    })).labelsHidden()
                    VStack(alignment: .leading) {
                        Text(r.name)
                        Text("\(r.query) → \(r.action == .tag ? "tag “\(r.value)”" : "alert")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contextMenu { Button("Remove rule") { Task { try? await appState.smartCollections?.retireRule(r.id); await reload() } } }
            }
            .frame(minHeight: 160)
            TextField("Rule name", text: $ruleName)
            TextField("When a new document matches", text: $ruleQuery)
            HStack {
                Picker("Then", selection: $ruleAction) {
                    Text("Tag it").tag(AutomationRule.Action.tag)
                    Text("Alert me").tag(AutomationRule.Action.alert)
                }
                .frame(width: 160)
                TextField(ruleAction == .tag ? "Tag name" : "Alert note (optional)", text: $ruleValue)
            }
            HStack {
                Button("Dry run") {
                    Task {
                        let ids = await appState.documentsMatching(ruleQuery)
                        let names = (try? await appState.objects?.sourceFilenames(for: Set(ids.prefix(8)))) ?? [:]
                        dryRun = (ruleQuery, ids.count, Array(names.values).sorted())
                    }
                }
                .disabled(AdvancedSearchCompiler.compile(ruleQuery).isEmpty)
                Button("Save rule") {
                    Task {
                        try? await appState.smartCollections?.createRule(name: ruleName, query: ruleQuery, action: ruleAction, value: ruleValue)
                        ruleName = ""; ruleQuery = ""; ruleValue = ""; dryRun = nil
                        await reload()
                    }
                }
                // A rule is saved only after a dry run of exactly this query.
                .disabled(ruleName.isEmpty || dryRun?.query != ruleQuery || (ruleAction == .tag && ruleValue.isEmpty))
            }
            if let d = dryRun {
                Text("Today this matches \(d.count) document\(d.count == 1 ? "" : "s"). Once saved, it acts only on documents added from now on.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(d.sample, id: \.self) { Text("• \($0)").font(.caption2) }
            }
        }
        .padding(.leading, 6)
    }

    private func reload() async {
        guard let repo = appState.smartCollections else { return }
        collections = (try? await repo.all()) ?? []
        rules = (try? await repo.rules()) ?? []
        var c: [UUID: Int] = [:]
        for col in collections { c[col.id] = await appState.documentsMatching(col.query).count }
        counts = c
        if selected != nil { await loadMembers() }
    }

    private func loadMembers() async {
        guard let s = selected else { members = []; return }
        let ids = await appState.documentsMatching(s.query)
        let names = (try? await appState.objects?.sourceFilenames(for: Set(ids.prefix(200)))) ?? [:]
        members = Array(names.values).sorted()
    }
}
