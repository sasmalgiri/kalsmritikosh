//
//  QueryView.swift
//  Kalsmritikosh
//
//  A no-code query builder over the ledger — pick a subject, add plain-language
//  filters, run. Anyone can use it; there's no SQL to write. A "View the SQL"
//  panel shows the exact read-only query it generated, for the curious. Results
//  export to CSV. Read-only throughout (LedgerQueryRepository).
//

import SwiftUI
import UniformTypeIdentifiers

struct QueryCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

public struct QueryView: View {
    @Environment(AppState.self) private var appState

    @State private var subjectID = LedgerQueryCatalog.subjects.first!.id
    @State private var filters: [QueryFilter] = []
    @State private var sortFieldKey: String?
    @State private var sortDescending = true
    @State private var limit = 100

    @State private var result: LedgerQueryRepository.QueryResult?
    @State private var running = false
    @State private var errorMessage: String?
    @State private var showSQL = false
    @State private var showExporter = false

    // "Describe your query" — plain language → fills the builder. Deterministic
    // and offline by default; when Full power is on, an on-device model reads
    // the request first (and still only fills this same safe builder).
    @State private var nlText = ""
    @State private var interpreted: String?
    @State private var aiThinking = false

    public init() {}

    /// The AI reading is offered only when Full power is on AND a capability
    /// provider is actually available. Otherwise the deterministic parser runs.
    private var aiAvailable: Bool {
        FeatureFlags.shared.fullPowerMode && appState.capabilities != nil
    }

    private var subject: QuerySubject {
        LedgerQueryCatalog.subject(subjectID) ?? LedgerQueryCatalog.subjects[0]
    }
    private var filterableFields: [QueryField] { subject.fields.filter { $0.filterable } }
    private var sortableFields: [QueryField] { subject.fields.filter { $0.selectable } }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                describeBar
                subjectPicker
                filtersSection
                controlsRow
                if let errorMessage { errorCard(errorMessage) }
                if let result { resultsSection(result) }
            }
            .padding(24)
            .frame(maxWidth: 940, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Query")
        .fileExporter(isPresented: $showExporter,
                      document: QueryCSVDocument(text: csv(result)),
                      contentType: .commaSeparatedText,
                      defaultFilename: "\(subject.label.replacingOccurrences(of: " ", with: "-").lowercased())-query") { _ in }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Query your ledger", systemImage: "line.3.horizontal.decrease.circle")
                .font(.title2.bold())
            Text("Ask a precise question of your own data — pick what you're looking at, add a few filters, and run. No formulas, no code. Every result comes straight from your on-device ledger.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var describeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                TextField("Describe it — e.g. “documents added last month”, “organizations with confidence over 0.8”, “open conflicts”",
                          text: $nlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { smartFill() }
                    .disabled(aiThinking)
                Button { smartFill() } label: {
                    if aiThinking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading…") }
                    } else {
                        Label("Build it", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(aiThinking || nlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let interpreted {
                Text("Interpreted as — \(interpreted). Edit the filters below, then Run.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if aiAvailable {
                Text("On-device AI reads your request and fills the builder — you stay in control, and it never writes SQL. Runs privately on this Mac.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Type a plain-language question; it fills the builder below — you stay in control, and it works offline.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var subjectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("I'm looking at…").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(LedgerQueryCatalog.subjects) { s in
                    Button {
                        subjectID = s.id
                        filters = []; sortFieldKey = nil; result = nil; errorMessage = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: s.systemImage)
                            Text(s.label).lineLimit(1)
                            Spacer()
                        }
                        .font(.callout)
                        .padding(10)
                        .background(subjectID == s.id ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(subjectID == s.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filters").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    if let f = filterableFields.first {
                        filters.append(QueryFilter(fieldKey: f.key, op: QueryOperator.operators(for: f.kind).first ?? .contains))
                    }
                } label: { Label("Add filter", systemImage: "plus") }
                    .controlSize(.small)
                    .disabled(filterableFields.isEmpty)
            }
            if filters.isEmpty {
                Text("No filters — running now returns everything (up to the row limit).")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach($filters) { $filter in
                filterRow($filter)
            }
        }
    }

    @ViewBuilder
    private func filterRow(_ filter: Binding<QueryFilter>) -> some View {
        let field = subject.field(filter.wrappedValue.fieldKey) ?? filterableFields[0]
        HStack(spacing: 8) {
            // Field
            Picker("", selection: filter.fieldKey) {
                ForEach(filterableFields) { Text($0.label).tag($0.key) }
            }
            .labelsHidden().frame(width: 150)
            .onChange(of: filter.wrappedValue.fieldKey) { _, newKey in
                if let f = subject.field(newKey) {
                    filter.wrappedValue.op = QueryOperator.operators(for: f.kind).first ?? .contains
                    filter.wrappedValue.value = ""; filter.wrappedValue.value2 = ""
                }
            }
            // Operator
            Picker("", selection: filter.op) {
                ForEach(QueryOperator.operators(for: field.kind), id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 130)
            // Value(s)
            valueEditor(filter, field: field)
            if filter.wrappedValue.op.needsSecondValue {
                Text("and").font(.caption).foregroundStyle(.secondary)
                valueEditor(filter, field: field, second: true)
            }
            Button { filters.removeAll { $0.id == filter.wrappedValue.id } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func valueEditor(_ filter: Binding<QueryFilter>, field: QueryField, second: Bool = false) -> some View {
        let text = second ? filter.value2 : filter.value
        switch field.kind {
        case .choice:
            Picker("", selection: text) {
                Text("—").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(minWidth: 120)
        case .date:
            DatePicker("", selection: dateBinding(text), displayedComponents: .date)
                .labelsHidden()
        case .number:
            TextField("value", text: text).textFieldStyle(.roundedBorder).frame(width: 90)
        case .text, .fileName:
            TextField("value", text: text).textFieldStyle(.roundedBorder).frame(minWidth: 140)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("Sort by").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { sortFieldKey ?? (subject.defaultSortKey ?? "") },
                                              set: { sortFieldKey = $0.isEmpty ? nil : $0 })) {
                    Text("Default").tag("")
                    ForEach(sortableFields) { Text($0.label).tag($0.key) }
                }.labelsHidden().frame(width: 130)
                Button { sortDescending.toggle() } label: {
                    Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                }.buttonStyle(.bordered).controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("Rows").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $limit) {
                    ForEach([50, 100, 250, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden().frame(width: 80)
            }
            Spacer()
            Button { run() } label: {
                if running { ProgressView().controlSize(.small) }
                else { Label("Run", systemImage: "play.fill") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
        }
    }

    private func resultsSection(_ r: LedgerQueryRepository.QueryResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(r.rows.count) result\(r.rows.count == 1 ? "" : "s")\(r.truncated ? " (row limit reached)" : "")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !r.rows.isEmpty {
                    Button { showExporter = true } label: { Label("Export CSV", systemImage: "square.and.arrow.down") }
                        .controlSize(.small)
                }
            }
            if r.rows.isEmpty {
                Text("No rows match. Loosen a filter and run again.").font(.callout).foregroundStyle(.secondary)
            } else {
                resultsTable(r)
            }
            DisclosureGroup(isExpanded: $showSQL) {
                Text(r.sql)
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Text("Read-only. This is exactly the query that ran — every value is bound, so nothing you type can change or write your data.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
            } label: {
                Label("View the SQL", systemImage: "curlybraces").font(.caption)
            }
        }
    }

    private func resultsTable(_ r: LedgerQueryRepository.QueryResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(r.columns.enumerated()), id: \.offset) { _, col in
                        Text(col.label).font(.caption.weight(.bold))
                            .frame(width: 170, alignment: .leading).padding(8)
                            .background(.quaternary.opacity(0.5))
                    }
                }
                ForEach(Array(r.rows.enumerated()), id: \.offset) { ri, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.caption).lineLimit(2)
                                .frame(width: 170, alignment: .leading).padding(8)
                        }
                    }
                    .background(ri % 2 == 0 ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.15)))
                }
            }
        }
        .frame(maxHeight: 460)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func errorCard(_ message: String) -> some View {
        GroupBox { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
    }

    // MARK: Logic

    private func dateBinding(_ text: Binding<String>) -> Binding<Date> {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        return Binding(
            get: { fmt.date(from: text.wrappedValue) ?? Date() },
            set: { text.wrappedValue = fmt.string(from: $0) }
        )
    }

    private func smartFill() {
        let text = nlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Full power: let the on-device model read it, fall back to the
        // deterministic parser if it can't. Lightning / no model: deterministic.
        if aiAvailable, let caps = appState.capabilities {
            aiThinking = true
            Task {
                if let p = await QueryAIParser.interpret(text, capabilities: caps) {
                    aiThinking = false
                    apply(p, viaAI: true)
                } else if let p = QueryNaturalParser.parse(text) {
                    aiThinking = false
                    apply(p, viaAI: false)
                } else {
                    aiThinking = false
                }
            }
        } else if let p = QueryNaturalParser.parse(text) {
            apply(p, viaAI: false)
        }
    }

    private func apply(_ p: QueryNaturalParser.Parsed, viaAI: Bool) {
        subjectID = p.query.subjectID
        filters = p.query.filters
        sortFieldKey = p.query.sortFieldKey
        sortDescending = p.query.sortDescending
        limit = p.query.limit
        interpreted = viaAI ? "\(p.summary) (read by on-device AI)" : p.summary
        run()
    }

    private func run() {
        guard let db = appState.database else { errorMessage = "The ledger isn't ready yet."; return }
        running = true; errorMessage = nil
        let q = LedgerQuery(subjectID: subjectID, filters: filters, columns: [],
                            sortFieldKey: sortFieldKey, sortDescending: sortDescending, limit: limit)
        Task {
            do {
                result = try await LedgerQueryRepository(database: db).run(q)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            running = false
        }
    }

    private func csv(_ r: LedgerQueryRepository.QueryResult?) -> String {
        guard let r else { return "" }
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        var lines = [r.columns.map { esc($0.label) }.joined(separator: ",")]
        for row in r.rows { lines.append(row.map(esc).joined(separator: ",")) }
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
#Preview("Query") {
    QueryView()
        .environment(AppState())
        .frame(width: 980, height: 720)
}
#endif
