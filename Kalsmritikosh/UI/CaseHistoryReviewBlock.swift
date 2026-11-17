//
//  CaseHistoryReviewBlock.swift
//  Kalsmritikosh
//
//  Reachability recheck 2026-11-17 (QA-16) — the history set's work with one other case, whose services had no screen:
//  • HISTORY-04: compare this case with it — similarities, differences and the limits of the comparison; it records
//    nothing, and a likeness is never a common cause or a same-person decision.
//  • HISTORY-03: reference one of its questions explicitly — pinned to a recorded state or following the record — and read
//    the reference as it is today (re-checked; unavailable when the scope or the record no longer allows it).
//  • HISTORY-06: pin what that case had recorded at a moment, and read what was known then, with its revisions and the
//    history that is absent — later evidence is never shown as known earlier.
//  • HISTORY-05: start a review of it (this case becomes the review case) and record the review's findings about a
//    referenced record, each traced back to the original decision; the original case is never written.
//

import SwiftUI
import os

struct CaseHistoryReviewBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let source: CaseHistorySource
    let originTitle: String
    let service: CaseMapService?
    @State private var comparison: CaseHistoryComparisonCrossCase?
    @State private var references: [CaseCrossReferenceView] = []
    @State private var findings: [CaseReviewFinding] = []
    @State private var questions: [CaseAllegation] = []
    @State private var question: UUID?
    @State private var mode: CaseCrossReferenceMode = .live
    @State private var purpose = ""
    @State private var moment = ""
    @State private var known: [UUID: CaseOriginKnownAt] = [:]
    @State private var traces: [UUID: CaseReviewTrace] = [:]
    @State private var isReview = false
    @State private var assessment: CaseReviewAssessment = .observation
    @State private var findingText = ""
    @State private var state: CaseToolState = .ready
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                CaseToolStateView(state: state)
                HStack {
                    Button("Compare with this case") { Task { await compare() } }.caseMapControlHelp("Compare with this case")
                    if !isReview {
                        Button("Start a review of this case") { Task { await startReview() } }.caseMapControlHelp("Start a review of this case")
                            .disabled(reason: purpose.trimmingCharacters(in: .whitespaces).isEmpty ? "State the review's purpose below." : nil)
                    } else {
                        Text("This case reviews \(originTitle); its findings are written here only.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let c = comparison { comparisonView(c) }
                Text("References to its questions").font(.subheadline.weight(.semibold))
                if source.scope != .records && source.scope != .recordsAndSources {
                    Text("This source's scope (\(source.scope.label)) does not allow referencing its records; add the case again with a scope that includes records.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Question", selection: $question) {
                        Text("Choose a question of that case").tag(UUID?.none)
                        ForEach(questions) { q in Text(String(q.text.prefix(80))).tag(Optional(q.id)) }
                    }
                    Picker("Reference", selection: $mode) { ForEach(CaseCrossReferenceMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                    HStack {
                        TextField("Purpose (why this record is referenced)", text: $purpose).textFieldStyle(.roundedBorder)
                        TextField("Known at (yyyy-MM-dd), for a pinned state", text: $moment).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                    HStack {
                        Button("Reference this question") { Task { await reference() } }.caseMapControlHelp("Reference this question")
                            .disabled(reason: question == nil || purpose.trimmingCharacters(in: .whitespaces).isEmpty ? "Choose a question and state the purpose." : nil)
                        Button("Pin as known at that day") { Task { await pinKnownAt() } }.caseMapControlHelp("Pin as known at that day")
                            .disabled(reason: question == nil || purpose.trimmingCharacters(in: .whitespaces).isEmpty || CaseMoneyLedger.date(moment.trimmingCharacters(in: .whitespaces)) == nil
                                      ? "Choose a question, state the purpose and write the day yyyy-MM-dd." : nil)
                    }
                }
                ForEach(references, id: \.reference.id) { v in referenceView(v) }
            }
            .padding(.leading, 8)
        } label: {
            Text("Work with \(originTitle)").font(.callout.weight(.semibold))
        }
        .onChange(of: expanded) { _, open in if open { Task { await load() } } }
    }

    @ViewBuilder private func comparisonView(_ c: CaseHistoryComparisonCrossCase) -> some View {
        Text(CaseHistoryComparisonCrossCase.caution).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        ForEach(Array(c.similarities.enumerated()), id: \.offset) { _, l in
            Text("Alike — \(l.aspect): here \(l.thisCase); there \(l.otherCase)" + (l.note.isEmpty ? "" : " (\(l.note))")).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(c.differences.enumerated()), id: \.offset) { _, l in
            Text("Different — \(l.aspect): here \(l.thisCase); there \(l.otherCase)" + (l.note.isEmpty ? "" : " (\(l.note))")).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(c.limitations, id: \.self) { Text("Limit: \($0)").font(.caption2).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func referenceView(_ v: CaseCrossReferenceView) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((v.title ?? "A record of \(originTitle)") + " — " + v.reference.mode.label).font(.caption.weight(.semibold))
            switch v.state {
            case .available:
                if let w = v.wording { Text("“\(w)”").font(.caption).fixedSize(horizontal: false, vertical: true) }
                Text([v.statusText, "as of \(v.asOf)", v.note].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                if !v.work.isEmpty { Text("Its work: " + v.work.joined(separator: "; ")).font(.caption2).foregroundStyle(.secondary) }
            case .unavailable(let why):
                Text("Unavailable: \(why)").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("What was known then") { Task { await knownThen(v.reference) } }.controlSize(.small).caseMapControlHelp("What was known then")
                    .disabled(reason: CaseMoneyLedger.date(moment.trimmingCharacters(in: .whitespaces)) == nil ? "Write the day above (yyyy-MM-dd)." : nil)
            }
            if let k = known[v.reference.id] {
                Text(Self.knownLine(k.knownAt)).font(.caption2)
                ForEach(k.revisions, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                Text(k.absentHistory).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if isReview {
                ForEach(findings.filter { $0.referenceID == v.reference.id && $0.isActive }) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(f.assessment.label): \(f.text)").font(.caption)
                        if let t = traces[f.id] { Text("Original decision: \(t.originalDecision)").font(.caption2).foregroundStyle(.secondary) }
                        else { Button("Trace to the original decision") { Task { await trace(f.id) } }.buttonStyle(.link).font(.caption2) }
                    }
                }
                HStack {
                    Picker("Assessment", selection: $assessment) { ForEach(CaseReviewAssessment.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 260)
                    TextField("The review's finding", text: $findingText).textFieldStyle(.roundedBorder)
                    Button("Record review finding") { Task { await recordFinding(v.reference.id) } }.caseMapControlHelp("Record review finding")
                        .disabled(reason: findingText.trimmingCharacters(in: .whitespaces).isEmpty ? "Write the finding." : nil)
                }
            }
        }
        .padding(6).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    static func knownLine(_ k: CaseKnownAt) -> String {
        switch k {
        case .notRecorded(let b): return "Nothing was recorded then: history is kept from \(b.formatted(date: .abbreviated, time: .omitted))."
        case .noRecordedStateYet(let b): return "No state of that case was recorded yet (history kept from \(b.formatted(date: .abbreviated, time: .omitted)))."
        case .recorded(let c, let exact):
            return (exact ? "Recorded at that moment: " : "The nearest state recorded before it: ") + "\(c.name ?? c.kind.rawValue), \(c.recordedAt.formatted(date: .abbreviated, time: .shortened)) by \(c.recordedBy)."
        }
    }

    // MARK: actions

    private var review: CaseHistoryReviewService? {
        guard let db = appState.database, let file = appState.caseFiles?.file, let map = service ?? CaseMapServiceFactory.map(appState) else { return nil }
        return CaseHistoryReviewService(database: db, file: file, map: map)
    }
    private func fail(_ error: Error, _ doing: String) {
        KalsmritikoshLog.ui.error("History review, \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)")
        state = .from(error, doing: doing)
    }

    private func load() async {
        guard let file = appState.caseFiles?.file, let review, let origin = source.originCaseID else { return }
        do {
            isReview = try await file.reviewedCases(caseID: caseID).contains(origin)
            if source.scope == .records || source.scope == .recordsAndSources { questions = try await file.allegations(caseID: origin) }
            let refs = try await file.crossReferences(caseID: caseID).filter { $0.historySourceID == source.id && $0.isActive }
            var views: [CaseCrossReferenceView] = []
            for r in refs { views.append(try await review.resolve(caseID: caseID, referenceID: r.id)) }
            references = views
            findings = isReview ? try await file.reviewFindings(caseID: caseID) : []
            state = .ready
        } catch { fail(error, "reading the history set") }
    }
    private func compare() async {
        guard let review else { return }
        do { comparison = try await review.compare(caseID: caseID, historySourceID: source.id) } catch { fail(error, "comparing cases") }
    }
    private func origin() -> CaseMapNodeID? {
        guard let o = source.originCaseID, let q = question else { return nil }
        return CaseMapNodeID(caseID: o, kind: .allegation, id: q)
    }
    private func reference() async {
        guard let file = appState.caseFiles?.file, let node = origin() else { return }
        do {
            // A pinned reference needs a recorded state: "Pin as known at that day" finds it; here it follows the record or the latest state.
            if mode == .snapshot, let review, let day = CaseMoneyLedger.date(moment.trimmingCharacters(in: .whitespaces)) {
                _ = try await review.pinAsKnownAt(caseID: caseID, historySourceID: source.id, origin: node, at: day.addingTimeInterval(86_399), purpose: purpose, actor: actor)
            } else {
                _ = try await file.addCrossReference(caseID: caseID, historySourceID: source.id, origin: node, mode: mode, purpose: purpose, actor: actor)
            }
            purpose = ""; await load()
        } catch { fail(error, "referencing other cases") }
    }
    private func pinKnownAt() async {
        guard let review, let node = origin(), let day = CaseMoneyLedger.date(moment.trimmingCharacters(in: .whitespaces)) else { return }
        do { _ = try await review.pinAsKnownAt(caseID: caseID, historySourceID: source.id, origin: node, at: day.addingTimeInterval(86_399), purpose: purpose, actor: actor); purpose = ""; await load() }
        catch { fail(error, "pinning what was known") }
    }
    private func knownThen(_ r: CaseCrossReference) async {
        guard let review, let day = CaseMoneyLedger.date(moment.trimmingCharacters(in: .whitespaces)) else { return }
        do { known[r.id] = try await review.originKnownAt(caseID: caseID, referenceID: r.id, at: day.addingTimeInterval(86_399)) }
        catch { fail(error, "reading what was known") }
    }
    private func startReview() async {
        guard let file = appState.caseFiles?.file, let o = source.originCaseID else { return }
        do { _ = try await file.startReview(caseID: caseID, of: o, purpose: purpose, actor: actor); purpose = ""; await load() }
        catch { fail(error, "starting a review") }
    }
    private func recordFinding(_ reference: UUID) async {
        guard let file = appState.caseFiles?.file else { return }
        do { _ = try await file.recordReviewFinding(caseID: caseID, referenceID: reference, assessment: assessment, text: findingText, actor: actor); findingText = ""; await load() }
        catch { fail(error, "recording review findings") }
    }
    private func trace(_ finding: UUID) async {
        guard let review else { return }
        do { traces[finding] = try await review.trace(caseID: caseID, findingID: finding) } catch { fail(error, "tracing findings") }
    }
}

/// HISTORY-01 — identifiers this case chooses to look for in other cases (account numbers, references, phones, emails, or a
/// pattern with # for a digit), found by exact whole token; each result states its basis. A same name stays a candidate.
struct CaseOverlapIdentifiersBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let service: CaseMapService?
    @State private var kind: CaseOverlapIdentifierKind = .accountNumber
    @State private var value = ""
    @State private var overlaps: [CaseIdentifierOverlap] = []
    @State private var chosen: [CaseOverlapIdentifier] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Identifiers to look for in other cases").font(.headline)
            HStack {
                Picker("Kind", selection: $kind) { ForEach(CaseOverlapIdentifierKind.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 260)
                TextField(kind == .pattern ? "Pattern, # for a digit (e.g. INV-####)" : "Value exactly as written", text: $value).textFieldStyle(.roundedBorder)
                Button("Look for this identifier") { Task { await choose() } }.caseMapControlHelp("Look for this identifier")
                    .disabled(reason: value.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the identifier." : nil)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if chosen.isEmpty { Text("None chosen.").font(.caption).foregroundStyle(.secondary) }
            ForEach(overlaps) { o in Text(o.summary).font(.caption).fixedSize(horizontal: false, vertical: true) }
            ForEach(chosen.filter { c in !overlaps.contains { $0.identifier.id == c.id } }) { c in
                Text("\(c.kind.label) “\(c.value)” — not read yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let db = appState.database, let file = appState.caseFiles?.file, let map = service ?? CaseMapServiceFactory.map(appState) else { return }
        do {
            chosen = try await file.overlapIdentifiers(caseID: caseID)
            overlaps = try await CaseHistoryReviewService(database: db, file: file, map: map).identifierOverlaps(caseID: caseID)
        } catch {
            KalsmritikoshLog.ui.error("Identifier overlaps not read: \(error.localizedDescription, privacy: .public)")
            message = "Not read: \(error.localizedDescription). Nothing is shown as if there were no overlap."
        }
    }
    private func choose() async {
        guard let file = appState.caseFiles?.file else { return }
        do { _ = try await file.chooseOverlapIdentifier(caseID: caseID, kind: kind, value: value, actor: actor); value = ""; message = nil; await load() }
        catch { KalsmritikoshLog.ui.error("Identifier not chosen: \(error.localizedDescription, privacy: .public)"); message = "Not recorded: \(error.localizedDescription)" }
    }
}
