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
    /// MAP-13: "Check this claim in the documents" — the review closes and the claim check opens with this question, its
    /// supporting and contrary queries prefilled and editable (nil where the sheet is shown without the map's commands).
    var checkClaim: ((String) -> Void)? = nil
    @State private var question = ""
    @State private var review: CaseMethodReviewResult?
    @State private var problems: [String] = []
    @State private var loading = true
    @State private var showAll = false
    /// Case plan 2026-11-16 (ACTION-14/15): the checks to do next, and the person's reordering with reasons.
    @State private var checks: [CaseCheck] = []
    @State private var overrides: [CaseCheckOverride] = []
    @State private var showAllChecks = false
    @State private var moving: CaseCheck?
    @State private var moveReason = ""
    @State private var notice: String?
    /// AI-15: the AI's method reviews kept for this case (checked against what was sent), and a run in progress.
    @State private var aiReviews: [CaseAIMethodReviewRecord] = []
    @State private var aiRunning = false
    @State private var aiReport: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.question == nil ? "What haven't we considered?" : "Investigate this discrepancy").font(.title3.weight(.semibold))
            Text(target.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField("The question to review the methods against", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("case.methodReview.question")
                Button("Review again") { Task { await load() } }.disabled(loading)
                if let checkClaim {
                    Button("Check this claim in the documents") { let q = question; done(); checkClaim(q) }
                        .disabled(reason: question.trimmingCharacters(in: .whitespaces).isEmpty ? "Write the question first." : nil)
                        .caseMapControlHelp("Check this claim in the documents")
                }
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
                        checksPart
                        aiPart
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

    /// The AI's review, labelled and apart from the offline one: run only when asked; every quote verified word for word in
    /// the documents sent or the check marked ungrounded; a method the reply did not cover is "not assessed".
    @ViewBuilder private var aiPart: some View {
        HStack {
            Button("Ask the AI to review the methods") { Task { await runAI() } }
                .disabled(reason: aiRunning ? "A review is in progress." : (question.trimmingCharacters(in: .whitespaces).isEmpty ? "Write the question first." : nil))
                .caseMapControlHelp("Ask the AI to review the methods")
            if aiRunning { ProgressView().controlSize(.small) }
        }
        if let aiReport { Text(aiReport).font(.caption).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.methodReview.aiReport") }
        if let latest = aiReviews.first {
            DisclosureGroup("The AI's review — \(latest.recordedAt.formatted(date: .abbreviated, time: .shortened)), for “\(latest.question)”") {
                Text("Labelled as the AI's suggestion. It decides nothing; the offline review above stays the case's own.").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(latest.outcomeLabels.enumerated()), id: \.offset) { _, a in
                    Text("\(a.label): \(a.outcome) — \(a.reason)").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(latest.checks.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text((c.ungrounded ? "AI suggestion (ungrounded): " : "AI suggestion: ") + c.observation + (c.target.isEmpty ? "" : " — from \(c.target)"))
                            .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        ForEach(c.predicts.sorted { $0.key < $1.key }, id: \.key) { k, v in Text("If \(k): \(v)").font(.caption2) }
                        ForEach(c.quotes, id: \.self) { Text("“\($0)”").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if !latest.dropped.isEmpty {
                    Text("Not kept (\(latest.dropped.count)): " + latest.dropped.joined(separator: "; ")).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .accessibilityIdentifier("case.methodReview.ai")
        }
    }

    private func runAI() async {
        guard let ai = appState.caseAIAssist else { aiReport = "The AI is not available on this Mac now; the offline review above is complete without it."; return }
        aiRunning = true; defer { aiRunning = false }
        do {
            let run = try await ai.runMethodReview(caseID: target.caseID, question: question, methods: CaseMethodReviewMethod.registered, actor: actor)
            aiReport = run.result == nil ? (run.report.reason ?? "Nothing was kept.") : "Kept: the AI's review, checked against the \(run.report.coverage?.sent ?? 0) document(s) sent."
            aiReviews = try await ai.methodReviews(caseID: target.caseID)
        } catch {
            KalsmritikoshLog.ui.error("AI method review not run: \(error.localizedDescription, privacy: .public)")
            aiReport = "Not run: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var checksPart: some View {
        Text(checks.isEmpty ? "No check is waiting: no open request, no contradiction to decide, no method useful now." : "Checks to do next (\(checks.count))")
            .font(.headline)
        Text("Ordered by a deadline with a recorded source, then how many open explanations a check bears on, then known effort. The order is for work, not a measure of what is true.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        let shown = showAllChecks ? checks : Array(checks.prefix(CaseCheckShortlist.shortlistSize))
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(i + 1). \(c.title)").font(.callout.weight(.semibold)).lineLimit(2)
                    Spacer()
                    if i > 0 {
                        Button("Move to the top…") { moving = c; moveReason = "" }.controlSize(.small)
                            .caseMapControlHelp("Move to the top…")
                    }
                }
                Text(c.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if c.mergedFrom.count > 1 { Text("One check for \(c.mergedFrom.count) proposals asking for the same thing.").font(.caption2) }
                if let why = c.overrideReason { Text("Moved by you: \(why)").font(.caption2).foregroundStyle(.orange) }
            }
            .padding(6)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
        if checks.count > CaseCheckShortlist.shortlistSize {
            Toggle("Show all \(checks.count) checks", isOn: $showAllChecks).toggleStyle(.checkbox)
        }
        if let m = moving {
            HStack {
                TextField("Why this comes first", text: $moveReason).textFieldStyle(.roundedBorder)
                Button("Move") {
                    overrides.removeAll { $0.checkID == m.id }
                    overrides.append(CaseCheckOverride(checkID: m.id, position: 0, reason: moveReason))
                    moving = nil
                    Task {
                        do { try await appState.caseFiles?.file.logAction(caseID: target.caseID, action: "check order changed", detail: m.title + ": " + moveReason, actor: actor) } catch {
                            KalsmritikoshLog.ui.error("Check order log failed: \(error.localizedDescription, privacy: .public)")
                        }
                        await load()
                    }
                }
                .disabled(moveReason.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { moving = nil }
            }
        }
        Divider()
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
        if let ai = appState.caseAIAssist {
            do { aiReviews = try await ai.methodReviews(caseID: target.caseID) }
            catch { KalsmritikoshLog.ui.error("AI method reviews not read: \(error.localizedDescription, privacy: .public)") }
        }
        loading = true
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await appState.caseMethodReview(caseID: target.caseID, question: asked.isEmpty ? nil : asked, overrides: overrides)
        review = r.review; checks = r.checks; problems = r.problems
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
