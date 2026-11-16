//
//  CaseMethodReviewSheet.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (MAP-13, REASON-14) — the sheet behind "What haven't we considered?" and "Investigate this
//  discrepancy…": every registered method reviewed against the case (or one item of it), the few useful now first and
//  "Show all" for the rest, each with its reason. AI off; nothing is decided. "Start this method" creates a draft run
//  of the method in this case through the existing lifecycle — it never completes one.
//

import SwiftUI
import os

/// What the review is about: the whole case, or one item of the map (its title becomes the question).
struct CaseMethodReviewTarget: Identifiable {
    let caseID: UUID
    /// nil: the case's own question. Otherwise the question asked about one item.
    let question: String?
    let title: String
    var id: String { caseID.uuidString + (question ?? "") }
}

struct CaseMethodReviewSheet: View {
    @Environment(AppState.self) private var appState
    let target: CaseMethodReviewTarget
    let actor: String
    let closed: Bool
    let done: () -> Void
    @State private var question = ""
    @State private var review: CaseMethodReviewResult?
    @State private var problems: [String] = []
    @State private var loading = true
    @State private var showAll = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.question == nil ? "What haven't we considered?" : "Investigate this discrepancy").font(.title3.weight(.semibold))
            Text(target.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField("The question to review the methods against", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("case.methodReview.question")
                Button("Review again") { Task { await load() } }.disabled(loading)
            }
            Text("Every method is checked against what this case records, on this Mac with AI off. A method listed here is a suggestion: nothing is decided, and nothing is marked as done.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice { Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true) }
            if loading {
                ProgressView("Reading the case…")
            } else if let review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        let now = review.shortlist
                        Text(now.isEmpty ? "No method is useful right now on what the case records." : "Useful now (\(now.count))")
                            .font(.headline)
                        ForEach(now) { row($0) }
                        Toggle("Show all \(review.assessments.count) methods", isOn: $showAll)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("case.methodReview.showAll")
                        if showAll {
                            ForEach(review.assessments.filter { $0.outcome != .usefulNow }) { row($0) }
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420)
        .task {
            question = target.question ?? ""
            await load()
        }
    }

    private func row(_ a: CaseMethodAssessment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(a.label).font(.callout.weight(.semibold))
                Text(a.outcome.label).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(color(a.outcome).opacity(0.15), in: Capsule())
                Spacer()
                if a.outcome == .usefulNow && a.priorRunID == nil {
                    Button("Start this method") { Task { await start(a) } }
                        .controlSize(.small)
                        .disabled(closed)
                        .caseMapControlHelp("Start this method")
                }
            }
            Text(a.contributes).font(.caption).italic()
            Text(a.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("case.methodReview.row")
    }

    private func color(_ o: CaseMethodApplicability) -> Color {
        switch o {
        case .usefulNow: return .accentColor
        case .alreadyCovered: return .green
        case .needsInput, .notAssessed: return .orange
        case .usefulLater, .inapplicable: return .secondary
        }
    }

    private func load() async {
        loading = true
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await appState.caseMethodReview(caseID: target.caseID, question: asked.isEmpty ? nil : asked)
        review = r.review; problems = r.problems
        if question.isEmpty, let q = r.review?.question { question = q }
        loading = false
    }

    /// Creates a draft run of the method in this case (the existing lifecycle); the review then shows it to continue.
    private func start(_ a: CaseMethodAssessment) async {
        guard let methods = appState.investigationMethods else { notice = "The method engine is not available."; return }
        do {
            _ = try await methods.startMethod(caseID: target.caseID, methodDefinitionID: a.methodID, evidenceSpecs: [], createdBy: actor, now: Date())
            notice = "\(a.label) is started as a draft run in this case. It is not complete until its steps are recorded and reviewed."
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Start method failed: \(error.localizedDescription, privacy: .public)")
            notice = "\(a.label) could not be started: \(error.localizedDescription)"
        }
    }
}
