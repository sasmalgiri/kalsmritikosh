//
//  ExplorerView.swift
//  Kalsmritikosh
//
//  Phase J.17 — Vol 28 §Knowledge Graph Explorer. An interactive
//  entity-traversal surface that lists the selected entity's:
//
//      • co-occurring entities (sorted by edge weight),
//      • events touching this entity (sorted by date desc),
//      • verified causal links between those events,
//      • a navigation history so the user can step back through
//        prior selections.
//
//  Reading-only, list-based — no graph drawing. The user picks an
//  entity from a fuzzy-search bar, then clicks neighbors or events
//  to navigate. Differs from DossierView (which composes a
//  narrative) in that Explorer is purposeful graph traversal: click
//  → navigate → click → navigate.
//

import SwiftUI

public struct ExplorerView: View {
    @Environment(AppState.self) private var appState

    @State private var query: String = ""
    @State private var matches: [Entity] = []
    @State private var selection: Entity?
    @State private var navigationStack: [Entity] = []
    @State private var coOccurring: [(entity: Entity, weight: Int)] = []
    @State private var touchingEvents: [Event] = []
    @State private var causalLinks: [CausalLink] = []
    @State private var loading: Bool = false
    /// Phase J.19 — assertions touching the selected entity. Re-fetched
    /// on every selection alongside the other neighborhood data.
    @State private var entityAssertions: [Assertion] = []
    @State private var pendingPredicate: String = ""
    @State private var pendingObjectLiteral: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .background(AuroraBackdrop(intensity: 0.5))
    }

    // MARK: - Header / search

    private var header: some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Explore")
                    .font(Theme.display(28, .bold))
                Text("Walk the entity graph — click through neighbours, events, causal links and assertions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !navigationStack.isEmpty {
                Button {
                    Task { await navigateBack() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search entities — Khurana, Project Delta, gmail.com…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await runSearch() } }
            if !matches.isEmpty {
                Picker("Pick", selection: $selection) {
                    Text("Choose match…").tag(Entity?.none)
                    ForEach(matches, id: \.id) { entity in
                        Text("\(entity.value) · \(entity.kind.rawValue)")
                            .tag(Optional(entity))
                    }
                }
                .frame(maxWidth: 260)
                .labelsHidden()
                .onChange(of: selection) { _, newValue in
                    guard let newValue else { return }
                    Task { await select(newValue, pushHistory: true) }
                }
            }
            Button {
                Task { await runSearch() }
            } label: { Image(systemName: "arrow.right.circle.fill") }
            .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
        }
        .padding(10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let entity = selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    entityHeader(entity)
                    Divider()
                    HStack(alignment: .top, spacing: 18) {
                        coOccurringPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        eventsPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if !causalLinks.isEmpty {
                        Divider()
                        causalLinksPanel
                    }
                    Divider()
                    assertionsPanel(for: entity)
                    Spacer(minLength: 24)
                }
                .padding(16)
            }
            .overlay {
                if loading {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Explore your knowledge graph")
                .font(.title3.weight(.medium))
            Text("Search for a person, organization, project, or identifier. Click any neighbor or event to keep traversing — use Back to retrace.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func entityHeader(_ entity: Entity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: Self.iconForKind(entity.kind))
                    .foregroundStyle(.tint)
                Text(entity.value)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Text(entity.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
                Text(entity.qualityTier.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let normalized = entity.normalizedValue, normalized != entity.value {
                Text("normalized: \(normalized)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !navigationStack.isEmpty {
                Text("path: " + navigationStack.suffix(4).map(\.value).joined(separator: " › ") + " › " + entity.value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var coOccurringPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Co-occurring entities (\(coOccurring.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if coOccurring.isEmpty {
                Text("No co-occurrences yet — the cooccurrence builder may not have run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coOccurring, id: \.entity.id) { row in
                    Button {
                        Task { await select(row.entity, pushHistory: true) }
                    } label: {
                        HStack {
                            Image(systemName: Self.iconForKind(row.entity.kind))
                                .foregroundStyle(.tint)
                            Text(row.entity.value)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Text("× \(row.weight)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Events touching this entity (\(touchingEvents.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if touchingEvents.isEmpty {
                Text("No events recorded for this entity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(touchingEvents) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(event.datePrecision.renderPhrase(date: event.date))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(event.kind.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        Text(event.title)
                            .font(.callout)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    private var causalLinksPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Causal links across this entity's events (\(causalLinks.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(causalLinks.prefix(10), id: \.id) { link in
                let sourceTitle = touchingEvents.first(where: { $0.id == link.sourceEventID })?.title
                    ?? link.sourceEventID.uuidString.prefix(8).description
                let targetTitle = touchingEvents.first(where: { $0.id == link.targetEventID })?.title
                    ?? link.targetEventID.uuidString.prefix(8).description
                HStack(spacing: 6) {
                    Text(sourceTitle)
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(link.relation.renderVerb)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.purple)
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(targetTitle)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", link.confidence * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    // MARK: - Assertions panel

    @ViewBuilder
    private func assertionsPanel(for entity: Entity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("User assertions (\(entityAssertions.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if entityAssertions.isEmpty {
                Text("No assertions recorded for this entity yet. Add one below to capture knowledge that isn't in any source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entityAssertions, id: \.id) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(a.predicate.uppercased())
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 130, alignment: .leading)
                        Text(Self.formatObject(a.object))
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                        Text(String(format: "%.0f%%", a.confidence * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(a.agent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Task { await retract(a) }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Retract this assertion")
                    }
                }
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 8) {
                TextField("predicate (e.g. works_for, lives_in)", text: $pendingPredicate)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                TextField("object value", text: $pendingObjectLiteral)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await addAssertion(for: entity) }
                } label: {
                    Label("Add assertion", systemImage: "plus.circle")
                }
                .disabled(
                    pendingPredicate.trimmingCharacters(in: .whitespaces).isEmpty
                    || pendingObjectLiteral.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    private func addAssertion(for entity: Entity) async {
        guard let repo = appState.assertions else { return }
        let predicate = pendingPredicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = pendingObjectLiteral.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !literal.isEmpty else { return }
        let assertion = Assertion(
            subjectKind: .entity,
            subjectID: entity.id,
            predicate: predicate,
            object: .literal(literal),
            confidence: 0.95,
            agent: "user",
            reason: "User assertion via Explore tab"
        )
        try? await repo.insert(assertion)
        await MainActor.run {
            pendingPredicate = ""
            pendingObjectLiteral = ""
        }
        await loadAssertions(for: entity)
    }

    private func retract(_ assertion: Assertion) async {
        guard let repo = appState.assertions else { return }
        try? await repo.retract(assertion.id)
        if let entity = selection {
            await loadAssertions(for: entity)
        }
    }

    private func loadAssertions(for entity: Entity) async {
        guard let repo = appState.assertions else { return }
        let list = (try? await repo.assertions(subjectKind: .entity, subjectID: entity.id)) ?? []
        await MainActor.run { self.entityAssertions = list }
    }

    private static func formatObject(_ object: Assertion.Object) -> String {
        switch object {
        case .entity(let id):  return "entity:\(id.uuidString.prefix(8))"
        case .event(let id):   return "event:\(id.uuidString.prefix(8))"
        case .literal(let v):  return v
        }
    }

    // MARK: - I/O

    private func runSearch() async {
        guard let repo = appState.entities else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        let hits = (try? await repo.find(byValue: q, limit: 25)) ?? []
        await MainActor.run {
            self.matches = hits
            // Auto-select the first hit if there's only one match.
            if hits.count == 1 {
                Task { await select(hits[0], pushHistory: true) }
            }
        }
    }

    private func select(_ entity: Entity, pushHistory: Bool) async {
        await MainActor.run {
            if pushHistory, let current = selection {
                navigationStack.append(current)
            }
            self.selection = entity
            self.loading = true
        }
        await loadNeighborhood(for: entity)
        await MainActor.run { self.loading = false }
    }

    private func navigateBack() async {
        guard let previous = navigationStack.popLast() else { return }
        await select(previous, pushHistory: false)
    }

    private func loadNeighborhood(for entity: Entity) async {
        async let cooc = loadCoOccurring(for: entity)
        async let events = loadEvents(for: entity)
        let (coocResult, eventsResult) = await (cooc, events)
        // Causal links touching those events.
        let links: [CausalLink]
        if let linksRepo = appState.eventLinks, !eventsResult.isEmpty {
            links = (try? await linksRepo.links(in: eventsResult.map(\.id))) ?? []
        } else {
            links = []
        }
        await MainActor.run {
            self.coOccurring = coocResult
            self.touchingEvents = eventsResult
            self.causalLinks = links
        }
        await loadAssertions(for: entity)
    }

    private func loadCoOccurring(for entity: Entity) async -> [(Entity, Int)] {
        guard let db = appState.database, let entities = appState.entities else { return [] }
        let rows = (try? await db.query("""
        SELECT CASE WHEN entity_a = ? THEN entity_b ELSE entity_a END AS other, weight
        FROM entity_cooccurrences
        WHERE entity_a = ? OR entity_b = ?
        ORDER BY weight DESC
        LIMIT 12;
        """, [.uuid(entity.id), .uuid(entity.id), .uuid(entity.id)])) ?? []
        let weightByID: [(Entity.ID, Int)] = rows.compactMap { row in
            guard let id = row.uuid(0), let w = row.int(1) else { return nil }
            return (id, Int(w))
        }
        guard !weightByID.isEmpty else { return [] }
        let ids = weightByID.map(\.0)
        let hydrated = (try? await entities.findByIDs(ids)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
        return weightByID.compactMap { pair in
            guard let ent = byID[pair.0] else { return nil }
            return (ent, pair.1)
        }
    }

    private func loadEvents(for entity: Entity) async -> [Event] {
        guard let db = appState.database, let events = appState.events else { return [] }
        let rows = (try? await db.query("""
        SELECT event_id FROM event_entities WHERE entity_id = ? LIMIT 30;
        """, [.uuid(entity.id)])) ?? []
        let ids: [Event.ID] = rows.compactMap { $0.uuid(0) }
        guard !ids.isEmpty else { return [] }
        let hydrated = (try? await events.findByIDs(ids)) ?? []
        return hydrated.sorted { $0.date > $1.date }
    }

    private static func iconForKind(_ kind: Entity.Kind) -> String {
        switch kind {
        case .person:           return "person"
        case .emailAddress:     return "envelope"
        case .phoneNumber:      return "phone"
        case .organization,
             .vendor, .client:  return "building.2"
        case .project,
             .deliverable:      return "folder"
        case .address, .city,
             .country, .location: return "mappin.and.ellipse"
        case .money, .currency,
             .invoiceNumber,
             .paymentID:        return "dollarsign.circle"
        case .date, .deadline,
             .milestone:        return "calendar"
        case .other:             return "circle"
        }
    }
}
