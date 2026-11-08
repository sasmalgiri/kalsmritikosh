//
//  CaseMapInspector.swift
//  Kalsmritikosh
//
//  Living case map, M2/M4 (plan §4.4): ONE inspector for items and links. It shows the type and recorded
//  state, the exact wording, every source with its version and locator ("Position unavailable" when only
//  the document is known), who recorded or proposed it, the review history and any changed-source warning.
//  A link says why it exists. The actions are the EXISTING commands, so a decision made here is the same
//  record the case sections and the report show: contradiction review (InvestigationContradictionGapService
//  through the case's review model), carrying a confirmed item to the chronology or the report
//  (JobResultHandoff), linking a document to an allegation (CaseFileService.linkEvidence, verified) or a
//  hypothesis (InvestigationAnalysisService.addEvidence), creating or opening an evidence request, and
//  opening the source. The services' guards (closed case, case scope, paid action, reasons) stay in force.
//

import SwiftUI
import os

struct CaseMapInspector: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    let projection: CaseMapProjection
    let repository: CaseMapRepository?
    let reload: () async -> Void
    let openSource: (CaseMapSourceRef) -> Void
    /// Smart-map M1 — open the item as a frame of the map.
    var openFrame: (CaseMapNodeID) -> Void = { _ in }

    @State private var reason: CaseReviewReason?
    @State private var note = ""
    @State private var linking = false
    @State private var withdrawing: CaseMapLink?
    @State private var withdrawReason = ""
    @State private var creatingRequest = false
    @State private var requestForm = EvidenceRequestForm()
    // S3
    @State private var placing = false
    @State private var revising: CaseMapLink?
    @State private var deciding: (link: CaseMapLink, decision: CasePersonIdentityDecision.Decision)?
    @State private var decisionReason = ""
    @State private var withdrawingDecision: CaseMapLink?
    @State private var removingPlacement: CaseMapLink?
    @State private var history: [CaseMapInvestigatorLink] = []
    @State private var omitted: [CaseMapOmittedStore: CaseMapOmittedPage] = [:]
    @State private var omittedError: String?

    private var map: CaseMapWorkspaceModel { model.map }
    private var closed: Bool { s.caseHeader.status == .closed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch map.selection {
                case .node(let id)?:
                    if let n = projection.node(id) { nodeView(n) } else { gone }
                case .link(let id)?:
                    if let l = projection.link(id) { linkView(l) } else { gone }
                case nil:
                    Text("Choose an item or a link on the map or in the list to see its sources, its state and what you can do with it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("case.map.inspector")
        .sheet(isPresented: $linking) { if case .node(let id)? = map.selection { linkSheet(from: id) } }
        .sheet(item: $withdrawing) { l in withdrawSheet(l) }
        .sheet(isPresented: $creatingRequest) { requestSheet }
        .sheet(isPresented: $placing) { if case .node(let id)? = map.selection { placeSheet(id) } }
        .sheet(item: $revising) { l in reviseSheet(l) }
        .sheet(isPresented: Binding(get: { deciding != nil }, set: { if !$0 { deciding = nil } })) { if let d = deciding { decisionSheet(d.link, d.decision) } }
        .sheet(item: $withdrawingDecision) { l in reasonSheet("Withdraw this decision", "The two rows go back to “possibly the same person”, pending. Neither row was ever changed, so nothing needs restoring.", "Withdraw decision") { why in
            guard let file = appState.caseFiles?.file, let o = l.origins.first, let id = UUID(uuidString: o.recordID) else { return }
            let caseID = model.caseID, actor = model.actor
            await perform("Decision withdrawn.") { try await file.withdrawIdentityDecision(caseID: caseID, id: id, reason: why, actor: actor) }
        } }
        .sheet(item: $removingPlacement) { l in reasonSheet("Remove from this branch", "The placement is withdrawn with your reason and kept in the case record. The item itself, and every other branch it is in, are unchanged.", "Remove") { why in
            guard let file = appState.caseFiles?.file, let o = l.origins.first, let id = UUID(uuidString: o.recordID) else { return }
            let caseID = model.caseID, actor = model.actor
            await perform("Removed from the branch.") { try await file.withdrawFromFrame(caseID: caseID, membershipID: id, reason: why, actor: actor) }
        } }
        .onChange(of: map.selection) { _, _ in reason = nil; note = ""; history = []; omitted = [:]; omittedError = nil }
    }

    private var gone: some View {
        Text("This item is no longer in the case's map (it was removed, erased or left the case scope).").font(.callout).foregroundStyle(.secondary)
    }

    // MARK: Item

    @ViewBuilder private func nodeView(_ n: CaseMapNode) -> some View {
        Label(n.kind.label, systemImage: n.kind.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(n.title).font(.headline).fixedSize(horizontal: false, vertical: true)
        stateLine(n.status, review: n.review)
        if let w = n.changedSourceWarning {
            Label(w, systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if n.kind == .note {
            Label("An investigator's note — it is not documentary support for anything.", systemImage: "note.text")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        } else if [.event, .finding].contains(n.kind) {
            Label(n.isDocumentary ? "Documentary support: a verified passage or live exhibit." : "Not documentary support (no verified passage).",
                  systemImage: n.isDocumentary ? "checkmark.seal" : "minus.circle")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        } else if n.id.kind == .document {
            Text("A document in the case. Its presence does not establish that what it says is true.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let w = n.wording, !w.isEmpty {
            if n.id.kind == .reportPoint {
                // SRC-02/SRC-04 — a point's statement is the investigator's wording; the source's exact words are under Sources.
                section("The investigator's statement of the point") {
                    ExtractionProvenanceBadge(kind: .interpretation)
                    Text(w).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                section("Exact wording") { Text(w).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
        if !n.qualifications.isEmpty {
            section("Qualifications (\(n.qualifications.count))") {
                ForEach(Array(n.qualifications.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "exclamationmark.bubble").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Text("They travel with the point into every summary and output.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        if !n.sources.isEmpty { section("Sources (\(n.sources.count))") { sources(n.sources) } }
        if let dep = n.dependence { dependenceSection(dep) }
        section("Recorded") {
            VStack(alignment: .leading, spacing: 2) {
                if let a = n.author { Text(a.label).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if let at = n.recordedAt { Text("Recorded \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                if let d = n.dateLabel { Text("Date recorded for it: \(d)").font(.caption).fixedSize(horizontal: false, vertical: true) }
                if let m = n.money { Text("Amount as the documents state it: \(m.display) — not a verified payment").font(.caption).fixedSize(horizontal: false, vertical: true) }
                Text("Record: \(n.id.kind.rawValue) \(n.id.recordID.prefix(8))" + (n.revision.map { " · revision \($0.prefix(12))" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if !n.history.isEmpty {
            section("Review history (\(n.history.count))") {
                ForEach(Array(n.history.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        let links = projection.links(of: n.id)
        if !links.isEmpty {
            section("Links (\(links.count))") {
                ForEach(links) { l in
                    let other = l.from == n.id ? l.to : l.from
                    Button { map.select(.link(l.id)) } label: {
                        Text((l.from == n.id ? "→ \(l.type.label) " : "← \(l.type.label) ") + (projection.node(other)?.title ?? "?"))
                            .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        if !map.isHistorical, !CaseMapOmittedStore.stores(for: n.id.kind).isEmpty { otherRecords(n) }
        if map.isHistorical { historyNote } else { actions(n) }
    }

    /// GRAPH-07 — the stores the map does not draw, under this record, read a page at a time only when asked.
    private func otherRecords(_ n: CaseMapNode) -> some View {
        section("Other records of this " + (n.id.kind == .caseFile ? "case" : "item")) {
            Text("Kept in the case but not drawn on the map. Each is read from the ledger when you open it.").font(.caption2).foregroundStyle(.secondary)
            ForEach(CaseMapOmittedStore.stores(for: n.id.kind)) { store in
                if let page = omitted[store] {
                    Text("\(store.title) (\(page.total))").font(.caption.weight(.medium))
                    if page.rows.isEmpty { Text("None recorded.").font(.caption2).foregroundStyle(.secondary) }
                    ForEach(page.rows) { r in
                        Text(r.line + (r.by.map { " — \($0)" } ?? "") + (r.at.map { ", \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                            .font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                    if page.remaining > 0 {
                        Button("Show \(min(50, page.remaining)) more (\(page.remaining) not shown yet)") { loadOmitted(store, n.id, offset: page.offset + page.rows.count, append: page) }
                            .buttonStyle(.borderless).font(.caption2)
                    }
                } else {
                    Button("Show \(store.title.lowercased())") { loadOmitted(store, n.id, offset: 0, append: nil) }.buttonStyle(.link).font(.caption)
                }
            }
            if let e = omittedError { Text(e).font(.caption2).foregroundStyle(.red) }
        }
    }

    private func loadOmitted(_ store: CaseMapOmittedStore, _ anchor: CaseMapNodeID, offset: Int, append: CaseMapOmittedPage?) {
        guard let repository else { return }
        let caseID = model.caseID
        Task {
            do {
                let page = try await repository.omittedRecords(caseID: caseID, store: store, anchor: anchor, offset: offset)
                omitted[store] = append.map { CaseMapOmittedPage(store: store, rows: $0.rows + page.rows, total: page.total, offset: $0.offset) } ?? page
                omittedError = nil
            } catch {
                KalsmritikoshLog.ui.error("Case map other records not read: \(error.localizedDescription, privacy: .public)")
                omittedError = "Not read: \(error.localizedDescription). Nothing is shown as if there were none."
            }
        }
    }

    private func perform(_ done: String, _ body: @escaping () async throws -> Void) async {
        guard PurchaseCenter.shared.allowPaidAction("edit the case file") else { return }
        do { try await body(); map.error = nil; map.notice = done } catch {
            KalsmritikoshLog.ui.error("Case map change not recorded: \(error.localizedDescription, privacy: .public)")
            map.error = "Not recorded: \(error.localizedDescription)"
        }
        await reload()
    }

    /// M7 — a recorded state is read-only: no review, link, request, hide or carry from here.
    private var historyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Label("Recorded state — read-only. Its review states and links are as they were then. Choose “Return to current” to act on the case.",
                  systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Link

    @ViewBuilder private func linkView(_ l: CaseMapLink) -> some View {
        Label("Link — \(l.type.label)", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        HStack(spacing: 4) {
            Button(projection.node(l.from)?.title ?? "?") { map.select(.node(l.from)) }.buttonStyle(.link)
            Text(l.directed ? "→" : "↔").accessibilityLabel(l.directed ? "to" : "and")
            Button(projection.node(l.to)?.title ?? "?") { map.select(.node(l.to)) }.buttonStyle(.link)
        }
        .font(.callout).lineLimit(2)
        stateLine(l.status, review: l.review)
        // M9 — what this kind of link means, in words (not only on hover).
        Text(HelpRegistry.caseMapLinkHelp(l.type)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        section("Why this link exists") { Text(l.basis).font(.callout).fixedSize(horizontal: false, vertical: true) }
        // GRAPH-04 / SM-04 — kind of relationship, stated certainty, when it holds, when recorded. A path is not a cause.
        section("What it is and is not") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Relationship: \(l.type.family.rawValue)" + (l.directed ? ", directed" : ", either way")).font(.caption)
                Text(l.certainty.label).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(l.validity?.label ?? "When it holds: not recorded").font(.caption)
                if let at = l.recordedAt { Text("Recorded \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                Text("A link records a stated connection. It does not show that one thing caused another, or that anyone did wrong.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if l.origins.first?.kind == .investigatorLink {
            if history.count > 1 {
                section("Revision history (\(history.count))") {
                    ForEach(history, id: \.id) { h in
                        Text("\(h.type.label) — “\(h.rationale)” by \(h.createdBy), \(h.createdAt.formatted(date: .abbreviated, time: .shortened))"
                             + (h.withdrawnReason.map { " · \($0)" } ?? ""))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if l.revisesLinkID != nil {
                Button("Show revision history") { loadHistory(l) }.buttonStyle(.link).font(.caption)
            }
        }
        section("Asserted by") { Text(l.assertedBy.label).font(.caption).fixedSize(horizontal: false, vertical: true) }
        if !l.sources.isEmpty { section("Sources (\(l.sources.count))") { sources(l.sources) } }
        section("Comes from") {
            ForEach(Array(l.origins.enumerated()), id: \.offset) { _, o in
                Text("\(o.kind.rawValue) \(o.recordID.prefix(8))" + (o.revision.map { " · revision \($0.prefix(12))" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if map.isHistorical {
            historyNote
        } else if l.origins.first?.kind == .investigatorLink {
            HStack {
                Button("Revise link…") { revising = l }
                    .disabled(reason: closed ? "The case is closed." : nil, remedy: closed ? "Reopen the case to change its links." : nil)
                    .help("Records a corrected link (its type, reason, certainty or period) that names this one; this one is withdrawn with your reason and kept.")
                Button("Withdraw link…") { withdrawReason = ""; withdrawing = l }
                    .disabled(reason: closed ? "The case is closed." : nil, remedy: closed ? "Reopen the case to change its links." : nil)
                    .help("Withdraws the link with your reason. It stays in the case record, marked withdrawn.")
            }
            .controlSize(.small)
        } else if l.type == .possibleSamePerson, l.origins.first?.kind == .rule {
            // GRAPH-09 — a recorded, reversible decision; nothing is merged.
            HStack {
                Button("Record as the same person…") { decisionReason = ""; deciding = (l, .samePerson) }
                Button("Record as different people…") { decisionReason = ""; deciding = (l, .differentPeople) }
            }
            .controlSize(.small)
            .disabled(reason: closed ? "The case is closed." : nil)
            Text("Neither choice merges the two rows: each keeps its statements, links and history, and the decision can be withdrawn.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if l.origins.first?.kind == .identityDecision {
            Button("Withdraw decision…") { withdrawingDecision = l }.controlSize(.small).disabled(reason: closed ? "The case is closed." : nil)
        } else if l.origins.first?.kind == .frameMember {
            Button("Remove from this branch…") { removingPlacement = l }.controlSize(.small).disabled(reason: closed ? "The case is closed." : nil)
        } else {
            // GRAPH-08 — a link that comes from a record is changed where that record is.
            Text("This link comes from the record named under “Comes from”. Change or withdraw it there (open the item at either end); the link follows.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadHistory(_ l: CaseMapLink) {
        guard let repository, let o = l.origins.first, let id = UUID(uuidString: o.recordID) else { return }
        let caseID = model.caseID
        Task {
            do { history = try await repository.linkHistory(caseID: caseID, id: id) } catch {
                KalsmritikoshLog.ui.error("Case map link history not read: \(error.localizedDescription, privacy: .public)")
                map.error = "The link's history could not be read: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Pieces

    private func stateLine(_ st: CaseMapStatus, review: CaseMapReviewState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(st.kind.label): \(st.text)", systemImage: st.kind.symbol).font(.caption).fixedSize(horizontal: false, vertical: true)
            if st.kind != .recorded {
                Text(HelpRegistry.caseMapStatusHelp(st.kind)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if review != .notApplicable { Label(review.label, systemImage: review.awaitingReview ? "hourglass" : "checkmark.circle").font(.caption) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 2)
    }

    /// SRC-10 — the origins the item rests on, the copies of them in the case and the other records citing them.
    private func dependenceSection(_ dep: CaseMapSourceDependence) -> some View {
        section("Source dependence") {
            ForEach(Array(dep.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(dep.occurrences, id: \.self) { o in
                Button { map.select(.node(o.node)) } label: {
                    Text(o.title + (o.sameWords ? " — same words" : "") + (o.viaCopy ? " — cites a copy" : ""))
                        .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
            }
            if dep.occurrenceTotal > dep.occurrences.count {
                Text("and \(dep.occurrenceTotal - dep.occurrences.count) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func sources(_ refs: [CaseMapSourceRef]) -> some View {
        ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.documentName ?? "A document in the case").font(.caption.weight(.medium))
                Text(ref.locatorText).font(.caption2).foregroundStyle(.secondary)
                if let q = ref.quote, !q.isEmpty { Text("\u{201C}\(q)\u{201D}").font(.caption).fixedSize(horizontal: false, vertical: true) }
                // SRC-02 — whether these are the file's own words, recognised (OCR), transcribed or entered text.
                if !map.isHistorical, ref.objectID != nil || ref.sourceVersionID != nil || ref.blockID != nil {
                    ExtractionProvenanceBadgeLoader(objectID: ref.objectID, sourceVersionID: ref.sourceVersionID, blockID: ref.blockID, quote: ref.quote)
                }
                if map.isHistorical, ref.objectID == nil, ref.sourceVersionID != nil {
                    Text("The version this recorded state cited is no longer in the ledger. Its words are not shown, and the current version is not shown in its place.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if ref.objectID != nil {
                    Button("Open source") { openSource(ref) }.buttonStyle(.link).font(.caption)
                } else {
                    Text("No readable document to open.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Actions (the existing commands)

    @ViewBuilder private func actions(_ n: CaseMapNode) -> some View {
        Divider()
        Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        CaseMapWorkCommands(model: model, node: n, projection: projection, closed: closed, openFrame: openFrame)
        switch n.id.kind {
        case .contradiction:
            contradictionActions(n)
        case .document:
            documentActions(n)
        case .allegation, .hypothesis, .caseFile:
            Button("Create evidence request…") {
                requestForm = EvidenceRequestForm()
                if n.id.kind == .allegation { requestForm.allegationID = UUID(uuidString: n.id.recordID) }
                if n.id.kind == .caseFile { requestForm.question = n.wording ?? "" }
                creatingRequest = true
            }
            .disabled(reason: closed ? "The case is closed." : nil)
            .help("Records what you will ask for and from whom, for this question. The app sends nothing.")
        case .request:
            Button("Open in Evidence requests") { openSections(.evidence) { $0.selectedRequestID = UUID(uuidString: n.id.recordID) } }
        case .journal:
            Button("Open in Chronology & notes") { openSections(.chronology) }
        case .reportItem:
            Button("Open in Log & exports") { openSections(.log) }
        case .person, .interview, .addendum:
            Button("Open in People & interviews") { openSections(.people) }
        case .task:
            Button("Open in Tasks") { openSections(.tasks) }
        default:
            EmptyView()
        }
        HStack {
            Button("Brief of this branch") { map.briefAnchor = n.id; map.briefRequested = true }
                .help("The brief of this item and everything reached from it: position, unresolved, contrary material, changes and next work.")
            if CaseMapRecordKind.linkable.contains(n.id.kind) {
                Button("Place in frame…") { placing = true }
                    .disabled(reason: closed ? "The case is closed." : nil)
                    .help("Puts this item in the branch of another item. It is stored once and appears in every branch it is placed in.")
            }
        }
        .controlSize(.small)
        HStack {
            if CaseMapRecordKind.linkable.contains(n.id.kind) {
                Button("Link to another item…") { linking = true }
                    .disabled(reason: closed ? "The case is closed." : nil)
                    .help("Draws a typed link with your reason, for a connection no other record holds.")
            }
            Button("Hide from this view") { Task { await map.hide(n.id, repository: repository, actor: model.actor) } }
                .help("Removes it from this view only. Nothing in the case changes.")
            // M9 — the map's Pin, also here so the list path can do it with the keyboard.
            let pinned = map.displayPlacements[n.id]?.pinned == true
            Button(pinned ? "Unpin" : "Pin") { Task { await map.togglePin(n.id, repository: repository) } }
                .help("Keeps the item where it is on the map, through refreshes and Arrange. Changes no case record.")
        }
        .controlSize(.small)
    }

    @ViewBuilder private func contradictionActions(_ n: CaseMapNode) -> some View {
        let cid = UUID(uuidString: n.id.recordID)
        let item = model.review.items.first { $0.id == cid }
        Picker("Reason", selection: $reason) {
            Text("No reason chosen").tag(CaseReviewReason?.none)
            ForEach(CaseReviewReason.allCases) { Text($0.label).tag(Optional($0)) }
        }
        TextField("Note (optional; needed for “Other”)", text: $note, axis: .vertical).lineLimit(1...3)
        HStack {
            decide(.confirmed, "Confirm", cid)
            decide(.dismissed, "Dismiss", cid)
            decide(.deferred, "Defer", cid)
        }
        .controlSize(.small)
        Text("The same decision as in Case sections ▸ Overview ▸ Contradictions; it is kept with the version of both documents.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if item?.status.current == .confirmed, let caseFiles = appState.caseFiles {
            HStack {
                Button("Add to chronology") { Task { await carry(.chronology, cid, caseFiles) } }
                Button("Include in report") { Task { await carry(.report, cid, caseFiles) } }
            }
            .controlSize(.small)
            .disabled(closed)
        }
        if let e = model.review.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        else if let msg = model.review.notice { Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        ForEach(n.sources.filter { $0.objectID != nil }, id: \.self) { ref in
            Button("Open source — \(ref.documentName ?? "document")") { openSource(ref) }.buttonStyle(.link).font(.caption)
        }
    }

    private func decide(_ decision: CaseReviewDecision, _ title: String, _ cid: UUID?) -> some View {
        Button(title) {
            guard let cid, let desk = appState.investigationContradictionGap else { return }
            let r = reason, text = note
            Task {
                let review = model.review
                if !review.loaded { await review.load(desk: desk, objects: appState.objects) }
                review.selectedID = cid
                review.draftReason = r
                review.draftNote = text
                if await review.decide(decision, desk: desk, objects: appState.objects, actor: model.actor) != nil {
                    reason = nil; note = ""
                }
                await model.refreshGlance(appState)
                await reload()
            }
        }
        .disabled(reason: closed ? "The case is closed." : (decision == .dismissed && reason == nil) ? "Choose why you are dismissing it."
                  : (reason == .other && note.trimmingCharacters(in: .whitespaces).isEmpty) ? "Say why in the note." : nil,
                  remedy: closed ? "Reopen the case to record decisions." : nil)
    }

    private func carry(_ to: CaseContradictionReviewModel.Destination, _ cid: UUID?, _ caseFiles: CaseFileService) async {
        guard let cid else { return }
        model.review.selectedID = cid
        await model.review.carry(to, caseFiles: caseFiles, actor: model.actor)
        await model.load(appState)
        await reload()
    }

    @ViewBuilder private func documentActions(_ n: CaseMapNode) -> some View {
        let current = n.sources.first
        if let version = current?.sourceVersionID {
            Menu("Link to allegation…") {
                if s.allegations.isEmpty { Text("No allegations recorded yet") }
                ForEach(s.allegations) { a in
                    Menu("\(a.label) — \(a.text)") {
                        Button("Supports") { linkAllegation(a.id, .supports, version, current?.objectID, n.title) }
                        Button("Challenges") { linkAllegation(a.id, .contradicts, version, current?.objectID, n.title) }
                        Button("Mentions") { linkAllegation(a.id, .neutral, version, current?.objectID, n.title) }
                    }
                }
            }
            .disabled(closed)
            let hypotheses = projection.nodes.filter { $0.id.kind == .hypothesis }
            if let object = current?.objectID {
                Menu("Link to hypothesis…") {
                    if hypotheses.isEmpty { Text("No hypotheses or leads recorded yet") }
                    ForEach(hypotheses) { h in
                        Menu(h.title) {
                            Button("For") { linkHypothesis(h.id, .supporting, version, object) }
                            Button("Against") { linkHypothesis(h.id, .opposing, version, object) }
                        }
                    }
                }
                .disabled(closed)
            }
            let open = model.requests.filter { $0.request.status.isOutstanding }
            if !open.isEmpty {
                Menu("Received for request…") {
                    ForEach(open) { f in Button(f.request.description) { linkReceived(f.request.id, version, current?.objectID) } }
                }
                .disabled(closed)
            }
            Text("Linking a whole document records no passage, so it shows as unverified until a passage is selected (Case sections ▸ Plan & allegations).")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let ref = current, ref.objectID != nil { Button("Open source") { openSource(ref) } }
    }

    private func linkAllegation(_ allegation: UUID, _ stance: GridStance, _ version: UUID, _ object: UUID?, _ label: String) {
        let caseID = model.caseID, actor = model.actor
        model.run(appState) { svc in
            _ = try await svc.linkEvidence(caseID: caseID, allegationID: allegation, evidenceRef: version.uuidString, label: label, stance: stance,
                                           note: nil, passage: StudioEvidenceRef(sourceVersionID: version, objectID: object), actor: actor)
        }
        Task { try? await Task.sleep(for: .milliseconds(300)); await reload() }
    }

    private func linkHypothesis(_ node: CaseMapNodeID, _ stance: EvidenceStance, _ version: UUID, _ object: UUID) {
        guard let analysis = appState.investigationAnalysis, let hid = UUID(uuidString: node.recordID) else { return }
        let caseID = model.caseID, actor = model.actor
        EvidenceRequestRow.perform(model, appState) {
            _ = try await analysis.addEvidence(caseID: caseID, hypothesisID: hid, stance: stance, sourceVersionID: version,
                                               knowledgeObjectID: object, note: nil, actor: actor, at: Date())
        }
        Task { try? await Task.sleep(for: .milliseconds(300)); await reload() }
    }

    private func linkReceived(_ request: UUID, _ version: UUID, _ object: UUID?) {
        guard let analysis = appState.investigationAnalysis else { return }
        let actor = model.actor
        EvidenceRequestRow.perform(model, appState) {
            _ = try await analysis.linkReceivedSource(requestID: request, itemID: nil, sourceVersionID: version, knowledgeObjectID: object,
                                                      actor: actor, at: Date())
        }
    }

    /// Open the case sections at a tab (the map keeps its place for when the person comes back).
    private func openSections(_ tab: CaseFileTab, _ adjust: (inout CaseWorkspaceState) -> Void = { _ in }) {
        var state = model.workspace.state
        var m = state.map ?? CaseMapWorkspaceMemory()
        m.showsSections = true
        state.map = m
        state.tab = tab.rawValue
        adjust(&state)
        model.workspace.state = state
    }

    // MARK: Sheets

    private func linkSheet(from id: CaseMapNodeID) -> some View {
        CaseMapLinkSheet(projection: projection, from: id) { target, type, rationale, certainty, validity in
            guard let repository else { return }
            guard PurchaseCenter.shared.allowPaidAction("edit the case file") else { return }
            let caseID = model.caseID, actor = model.actor
            Task {
                do {
                    _ = try await repository.addLink(caseID: caseID, type: type, from: id, to: target, rationale: rationale,
                                                     certainty: certainty, validity: validity, actor: actor)
                    map.error = nil
                    map.notice = "Link recorded with your reason."
                } catch {
                    KalsmritikoshLog.ui.error("Case map link not recorded: \(error.localizedDescription, privacy: .public)")
                    map.error = "Not recorded: \(error.localizedDescription)"
                }
                await reload()
            }
        } cancel: { linking = false }
    }

    // MARK: S3 sheets

    /// "Place in frame…": choose the branch (any other record of the case) to place this item in, with a purpose.
    private func placeSheet(_ id: CaseMapNodeID) -> some View {
        CaseMapPlaceSheet(projection: projection, member: id) { frame, purpose in
            guard let file = appState.caseFiles?.file else { map.error = "The ledger isn't ready yet; nothing was placed."; return }
            let caseID = model.caseID, actor = model.actor
            Task { await perform("Placed in the branch. The item is stored once; it now also appears in that branch.") {
                _ = try await file.placeInFrame(caseID: caseID, frame: frame, member: id, purpose: purpose, actor: actor)
            } }
        } cancel: { placing = false }
    }

    private func reviseSheet(_ l: CaseMapLink) -> some View {
        CaseMapReviseSheet(link: l) { type, rationale, certainty, validity, why in
            guard let repository, let o = l.origins.first, let id = UUID(uuidString: o.recordID) else { return }
            let caseID = model.caseID, actor = model.actor
            Task { await perform("Revised. The earlier link is kept, withdrawn with your reason.") {
                _ = try await repository.reviseLink(caseID: caseID, id: id, type: type, rationale: rationale, certainty: certainty,
                                                    validity: validity, reason: why, actor: actor)
                await MainActor.run { map.select(nil, recordBack: false) }
            } }
        } cancel: { revising = nil }
    }

    private func decisionSheet(_ l: CaseMapLink, _ d: CasePersonIdentityDecision.Decision) -> some View {
        reasonSheet(d == .samePerson ? "Record as the same person" : "Record as different people",
                    "Your decision and reason are kept. The two rows are not merged: each keeps its statements, links and history, and withdrawing the decision puts the pair back to pending.",
                    "Record decision") { why in
            guard let file = appState.caseFiles?.file, l.from.kind == .person, l.to.kind == .person,
                  let a = UUID(uuidString: l.from.recordID), let b = UUID(uuidString: l.to.recordID) else { return }
            let caseID = model.caseID, actor = model.actor
            await perform("Decision recorded.") { _ = try await file.recordIdentityDecision(caseID: caseID, personA: a, personB: b, decision: d, rationale: why, actor: actor) }
            deciding = nil
        }
    }

    private func reasonSheet(_ title: String, _ explanation: String, _ action: String, _ run: @escaping (String) async -> Void) -> some View {
        CaseMapReasonSheet(title: title, explanation: explanation, action: action, run: run) {
            deciding = nil; withdrawingDecision = nil; removingPlacement = nil
        }
    }

    private func withdrawSheet(_ l: CaseMapLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Withdraw this link").font(.headline)
            Text("The link stays in the case record, marked withdrawn with your reason. Neither item changes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Why it is withdrawn", text: $withdrawReason)
            HStack {
                Spacer()
                Button("Cancel") { withdrawing = nil }.keyboardShortcut(.cancelAction)
                Button("Withdraw") {
                    guard let repository, let o = l.origins.first, let id = UUID(uuidString: o.recordID) else { return }
                    let caseID = model.caseID, actor = model.actor, why = withdrawReason
                    Task {
                        do { try await repository.withdrawLink(caseID: caseID, id: id, reason: why, actor: actor); map.select(nil, recordBack: false) } catch {
                            KalsmritikoshLog.ui.error("Case map link not withdrawn: \(error.localizedDescription, privacy: .public)")
                            map.error = "Not withdrawn: \(error.localizedDescription)"
                        }
                        await reload()
                    }
                    withdrawing = nil
                }
                .disabled(reason: withdrawReason.trimmingCharacters(in: .whitespaces).isEmpty ? "Say why." : nil)
            }
        }
        .padding(16).frame(width: 420)
    }

    private var requestSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New evidence request").font(.headline)
            Text("The same request as Case sections ▸ Evidence ▸ Evidence requests: what is requested, from whom, for which question. The app sends nothing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("What is requested (e.g. Bank statements, account 1234)", text: $requestForm.description)
            TextField("Custodian — who holds it", text: $requestForm.custodian)
            Picker("For allegation", selection: $requestForm.allegationID) {
                Text("None").tag(UUID?.none)
                ForEach(s.allegations) { Text("\($0.label) — \($0.text)").lineLimit(1).tag(Optional($0.id)) }
            }
            TextField("Or the question it answers", text: $requestForm.question)
            Toggle("One item per month", isOn: $requestForm.monthly)
            if requestForm.monthly {
                HStack {
                    DatePicker("From", selection: $requestForm.from, displayedComponents: .date)
                    DatePicker("To", selection: $requestForm.to, displayedComponents: .date)
                }
            } else {
                TextField("Expected items, one per line", text: $requestForm.itemLines, axis: .vertical).lineLimit(2...5)
            }
            HStack {
                Spacer()
                Button("Cancel") { creatingRequest = false }.keyboardShortcut(.cancelAction)
                Button("Create request") {
                    guard var details = requestForm.details(), let analysis = appState.investigationAnalysis else { return }
                    if case .node(let id)? = map.selection, id.kind == .hypothesis { details.hypothesisID = UUID(uuidString: id.recordID) }
                    let caseID = model.caseID, actor = model.actor
                    EvidenceRequestRow.perform(model, appState) {
                        let r = try await analysis.createEvidenceRequest(caseID: caseID, details: details, actor: actor, at: Date())
                        await MainActor.run { model.workspace.state.selectedRequestID = r.id }
                    }
                    creatingRequest = false
                }
                .disabled(reason: requestForm.problem, remedy: nil)
            }
        }
        .padding(16).frame(width: 520)
    }
}

/// Draw a typed link from one item to another, with the reason (a connection no other record holds).
struct CaseMapLinkSheet: View {
    let projection: CaseMapProjection
    let from: CaseMapNodeID
    let save: (CaseMapNodeID, CaseMapLinkType, String, CaseMapCertainty, CaseMapValidity?) -> Void
    let cancel: () -> Void
    @State private var target: CaseMapNodeID?
    @State private var type: CaseMapLinkType = .supports
    @State private var rationale = ""
    @State private var find = ""
    @State private var certainty: CaseMapCertainty = .notStated
    @State private var validity = CaseMapValidityForm()

    private var candidates: [CaseMapNode] {
        let words = find.lowercased().split(separator: " ").map(String.init)
        return projection.nodes.filter { n in
            n.id != from && CaseMapRecordKind.linkable.contains(n.id.kind)
                && (words.isEmpty || words.allSatisfy { n.title.lowercased().contains($0) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link to another item").font(.headline)
            Text("From: \(projection.node(from)?.title ?? "?")").font(.caption).lineLimit(2)
            Picker("Link type", selection: $type) {
                ForEach(CaseMapLinkType.allCases.filter(\.drawable)) { Text($0.label).tag($0) }
            }
            TextField("Find the other item", text: $find)
            List(candidates, selection: $target) { n in
                Label(n.title, systemImage: n.kind.symbol).lineLimit(1).tag(Optional(n.id))
            }
            .frame(height: 200)
            TextField("Why are they linked? (your reason is kept with the link)", text: $rationale, axis: .vertical).lineLimit(2...4)
            Picker("How certain", selection: $certainty) { ForEach(CaseMapCertainty.allCases) { Text($0.label).tag($0) } }
            CaseMapValidityFields(form: $validity)
            Text("A link records your reasoning. It is not evidence, and it decides nothing.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Record link") {
                    if let target { save(target, type, rationale, certainty, validity.value) }
                    cancel()
                }
                .disabled(reason: target == nil ? "Choose the other item." : rationale.trimmingCharacters(in: .whitespaces).isEmpty ? "Say why they are linked."
                          : validity.problem)
            }
        }
        .padding(16).frame(width: 520)
    }
}

/// S3 (GRAPH-04) — when a link holds: an optional start, an optional end, and the source's own words.
struct CaseMapValidityForm: Equatable {
    var hasFrom = false
    var hasTo = false
    var from = Date()
    var to = Date()
    var text = ""
    var value: CaseMapValidity? {
        let v = CaseMapValidity(from: hasFrom ? from : nil, to: hasTo ? to : nil, text: text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text)
        return v.isRecorded ? v : nil
    }
    var problem: String? { hasFrom && hasTo && to < from ? "The period ends before it starts." : nil }
}

struct CaseMapValidityFields: View {
    @Binding var form: CaseMapValidityForm
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("When it holds (optional)").font(.caption.weight(.semibold))
            HStack {
                Toggle("From", isOn: $form.hasFrom).toggleStyle(.checkbox)
                if form.hasFrom { DatePicker("", selection: $form.from, displayedComponents: .date).labelsHidden() }
                Toggle("To", isOn: $form.hasTo).toggleStyle(.checkbox)
                if form.hasTo { DatePicker("", selection: $form.to, displayedComponents: .date).labelsHidden() }
            }
            TextField("Or as the source puts it (e.g. “during 2025”)", text: $form.text)
            if let p = form.problem { Text(p).font(.caption2).foregroundStyle(.red) }
        }
    }
}

/// "Place in frame…" — choose the branch to place an item in.
struct CaseMapPlaceSheet: View {
    let projection: CaseMapProjection
    let member: CaseMapNodeID
    let save: (CaseMapNodeID, String?) -> Void
    let cancel: () -> Void
    @State private var frame: CaseMapNodeID?
    @State private var purpose = ""
    @State private var find = ""

    private var candidates: [CaseMapNode] {
        let words = find.lowercased().split(separator: " ").map(String.init)
        return projection.nodes.filter { n in
            n.id != member && CaseMapRecordKind.linkable.contains(n.id.kind)
                && (words.isEmpty || words.allSatisfy { n.title.lowercased().contains($0) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Place in frame").font(.headline)
            Text("Item: \(projection.node(member)?.title ?? "?")").font(.caption).lineLimit(2)
            Text("Choose the item whose branch it belongs in. The item is not copied or moved: it stays one record and appears in every branch it is placed in. A branch can't end up inside itself.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Find the branch", text: $find)
            List(candidates, selection: $frame) { n in Label(n.title, systemImage: n.kind.symbol).lineLimit(1).tag(Optional(n.id)) }
                .frame(height: 200)
            TextField("Why it belongs there (optional)", text: $purpose)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Place") {
                    if let frame { save(frame, purpose.trimmingCharacters(in: .whitespaces).isEmpty ? nil : purpose) }
                    cancel()
                }
                .disabled(reason: frame == nil ? "Choose the branch." : nil)
            }
        }
        .padding(16).frame(width: 520)
    }
}

/// "Revise link…" — a corrected link that names the one it revises.
struct CaseMapReviseSheet: View {
    let link: CaseMapLink
    let save: (CaseMapLinkType, String, CaseMapCertainty, CaseMapValidity?, String) -> Void
    let cancel: () -> Void
    @State private var type: CaseMapLinkType = .supports
    @State private var rationale = ""
    @State private var certainty: CaseMapCertainty = .notStated
    @State private var validity = CaseMapValidityForm()
    @State private var why = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Revise this link").font(.headline)
            Text("The corrected link is recorded between the same two items and names this one; this one is withdrawn with your reason and kept, so the link's history stays readable.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Link type", selection: $type) { ForEach(CaseMapLinkType.allCases.filter(\.drawable)) { Text($0.label).tag($0) } }
            TextField("Why are they linked?", text: $rationale, axis: .vertical).lineLimit(2...4)
            Picker("How certain", selection: $certainty) { ForEach(CaseMapCertainty.allCases) { Text($0.label).tag($0) } }
            CaseMapValidityFields(form: $validity)
            TextField("Why it is revised", text: $why)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Record revision") { save(type, rationale, certainty, validity.value, why); cancel() }
                    .disabled(reason: rationale.trimmingCharacters(in: .whitespaces).isEmpty ? "Say why they are linked."
                              : why.trimmingCharacters(in: .whitespaces).isEmpty ? "Say why it is revised." : validity.problem)
            }
        }
        .padding(16).frame(width: 520)
        .onAppear {
            type = link.type.drawable ? link.type : .supports
            rationale = link.basis
            certainty = link.certainty
            if let v = link.validity {
                validity.hasFrom = v.from != nil; validity.from = v.from ?? Date()
                validity.hasTo = v.to != nil; validity.to = v.to ?? Date()
                validity.text = v.text ?? ""
            }
        }
    }
}

/// A short sheet that asks for a reason, then runs the change.
struct CaseMapReasonSheet: View {
    let title: String
    let explanation: String
    let action: String
    let run: (String) async -> Void
    let cancel: () -> Void
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Your reason", text: $reason)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button(action) { let r = reason; Task { await run(r); cancel() } }
                    .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the reason." : nil)
            }
        }
        .padding(16).frame(width: 440)
    }
}
