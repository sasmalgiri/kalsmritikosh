//
//  CaseMoneyStatementImportSheet.swift
//  Kalsmritikosh
//
//  Ease fixes A (AI-off assessment 2026-11-15, friction point 2) — the money panel's "Import bank statement…" flow and
//  its "Change kind…" revision. Import: the file chosen, the account and statement period chosen or confirmed, every row
//  previewed with the kind the rules give it (changeable) and every refused row with why, then "Import all rows" — all
//  or nothing, through CaseFileRepository.importStatement in one savepoint — and a receipt. The statement is tied to the
//  case document with the same bytes when the case has it; otherwise the file is recorded as supplied. Nothing here
//  calls a model or the network; amounts are read by the shared money reader, never guessed.
//

import SwiftUI
import CryptoKit
import os

/// A statement file chosen for import, before anything is written.
struct CaseStatementImportDraft: Identifiable {
    let id = UUID()
    let fileName: String
    let text: String
    let sha256: String
    /// The case document with the same bytes (nil: the file is not a document of the case).
    let document: CaseMoneyDocument?

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct CaseStatementImportSheet: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let draft: CaseStatementImportDraft
    let accounts: [CaseMoneyAccount]
    /// The receipt of a written import, or nil when the person cancelled.
    let done: (CaseMoneyStatementImportReceipt?) -> Void

    @State private var accountID: UUID?
    @State private var newIdentifier = ""
    @State private var newInstitution = ""
    @State private var periodStart = ""
    @State private var periodEnd = ""
    @State private var currency = ""
    @State private var opening = ""
    @State private var closing = ""
    @State private var overrides: [Int: CaseMoneyKind] = [:]
    @State private var refusedReceipt: CaseMoneyStatementImportReceipt?
    @State private var error: String?
    @State private var working = false
    @State private var prepared = false

    private var period: (start: String, end: String)? {
        let s = periodStart.trimmingCharacters(in: .whitespaces), e = periodEnd.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !e.isEmpty else { return nil }
        return (s, e)
    }

    private var preview: CaseMoneyStatementPreview {
        CaseMoneyStatementParser.preview(draft.text, currency: currency, period: period)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import bank statement").font(.title3.weight(.semibold))
            Text(sourceLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            statementFields
            Divider()
            rowsPreview
            if let refusedReceipt { Text(refusedReceipt.summary).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(importNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Import all rows") { Task { await importAll() } }
                    .keyboardShortcut(.defaultAction)
                    .caseMapControlHelp("Import all rows")
                    .disabled(reason: blocked)
            }
        }
        .padding(16)
        .frame(width: 820, height: 620)
        .onAppear(perform: prefill)
    }

    private var sourceLine: String {
        if let d = draft.document { return "File: \(draft.fileName). It is the case document “\(d.name)” (the same bytes), so the statement is tied to it." }
        return "File: \(draft.fileName). It is not a document of this case, so it is recorded as supplied by \(actor), with its SHA-256."
    }

    private var importNote: String {
        let p = preview
        return "\(p.importable.count) row(s) ready, \(p.refused.count) refused. All or nothing: a refused row stops the whole import."
    }

    private var blocked: String? {
        if working { return "The statement is being imported." }
        if accountID == nil && newIdentifier.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose the account, or type a new account's number." }
        if period == nil { return "Type the statement period (yyyy-MM-dd)." }
        if currency.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the statement's currency (for example INR)." }
        let p = preview
        if !p.fileProblems.isEmpty { return "The file cannot be read: " + p.fileProblems.joined(separator: " ") }
        if p.rows.isEmpty { return "The file has no statement rows." }
        if !p.refused.isEmpty { return "\(p.refused.count) row(s) are refused; fix the file and choose it again." }
        return nil
    }

    @ViewBuilder private var statementFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Picker("Account", selection: $accountID) {
                    Text("A new account").tag(UUID?.none)
                    ForEach(accounts) { a in Text(a.title).tag(Optional(a.id)) }
                }
                if accountID == nil {
                    HStack {
                        TextField("New account number", text: $newIdentifier).textFieldStyle(.roundedBorder)
                        TextField("Bank, optional", text: $newInstitution).textFieldStyle(.roundedBorder)
                    }
                } else {
                    Text("")
                }
            }
            GridRow {
                TextField("Period from (yyyy-MM-dd)", text: $periodStart).textFieldStyle(.roundedBorder)
                TextField("Period to (yyyy-MM-dd)", text: $periodEnd).textFieldStyle(.roundedBorder)
            }
            GridRow {
                TextField("Currency (e.g. INR)", text: $currency).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Opening balance, optional", text: $opening).textFieldStyle(.roundedBorder)
                    TextField("Closing balance, optional", text: $closing).textFieldStyle(.roundedBorder)
                }
            }
        }
        .onChange(of: accountID) { _, id in
            if let c = accounts.first(where: { $0.id == id })?.currency, currency.isEmpty { currency = c }
        }
    }

    @ViewBuilder private var rowsPreview: some View {
        let p = preview
        Text("Preview (\(p.rows.count) row(s))").font(.headline)
        ForEach(p.fileProblems, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red) }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(p.rows) { row in previewRow(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func previewRow(_ row: CaseMoneyStatementPreview.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Row \(row.row)").font(.caption.monospacedDigit()).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.rowSummary(row)).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let why = row.refusal {
                    Label("Refused: \(why)", systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let proposed = row.kind {
                Picker("Kind", selection: kindBinding(row.row, proposed: proposed)) {
                    ForEach(CaseMoneyKind.allCases.filter { $0 != .unclassified }, id: \.self) { k in Text(k.label).tag(k) }
                }
                .labelsHidden().frame(width: 200)
                .accessibilityLabel("Kind of row \(row.row)")
            }
        }
    }

    static func rowSummary(_ row: CaseMoneyStatementPreview.Row) -> String {
        var parts = [row.dateText, row.description]
        if let r = row.reference { parts.append(r) }
        parts.append("\(row.side): \(row.reading)")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func kindBinding(_ row: Int, proposed: CaseMoneyKind) -> Binding<CaseMoneyKind> {
        Binding(get: { overrides[row] ?? proposed }, set: { overrides[row] = $0 })
    }

    private func prefill() {
        guard !prepared else { return }
        prepared = true
        let p = CaseMoneyStatementParser.preview(draft.text, currency: nil)
        periodStart = p.firstDay ?? ""
        periodEnd = p.lastDay ?? ""
        if accounts.count == 1, let only = accounts.first {
            accountID = only.id
            currency = only.currency ?? ""
        }
    }

    private func importAll() async {
        guard let file = appState.caseFiles?.file, let period else { return }
        working = true
        defer { working = false }
        var request = CaseMoneyStatementImport(accountID: accountID, periodStart: period.start, periodEnd: period.end, currency: currency,
                                               text: draft.text, fileName: draft.fileName)
        request.newAccountIdentifier = newIdentifier
        request.newAccountInstitution = newInstitution
        request.opening = opening
        request.closing = closing
        request.fileSHA256 = draft.sha256
        request.sourceVersionID = draft.document?.id
        request.kindOverrides = overrides
        do {
            let receipt = try await file.importStatement(caseID: caseID, request, actor: actor)
            if receipt.written { done(receipt) } else { refusedReceipt = receipt }
        } catch {
            KalsmritikoshLog.ui.error("Statement not imported: \(error.localizedDescription, privacy: .public)")
            self.error = "Nothing was imported: \(error.localizedDescription)"
        }
    }
}

/// "Change kind…": a record's new kind, with the reason, kept as a revision (who and when).
struct CaseMoneyReclassifySheet: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let record: CaseMoneyRecord
    /// A message when the change was recorded, or nil when cancelled.
    let done: (String?) -> Void
    @State private var kind: CaseMoneyKind?
    @State private var reason = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change kind").font(.headline)
            Text(CaseMoneyTool.recordLine(record)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("The change is kept with your name and the time. A classified record is replaced by a revision of the new kind; the original stays, out of every figure.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("New kind", selection: $kind) {
                Text("Choose a kind").tag(CaseMoneyKind?.none)
                ForEach(CaseMoneyKind.allCases.filter { $0 != .unclassified && $0 != record.kind }, id: \.self) { k in Text(k.label).tag(Optional(k)) }
            }
            TextField("Reason (kept with the change)", text: $reason).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Record the new kind") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .caseMapControlHelp("Record the new kind")
                    .disabled(reason: blocked)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private var blocked: String? {
        if kind == nil { return "Choose the new kind." }
        if reason.trimmingCharacters(in: .whitespaces).isEmpty { return "A reason is needed." }
        return nil
    }

    private func save() async {
        guard let file = appState.caseFiles?.file, let kind else { return }
        do {
            _ = try await file.reclassifyMoney(caseID: caseID, id: record.id, kind: kind, reason: reason, actor: actor)
            done("Kind changed to \(kind.label); the change is kept with your name.")
        } catch {
            KalsmritikoshLog.ui.error("Kind not changed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}
