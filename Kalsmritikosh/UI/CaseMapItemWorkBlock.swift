//
//  CaseMapItemWorkBlock.swift
//  Kalsmritikosh
//
//  Reachability recheck 2026-11-17 (QA-16) — the per-item services that had no screen, in the map inspector of the
//  selected item. Each part is read only when the person opens it.
//  • Any item — TIME-04: its own timeline (events and work kept apart; the case's timeline is the same records together);
//    TIME-03: every time asserted for it, kept as asserted, and choosing one as the interpretation with a reason (the
//    others stay).
//  • Contradiction — REASON-03: both accounts side by side with their context, versions, figures and dates; REASON-04: the
//    cautions that a difference may not be a contradiction, and recording it as an explained difference; REASON-07: a
//    follow-up action with the exact question and the result needed, linked to both accounts, whose outcome may be
//    inconclusive.
//  • Question — REASON-02: each linked document's relation (supports, challenges, mentions, qualifies, not assessed);
//    REASON-10: the inputs frozen with each decision (what it rested on, the alternatives and the reviewer's reason).
//  • Action — ACTION-10: what its child actions hold open (blocked, unassigned, unresolved, waiting for review), each
//    outcome as recorded, never averaged.
//  • Document — IN-06: exact copies, same-content copies and possible earlier versions, and confirming a revision with
//    its basis; nothing is merged.
//

import SwiftUI
import os

struct CaseMapItemWorkBlock: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let node: CaseMapNode
    let projection: CaseMapProjection
    let closed: Bool
    let reload: () async -> Void
    @State private var timeline: [CaseTimelineEntry]?
    @State private var times: CaseRecordTimes?
    @State private var timeReason = ""
    @State private var comparison: CaseConflictComparison?
    @State private var followUps: [CaseConflictFollowUp] = []
    @State private var followQuestion = ""
    @State private var followResult = ""
    @State private var followNote = ""
    @State private var explainedNote = ""
    @State private var evidence: [AllegationEvidence]?
    @State private var decisions: [CaseDecisionInputs]?
    @State private var rollup: CaseActionRollup?
    @State private var sameness: (copies: [UUID], candidates: [UUID], links: [SourceVersionLink])?
    @State private var revisionBasis = ""
    // IN-11
    @State private var attributions: [CaseDocumentAttribution]?
    @State private var suppliedBy = ""
    @State private var claimedAuthor = ""
    @State private var capturedText = ""
    @State private var message: String?

    private var caseID: UUID { model.caseID }
    private var actor: String { model.actor }
    private var recordID: UUID? { UUID(uuidString: node.id.recordID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            switch node.id.kind {
            case .contradiction: contradictionPart
            case .allegation: questionPart
            case .task: actionPart
            case .document: documentPart
            default: EmptyView()
            }
            timePart
        }
        .onChange(of: node.id) { _, _ in
            timeline = nil; times = nil; comparison = nil; followUps = []; evidence = nil; decisions = nil; rollup = nil; sameness = nil; message = nil; attributions = nil
        }
    }

    // MARK: TIME-03 / TIME-04

    /// One timeline row as text. Built in steps: as a single concatenation it timed out the type checker on CI.
    static func timelineLine(_ e: CaseTimelineEntry) -> String {
        let lane: String = e.lane == .event ? "Event" : "Work"
        let when: String = e.eventTime.map { $0.label() + " · " } ?? ""
        let recorded: String = e.recordedAt.formatted(date: .abbreviated, time: .shortened)
        let by: String = e.actor.map { " by \($0)" } ?? ""
        return "\(lane) — \(when)\(e.text) (recorded \(recorded)\(by))"
    }

    @ViewBuilder private var timePart: some View {
        DisclosureGroup("Timeline of this item") {
            if let timeline {
                if timeline.isEmpty { Text("Nothing dated is recorded for it.").font(.caption2).foregroundStyle(.secondary) }
                ForEach(timeline) { e in
                    Text(Self.timelineLine(e))
                        .font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
            } else { ProgressView().controlSize(.small).task { await loadTimes() } }
            if let times {
                ForEach(CaseTypedTimeKind.allCases.filter { times.assertions($0).count > 1 }) { k in
                    let all = times.assertions(k)
                    let chosen: String = times.interpretation(k).map { " — interpreted as \($0.value.label()) (\($0.rationale))" } ?? " — no interpretation chosen"
                    Text("\(k.label): \(all.count) times asserted\(chosen)")
                        .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(all) { t in
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.line).font(.caption2).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Use this time") { Task { await interpret(k, chosen: t.id, considered: all.map(\.id)) } }
                                .controlSize(.mini).caseMapControlHelp("Use this time")
                                .disabled(reason: closed ? "The case is closed." : (timeReason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil),
                                          remedy: "Type why below.")
                        }
                    }
                }
                if !times.assertions.isEmpty, CaseTypedTimeKind.allCases.contains(where: { times.assertions($0).count > 1 }) {
                    TextField("Why this time (kept with the choice; the others stay recorded)", text: $timeReason).textFieldStyle(.roundedBorder).font(.caption)
                }
            }
        }
        .font(.caption)
    }

    private func loadTimes() async {
        guard let file = appState.caseFiles?.file else { return }
        do {
            timeline = try await file.timeline(caseID: caseID, recordKind: node.id.kind.rawValue, recordID: node.id.recordID)
            times = try await file.times(caseID: caseID, recordKind: node.id.kind.rawValue, recordID: node.id.recordID)
        } catch { fail(error, "reading the item's times"); timeline = [] }
    }
    private func interpret(_ k: CaseTypedTimeKind, chosen: UUID, considered: [UUID]) async {
        await act("The interpretation is recorded; every asserted time is kept.") { file in
            _ = try await file.interpretTime(caseID: caseID, recordKind: node.id.kind.rawValue, recordID: node.id.recordID, kind: k, choosing: chosen, value: nil,
                                             considered: considered, rationale: timeReason, actor: actor)
            timeReason = ""; timeline = nil; times = nil
        }
    }

    // MARK: REASON-03 / 04 / 07

    @ViewBuilder private var contradictionPart: some View {
        DisclosureGroup("Both accounts side by side") {
            if let c = comparison {
                ForEach(Array(c.lines.enumerated()), id: \.offset) { _, l in Text(l).font(.caption2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if !c.cautions.isEmpty {
                    Text("It may be a difference, not a contradiction:").font(.caption.weight(.semibold))
                    ForEach(c.cautions, id: \.self) { Label($0.label, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
                }
                HStack {
                    TextField("How the difference is explained", text: $explainedNote).textFieldStyle(.roundedBorder).font(.caption)
                    Button("Record as an explained difference") { Task { await explained() } }.controlSize(.small).caseMapControlHelp("Record as an explained difference")
                        .disabled(reason: closed ? "The case is closed." : (explainedNote.trimmingCharacters(in: .whitespaces).isEmpty ? "Say how it is explained." : nil))
                }
            } else { ProgressView().controlSize(.small).task { await loadComparison() } }
        }
        .font(.caption)
        DisclosureGroup("Follow-up actions (\(followUps.count))") {
            ForEach(followUps) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(f.question) — needed: \(f.neededResult)").font(.caption2).fixedSize(horizontal: false, vertical: true)
                    Text(f.outcome.label + (f.outcomeNote.map { ": \($0)" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                    if f.outcome == .pending {
                        Menu("Record follow-up outcome") {
                            ForEach(CaseFollowUpOutcome.allCases.filter { $0 != .pending }, id: \.self) { o in
                                Button(o.label) { Task { await followOutcome(f.taskID, o) } }
                            }
                        }
                        .controlSize(.small).caseMapControlHelp("Record follow-up outcome")
                        .disabled(reason: followNote.trimmingCharacters(in: .whitespaces).isEmpty ? "Write what the result showed." : nil, remedy: "Type it below.")
                    }
                }
            }
            if followUps.contains(where: { $0.outcome == .pending }) {
                TextField("What the result showed", text: $followNote).textFieldStyle(.roundedBorder).font(.caption)
            }
            TextField("The exact question to settle", text: $followQuestion).textFieldStyle(.roundedBorder).font(.caption)
            TextField("The result needed to settle it", text: $followResult).textFieldStyle(.roundedBorder).font(.caption)
            Button("Create follow-up action") { Task { await createFollowUp() } }.controlSize(.small).caseMapControlHelp("Create follow-up action")
                .disabled(reason: closed ? "The case is closed." : ([followQuestion, followResult].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? "Write the question and the result needed." : nil))
        }
        .font(.caption)
        .task(id: node.id) { await loadFollowUps() }
    }

    private func loadComparison() async {
        guard let desk = appState.investigationContradictionGap, let id = recordID else { return }
        do { comparison = try await desk.comparison(caseID: caseID, contradictionID: id) } catch { fail(error, "comparing the accounts") }
    }
    private func loadFollowUps() async {
        guard let file = appState.caseFiles?.file, let id = recordID else { return }
        do { followUps = try await file.conflictFollowUps(caseID: caseID).filter { $0.contradictionID == id } } catch { fail(error, "reading follow-ups") }
    }
    private func explained() async {
        guard let desk = appState.investigationContradictionGap, let id = recordID else { return }
        do {
            _ = try await desk.reviewContradiction(caseID: caseID, contradictionID: id, decision: .explained, reason: nil, note: explainedNote, actor: actor, at: Date())
            explainedNote = ""; message = "Recorded as an explained difference, with both documents' versions."
            await model.refreshGlance(appState); await reload()
        } catch { fail(error, "recording the decision") }
    }
    private func createFollowUp() async {
        guard let svc = appState.caseFiles, let id = recordID else { return }
        if !model.review.loaded, let desk = appState.investigationContradictionGap { await model.review.load(desk: desk, objects: appState.objects) }
        guard let item = model.review.items.first(where: { $0.id == id }) else { message = "The contradiction is not in the case's review list; choose Refresh."; return }
        let c = item.contradiction
        let va = c.evidenceA.flatMap { item.currentVersions[$0] ?? nil }, vb = c.evidenceB.flatMap { item.currentVersions[$0] ?? nil }
        do {
            _ = try await svc.createConflictFollowUp(caseID: caseID, contradiction: c, versionA: va, versionB: vb, question: followQuestion, neededResult: followResult, actor: actor)
            followQuestion = ""; followResult = ""; message = "Follow-up action created, linked to both accounts."
            await loadFollowUps(); await reload()
        } catch { fail(error, "creating follow-up actions") }
    }
    private func followOutcome(_ task: UUID, _ o: CaseFollowUpOutcome) async {
        await act("Outcome recorded; the contradiction's own decision is separate.") { file in
            try await file.recordFollowUpOutcome(caseID: caseID, taskID: task, outcome: o, note: followNote, actor: actor); followNote = ""
        }
        await loadFollowUps()
    }

    // MARK: REASON-02 / REASON-10

    @ViewBuilder private var questionPart: some View {
        DisclosureGroup("How each linked document bears on it") {
            if let evidence {
                if evidence.isEmpty { Text("No document is linked to this question.").font(.caption2).foregroundStyle(.secondary) }
                ForEach(evidence) { e in
                    HStack {
                        Text(e.label ?? e.evidenceRef).font(.caption2).lineLimit(2)
                        Spacer()
                        Picker("Relation", selection: Binding(get: { e.relation }, set: { r in Task { await setRelation(e.id, r) } })) {
                            ForEach(CaseEvidenceRelation.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 260).controlSize(.small).disabled(closed)
                    }
                }
                Text("Only “Supports” counts as support; a linked document whose relevance is not assessed counts for nothing.").font(.caption2).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small).task { await loadEvidence() } }
        }
        .font(.caption)
        DisclosureGroup("Why it was decided") {
            if let decisions {
                if decisions.isEmpty { Text("No decision is recorded for this question.").font(.caption2).foregroundStyle(.secondary) }
                ForEach(decisions) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(d.lines.enumerated()), id: \.offset) { _, l in Text(l).font(.caption2).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(4).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            } else { ProgressView().controlSize(.small).task { await loadDecisions() } }
        }
        .font(.caption)
    }

    private func loadEvidence() async {
        guard let file = appState.caseFiles?.file, let id = recordID else { return }
        do { evidence = try await file.allegationEvidence(caseID: caseID).filter { $0.allegationID == id } } catch { fail(error, "reading linked documents"); evidence = [] }
    }
    private func setRelation(_ link: UUID, _ r: CaseEvidenceRelation) async {
        await act("Relation recorded.") { try await $0.setEvidenceRelation(caseID: caseID, linkID: link, relation: r, actor: actor) }
        evidence = nil
        await reload()
    }
    private func loadDecisions() async {
        guard let file = appState.caseFiles?.file, let id = recordID else { return }
        do { decisions = try await file.decisionInputs(caseID: caseID, allegationID: id) } catch { fail(error, "reading decisions"); decisions = [] }
    }

    // MARK: ACTION-10

    @ViewBuilder private var actionPart: some View {
        DisclosureGroup("Its child actions") {
            if let r = rollup {
                if r.children.isEmpty { Text("This action has no child actions.").font(.caption2).foregroundStyle(.secondary) }
                else {
                    Text("Blocked \(r.blocked) · waiting \(r.waiting) · unassigned \(r.unassigned) · unresolved \(r.unresolved) · waiting for review \(r.reviewNeeded) · optional \(r.optional)")
                        .font(.caption2.monospacedDigit())
                    Text("Outcomes as recorded: " + r.outcomes.map { "\($0.0.rawValue) \($0.1)" }.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                    if let c = r.closureCriteria { Text("Closes when: \(c)").font(.caption2) }
                    if r.holdingClosure.isEmpty { Text("No required child holds it open.").font(.caption2) }
                    else { Text("Holding it open: " + r.holdingClosure.map(\.title).joined(separator: "; ")).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            } else { ProgressView().controlSize(.small).task { await loadRollup() } }
        }
        .font(.caption)
    }

    private func loadRollup() async {
        guard let svc = appState.caseFiles, let id = recordID else { return }
        do { rollup = try await svc.actionRollup(caseID: caseID, parentTaskID: id) } catch { fail(error, "reading child actions") }
    }

    // MARK: IN-06

    @ViewBuilder private var documentPart: some View {
        if let version = node.sources.first?.sourceVersionID {
            // IN-11: who supplied it, the author it claims, when it was captured — a person's statement, kept apart from
            // who entered it and when it arrived, and never a verification.
            DisclosureGroup("Who supplied it") {
                if let attributions {
                    let mine = attributions.filter { $0.sourceVersionID == version }
                    if mine.isEmpty { Text("Nothing recorded beyond who entered it and when it arrived.").font(.caption2).foregroundStyle(.secondary) }
                    ForEach(mine) { a in Text(a.line).font(.caption2).fixedSize(horizontal: false, vertical: true) }
                    TextField("Supplied by (a person or office)", text: $suppliedBy).textFieldStyle(.roundedBorder).font(.caption)
                    TextField("Author it claims, optional", text: $claimedAuthor).textFieldStyle(.roundedBorder).font(.caption)
                    TextField("When it was captured, as stated (e.g. photo taken 4 March 2026), optional", text: $capturedText).textFieldStyle(.roundedBorder).font(.caption)
                    Button("Record who supplied it") { Task { await recordAttribution(version) } }.controlSize(.small).caseMapControlHelp("Record who supplied it")
                        .disabled(reason: closed ? "The case is closed." : ([suppliedBy, claimedAuthor, capturedText].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                                  ? "Fill at least one of the three." : nil))
                } else { ProgressView().controlSize(.small).task { await loadAttributions() } }
            }
            .font(.caption)
            DisclosureGroup("Copies and versions") {
                if let s = sameness {
                    if s.copies.isEmpty && s.candidates.isEmpty && s.links.isEmpty {
                        Text("No other copy or version of this document is recorded.").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(s.copies, id: \.self) { v in Text("Same content: \(documentName(v))").font(.caption2) }
                    ForEach(s.links.filter(\.isActive), id: \.id) { l in
                        Text("Confirmed revision of \(documentName(l.earlierSourceVersionID)) — \(l.basis) (\(l.confirmedBy))").font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(s.candidates.filter { c in !s.links.contains { $0.earlierSourceVersionID == c && $0.isActive } }, id: \.self) { c in
                        HStack {
                            Text("Possibly a revision of \(documentName(c))").font(.caption2)
                            Spacer()
                            Button("Confirm as a revision") { Task { await confirmRevision(version, earlier: c) } }.controlSize(.mini).caseMapControlHelp("Confirm as a revision")
                                .disabled(reason: revisionBasis.trimmingCharacters(in: .whitespaces).isEmpty ? "Say what shows it is a revision." : nil, remedy: "Type it below.")
                        }
                    }
                    if !s.candidates.isEmpty {
                        TextField("What shows it is a revision (e.g. same memo number, later date)", text: $revisionBasis).textFieldStyle(.roundedBorder).font(.caption)
                    }
                    Text("Nothing is merged: copies and versions stay separate documents with their own receipts.").font(.caption2).foregroundStyle(.secondary)
                } else { ProgressView().controlSize(.small).task { await loadSameness(version) } }
            }
            .font(.caption)
        }
    }

    private func loadAttributions() async {
        guard let file = appState.caseFiles?.file else { return }
        do { attributions = try await file.documentAttributions(caseID: caseID) } catch { fail(error, "reading who supplied it"); attributions = [] }
    }
    private func recordAttribution(_ version: UUID) async {
        await act("Recorded; the document itself is unchanged and not verified by this.") { file in
            _ = try await file.recordDocumentAttribution(caseID: caseID, sourceVersionID: version, suppliedBy: suppliedBy, claimedAuthor: claimedAuthor,
                                                         capturedText: capturedText, note: nil, actor: actor)
            suppliedBy = ""; claimedAuthor = ""; capturedText = ""
        }
        attributions = nil
    }

    private func documentName(_ version: UUID) -> String {
        projection.nodes.first { $0.id.kind == .document && $0.sources.contains { $0.sourceVersionID == version } }?.title ?? "a document not in this case's map"
    }
    private func loadSameness(_ version: UUID) async {
        guard let db = appState.database else { return }
        let repo = SourceSamenessRepository(database: db)
        do {
            sameness = (try await repo.contentEquivalents(of: version), try await repo.revisionCandidates(for: version), try await repo.revisionLinks(of: version))
        } catch { fail(error, "reading copies and versions"); sameness = ([], [], []) }
    }
    private func confirmRevision(_ revised: UUID, earlier: UUID) async {
        guard let db = appState.database else { return }
        do {
            _ = try await SourceSamenessRepository(database: db).confirmRevision(revised: revised, earlier: earlier, basis: revisionBasis, actor: actor, at: Date())
            revisionBasis = ""; message = "Confirmed as a revision; both documents are kept."; sameness = nil
        } catch { fail(error, "confirming revisions") }
    }

    // MARK: shared

    private func act(_ done: String, _ body: (CaseFileRepository) async throws -> Void) async {
        guard let file = appState.caseFiles?.file else { return }
        do { try await body(file); message = done } catch { fail(error, "recording it") }
    }
    private func fail(_ error: Error, _ doing: String) {
        KalsmritikoshLog.ui.error("Case map item work, \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)")
        message = "Not done (\(doing)): \(error.localizedDescription)"
    }
}

/// PEOPLE-07 — the versioned rule's assessment of two person rows, with every reason and what it counts for. Reading the
/// stored assessment records nothing; "Check with the matching rules" stores a new assessment (no decision, no merge).
struct CasePersonMatchBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let personA: UUID
    let personB: UUID
    let actor: String
    @State private var assessment: CasePersonMatchAssessment?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let a = assessment {
                Text("\(a.verdict.label) (rule version \(a.ruleVersion), \(a.assessedAt.formatted(date: .abbreviated, time: .shortened)))")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                ForEach(a.reasons, id: \.self) { r in Text("• \(r.detail) — \(r.counts)").font(.caption2).fixedSize(horizontal: false, vertical: true) }
            } else {
                Text("Not yet checked with the matching rules.").font(.caption2).foregroundStyle(.secondary)
            }
            Button("Check with the matching rules") { Task { await assess() } }.controlSize(.small).caseMapControlHelp("Check with the matching rules")
            if let message { Text(message).font(.caption2).foregroundStyle(.red) }
        }
        .task(id: personA) { await load() }
    }

    static func latest(_ all: [CasePersonMatchAssessment], _ a: UUID, _ b: UUID) -> CasePersonMatchAssessment? {
        all.filter { Set([$0.personA, $0.personB]) == Set([a, b]) }.max { $0.assessedAt < $1.assessedAt }
    }
    private func load() async {
        guard let file = appState.caseFiles?.file else { return }
        do { assessment = Self.latest(try await file.matchAssessments(caseID: caseID), personA, personB) }
        catch { KalsmritikoshLog.ui.error("Match assessment not read: \(error.localizedDescription, privacy: .public)"); message = "Not read: \(error.localizedDescription)" }
    }
    private func assess() async {
        guard let file = appState.caseFiles?.file else { return }
        do { assessment = try await file.assessSamePerson(caseID: caseID, personA: personA, personB: personB, actor: actor); message = nil }
        catch { KalsmritikoshLog.ui.error("Match assessment not made: \(error.localizedDescription, privacy: .public)"); message = "Not checked: \(error.localizedDescription)" }
    }
}
