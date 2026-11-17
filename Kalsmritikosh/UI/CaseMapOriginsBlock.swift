//
//  CaseMapOriginsBlock.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (REASON-16) — in the inspector, what a path rests on:
//    • a question: how many separate evidential origins its supporting material rests on (copies and shared wording are
//      one origin until a person reviews them; independence is "not assessed" until then), with the pairs to review;
//    • an explanation: what is cited for and against it, and its recorded status — kept beside the leading view, never
//      ranked or voted away.
//  It reads the tested services (supportOrigins, reviewDependence, alternatives); nothing is decided for the person.
//

import SwiftUI
import os

struct CaseMapOriginsBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let node: CaseMapNode
    let actor: String
    let closed: Bool
    @State private var origins: CaseSupportOrigins?
    @State private var alternative: CaseAlternativeExplanation?
    @State private var failure: String?
    @State private var reason = ""
    @State private var notice: String?

    private var recordID: UUID? { UUID(uuidString: node.id.recordID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let origins {
                Text("Independent origins").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(origins.line).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("case.map.origins")
                ForEach(Array(origins.joinedUnreviewed.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Two sources share wording — \(pair.basis). Counted as one origin until you review them.")
                            .font(.caption2).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            TextField("Why", text: $reason).textFieldStyle(.roundedBorder).font(.caption)
                            Button("Independent") { Task { await review(pair, .independent) } }
                                .disabled(closed || reason.trimmingCharacters(in: .whitespaces).isEmpty)
                                .caseMapControlHelp("Independent")
                            Button("One origin") { Task { await review(pair, .dependent) } }
                                .disabled(closed || reason.trimmingCharacters(in: .whitespaces).isEmpty)
                                .caseMapControlHelp("One origin")
                        }
                        .controlSize(.small)
                    }
                }
            }
            if let alternative {
                Text("This explanation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Recorded as \(alternative.status). Kept beside the other explanations; the app does not rank or vote between them.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("Cited for it (\(alternative.materialFor.count)): " + (alternative.materialFor.isEmpty ? "nothing yet" : alternative.materialFor.joined(separator: "; ")))
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
                Text("Cited against it (\(alternative.materialAgainst.count)): " + (alternative.materialAgainst.isEmpty ? "nothing yet — what would weaken it is not recorded" : alternative.materialAgainst.joined(separator: "; ")))
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
            if let notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
        }
        .task(id: node.id) { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file, let id = recordID else { return }
        failure = nil
        do {
            switch node.id.kind {
            case .allegation: origins = try await file.supportOrigins(caseID: caseID, allegationID: id)
            case .hypothesis: alternative = try await file.alternatives(caseID: caseID).explanations.first { $0.id == id }
            default: break
            }
        } catch {
            KalsmritikoshLog.ui.error("Origins read failed: \(error.localizedDescription, privacy: .public)")
            failure = "What this rests on could not be read (\(error.localizedDescription)); it is not shown as independent."
        }
    }

    private func review(_ pair: CaseDerivedTextPair, _ judgment: CaseDependenceJudgment) async {
        guard let file = appState.caseFiles?.file else { return }
        do {
            _ = try await file.reviewDependence(caseID: caseID, sourceA: pair.a, sourceB: pair.b, judgment: judgment, detectedBasis: pair.basis,
                                                rationale: reason, actor: actor)
            reason = ""
            notice = judgment == .independent ? "Recorded as independent: they count as two origins." : "Recorded as one origin."
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Dependence review failed: \(error.localizedDescription, privacy: .public)")
            notice = "Not recorded: \(error.localizedDescription)"
        }
    }
}
