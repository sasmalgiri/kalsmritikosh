//
//  CaseMoneyMoreBlock.swift
//  Kalsmritikosh
//
//  Reachability recheck 2026-11-17 (QA-16) — the money services that had no screen, under the Money tool's figures:
//  • MONEY-08: exchange rates recorded with their source, day and method; a converted figure is shown beside the original
//    currencies (never in place of them) and says when a currency had no rate and was left out.
//  • MONEY-09: who holds, signs for, owns or controls an account, over which period, from which source — a relationship
//    says nothing about who authorised a payment.
//  • MONEY-11: gaps the records show (a missing statement, movements no statement covers, a statement not reconciled),
//    each proposed once; accepting one creates the action with its account, period and deliverable.
//

import SwiftUI
import os

struct CaseMoneyMoreBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let ledger: CaseMoneyLedger
    let documents: [CaseMoneyDocument]
    /// A message for the tool's notice, then the tool reloads.
    let changed: (String) -> Void
    @State private var state: CaseToolState = .ready
    // Rates
    @State private var from = ""
    @State private var to = ""
    @State private var rate = ""
    @State private var rateDate = ""
    @State private var rateSource = ""
    @State private var method = ""
    @State private var target = ""
    // Ownership
    @State private var account: UUID?
    @State private var holder = ""
    @State private var relation: CaseMoneyRelation = .holder
    @State private var basis: CaseMoneyBasis = .source
    @State private var source: UUID?
    @State private var quote = ""
    @State private var suppliedBy = ""
    @State private var validFrom = ""
    @State private var validTo = ""
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaseToolStateView(state: state)
            rates
            Divider()
            ownership
            Divider()
            gaps
        }
    }

    // MARK: MONEY-08

    @ViewBuilder private var rates: some View {
        Text("Exchange rates").font(.headline)
        ForEach(ledger.conversions.filter(\.isActive), id: \.line) { Text($0.line).font(.caption) }
        HStack {
            TextField("From (e.g. INR)", text: $from).textFieldStyle(.roundedBorder).frame(maxWidth: 110)
            TextField("To (e.g. EUR)", text: $to).textFieldStyle(.roundedBorder).frame(maxWidth: 110)
            TextField("Rate (1 from = ? to)", text: $rate).textFieldStyle(.roundedBorder).frame(maxWidth: 150)
            TextField("Rate day (yyyy-MM-dd)", text: $rateDate).textFieldStyle(.roundedBorder)
        }
        HStack {
            TextField("Rate source (e.g. ECB reference rate)", text: $rateSource).textFieldStyle(.roundedBorder)
            TextField("Method (e.g. rate on the payment day)", text: $method).textFieldStyle(.roundedBorder)
            Button("Record rate") { Task { await recordRate() } }.caseMapControlHelp("Record rate")
                .disabled(reason: [from, to, rate, rateDate, rateSource, method].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? "Every field is needed." : nil)
        }
        let currencies = Array(Set(ledger.conversions.filter(\.isActive).map(\.to))).sorted()
        if !currencies.isEmpty {
            Picker("Show a converted figure in", selection: $target) {
                Text("No conversion").tag("")
                ForEach(currencies, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 320)
            if !target.isEmpty {
                Text(ledger.converted({ $0.grossPaid.amount }, figure: "Gross paid", to: target).label).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("case.money.converted")
            }
        }
    }

    // MARK: MONEY-09

    @ViewBuilder private var ownership: some View {
        Text("Holders, owners and control of accounts").font(.headline)
        Text("A holder or owner is not thereby the person who authorised a payment.").font(.caption).foregroundStyle(.secondary)
        TextField("Reason (needed to withdraw or dismiss)", text: $reason).textFieldStyle(.roundedBorder)
        ForEach(ledger.ownership.filter(\.isActive), id: \.id) { o in
            HStack {
                Text(o.line).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Withdraw relationship") { Task { await withdraw(o.id) } }.controlSize(.small).caseMapControlHelp("Withdraw relationship")
                    .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason above.")
            }
        }
        let accounts = ledger.accounts.filter(\.isActive)
        if accounts.isEmpty {
            Text("Record an account first (import a statement, or record money with its account).").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                Picker("Account", selection: $account) {
                    Text("Choose an account").tag(UUID?.none)
                    ForEach(accounts) { a in Text(a.title).tag(Optional(a.id)) }
                }
                TextField("Name as written", text: $holder).textFieldStyle(.roundedBorder)
                Picker("Relationship", selection: $relation) { ForEach(CaseMoneyRelation.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 220)
            }
            HStack {
                TextField("From (yyyy-MM-dd), optional", text: $validFrom).textFieldStyle(.roundedBorder)
                TextField("To (yyyy-MM-dd), optional", text: $validTo).textFieldStyle(.roundedBorder)
                Picker("Basis", selection: $basis) { ForEach(CaseMoneyBasis.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 220)
            }
            HStack {
                if basis == .source {
                    Picker("Document", selection: $source) {
                        Text("Choose a document").tag(UUID?.none)
                        ForEach(documents) { d in Text(d.name).tag(Optional(d.id)) }
                    }
                    TextField("Words as written, optional", text: $quote).textFieldStyle(.roundedBorder)
                } else if basis == .supplied {
                    TextField("Supplied by", text: $suppliedBy).textFieldStyle(.roundedBorder)
                }
                Button("Record relationship") { Task { await recordRelation() } }.caseMapControlHelp("Record relationship")
                    .disabled(reason: ownershipBlocked)
            }
        }
    }

    private var ownershipBlocked: String? {
        if account == nil { return "Choose the account." }
        if holder.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the name as the document writes it." }
        if basis == .source, source == nil { return "Choose the document it comes from." }
        if basis == .supplied, suppliedBy.trimmingCharacters(in: .whitespaces).isEmpty { return "Name who supplied it." }
        return nil
    }

    // MARK: MONEY-11

    @ViewBuilder private var gaps: some View {
        Text("Gaps in the money records").font(.headline)
        Button("Check for gaps") { Task { await sync() } }.caseMapControlHelp("Check for gaps")
        let open = ledger.proposals.filter { $0.state == .proposed }
        if open.isEmpty { Text("No gap waits for a decision.").font(.caption).foregroundStyle(.secondary) }
        ForEach(open) { p in
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Self.kindLabel(p.kind)): \(accountTitle(p.accountID)), \(p.periodStart) to \(p.periodEnd)").font(.caption.weight(.semibold))
                Text("\(p.reason) Deliverable: \(p.deliverable)").font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Create the action") { Task { await accept(p) } }.caseMapControlHelp("Create the action")
                    Button("Dismiss gap") { Task { await dismiss(p.id) } }.caseMapControlHelp("Dismiss gap")
                        .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason above.")
                }
                .controlSize(.small)
            }
            .padding(6).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    static func kindLabel(_ k: CaseMoneyGapProposal.Kind) -> String {
        switch k {
        case .missingStatement: return "Missing statement"
        case .uncoveredMovements: return "Movements no statement covers"
        case .unreconciledStatement: return "Statement not reconciled"
        }
    }
    private func accountTitle(_ id: UUID?) -> String { ledger.accounts.first { $0.id == id }?.title ?? "no account" }

    // MARK: actions

    private func run(_ doing: String, _ done: String, _ body: (CaseFileRepository) async throws -> Void) async {
        guard let file = appState.caseFiles?.file else { return }
        do { try await body(file); state = .ready; changed(done) }
        catch { KalsmritikoshLog.ui.error("Money, \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: doing) }
    }
    private func recordRate() async {
        await run("recording rates", "Rate recorded; the original-currency figures are unchanged.") { file in
            _ = try await file.recordConversionRate(caseID: caseID, from: from.uppercased(), to: to.uppercased(), rate: rate, rateDate: rateDate,
                                                    rateSource: rateSource, method: method, actor: actor)
            target = to.uppercased(); rate = ""
        }
    }
    private func recordRelation() async {
        guard let account else { return }
        let f = validFrom.trimmingCharacters(in: .whitespaces), t = validTo.trimmingCharacters(in: .whitespaces)
        if (!f.isEmpty && CaseMoneyLedger.date(f) == nil) || (!t.isEmpty && CaseMoneyLedger.date(t) == nil) {
            state = .blocked(reason: "a period day is not written yyyy-MM-dd.", next: "Write the days as yyyy-MM-dd, or leave them empty."); return
        }
        let q = quote.trimmingCharacters(in: .whitespaces), by = suppliedBy.trimmingCharacters(in: .whitespaces)
        await run("recording account relationships", "Relationship recorded with its source and period.") { file in
            _ = try await file.recordAccountRelation(caseID: caseID, accountID: account, holderName: holder, relation: relation,
                                                     validFrom: f.isEmpty ? nil : CaseMoneyLedger.date(f), validTo: t.isEmpty ? nil : CaseMoneyLedger.date(t),
                                                     basis: basis, sourceVersionID: basis == .source ? source : nil, quote: q.isEmpty ? nil : q,
                                                     suppliedBy: basis == .supplied ? by : nil, actor: actor)
            holder = ""; quote = ""
        }
    }
    private func withdraw(_ id: UUID) async {
        await run("withdrawing account relationships", "Withdrawn; it is kept in the history.") { try await $0.withdrawAccountRelation(caseID: caseID, id: id, reason: reason, actor: actor); reason = "" }
    }
    private func sync() async {
        await run("checking money gaps", "Checked; each gap is proposed once, however often its statement appears.") { file in
            _ = try await file.syncMoneyGapProposals(caseID: caseID, actor: actor)
        }
    }
    private func accept(_ p: CaseMoneyGapProposal) async {
        guard let svc = appState.caseFiles else { return }
        do {
            let title = "\(Self.kindLabel(p.kind)): \(accountTitle(p.accountID)), \(p.periodStart) to \(p.periodEnd)"
            let task = try await svc.createAction(caseID: caseID, .init(title: title, purpose: p.reason, deliverable: p.deliverable), actor: actor)
            try await svc.file.decideMoneyGapProposal(caseID: caseID, id: p.id, accept: true, reason: "Action created", taskID: task, actor: actor)
            state = .ready
            changed("Action created: \(title).")
        } catch { KalsmritikoshLog.ui.error("Money gap not accepted: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "creating actions") }
    }
    private func dismiss(_ id: UUID) async {
        await run("dismissing money gaps", "Dismissed with your reason; it is not proposed again.") {
            try await $0.decideMoneyGapProposal(caseID: caseID, id: id, accept: false, reason: reason, actor: actor); reason = ""
        }
    }
}
