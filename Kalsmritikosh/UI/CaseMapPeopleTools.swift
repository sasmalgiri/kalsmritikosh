//
//  CaseMapPeopleTools.swift
//  Kalsmritikosh
//
//  Reachability recheck 2026-11-17 (QA-16) — screens for the S6 people services that had none:
//  • People in the case (PEOPLE-01/02/03/04): one row per person with every role they hold in the case (identity kept
//    apart from role; a role never implies wrongdoing), the sourced profile where every line says where it comes from,
//    whereabouts recorded as past observations with their precision and source (never "where they are"), and the
//    statement's questions and answers, corrected after confirmation only as a recorded correction with its reason.
//  • Team and work (PEOPLE-06/08/09): the case team, ending a membership with the open work handed to a named person,
//    each investigator's work history (every entry opens its record on the map), declared capabilities and absences,
//    conflict checks, and who could take a piece of work — alphabetical, each with its declared reasons, never ranked.
//  Every change goes through the existing repository, which checks roles, the closed case and the inputs.
//

import SwiftUI
import os

// MARK: - People in the case

struct CasePeopleInCaseTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var people: [CasePersonIdentityView] = []
    @State private var selected: UUID?
    @State private var profile: CasePersonProfile?
    @State private var history: [CaseStatementHistoryEntry] = []
    @State private var interviews: [CaseInterview] = []
    @State private var items: [CaseInterviewItem] = []
    @State private var documents: [CaseMoneyDocument] = []
    @State private var notice: String?
    // Add a person or a role
    @State private var name = ""
    @State private var roleKind: CasePersonRoleKind = .witness
    @State private var roleContext = ""
    @State private var reason = ""
    // Profile line
    @State private var attrKind: CasePersonAttributeKind = .organisation
    @State private var attrValue = ""
    @State private var attrOrigin: CasePersonAttributeOrigin = .source
    @State private var attrSource: UUID?
    @State private var attrQuote = ""
    @State private var suppliedBy = ""
    // Whereabouts
    @State private var place = ""
    @State private var placeDay = ""
    @State private var timePrecision: CaseLocationTimePrecision = .day
    @State private var placePrecision: CaseLocationPlacePrecision = .city
    @State private var basis: CaseLocationBasis = .source
    @State private var placeSource: UUID?
    @State private var uncertainty = ""
    // Statement
    @State private var question = ""
    @State private var response = ""
    @State private var correcting: CaseInterviewItem?
    @State private var correction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Person's name as the documents write it", text: $name).textFieldStyle(.roundedBorder)
                Picker("Role", selection: $roleKind) { ForEach(CasePersonRoleKind.allCases) { Text($0.label).tag($0) } }.frame(maxWidth: 260)
            }
            HStack {
                TextField("In what context (e.g. account ending 4471), optional", text: $roleContext).textFieldStyle(.roundedBorder)
                Button("Add person or role") { Task { await addPersonOrRole() } }.caseMapControlHelp("Add person or role")
                    .disabled(reason: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the person's name." : nil)
            }
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.people.notice") }
            if people.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "No person is recorded in this case.", next: "Add one above with the role they have in this case."))
            }
            ForEach(people) { v in
                Button { Task { await choose(v.person.id) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.person.name).font(.callout.weight(selected == v.person.id ? .semibold : .regular))
                        Text(v.roles.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !v.sameEntityRows.isEmpty {
                            Text("\(v.sameEntityRows.count) other row(s) are linked to the same person in the documents; they stay separate until you decide.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("case.people.row")
            }
            if let p = profile { profileSection(p) }
        }
        .sheet(item: $correcting) { item in correctionSheet(item) }
        .task { await load() }
    }

    @ViewBuilder private func profileSection(_ p: CasePersonProfile) -> some View {
        Divider()
        Text("Profile of \(p.person.name)").font(.headline)
        Text("Each line says where it comes from; a supplied or unsourced line is never shown as checked.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        if !p.isRestricted {
            TextField("Reason (needed to end a role or withdraw a line)", text: $reason).textFieldStyle(.roundedBorder)
            ForEach(p.roles.filter(\.isActive)) { r in
                HStack {
                    Text(r.line).font(.caption)
                    Spacer()
                    Button("End role…") { Task { await endRole(r.id) } }.controlSize(.small).caseMapControlHelp("End role…")
                        .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason above.")
                }
            }
            ForEach(p.attributes.filter(\.isActive)) { a in
                HStack {
                    Text(a.line).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Withdraw line…") { Task { await withdraw(a.id) } }.controlSize(.small).caseMapControlHelp("Withdraw line…")
                        .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason above.")
                }
            }
            attributeForm
            whereaboutsForm
            statementSection
        }
    }

    @ViewBuilder private var attributeForm: some View {
        Text("Add a profile line").font(.subheadline.weight(.semibold))
        HStack {
            Picker("Kind", selection: $attrKind) { ForEach(CasePersonAttributeKind.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 240)
            TextField("Value", text: $attrValue).textFieldStyle(.roundedBorder)
        }
        HStack {
            Picker("Comes from", selection: $attrOrigin) {
                Text("A document in the case").tag(CasePersonAttributeOrigin.source)
                Text("Supplied by someone").tag(CasePersonAttributeOrigin.supplied)
                Text("My own note").tag(CasePersonAttributeOrigin.investigatorNote)
            }
            .frame(maxWidth: 260)
            if attrOrigin == .source {
                Picker("Document", selection: $attrSource) {
                    Text("Choose a document").tag(UUID?.none)
                    ForEach(documents) { d in Text(d.name).tag(Optional(d.id)) }
                }
            } else if attrOrigin == .supplied {
                TextField("Supplied by", text: $suppliedBy).textFieldStyle(.roundedBorder)
            }
        }
        if attrOrigin == .source { TextField("Words as the document writes them, optional", text: $attrQuote).textFieldStyle(.roundedBorder) }
        Button("Add profile line") { Task { await addAttribute() } }.caseMapControlHelp("Add profile line")
            .disabled(reason: attributeBlocked)
    }

    private var attributeBlocked: String? {
        if attrValue.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the value." }
        if attrOrigin == .source, attrSource == nil { return "Choose the document it comes from." }
        if attrOrigin == .supplied, suppliedBy.trimmingCharacters(in: .whitespaces).isEmpty { return "Name who supplied it." }
        return nil
    }

    @ViewBuilder private var whereaboutsForm: some View {
        Text("Record a place the person was observed").font(.subheadline.weight(.semibold))
        Text("A past observation with its time, precision and source; the app never shows it as where the person is now.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            TextField("Place", text: $place).textFieldStyle(.roundedBorder)
            TextField("Day observed (yyyy-MM-dd)", text: $placeDay).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
        }
        HStack {
            Picker("Time precision", selection: $timePrecision) { ForEach(CaseLocationTimePrecision.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Place precision", selection: $placePrecision) { ForEach(CaseLocationPlacePrecision.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("From", selection: $basis) { ForEach(CaseLocationBasis.allCases, id: \.self) { Text($0.label).tag($0) } }
        }
        HStack {
            if basis == .source {
                Picker("Document", selection: $placeSource) {
                    Text("Choose a document").tag(UUID?.none)
                    ForEach(documents) { d in Text(d.name).tag(Optional(d.id)) }
                }
            }
            TextField("Uncertainty, optional (e.g. camera clock not checked)", text: $uncertainty).textFieldStyle(.roundedBorder)
        }
        Button("Record observation") { Task { await recordPlace() } }.caseMapControlHelp("Record observation")
            .disabled(reason: place.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the place." : (basis == .source && placeSource == nil ? "Choose the document it comes from." : nil))
    }

    @ViewBuilder private var statementSection: some View {
        let mine = interviews.filter { $0.personID == selected }
        Text("Statement").font(.subheadline.weight(.semibold))
        if mine.isEmpty {
            Text("No interview of this person is recorded; start one in Case sections ▸ Interviews.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(mine) { iv in
            let confirmed = iv.attestedAt != nil
            Text(confirmed ? "Interview confirmed by \(iv.attestedBy ?? "the person") — answers change only by a recorded correction."
                           : "Interview not yet confirmed — questions and answers can still be edited.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(items.filter { $0.interviewID == iv.id && $0.isCurrent }) { it in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Q\(it.ordinal): \(it.question)").font(.caption)
                        Text("A: \(it.response ?? "—")").font(.caption).foregroundStyle(.secondary)
                        if let why = it.correctionReason { Text("Corrected: \(why)").font(.caption2).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if confirmed {
                        Button("Correct this answer…") { correction = it.response ?? ""; correcting = it }.controlSize(.small).caseMapControlHelp("Correct this answer…")
                    }
                }
            }
            if !confirmed {
                HStack {
                    TextField("Question", text: $question).textFieldStyle(.roundedBorder)
                    TextField("Answer, optional", text: $response).textFieldStyle(.roundedBorder)
                    Button("Add question and answer") { Task { await addItem(iv.id) } }.caseMapControlHelp("Add question and answer")
                        .disabled(reason: question.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the question." : nil)
                }
            }
        }
        if !history.isEmpty {
            DisclosureGroup("Statement history (\(history.count))") {
                ForEach(history) { h in
                    Text("\(h.at.formatted(date: .abbreviated, time: .shortened)) — \(h.text)").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func correctionSheet(_ item: CaseInterviewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Correct a confirmed answer").font(.headline)
            Text("Q\(item.ordinal): \(item.question)").font(.callout)
            Text("As confirmed: \(item.response ?? "—")").font(.caption).foregroundStyle(.secondary)
            TextField("The corrected answer", text: $correction).textFieldStyle(.roundedBorder)
            TextField("Why it is corrected (recorded with the correction)", text: $reason).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { correcting = nil }.keyboardShortcut(.cancelAction)
                Button("Record the correction") { Task { await correct(item) } }.keyboardShortcut(.defaultAction).caseMapControlHelp("Record the correction")
                    .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil)
            }
        }
        .padding(16).frame(width: 520)
    }

    // MARK: actions

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do {
            people = try await file.identityViews(caseID: caseID)
            documents = try await file.moneyCaseDocuments(caseID: caseID)
            interviews = try await file.interviews(caseID: caseID)
            items = try await file.interviewItems(caseID: caseID)
            if let s = selected, people.contains(where: { $0.person.id == s }) {
                profile = try await file.personProfile(caseID: caseID, personID: s)
                history = try await file.statementHistory(caseID: caseID, personID: s)
            } else { selected = nil; profile = nil; history = [] }
            state = .ready
        } catch { KalsmritikoshLog.ui.error("People tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading the case's people") }
    }
    private func choose(_ id: UUID) async { selected = id; await load() }

    private func run(_ doing: String, _ done: String, _ body: (CaseFileRepository) async throws -> Void) async {
        guard let file = appState.caseFiles?.file else { return }
        do { try await body(file); notice = done; await load() }
        catch { KalsmritikoshLog.ui.error("People tool, \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: doing) }
    }

    private func addPersonOrRole() async {
        let ctx = roleContext.trimmingCharacters(in: .whitespaces)
        await run("adding people", "Recorded.") { file in
            switch try await file.addPersonOrRole(caseID: caseID, name: name, role: roleKind, context: ctx.isEmpty ? nil : ctx, entityID: nil, actor: actor) {
            case .added(let id): selected = id
            case .roleAdded(let person, _): selected = person; notice = "This person was already in the case; the role was added to them."
            }
            name = ""; roleContext = ""
        }
    }
    private func endRole(_ id: UUID) async {
        await run("ending roles", "The role is ended; it stays in the profile's history.") { try await $0.endPersonRole(caseID: caseID, id: id, reason: reason, actor: actor); reason = "" }
    }
    private func withdraw(_ id: UUID) async {
        await run("withdrawing profile lines", "Withdrawn; the line is kept in the history.") { try await $0.withdrawPersonAttribute(caseID: caseID, id: id, reason: reason, actor: actor); reason = "" }
    }
    private func addAttribute() async {
        guard let person = selected else { return }
        let q = attrQuote.trimmingCharacters(in: .whitespaces), by = suppliedBy.trimmingCharacters(in: .whitespaces)
        await run("adding profile lines", "Added with where it comes from.") { file in
            _ = try await file.addPersonAttribute(caseID: caseID, personID: person, kind: attrKind, value: attrValue, origin: attrOrigin,
                                                  sourceVersionID: attrOrigin == .source ? attrSource : nil, quote: q.isEmpty ? nil : q,
                                                  suppliedBy: attrOrigin == .supplied ? by : nil, actor: actor)
            attrValue = ""; attrQuote = ""
        }
    }
    private func recordPlace() async {
        guard let person = selected else { return }
        let d = placeDay.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty, CaseMoneyLedger.date(d) == nil { notice = "The day must be written yyyy-MM-dd."; return }
        let u = uncertainty.trimmingCharacters(in: .whitespaces)
        await run("recording whereabouts", "Recorded as a past observation.") { file in
            _ = try await file.recordLocationObservation(caseID: caseID, personID: person, place: place, observedFrom: d.isEmpty ? nil : CaseMoneyLedger.date(d),
                                                         timePrecision: d.isEmpty ? .unknown : timePrecision, placePrecision: placePrecision, basis: basis,
                                                         sourceVersionID: basis == .source ? placeSource : nil, uncertainty: u.isEmpty ? nil : u, actor: actor)
            place = ""; placeDay = ""; uncertainty = ""
        }
    }
    private func addItem(_ interview: UUID) async {
        let r = response.trimmingCharacters(in: .whitespaces)
        await run("recording statements", "Added to the interview.") { file in
            _ = try await file.addInterviewItem(caseID: caseID, interviewID: interview, question: question, response: r.isEmpty ? nil : r, actor: actor)
            question = ""; response = ""
        }
    }
    private func correct(_ item: CaseInterviewItem) async {
        await run("correcting statements", "The correction is recorded beside the confirmed answer, which is kept.") { file in
            _ = try await file.correctInterviewItem(caseID: caseID, id: item.id, question: nil, response: correction, reason: reason, actor: actor)
            correcting = nil; reason = ""; correction = ""
        }
    }
}

// MARK: - Team and work

struct CaseTeamWorkTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    /// Opens a record on the map (the panel closes first); nil when the tools are shown without a map.
    var open: ((CaseMapNodeID) -> Void)?
    @State private var state: CaseToolState = .loading
    @State private var team: [CaseTeamMembership] = []
    @State private var capabilities: [CaseInvestigatorCapability] = []
    @State private var checks: [CaseConflictCheck] = []
    @State private var notice: String?
    @State private var member = ""
    @State private var memberRole: CaseTeamMembership.Role = .investigator
    @State private var reason = ""
    @State private var transferTo = ""
    @State private var historyOf: CaseInvestigatorHistory?
    @State private var capName = ""
    @State private var capability = ""
    @State private var capBasis = ""
    @State private var awayFrom = ""
    @State private var awayTo = ""
    @State private var relationships = ""
    @State private var routingCapability = ""
    @State private var candidates: [CaseRoutingCandidate]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.team.notice") }
            Text("Case team").font(.headline)
            if team.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "No team is recorded: the case counts as worked alone, and anyone using this Mac may act.",
                                                next: "Add a person to the team below when someone else works on this case."))
            }
            ForEach(team) { m in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(m.member) — \(m.role.rawValue), from \(m.startedAt.formatted(date: .abbreviated, time: .omitted))"
                         + (m.endedAt.map { " to \($0.formatted(date: .abbreviated, time: .omitted)) (\(m.endReason ?? ""))" + (m.transferredTo.map { "; work passed to \($0)" } ?? "") } ?? ""))
                        .font(.caption).foregroundStyle(m.isActive ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Work history") { Task { await showHistory(m.member) } }.controlSize(.small).caseMapControlHelp("Work history")
                    if m.isActive {
                        Button("End membership…") { Task { await end(m.id) } }.controlSize(.small).caseMapControlHelp("End membership…")
                            .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason below.")
                    }
                }
            }
            HStack {
                TextField("Name", text: $member).textFieldStyle(.roundedBorder)
                Picker("Team role", selection: $memberRole) { ForEach(CaseTeamMembership.Role.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 220)
                Button("Add to the team") { Task { await addMember() } }.caseMapControlHelp("Add to the team")
                    .disabled(reason: member.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the name." : nil)
            }
            HStack {
                TextField("Reason (to end a membership)", text: $reason).textFieldStyle(.roundedBorder)
                TextField("Who takes over their open work", text: $transferTo).textFieldStyle(.roundedBorder)
            }
            if let h = historyOf { historySection(h) }
            Divider()
            Text("Declared capabilities and absences").font(.headline)
            Text("Only what a person declares, with its basis; the app infers no expertise and keeps no personal score.").font(.caption).foregroundStyle(.secondary)
            ForEach(capabilities.filter(\.isActive)) { c in
                HStack {
                    Text("\(c.investigator): \(c.capability) — basis: \(c.basis)").font(.caption)
                    Spacer()
                    Button("Withdraw capability") { Task { await withdrawCapability(c.id) } }.controlSize(.small).caseMapControlHelp("Withdraw capability")
                }
            }
            HStack {
                TextField("Investigator", text: $capName).textFieldStyle(.roundedBorder)
                TextField("Capability", text: $capability).textFieldStyle(.roundedBorder)
                TextField("Basis (e.g. certificate supplied)", text: $capBasis).textFieldStyle(.roundedBorder)
                Button("Declare capability") { Task { await declare() } }.caseMapControlHelp("Declare capability")
                    .disabled(reason: [capName, capability, capBasis].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? "Name, capability and basis are needed." : nil)
            }
            HStack {
                TextField("Away from (yyyy-MM-dd)", text: $awayFrom).textFieldStyle(.roundedBorder)
                TextField("to (yyyy-MM-dd)", text: $awayTo).textFieldStyle(.roundedBorder)
                Button("Record absence") { Task { await away() } }.caseMapControlHelp("Record absence")
                    .disabled(reason: capName.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the investigator's name above." : nil)
            }
            Text("Conflict checks").font(.subheadline.weight(.semibold))
            ForEach(checks) { c in
                Text("\(c.investigator): \(c.result.rawValue)" + (c.matched.map { " — matches \($0)" } ?? "") + (c.note.map { " — \($0)" } ?? "")
                     + " (checked by \(c.checkedBy), \(c.checkedAt.formatted(date: .abbreviated, time: .omitted)))").font(.caption)
            }
            HStack {
                TextField("Their declared relationships, comma-separated", text: $relationships).textFieldStyle(.roundedBorder)
                Button("Run conflict check") { Task { await conflictCheck() } }.caseMapControlHelp("Run conflict check")
                    .disabled(reason: capName.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the investigator's name above." : nil)
            }
            Text("Who could take a piece of work").font(.subheadline.weight(.semibold))
            HStack {
                TextField("Capability needed, optional", text: $routingCapability).textFieldStyle(.roundedBorder)
                Button("List who could take it") { Task { await route() } }.caseMapControlHelp("List who could take it")
            }
            if let candidates {
                if candidates.isEmpty { Text("Nobody is recorded who could take it.").font(.caption).foregroundStyle(.secondary) }
                ForEach(candidates) { c in
                    Text("\(c.name): \(c.eligible ? "could take it" : "not eligible") — \(c.reasons.joined(separator: "; "))").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Text("Alphabetical, not ranked.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private func historySection(_ h: CaseInvestigatorHistory) -> some View {
        Text("Work history of \(h.name)").font(.subheadline.weight(.semibold))
        Text((h.periods.isEmpty ? "No team period recorded." : h.periods.joined(separator: "; ")) + " Open assignments: \(h.openAssignments).")
            .font(.caption).foregroundStyle(.secondary)
        if h.entries.isEmpty { Text("No work is recorded under this name.").font(.caption).foregroundStyle(.secondary) }
        ForEach(h.entries) { e in
            HStack(alignment: .firstTextBaseline) {
                Text("\(e.at.formatted(date: .abbreviated, time: .shortened)) — \(e.kind.label): \(e.text)").font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let t = e.target, let open { Button("Show on map") { open(t) }.buttonStyle(.link).font(.caption) }
                else if let why = e.unavailable { Text(why).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do {
            team = try await file.teamMemberships(caseID: caseID)
            capabilities = try await file.capabilities()
            checks = try await file.conflictChecks(caseID: caseID)
            state = .ready
        } catch { KalsmritikoshLog.ui.error("Team tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading the case team") }
    }
    private func run(_ doing: String, _ done: String, _ body: (CaseFileRepository) async throws -> Void) async {
        guard let file = appState.caseFiles?.file else { return }
        do { try await body(file); notice = done; await load() }
        catch { KalsmritikoshLog.ui.error("Team tool, \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: doing) }
    }
    private func showHistory(_ name: String) async {
        guard let file = appState.caseFiles?.file else { return }
        do { historyOf = try await file.workHistory(caseID: caseID, person: name) }
        catch { KalsmritikoshLog.ui.error("Work history not read: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading work histories") }
    }
    private func addMember() async {
        await run("changing the team", "Added to the team.") { _ = try await $0.addTeamMember(caseID: caseID, member: member, role: memberRole, actor: actor); member = "" }
    }
    private func end(_ id: UUID) async {
        let to = transferTo.trimmingCharacters(in: .whitespaces)
        await run("changing the team", "The membership is ended; what they recorded keeps their name.") { file in
            try await file.endTeamMembership(caseID: caseID, membershipID: id, reason: reason, transferTo: to.isEmpty ? nil : to, actor: actor)
            reason = ""; transferTo = ""
        }
    }
    private func declare() async {
        await run("declaring capabilities", "Declared.") { _ = try await $0.declareCapability(investigator: capName, capability: capability, basis: capBasis, actor: actor); capability = ""; capBasis = "" }
    }
    private func withdrawCapability(_ id: UUID) async {
        await run("withdrawing capabilities", "Withdrawn.") { try await $0.withdrawCapability(id: id, actor: actor) }
    }
    private func away() async {
        guard let from = CaseMoneyLedger.date(awayFrom.trimmingCharacters(in: .whitespaces)), let to = CaseMoneyLedger.date(awayTo.trimmingCharacters(in: .whitespaces)) else {
            notice = "Write both days yyyy-MM-dd."; return
        }
        await run("recording absences", "Recorded.") { _ = try await $0.declareUnavailable(investigator: capName, from: from, to: to.addingTimeInterval(86_399), note: nil, actor: actor) }
    }
    private func conflictCheck() async {
        let declared = relationships.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await run("checking conflicts", "Checked; a match is recorded as a conflict for a person to decide.") {
            _ = try await $0.runConflictCheck(caseID: caseID, investigator: capName, declaredRelationships: declared, waiveNote: nil, actor: actor)
        }
    }
    private func route() async {
        guard let file = appState.caseFiles?.file else { return }
        let c = routingCapability.trimmingCharacters(in: .whitespaces)
        do { candidates = try await file.routingCandidates(caseID: caseID, capability: c.isEmpty ? nil : c) }
        catch { KalsmritikoshLog.ui.error("Routing not read: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "listing who could take work") }
    }
}
