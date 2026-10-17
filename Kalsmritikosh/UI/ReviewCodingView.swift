//
//  ReviewCodingView.swift
//  Kalsmritikosh
//
//  N-4 — code documents responsive / not responsive / privileged / hot, with
//  suggestions that learn from your choices and show the words behind them.
//  N-13 — sort by "what to read first": an explained score per document.
//

import SwiftUI
import os

extension AppState {
    public var reviewCodes: ReviewCodesRepository? {
        guard ProductModuleFlags.isEnabled(.reviewCoding), let database else { return nil }
        return ReviewCodesRepository(database: database)
    }

    struct ReviewDocument: Identifiable, Sendable {
        let id: UUID
        let name: String
        let text: String
    }

    /// Documents with their first passages (enough text for coding and suggestions).
    func reviewDocuments(limit: Int = 400) async -> [ReviewDocument] {
        guard let database else { return [] }
        let rows = (try? await database.query("""
            SELECT ko.id, f.url, (SELECT GROUP_CONCAT(text, ' ') FROM (SELECT text FROM chunks c
                WHERE c.object_id = ko.id AND c.review_status IS NULL AND c.superseded_by_run IS NULL ORDER BY ordinal LIMIT 4))
            FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            ORDER BY ko.created_at DESC LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        return rows.compactMap { r in
            guard let id = r.uuid(0) else { return nil }
            let name = r.string(1).flatMap { URL(string: $0)?.lastPathComponent } ?? "Document"
            return ReviewDocument(id: id, name: name, text: r.string(2) ?? "")
        }
    }
}

struct ReviewCodingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var docs: [AppState.ReviewDocument] = []
    @State private var codes: [UUID: ReviewCode] = [:]
    @State private var suggester: CodingSuggester?
    @State private var risk: [UUID: RiskScore] = [:]
    @State private var sortByRisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review coding").font(.title3.bold())
                Spacer()
                if ProductModuleFlags.isEnabled(.riskScore) {
                    Toggle("Read first", isOn: $sortByRisk).toggleStyle(.switch)
                }
            }
            Text(suggester == nil
                 ? "Code at least \(CodingSuggester.minPerClass) documents responsive and \(CodingSuggester.minPerClass) not responsive to get suggestions."
                 : "Suggestions learn from your coding. They never change a document or its evidence.")
                .font(.caption).foregroundStyle(.secondary)
            List(ordered) { d in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.callout.weight(.medium))
                        Text(d.text.prefix(160)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        if codes[d.id] == nil, let s = suggester?.suggest(d.text) {
                            Text("\(s.label) (\(Int(s.responsiveProbability * 100))%) — because of: \(s.reasons.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.blue)
                        }
                        if let r = risk[d.id], r.total > 0 {
                            Text("Read-first score \(r.total): \(r.explanation)").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { codes[d.id] }, set: { new in
                        guard let new else { return }
                        Task { try? await appState.reviewCodes?.setCode(new, for: d.id); await reload() }
                    })) {
                        Text("—").tag(ReviewCode?.none)
                        ForEach(ReviewCode.allCases) { Text($0.label).tag(ReviewCode?.some($0)) }
                    }
                    .frame(width: 160)
                }
            }
            .frame(minHeight: 360)
            HStack {
                Text("\(codes.count) of \(docs.count) coded").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .task {
            docs = await appState.reviewDocuments()
            await reload()
            if ProductModuleFlags.isEnabled(.riskScore) { risk = await appState.riskScores(for: docs.map(\.id)) }
        }
    }

    private var ordered: [AppState.ReviewDocument] {
        sortByRisk ? docs.sorted { (risk[$0.id]?.total ?? 0) > (risk[$1.id]?.total ?? 0) } : docs
    }

    private func reload() async {
        codes = (try? await appState.reviewCodes?.current()) ?? [:]
        let training = docs.compactMap { d -> (String, Bool)? in
            switch codes[d.id] {
            case .responsive?, .hot?: return (d.text, true)
            case .notResponsive?: return (d.text, false)
            default: return nil
            }
        }
        suggester = CodingSuggester(training: training)
    }
}
