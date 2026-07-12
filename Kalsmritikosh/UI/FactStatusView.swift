//
//  FactStatusView.swift
//  Kalsmritikosh
//
//  The Fact Status Matrix (T14) — the product-facing surface that presents
//  every reconstructed fact under one explicit status: Proven / Inferred /
//  Contradicted / Missing / Unverified. Four tabs — Timeline · Evidence ·
//  Contradictions · Missing Proof — over the SAME classified working set.
//
//  Read-only: it reads the structured ledger (events, assertions,
//  contradictions, gaps) through the existing repositories, runs the pure
//  FactStatusClassifier, and renders. It writes nothing and calls no model.
//

import SwiftUI

public struct FactStatusView: View {
    @Environment(AppState.self) private var appState

    @State private var items: [FactStatusItem] = []
    @State private var loading = true
    @State private var tab: Tab = .timeline
    @State private var evidenceFor: FactStatusItem?
    @State private var reviewing: FactStatusItem?

    public init() {}

    enum Tab: String, CaseIterable, Identifiable {
        case timeline      = "Timeline"
        case evidence      = "Evidence"
        case contradictions = "Contradictions"
        case missing       = "Missing Proof"
        case needsReview   = "Needs Review"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .timeline:       return "calendar.day.timeline.left"
            case .evidence:       return "doc.text.magnifyingglass"
            case .contradictions: return "arrow.triangle.branch"
            case .missing:        return "questionmark.square.dashed"
            case .needsReview:    return "checkmark.seal"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            countStrip
            Divider()
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            content
        }
        .task { await load() }
        .sheet(item: $evidenceFor) { item in
            EvidenceSheet(item: item)
                .environment(appState)
        }
        .sheet(item: $reviewing) { item in
            ReviewSheet(item: item) { Task { await load() } }
                .environment(appState)
        }
    }

    // MARK: Count strip

    private var countStrip: some View {
        HStack(spacing: 10) {
            ForEach(FactStatus.allCases, id: \.self) { status in
                let n = items.filter { $0.status == status }.count
                HStack(spacing: 5) {
                    Image(systemName: status.systemImage)
                        .imageScale(.small)
                        .foregroundStyle(color(for: status))
                    Text("\(n)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text(status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(color(for: status).opacity(0.10), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Tab content

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Classifying the ledger…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .timeline:       timelineTab
                    case .evidence:       evidenceTab
                    case .contradictions: contradictionsTab
                    case .missing:        missingTab
                    case .needsReview:    needsReviewTab
                    }
                }
                .padding(14)
            }
        }
    }

    private var timelineTab: some View {
        let rows = items
            .filter { $0.status != .missing && $0.date != nil }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return Group {
            if rows.isEmpty {
                tabEmpty("No dated facts to place on a timeline yet.")
            } else {
                ForEach(rows) { row($0) }
            }
        }
    }

    private var evidenceTab: some View {
        Group {
            ForEach([FactStatus.proven, .inferred, .unverified], id: \.self) { status in
                let rows = items.filter { $0.status == status }
                if !rows.isEmpty {
                    sectionHeader(status)
                    ForEach(rows) { row($0) }
                }
            }
        }
    }

    private var contradictionsTab: some View {
        let rows = items.filter { $0.sourceKind == .contradiction }
        return Group {
            if rows.isEmpty {
                tabEmpty("No contradictions detected. Conflicting sources will appear here — both sides preserved.")
            } else {
                ForEach(rows) { contradictionRow($0) }
            }
        }
    }

    private var missingTab: some View {
        let rows = items.filter { $0.status == .missing }
        return Group {
            if rows.isEmpty {
                tabEmpty("No gaps detected. Missing originals, sequence holes and dangling references will appear here.")
            } else {
                ForEach(rows) { row($0) }
            }
        }
    }

    /// Facts the system flags for a human: contradicted or unverified, minus
    /// anything a reviewer has already accepted/corrected (which the overlay
    /// promotes out of this set). Accept/reject/correct writes to the ledger.
    private var needsReviewTab: some View {
        let rows = items.filter { $0.status == .contradicted || $0.status == .unverified }
        return Group {
            Text("Human review is authoritative and preserved as a new ledger entry — it never overwrites history, and never replaces professional legal/forensic judgment.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            if rows.isEmpty {
                tabEmpty("Nothing awaiting review. Contradicted and unverified facts appear here for accept / reject / correct.")
            } else {
                ForEach(rows) { row($0) }
            }
        }
    }

    // MARK: Rows

    private func row(_ item: FactStatusItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: item.status))
                .frame(width: 30, height: 30)
                .background(color(for: item.status).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                metaRow(item)
            }
            Spacer(minLength: 0)
            statusChip(item.status)
        }
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private func contradictionRow(_ item: FactStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusChip(.contradicted)
                Spacer()
                ConfidenceBadge(Confidence(item.confidence))
            }
            claimBubble(item.title, tint: Theme.brand)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .imageScale(.small).foregroundStyle(.secondary)
                Text("conflicts with").font(.caption2).foregroundStyle(.secondary)
            }
            claimBubble(item.secondaryText ?? "—", tint: Theme.brandAlt)
            Text(item.reason).font(.caption).foregroundStyle(.secondary)
            metaRow(item)
        }
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private func claimBubble(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func metaRow(_ item: FactStatusItem) -> some View {
        HStack(spacing: 10) {
            if let date = item.date {
                Label(date.formatted(date: .abbreviated, time: .omitted),
                      systemImage: "calendar")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if item.sourceKind != .contradiction {
                ConfidenceBadge(Confidence(item.confidence))
            }
            if !item.evidenceObjectIDs.isEmpty {
                Button {
                    evidenceFor = item
                } label: {
                    Label("\(item.evidenceObjectIDs.count) source\(item.evidenceObjectIDs.count == 1 ? "" : "s")",
                          systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            // T17 — human review (gaps aren't reviewable facts).
            if item.sourceKind != .gap {
                Button {
                    reviewing = item
                } label: {
                    Label("Review", systemImage: "checkmark.seal").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Bits

    private func statusChip(_ status: FactStatus) -> some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color(for: status).opacity(0.16), in: .capsule)
            .foregroundStyle(color(for: status))
    }

    private func sectionHeader(_ status: FactStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.systemImage).foregroundStyle(color(for: status))
            Text(status.displayName)
                .font(.headline)
            Spacer()
        }
        .padding(.top, 6)
    }

    private func tabEmpty(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing to reconstruct yet")
                .font(.title3.weight(.semibold))
            Text("Ingest documents and the ledger's events, claims, contradictions and gaps will appear here — each labelled by how well the evidence supports it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Semantic colour per status. Kept in the UI layer so the model stays
    /// Foundation-only.
    private func color(for status: FactStatus) -> Color {
        switch status {
        case .proven:        return .green
        case .humanConfirmed: return .mint   // affirmed by a person, distinct from structurally proven
        case .inferred:      return Theme.brandAlt
        case .contradicted:  return .red
        case .missing:       return .orange
        case .unverified:    return .secondary
        }
    }

    // MARK: Load

    private func load() async {
        loading = true
        let events: [Event]
        let gaps: [GapNode]
        let cons: [Contradiction]
        let asserts: [Assertion]

        if let repo = appState.events {
            events = (try? await repo.recent(limit: 500)) ?? []
        } else { events = [] }
        if let repo = appState.gapNodes {
            gaps = await repo.all()
        } else { gaps = [] }
        if let repo = appState.contradictions {
            cons = await repo.all()
        } else { cons = [] }
        if let repo = appState.assertions {
            asserts = (try? await repo.recent(limit: 300)) ?? []
        } else { asserts = [] }

        // T17 — latest human-review verdict per subject (overlay input).
        let reviews: [UUID: FactReview]
        if let repo = appState.factReviews {
            reviews = (try? await repo.latestBySubject()) ?? [:]
        } else { reviews = [:] }

        let classified = FactStatusClassifier().classify(
            events: events, assertions: asserts,
            contradictions: cons, gaps: gaps,
            reviews: reviews
        )
        items = classified
        loading = false
    }
}

// MARK: - Evidence sheet

/// Resolves a fact's evidence KnowledgeObject IDs to real sources and lets
/// the user open each in the existing SourceViewer. Proves every citation
/// points at a real object — no dead links.
private struct EvidenceSheet: View {
    let item: FactStatusItem
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var objects: [KnowledgeObject] = []
    @State private var withheldCount = 0
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if objects.isEmpty {
                    Text(withheldCount > 0
                         ? "\(withheldCount) source\(withheldCount == 1 ? "" : "s") withheld as privileged."
                         : "The evidence for this fact could not be resolved to a stored source.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(40)
                } else {
                    List(objects) { ko in
                        NavigationLink {
                            SourceViewer(url: ko.sourceFile)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(Theme.brand)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ko.sourceFile.lastPathComponent)
                                        .font(.callout.weight(.medium))
                                    Text(ko.content.prefix(90))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Evidence")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            var loaded: [KnowledgeObject] = []
            var withheld = 0
            if let repo = appState.objects {
                for id in item.evidenceObjectIDs {
                    // T18 — privileged material is withheld from the evidence
                    // surface (§21), not shown and then hidden.
                    if (try? await repo.isPrivileged(id)) == true { withheld += 1; continue }
                    if let ko = try? await repo.load(id: id) { loaded.append(ko) }
                }
            }
            objects = loaded
            withheldCount = withheld
            loading = false
        }
    }
}

// MARK: - Review sheet

/// T17 — records a human accept / reject / correct as a NEW append-only
/// `fact_reviews` row. Nothing is overwritten; the prior value is captured.
private struct ReviewSheet: View {
    let item: FactStatusItem
    let onDone: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var action: FactReview.Action = .accept
    @State private var reason: String = ""
    @State private var corrected: String = ""
    @State private var saving = false

    private var reasonRequired: Bool { action != .accept }
    private var canSave: Bool {
        !saving && (!reasonRequired || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Fact") {
                    Text(item.title).font(.callout.weight(.medium))
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                }
                Section("Verdict") {
                    Picker("Action", selection: $action) {
                        Text("Accept").tag(FactReview.Action.accept)
                        Text("Reject").tag(FactReview.Action.reject)
                        Text("Correct").tag(FactReview.Action.correct)
                    }
                    .pickerStyle(.segmented)
                    if action == .correct {
                        TextField("Corrected value", text: $corrected, axis: .vertical)
                    }
                    TextField(reasonRequired ? "Reason (required)" : "Reason (optional)",
                              text: $reason, axis: .vertical)
                }
                Section {
                    Text("Recorded as a new ledger entry — it never overwrites history, and never replaces professional judgment.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Review fact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    private func save() async {
        saving = true
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = FactReview(
            subjectKind: item.sourceKind,
            subjectID: item.id,
            action: action,
            priorValue: "\(item.status.displayName): \(item.title)",
            newValue: action == .correct
                ? corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil,
            reason: trimmedReason.isEmpty ? nil : trimmedReason
        )
        try? await appState.factReviews?.record(review)
        saving = false
        onDone()
        dismiss()
    }
}
