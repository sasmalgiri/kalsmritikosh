//
//  EventDetailSheet.swift
//  Kalsmritikosh
//
//  Phase J.22 — deep-dive sheet for a single Event. Tapping any
//  event row in TimelineView or ExplorerView opens this. It loads
//  everything the ledger knows about the event in parallel:
//
//      • full Event payload (title / summary / kind / dates /
//        confidences / precision)
//      • source KnowledgeObject (filename + sourceURL link)
//      • entities tied to the event via event_entities
//      • outgoing causal links + incoming causal links (non-superseded)
//      • assertions where subjectKind=.event and subjectID matches
//      • version chain length (links into the existing diff sheet)
//
//  Read-only — the sheet is a viewer. Future v2 can wire inline
//  edits that go through EventMutator + record a new version.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Revalidation key: combines the event UUID with the current policy revision so that
/// `.task(id:)` re-fires whenever a scope assignment is created or revoked while the
/// sheet is open — ensuring previously authorized content is hidden immediately.
private struct AuthorizationTaskID: Equatable, Hashable {
    let targetID: UUID
    let policyRevision: Int
}

public struct EventDetailSheet: View {
    @Environment(AppState.self) private var appState
    let event: Event
    let onClose: () -> Void
    /// Called after a reject/restore so the presenting list can refresh.
    let onReviewChanged: () -> Void

    @State private var sourceObject: KnowledgeObject?
    @State private var sourceURL: URL?
    @State private var entities: [Entity] = []
    @State private var outgoing: [CausalLink] = []
    @State private var incoming: [CausalLink] = []
    @State private var assertions: [Assertion] = []
    @State private var versionCount: Int = 0
    @State private var loading: Bool = true
    /// OPS-003D.1.1 — event-level authorization check runs before any load.
    /// nil = pending, false = denied (restricted placeholder shown), true = permitted.
    @State private var eventAuthorized: Bool? = nil
    /// v50 human-in-loop: whether this event is currently soft-excluded.
    @State private var isExcluded: Bool = false
    @State private var reviewBusy: Bool = false
    @State private var sourceAuthorized: Bool = false

    public init(
        event: Event,
        onClose: @escaping () -> Void,
        onReviewChanged: @escaping () -> Void = {}
    ) {
        self.event = event
        self.onClose = onClose
        self.onReviewChanged = onReviewChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if eventAuthorized == false {
                restrictedEventPlaceholder
            } else if loading || eventAuthorized == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading event context…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        payloadPanel
                        sourcePanel
                        entitiesPanel
                        causalPanel
                        assertionsPanel
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 360, maxHeight: 560)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task(id: AuthorizationTaskID(targetID: event.id,
                                      policyRevision: appState.sensitiveScopeRevision)) {
            // OPS-003D.1.2 — revision-aware task so policy changes after the sheet
            // opens re-run this check. Set eventAuthorized=nil first to enter the
            // pending (ProgressView) state before any await.
            eventAuthorized = nil
            let target = SensitiveScopeTarget(kind: .event, id: event.id)
            let allowed = await appState.screenAuthorizer?.authorize(
                target: target, boundary: .globalOwner) ?? false
            guard allowed else {
                // Clear all sensitive state before showing the restricted placeholder.
                // loading is reset to true so that if access is later restored the
                // data is reloaded from scratch.
                sourceObject = nil
                sourceURL = nil
                entities = []
                outgoing = []
                incoming = []
                assertions = []
                versionCount = 0
                sourceAuthorized = false
                loading = true
                eventAuthorized = false
                return
            }
            eventAuthorized = true
            if loading { await load() }
        }
    }

    private var restrictedEventPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Event restricted")
                .font(.headline)
            Text("This event is not available at the current access level.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.tint)
            Text("Event detail")
                .font(.headline)
            Spacer()
            if isExcluded {
                Label("Excluded", systemImage: "eye.slash")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if versionCount >= 2 {
                Label("\(versionCount) versions", systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            // Human-in-loop reject / restore (reversible, audit-logged).
            if isExcluded {
                Button { Task { await setExcluded(false) } } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .disabled(reviewBusy)
            } else {
                Button(role: .destructive) { Task { await setExcluded(true) } } label: {
                    Label("Reject", systemImage: "eye.slash")
                }
                .disabled(reviewBusy)
            }
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Soft-exclude or restore this event. Never deletes the row — flips the
    /// separate review_status marker and records an append-only FactReview so
    /// the action shows in the Audit trail and can be undone.
    private func setExcluded(_ excluded: Bool) async {
        guard let events = appState.events else { return }
        reviewBusy = true
        defer { reviewBusy = false }
        try? await events.setReviewStatus(event.id, excluded ? "rejected" : nil)
        _ = try? await appState.factReviews?.record(FactReview(
            subjectKind: .event, subjectID: event.id,
            action: excluded ? .reject : .accept,
            priorValue: event.title, reviewer: "user",
            reason: excluded ? "Excluded from the timeline" : "Restored"
        ))
        isExcluded = excluded
        onReviewChanged()
        onClose()
    }

    // MARK: - Panels

    private var payloadPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if let summary = event.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                tag("kind", event.kind.rawValue)
                tag("precision", event.datePrecision.displayName)
                tag("date", event.datePrecision.renderPhrase(date: event.date))
                tag("date conf", String(format: "%.0f%%", event.dateConfidence * 100))
                tag("conf", String(format: "%.0f%%", event.confidence.value * 100))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let object = sourceObject {
                if sourceAuthorized {
                    let filename = object.sourceFile.lastPathComponent
                    HStack {
                        Image(systemName: "doc")
                            .foregroundStyle(.tint)
                        Text(filename)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        if let url = sourceURL {
                            Button {
                                #if canImport(AppKit)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                #endif
                            } label: {
                                Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("KO id: \(object.id.uuidString.prefix(8))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Label("Source restricted", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No source KnowledgeObject linked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    private var entitiesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Entities (\(entities.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if entities.isEmpty {
                Text("No entities linked to this event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entities) { entity in
                    HStack {
                        Text(entity.value)
                            .font(.callout)
                        Spacer()
                        Text(entity.kind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.tint)
                        Text(entity.qualityTier.rawValue)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var causalPanel: some View {
        if outgoing.isEmpty && incoming.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Causal links")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !outgoing.isEmpty {
                    Text("This event → (\(outgoing.count))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                    ForEach(outgoing, id: \.id) { link in
                        causalRow(link, outgoing: true)
                    }
                }
                if !incoming.isEmpty {
                    Text("(\(incoming.count)) → this event")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.top, 4)
                    ForEach(incoming, id: \.id) { link in
                        causalRow(link, outgoing: false)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private func causalRow(_ link: CausalLink, outgoing: Bool) -> some View {
        HStack(spacing: 6) {
            Text(link.relation.renderVerb)
                .font(.caption.monospaced())
                .foregroundStyle(.purple)
            Text(outgoing
                ? "→ event \(link.targetEventID.uuidString.prefix(8))"
                : "← event \(link.sourceEventID.uuidString.prefix(8))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text(link.source.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", link.confidence * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var assertionsPanel: some View {
        if assertions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Assertions about this event (\(assertions.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(assertions, id: \.id) { a in
                    HStack {
                        Text(a.predicate.uppercased())
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(formatObject(a.object))
                            .font(.caption)
                        Spacer()
                        Text(a.agent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
            .cornerRadius(10)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tag(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08), in: .capsule)
    }

    private func formatObject(_ object: Assertion.Object) -> String {
        switch object {
        case .entity(let id):  return "entity:\(id.uuidString.prefix(8))"
        case .event(let id):   return "event:\(id.uuidString.prefix(8))"
        case .literal(let v):  return v
        }
    }

    // MARK: - I/O

    private func load() async {
        async let objectPromise: KnowledgeObject? = {
            try? await appState.objects?.load(id: event.sourceObjectID)
        }()
        async let urlPromise: URL? = {
            try? await appState.objects?.fetchSourceURL(id: event.sourceObjectID)
        }()
        async let entitiesPromise: [Entity] = loadEntities()
        async let outgoingPromise: [CausalLink] = {
            (try? await appState.eventLinks?.outgoing(from: event.id)) ?? []
        }()
        async let incomingPromise: [CausalLink] = {
            (try? await appState.eventLinks?.incoming(to: event.id)) ?? []
        }()
        async let assertionsPromise: [Assertion] = {
            (try? await appState.assertions?.assertions(subjectKind: .event, subjectID: event.id)) ?? []
        }()
        async let versionsPromise: [EventVersion] = {
            (try? await appState.eventVersions?.versions(of: event.id)) ?? []
        }()

        let (obj, url, ents, out, inn, asserts, versions) = await (
            objectPromise, urlPromise, entitiesPromise,
            outgoingPromise, incomingPromise, assertionsPromise, versionsPromise
        )

        let excluded = (try? await appState.events?.reviewStatus(forID: event.id)) == "rejected"
        let sourceAuth: Bool
        if let object = obj {
            sourceAuth = await appState.screenAuthorizer?.authorize(object.id, boundary: .globalOwner) ?? false
        } else {
            sourceAuth = true
        }

        await MainActor.run {
            self.sourceObject = obj
            self.sourceURL = url
            self.sourceAuthorized = sourceAuth
            self.entities = ents
            self.outgoing = out
            self.incoming = inn
            self.assertions = asserts
            self.versionCount = versions.count
            self.isExcluded = excluded
            self.loading = false
        }
    }

    private func loadEntities() async -> [Entity] {
        guard let db = appState.database, let entities = appState.entities else { return [] }
        let rows = (try? await db.query("""
        SELECT entity_id FROM event_entities WHERE event_id = ?;
        """, [.uuid(event.id)])) ?? []
        let ids: [Entity.ID] = rows.compactMap { $0.uuid(0) }
        guard !ids.isEmpty else { return [] }
        return (try? await entities.findByIDs(ids)) ?? []
    }
}
