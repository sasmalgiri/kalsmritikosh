//
//  JobRunnerView.swift
//  Kalsmritikosh
//
//  JOB-RUN — the guided, step-by-step job walkthrough (owner request
//  2026-08-15, UX ported from maxmailin's paged guide: Previous / Next /
//  Save / progress / per-step guide + help text). Content is 100% THIS
//  project's: every page is driven by the job's own JobDocumentation row
//  (ordered workflow steps, required inputs, professional methods, human
//  decisions, work products, prohibited conclusions) — the same SAP-style
//  matrix the ⓘ sheet shows, walked one step at a time.
//
//  The runner never becomes a second engine: "Run job now" calls the SAME
//  PersonaJobService launch path as the card's Run button. Walkthrough
//  progress (current step per job) is UI state, persisted in UserDefaults
//  so "Save & close" resumes exactly where the user left off — it is NOT
//  evidence and never touches the ledger.
//

import SwiftUI

// MARK: - Save & resume (UI walkthrough state, not evidence)

enum JobRunnerProgress {
    private static func key(_ jobID: String) -> String { "kalsmritikosh.jobrunner.step.\(jobID)" }

    /// The saved step index for a job, if a walkthrough is in progress.
    static func savedStep(jobID: String) -> Int? {
        let v = UserDefaults.standard.object(forKey: key(jobID)) as? Int
        return v.flatMap { $0 >= 0 ? $0 : nil }
    }

    static func save(jobID: String, step: Int) {
        UserDefaults.standard.set(step, forKey: key(jobID))
    }

    static func clear(jobID: String) {
        UserDefaults.standard.removeObject(forKey: key(jobID))
    }
}

// MARK: - The guided runner

struct JobRunnerView: View {
    let job: PersonaJob
    let doc: JobDocumentation
    /// Whether "Run job now" may launch (a matter is open, not busy).
    let canRun: Bool
    /// Launches the REAL job via the existing PersonaJobService path.
    let onRun: () -> Void
    let onClose: () -> Void

    @State private var step: Int = 0

    /// The ordered workflow steps from the coverage matrix ("a; b; c").
    static func steps(of doc: JobDocumentation) -> [String] {
        doc.workflow
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var steps: [String] { Self.steps(of: doc) }
    private var isLast: Bool { step >= steps.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepTitle
                    guideBoxes
                    guardrails
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .onAppear {
            // Resume where the user left off (clamped — the matrix may change).
            if let saved = JobRunnerProgress.savedStep(jobID: doc.jobID) {
                step = min(max(saved, 0), max(steps.count - 1, 0))
            }
        }
    }

    // MARK: Header — job identity + live progress

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "signpost.right.fill")
                    .foregroundStyle(Theme.brand)
                Text(doc.name).font(.headline)
                Text(doc.jobID)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.brand.opacity(0.12), in: Capsule())
                Spacer()
                Text("Step \(step + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(step + 1), total: Double(max(steps.count, 1)))
                .tint(Theme.brand)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Step body — the guide

    private var stepTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(steps.indices.contains(step) ? steps[step] : "Review & run")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Work through this step in the app, then press Next. Your place is saved if you close.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Contextual help boxes: inputs up front, methods mid-way, decisions and
    /// work products at the end — all from the job's own documentation row.
    @ViewBuilder
    private var guideBoxes: some View {
        if step == 0, !doc.requiredInputs.isEmpty {
            helpBox(icon: "tray.and.arrow.down", title: "You'll need",
                    help: "Have these ready before you start — the job can't proceed without them.",
                    bullets: doc.requiredInputs)
        }
        if step > 0, !isLast, !doc.methods.isEmpty {
            helpBox(icon: "wrench.and.screwdriver", title: "Professional methods for this step",
                    help: "Structured methods this job may use — run them from the Methods surface.",
                    bullets: doc.methods)
        }
        if isLast {
            if !doc.humanDecisions.isEmpty {
                helpBox(icon: "person.crop.circle.badge.checkmark", title: "You decide",
                        help: "These calls are always yours — the app never makes them for you.",
                        bullets: doc.humanDecisions)
            }
            if !doc.workProducts.isEmpty {
                helpBox(icon: "shippingbox", title: "This job produces",
                        help: "The durable work products, each citing its evidence.",
                        bullets: doc.workProducts)
            }
        }
    }

    /// The guardrails ride on EVERY page — what this job must never assert.
    @ViewBuilder
    private var guardrails: some View {
        if !doc.prohibitedConclusions.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                    .padding(.top, 2)
                Text("This job never: \(doc.prohibitedConclusions.joined(separator: " · "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func helpBox(icon: String, title: String, help: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(Theme.brand).imageScale(.small)
                Text(title).font(.caption.weight(.semibold))
            }
            Text(help).font(.caption2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bullets, id: \.self) { b in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Theme.brand)
                            .imageScale(.small)
                            .padding(.top, 1)
                        Text(b).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Footer — Previous / Next / Save / Run

    private var footer: some View {
        HStack {
            Button("Save & close") {
                JobRunnerProgress.save(jobID: doc.jobID, step: step)
                onClose()
            }
            .help("Keeps your place — reopen the guide any time to resume this step.")
            Spacer()
            if step > 0 {
                Button("Previous") {
                    step -= 1
                    JobRunnerProgress.save(jobID: doc.jobID, step: step)
                }
            }
            if !isLast {
                Button("Next") {
                    step += 1
                    JobRunnerProgress.save(jobID: doc.jobID, step: step)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
            } else {
                Button {
                    JobRunnerProgress.clear(jobID: doc.jobID)
                    onRun()
                    onClose()
                } label: {
                    Label("Run job now", systemImage: "arrow.right.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .disabled(!canRun)
                .help(canRun ? "Launches this job against the open matter."
                             : "Open a matter first (Start matter above), then run.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#if DEBUG
#Preview("Job runner — guided steps") {
    JobRunnerView(
        job: PersonaJob(persona: "p", id: "inv.caseIntake", title: "Case intake & scope",
                        detail: "Create case; define mandate.", kind: .caseIntake),
        doc: JobDocumentationCatalog.doc(forJobID: "INV-01")!,
        canRun: true, onRun: {}, onClose: {}
    )
}
#endif
