//
//  DossierView.swift
//  Kalsmritikosh
//
//  Universal History program, Phase 10. The Dossier now reconstructs a subject's
//  history through the CANONICAL engine: it resolves the typed name to a canonical
//  entity id (or asks the user to disambiguate) and calls
//  HistoryReconstructionEngine directly — it no longer sends a free-text
//  "Reconstruct the history of <name>" to a global search (trust rule 3: a named
//  subject can never silently become global archive activity). Chapters, coverage
//  and gaps come from the deterministic outline; the rendered prose is the rule-based
//  renderer, not RAG.
//

import SwiftUI

public struct DossierView: View {
    @Environment(AppState.self) private var appState

    @State private var subject: String = ""
    @State private var streaming = false
    @State private var phase: String = ""
    @State private var resolvedName: String?
    @State private var candidates: [SubjectCandidate] = []
    @State private var narrative: HistoryNarrative?
    @State private var coverage: HistoryCoverage?
    @State private var gaps: [HistoryGap] = []
    @State private var contradictions: Int = 0
    @State private var error: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            input
        }
        .background(AuroraBackdrop(intensity: 0.5))
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.text.rectangle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dossier").font(Theme.display(28, .bold))
                Text("A focused, evidence-cited history of one subject — resolved to a canonical identity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let name = resolvedName {
                Text("— \(name)").font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            if streaming {
                ProgressView().controlSize(.small)
                Text(phase.isEmpty ? "Reconstructing…" : phase).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if narrative == nil, candidates.isEmpty, error == nil {
            placeholder
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !candidates.isEmpty { ambiguityCard }
                    if let cov = coverage { coverageRibbon(cov) }
                    if let n = narrative {
                        ForEach(n.chapters, id: \.ordinal) { chapterCard($0) }
                        if let note = n.gapsNote { gapsCard(note) }
                    }
                    if contradictions > 0 {
                        Label("\(contradictions) contradiction(s) preserved — both accounts kept, none merged.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    if let err = error {
                        Text(err).font(.callout).foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.text.rectangle").font(.system(size: 36)).foregroundStyle(.tint)
            Text("Open a dossier.").font(.title3.weight(.medium))
            Text("Enter a person, project, or organization. Kalsmritikosh resolves it to a canonical identity and reconstructs its evidence-cited history — chapters, coverage and gaps.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .padding(40).frame(maxWidth: .infinity)
    }

    private var ambiguityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Which subject did you mean?", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(.tint)
            ForEach(candidates) { c in
                Button {
                    Task { await run(subject: .forKind(c.kind, id: c.id), name: c.displayName) }
                } label: {
                    HStack {
                        Text(c.displayName).font(.body)
                        Text("· \(c.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(c.mentionCount) mention(s)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08)).cornerRadius(10)
    }

    private func coverageRibbon(_ c: HistoryCoverage) -> some View {
        HStack(spacing: 14) {
            Label("\(c.datedItems) dated", systemImage: "calendar")
            Label("\(c.undatedItems) undated", systemImage: "calendar.badge.exclamationmark")
            Label("\(c.evidenceObjectCount) source(s)", systemImage: "doc.text.magnifyingglass")
            Label("\(c.eventCount) event · \(c.assertionCount) assertion · \(c.genericFactCount) fact",
                  systemImage: "square.stack.3d.up")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func chapterCard(_ chapter: RenderedChapter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chapter.title).font(.title3.weight(.semibold))
            if chapter.prose.isEmpty {
                Text("(\(chapter.itemIDs.count) item(s) recorded.)").font(.callout.italic()).foregroundStyle(.secondary)
            } else {
                Text(chapter.prose).font(.body).textSelection(.enabled)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .cornerRadius(10)
    }

    private func gapsCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Missing chapters", systemImage: "questionmark.folder").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(note).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06)).cornerRadius(10)
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField("Subject (person, project, organization)…", text: $subject)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await start() } }
                .disabled(streaming)
            Button { Task { await start() } } label: {
                Image(systemName: "doc.text.magnifyingglass").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(streaming || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func reset() {
        candidates = []; narrative = nil; coverage = nil; gaps = []; contradictions = 0; error = nil; resolvedName = nil
    }

    private func start() async {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }
        reset()
        // Canonical resolution FIRST — never a free-text global search.
        switch await appState.resolveHistorySubject(trimmed) {
        case .resolved(let r):
            await run(subject: r.subject, name: r.displayName)
        case .ambiguous(let cands):
            candidates = cands
        case .notFound, .none:
            error = "No canonical subject found for “\(trimmed)”. Try a different name, or add sources first."
        }
    }

    private func run(subject: HistorySubject, name: String) async {
        guard !streaming else { return }
        reset()
        resolvedName = name
        streaming = true
        defer { streaming = false }
        for await update in appState.reconstructHistory(subject: subject) {
            switch update {
            case .resolvingSubject: phase = "Resolving…"
            case .collecting(let n): phase = "Collecting (\(n) items)…"
            case .temporalising(let n): phase = "Building claims (\(n))…"
            case .reconciling: phase = "Reconciling…"
            case .outlineReady(let outline):
                let rendered = HistoryNarrativeRenderer().render(outline: outline)
                narrative = rendered
                coverage = outline.coverage
                gaps = outline.gaps
                contradictions = outline.contradictions.count
            case .chapterReady:
                continue   // chapters already in the rendered narrative
            case .verified(let result):
                await appState.persistHistory(result, narrative: narrative)
            case .failed(let reason):
                error = reason
            }
        }
        if narrative == nil, error == nil {
            error = "No history could be reconstructed for \(name)."
        }
    }
}
