//
//  CaseContradictionsSection.swift
//  Kalsmritikosh
//
//  P3 — the case file's contradictions: "Find contradictions" compares this case's own documents
//  (rules on the Mac; the person's AI reader too when Online document reading is on, every pair it
//  proposes checked against the documents). Each contradiction shows both statements verbatim, each
//  with "Open source" at its words — never averaged, never resolved. Confirm/dismiss stays the case's
//  disposition (the Contradiction & gap desk).
//

import SwiftUI
import os

struct CaseContradictionsSection: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let closed: Bool
    @State private var items: [CaseContradictionItem] = []
    @State private var names: [UUID: String] = [:]
    @State private var running = false
    @State private var lastRun: String?
    @State private var openSource: CitationOpenTarget?
    @State private var openedPassage: OpenedSource?

    var body: some View {
        CaseSection(title: "Contradictions",
                    subtitle: "Statements in this case's documents that cannot both be true. Both sides are shown with their sources; nothing is averaged or decided for you.") {
            HStack {
                Button {
                    Task { await find() }
                } label: {
                    Label("Find contradictions", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .disabled(running || closed || appState.investigationContradictionGap == nil)
                .help("Compares this case's documents with each other — never with documents outside the case.")
                .accessibilityIdentifier("case.contradictions.find")
                if running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let lastRun { Text(lastRun).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if items.isEmpty {
                Text(lastRun == nil ? "Not checked yet." : "No contradictions found by the checks run. That does not prove the documents agree.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items, id: \.contradiction.id) { item in row(item.contradiction, review: item.review) }
        }
        .task(id: caseID) { await reload() }
        .sheet(item: $openSource) { target in CitationSourceSheet(target: target) { openSource = nil } }
        .sheet(item: $openedPassage) { opened in
            VStack(spacing: 0) {
                EvidenceViewer(citation: opened.citation)
                HStack { Spacer(); Button("Close") { openedPassage = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            }
        }
    }

    private func row(_ c: Contradiction, review: InvestigationDeskReview?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(CaseContradictionFinder.kindLabel(of: c) ?? c.kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
                Text(Self.provenanceText(c)).font(.caption2).foregroundStyle(.secondary)
                if let review { Text("Case decision: \(review.decision.rawValue)").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
            }
            Text(Self.summary(c)).font(.callout.weight(.medium)).textSelection(.enabled)
            HStack(alignment: .top, spacing: 10) {
                side("A", quote: c.claimA, object: c.evidenceA)
                side("B", quote: c.claimB, object: c.evidenceB)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("case.contradictions.row")
    }

    private func side(_ title: String, quote: String, object: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("\u{201C}\(quote)\u{201D}").font(.callout).textSelection(.enabled)
            if let object {
                Button { open(object, quote: quote) } label: {
                    Label(names[object].map { "Open source — \($0)" } ?? "Open source", systemImage: "doc.text.magnifyingglass").font(.caption)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("case.contradictions.open")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The description without the check's provenance marker (shown separately).
    nonisolated static func summary(_ c: Contradiction) -> String {
        guard let p = CaseContradictionFinder.provenance(of: c) else { return c.description }
        return c.description.replacingOccurrences(of: " " + p.marker, with: "")
    }

    nonisolated static func provenanceText(_ c: Contradiction) -> String {
        switch CaseContradictionFinder.provenance(of: c) {
        case .rules?: return "Found by the rules"
        case .aiRead?: return "Found by the AI reading — both quotes checked against the documents"
        case nil: return "Found by the archive scan"
        }
    }

    private func reload() async {
        guard let desk = appState.investigationContradictionGap else { return }
        do {
            items = try await desk.contradictions(caseID: caseID)
            let ids = Set(items.flatMap { [$0.contradiction.evidenceA, $0.contradiction.evidenceB].compactMap { $0 } })
            if !ids.isEmpty, let repo = appState.objects { names = try await repo.sourceFilenames(for: ids) }
        } catch {
            KalsmritikoshLog.ui.error("Case contradictions load failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func find() async {
        guard let desk = appState.investigationContradictionGap else { return }
        running = true
        defer { running = false }
        do {
            let run = try await desk.findContradictions(caseID: caseID)
            var text = "Compared \(run.documents) document(s): \(run.ruleFindings.count) found by the rules"
            if run.readerAvailable {
                text += run.calls > 0
                    ? ", \(run.aiFindings.count) by the AI reading (\(run.passagesSent) passage(s) sent; \(run.aiDropped.count) proposed pair(s) did not check out and are not shown)"
                    : " (the AI reading did not run\(run.notSentReason.map { ": \($0)" } ?? ""))"
            } else {
                text += " (AI reading off — rules only)"
            }
            if run.deniedForCloud > 0 { text += "; \(run.deniedForCloud) document(s) stayed on this Mac" }
            lastRun = text + "."
            try? await appState.caseFiles?.file.logAction(caseID: caseID, action: "contradictions checked", detail: lastRun, actor: InvestigatorProfile.name)
        } catch {
            KalsmritikoshLog.ui.error("Find contradictions failed: \(String(describing: error), privacy: .public)")
            lastRun = "The check could not run: \(error.localizedDescription)"
        }
        await reload()
    }

    private func open(_ objectID: UUID, quote: String) {
        Task { @MainActor in
            do {
                if let repo = appState.objects, let url = try await repo.fetchSourceURL(id: objectID) {
                    openSource = CitationOpenTarget(url: url, objectID: objectID, quote: quote)
                    return
                }
            } catch {
                KalsmritikoshLog.ui.error("Contradiction open source failed: \(error.localizedDescription, privacy: .public)")
            }
            openedPassage = OpenedSource(citation: VerifiedAnswer.Citation(objectID: objectID, snippet: quote))
        }
    }
}
