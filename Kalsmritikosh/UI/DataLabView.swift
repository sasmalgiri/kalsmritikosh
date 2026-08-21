//
//  DataLabView.swift
//  Kalsmritikosh
//
//  DATALAB-UI (owner request 2026-08-18) — the door to the Stage-C
//  Workbench/DataLab engine that until now booted with no surface: cited
//  datasets over your evidence, safe deterministic transforms, NON-destructive
//  scenario overlays with undo/redo, the quality report, and CSV export.
//  Everything here calls the existing LAB-001..006 authorities; this file is
//  presentation only. Mode-aware: Simple shows outcome-first presets and
//  hides plumbing; Advanced exposes fields/rows/cells, formulas, scenarios,
//  and the full quality list (WorkbenchModePolicy — same data, two views).
//

import SwiftUI
import Charts
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct DataLabView: View {
    @Environment(AppState.self) private var appState

    // Catalog
    @State private var workspaces: [Workspace] = []
    @State private var selectedWorkspace: Workspace.ID?
    @State private var datasets: [WorkbenchDataset] = []
    @State private var newTitle = ""
    @State private var newMode: WorkbenchDatasetMode = .simple

    // Open dataset
    @State private var record: WorkbenchDatasetRecord?
    @State private var selectedCell: (rowID: UUID, fieldID: UUID)?
    @State private var cellEditor = ""
    @State private var newFieldName = ""
    @State private var newFieldShape: FactSchemaRegistry.ValueShape = .text

    // Transforms
    @State private var transformations: [WorkbenchTransformation] = []
    @State private var presetParams = WorkbenchPresetParameters()
    @State private var activePreset: WorkbenchAnalysisPreset?
    @State private var aggregateResult: WorkbenchAggregateResult?
    @State private var rowOrder: [UUID]?          // projection view (sort/filter/dedupe)
    @State private var projectionLabel: String?

    // Scenarios
    @State private var scenarios: [WorkbenchScenario] = []
    @State private var activeScenario: WorkbenchScenarioRecord?
    @State private var scenarioTitle = ""
    @State private var overrideReason = ""

    // Quality
    @State private var quality: WorkbenchDataQualityReport?
    @State private var showQuality = false

    @State private var errorMessage: String?

    // Persona starter template chosen on the create panel (optional).
    @State private var selectedStarter: DataLabStarterTemplate?

    // Interop — Excel/Word/PDF exports (each posts a numbered EXP document),
    // CSV import, and the chart panel.
    @State private var showImporter = false
    @State private var lastExportNumber: String?
    @State private var chartValueField: String?
    @State private var chartLabelField: String?

    // Advanced — formula columns, filter predicates, scenario promotion.
    @State private var formulaName = ""
    @State private var formulaShape: FactSchemaRegistry.ValueShape = .number
    @State private var formulaText = ""
    @State private var filterText = ""
    @State private var reviewingOpID: UUID?
    @State private var reviewDestination: WorkbenchScenarioPromotionDestination = .userCorrection
    @State private var reviewReason = ""

    public init() {}

    public var body: some View {
        Group {
            if record != nil {
                datasetScreen
            } else {
                catalogScreen
            }
        }
        .task { await loadCatalog() }
    }

    private var actorName: String {
        let name = NSFullUserName()
        return name.isEmpty ? "Owner" : name
    }

    /// Header summary line, built as a plain string so the ViewBuilder doesn't
    /// have to type-check a long `Text(...) + optional + optional` chain.
    private func datasetSummary(_ rec: WorkbenchDatasetRecord) -> String {
        var s = "\(rec.fields.count) fields · \(rec.rows.count) rows · revision \(rec.dataset.revision)"
        if let sc = activeScenario { s += " · scenario: \(sc.scenario.title)" }
        if let p = projectionLabel { s += " · view: \(p)" }
        return s
    }

    // MARK: - Catalog

    private var catalogScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DataLab").font(.largeTitle.weight(.bold))
                    Text("Build datasets over your evidence and work them into deeper meaning — transform, test what-if scenarios, check quality. Every source cell drills through to the exact evidence behind it; derived values carry their full lineage.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if workspaces.count > 1 {
                    Picker("Workspace", selection: $selectedWorkspace) {
                        ForEach(workspaces) { ws in
                            Text(ws.title).tag(Optional(ws.id))
                        }
                    }
                    .frame(maxWidth: 340)
                    .onChange(of: selectedWorkspace) { _, _ in Task { await loadDatasets() } }
                }

                // New dataset
                HStack(spacing: 8) {
                    TextField("New dataset — what is this table about?", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Picker("", selection: $newMode) {
                        Text("Simple").tag(WorkbenchDatasetMode.simple)
                        Text("Advanced").tag(WorkbenchDatasetMode.advanced)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 170)
                    Menu {
                        Button("Blank table") { selectedStarter = nil }
                        Divider()
                        ForEach(DataLabStarterTemplates.all) { t in
                            Button("\(t.displayName) · \(t.profession)") { selectedStarter = t }
                        }
                    } label: {
                        Label(selectedStarter?.displayName ?? "Start from a template", systemImage: "square.grid.2x2")
                            .font(.caption).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Optionally start from a ready-made table for your profession — privilege log, surveillance log, research log, transaction ledger, and more. You can still add or remove columns after.")
                    Button("Create") { createDataset() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Creates a dataset in this workspace — blank, or pre-filled with the columns of the chosen template")
                    Button {
                        showImporter = true
                    } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }
                        .help("Turn a spreadsheet into a dataset — export it from Excel/Numbers as CSV first; the header row becomes the fields")
                }
                .fileImporter(isPresented: $showImporter,
                              allowedContentTypes: [.commaSeparatedText, .plainText],
                              allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first { importCSV(url) }
                }

                if let starter = selectedStarter {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Template: \(starter.displayName) — \(starter.purpose)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(starter.note)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                }

                if let message = errorMessage { errorBanner(message) }

                sectionLabel(datasets.isEmpty ? "No datasets yet" : "Your datasets")
                if datasets.isEmpty {
                    Text("Datasets also appear here when a persona job prepares one (e.g. the Investigator's Source Inventory).")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(datasets) { ds in datasetCard(ds) }
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func datasetCard(_ ds: WorkbenchDataset) -> some View {
        Button {
            open(ds.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "tablecells").foregroundStyle(.tint)
                    Text(ds.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(ds.mode == .simple ? "Simple" : "Advanced")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                Text("Revision \(ds.revision) · updated \(ds.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this dataset in the lab")
    }

    // MARK: - Dataset screen

    @ViewBuilder
    private var datasetScreen: some View {
        if let rec = record {
            let mode = rec.dataset.mode
            let caps = WorkbenchModePolicy.capabilities(for: mode)
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    datasetHeader(rec, caps: caps)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        grid(rec)
                            .padding(12)
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                sidebar(rec, caps: caps)
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 400)
            }
        }
    }

    private func datasetHeader(_ rec: WorkbenchDatasetRecord, caps: WorkbenchModeCapabilities) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    close()
                } label: { Label("All datasets", systemImage: "chevron.left").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.tint)
                Spacer()
                Picker("", selection: modeBinding(rec)) {
                    Text("Simple").tag(WorkbenchDatasetMode.simple)
                    Text("Advanced").tag(WorkbenchDatasetMode.advanced)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 170)
                .help("Same data, two presentations — Simple is outcome-first; Advanced exposes fields, formulas and scenarios")
            }
            HStack(spacing: 10) {
                Text(rec.dataset.title).font(.title2.weight(.bold))
                if rec.isFullyProvenanced {
                    Label("Every source cell cited", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button {
                    Task { await loadQuality(rec) }
                } label: { Label("Quality", systemImage: "stethoscope").font(.caption) }
                .help("Check this dataset for missing values, stale sources, unreviewed scenario values and more")
                Menu {
                    Button("CSV — spreadsheet interchange") { export(rec, format: .csv) }
                    Button("Excel workbook (.xlsx)") { export(rec, format: .xlsx) }
                    Button("Word report (.docx)") { export(rec, format: .docx) }
                    Button("PDF report") { export(rec, format: .pdf) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Save the current view (including an active scenario) for Excel, Word or print — every export posts a numbered Export document in the Work Center register")
            }
            Text(datasetSummary(rec))
                .font(.caption).foregroundStyle(.secondary)
            if let number = lastExportNumber {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Exported — document ").font(.caption)
                        + Text(number).font(.caption.monospaced().weight(.bold))
                        + Text(" posted. Quote it anywhere; find it in Work Center ▸ Documents.").font(.caption)
                    Spacer()
                    Button { lastExportNumber = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = errorMessage { errorBanner(message) }
            if showQuality, let quality { qualityPanel(quality, mode: rec.dataset.mode) }
        }
        .padding(14)
    }

    // MARK: Grid

    private func grid(_ rec: WorkbenchDatasetRecord) -> some View {
        let fields = rec.fields.sorted { $0.ordinal < $1.ordinal }
        var rows = rec.rows.sorted { $0.ordinal < $1.ordinal }
        if let projection = activeProjection() {
            rows = rows.filter { !projection.excludedRows.contains($0.id) }
        }
        if let order = rowOrder {
            let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            rows = rows.filter { index[$0.id] != nil }.sorted { (index[$0.id] ?? 0) < (index[$1.id] ?? 0) }
        }
        var cellByKey: [String: WorkbenchCell] = [:]
        for cell in rec.cells { cellByKey["\(cell.rowID.uuidString)|\(cell.fieldID.uuidString)"] = cell }

        return VStack(alignment: .leading, spacing: 2) {
            // Header row
            HStack(spacing: 2) {
                ForEach(fields) { field in
                    Text(field.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .padding(6)
                        .background(.quaternary.opacity(0.5))
                }
            }
            ForEach(rows) { row in
                HStack(spacing: 2) {
                    ForEach(fields) { field in
                        gridCell(row: row, field: field,
                                 cell: cellByKey["\(row.id.uuidString)|\(field.id.uuidString)"],
                                 rec: rec)
                    }
                }
            }
            if rows.isEmpty {
                Text("No rows yet — add one from the panel on the right.")
                    .font(.caption).foregroundStyle(.tertiary).padding(8)
            }
        }
    }

    private func gridCell(row: WorkbenchRow, field: WorkbenchField,
                          cell: WorkbenchCell?, rec: WorkbenchDatasetRecord) -> some View {
        let projection = activeProjection()
        let overridden = projection?.cellOverrides["\(row.id.uuidString)|\(field.id.uuidString)"] != nil
        let display = projection?.projectedValue(rowID: row.id, fieldID: field.id) ?? cell?.value
        let selected = selectedCell?.rowID == row.id && selectedCell?.fieldID == field.id
        return Button {
            selectedCell = (row.id, field.id)
            cellEditor = display ?? ""
        } label: {
            HStack(spacing: 4) {
                if let cell {
                    Circle()
                        .fill(provenanceColor(cell, rec: rec, overridden: overridden))
                        .frame(width: 6, height: 6)
                }
                Text(display ?? "")
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .frame(width: 150)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.15))
                        : overridden ? AnyShapeStyle(.orange.opacity(0.10))
                        : AnyShapeStyle(.quaternary.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cellHelp(cell, rec: rec, overridden: overridden))
    }

    private func provenanceColor(_ cell: WorkbenchCell, rec: WorkbenchDatasetRecord, overridden: Bool) -> Color {
        if overridden { return .orange }
        switch cell.kind {
        case .sourceValue:
            return rec.bindings(forCell: cell.id).isEmpty ? .red : .green
        case .deterministicCalculation: return .blue
        case .userEntered, .userCorrected: return .gray
        case .modelProposal: return .purple
        case .reviewed: return .green
        }
    }

    private func cellHelp(_ cell: WorkbenchCell?, rec: WorkbenchDatasetRecord, overridden: Bool) -> String {
        guard let cell else { return "Empty — click to enter a value" }
        if overridden { return "Scenario override — the base value is untouched; see the scenario panel" }
        switch cell.kind {
        case .sourceValue:
            let n = rec.bindings(forCell: cell.id).count
            return n > 0 ? "Source value — drills through to \(n) bound source(s)" : "Source value with NO binding (should not happen)"
        case .deterministicCalculation: return "Calculated — derived deterministically; lineage recorded"
        case .userEntered: return "Entered by hand — carries no source"
        case .userCorrected: return "Corrected by hand"
        case .modelProposal: return "Model proposal — not confirmed"
        case .reviewed: return "Reviewed"
        }
    }

    // MARK: Sidebar (structure, analyses, scenario, selected cell)

    private func sidebar(_ rec: WorkbenchDatasetRecord, caps: WorkbenchModeCapabilities) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let sel = selectedCell { cellPanel(rec, selection: sel) }

                if caps.exposes(.rawFieldRowCellEditing) {
                    structurePanel(rec)
                }

                analysesPanel(rec, caps: caps)

                if caps.exposes(.formulaEditor) {
                    formulaPanel(rec)
                }

                chartPanel(rec)

                if caps.exposes(.scenarioBuilder) {
                    scenarioPanel(rec)
                }

                if !transformations.isEmpty {
                    sectionLabel("Transform history")
                    ForEach(transformations) { t in
                        HStack(spacing: 6) {
                            Image(systemName: "function").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.kind.rawValue).font(.caption.weight(.medium))
                                if let formula = t.formulaText {
                                    Text(formula).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(t.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(.background.secondary)
    }

    private func cellPanel(_ rec: WorkbenchDatasetRecord, selection: (rowID: UUID, fieldID: UUID)) -> some View {
        let cell = rec.cells.first { $0.rowID == selection.rowID && $0.fieldID == selection.fieldID }
        let field = rec.fields.first { $0.id == selection.fieldID }
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Selected cell — \(field?.name ?? "?")")
            if let cell, cell.kind == .sourceValue {
                Text("This value comes from a source — it can be questioned in a scenario, but not edited away.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(rec.bindings(forCell: cell.id)) { binding in
                    Label("\(binding.targetKind.rawValue) \(binding.targetID.prefix(8))…", systemImage: "link")
                        .font(.caption2).foregroundStyle(.tint)
                }
            } else {
                TextField("Value", text: $cellEditor)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save value") { saveCell(rec, selection: selection) }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                    if activeScenario != nil {
                        Button("Override in scenario") { applyOverride(rec, selection: selection) }
                            .controlSize(.small)
                            .help("Records a what-if value in the scenario — the base cell stays untouched")
                    }
                }
            }
        }
        .padding(10)
        .background(.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func structurePanel(_ rec: WorkbenchDatasetRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Structure")
            HStack(spacing: 6) {
                TextField("New field name", text: $newFieldName)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $newFieldShape) {
                    ForEach([FactSchemaRegistry.ValueShape.text, .number, .money, .date, .boolean], id: \.rawValue) { shape in
                        Text(shape.rawValue).tag(shape)
                    }
                }
                .labelsHidden().frame(width: 90)
                Button { addField(rec) } label: { Image(systemName: "plus") }
                    .disabled(newFieldName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add a field (column)")
            }
            Button { addRow(rec) } label: { Label("Add row", systemImage: "plus.rectangle") }
                .controlSize(.small)
                .disabled(rec.fields.isEmpty)

            Divider().padding(.vertical, 2)
            sectionLabel("Templates")
            Button { applyNetWorthTemplate(rec) } label: {
                Label("Net-worth workpaper", systemImage: "dollarsign.arrow.circlepath").font(.caption)
            }
            .controlSize(.small)
            .help("Set up the net-worth method: adds the input columns (assets, liabilities, opening net worth, reported income, known expenditures) and the derived columns (net worth, increase, funds applied, income from unknown sources). Fill inputs from source documents.")
            Text("An unexplained increase is a lead, not proof.")
                .font(.caption2).foregroundStyle(.secondary)

            Menu {
                ForEach(DataLabStarterTemplates.all) { t in
                    Button("\(t.displayName) · \(t.profession)") {
                        Task { await applyStarter(t, to: rec) }
                    }
                }
            } label: {
                Label("Apply a profession template", systemImage: "square.grid.2x2").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .help("Add the columns of a ready-made table for your profession to this dataset — existing columns are kept, so it's safe to apply.")
        }
    }

    private func analysesPanel(_ rec: WorkbenchDatasetRecord, caps: WorkbenchModeCapabilities) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Analyses — plain language, records provenance")
            ForEach(WorkbenchModePresetCatalog.simplePresets) { preset in
                Button {
                    activePreset = activePreset?.id == preset.id ? nil : preset
                    presetParams = WorkbenchPresetParameters()
                } label: {
                    HStack {
                        Text(preset.title).font(.caption)
                        Spacer()
                        Image(systemName: activePreset?.id == preset.id ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.plainLanguage)
                if activePreset?.id == preset.id {
                    presetForm(preset, rec: rec)
                }
            }
            if let agg = aggregateResult {
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("Result — \(agg.function.rawValue)")
                    ForEach(Array(agg.groups.enumerated()), id: \.offset) { _, group in
                        HStack {
                            Text(group.resultKey ?? "all rows").font(.caption)
                            Spacer()
                            Text(display(group.value)).font(.caption.monospaced().weight(.semibold))
                        }
                    }
                }
                .padding(8)
                .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if rowOrder != nil {
                Button {
                    rowOrder = nil; projectionLabel = nil
                } label: { Label("Clear view (show all rows, original order)", systemImage: "xmark.circle") }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func presetForm(_ preset: WorkbenchAnalysisPreset, rec: WorkbenchDatasetRecord) -> some View {
        let names = rec.fields.sorted { $0.ordinal < $1.ordinal }.map(\.name)
        VStack(alignment: .leading, spacing: 6) {
            switch preset.kind {
            case .totalByCategory, .countByCategory, .averageByCategory:
                fieldPicker("Group by", $presetParams.groupByField, names)
                if preset.kind != .countByCategory {
                    fieldPicker("Value field", $presetParams.valueField, names)
                }
            case .keepRowsAbove, .keepRowsBelow:
                fieldPicker("Field", $presetParams.valueField, names)
                TextField("Threshold", text: bindingFor(presetParams.threshold, into: { presetParams.threshold = $0 }))
                    .textFieldStyle(.roundedBorder)
            case .sortLowToHigh, .sortHighToLow:
                fieldPicker("Sort by", $presetParams.sortField, names)
            case .runningTotal:
                fieldPicker("Over field", $presetParams.valueField, names)
                TextField("New field name", text: bindingFor(presetParams.newFieldName, into: { presetParams.newFieldName = $0 }))
                    .textFieldStyle(.roundedBorder)
            case .removeDuplicates:
                fieldPicker("Key field", $presetParams.keyField, names)
            }
            Button("Run") { runPreset(preset, rec: rec) }
                .controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fieldPicker(_ label: String, _ selection: Binding<String?>, _ names: [String]) -> some View {
        Picker(label, selection: selection) {
            Text("—").tag(String?.none)
            ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .font(.caption)
    }

    /// Bridge an optional String parameter into a TextField binding.
    private func bindingFor(_ value: String?, into setter: @escaping (String?) -> Void) -> Binding<String> {
        Binding(get: { value ?? "" }, set: { setter($0.isEmpty ? nil : $0) })
    }

    // MARK: Formula columns + filter predicates (Advanced — the =formula tools)

    /// Live parse feedback for a formula: nil = empty, .success lists the
    /// fields it reads, .failure explains the problem before anything runs.
    private func formulaFeedback(_ source: String) -> Result<[String], Error>? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do { return .success(try WorkbenchExpressionParser.parse(trimmed).referencedFields) }
        catch { return .failure(error) }
    }

    private func formulaPanel(_ rec: WorkbenchDatasetRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Formula column — like =… in Excel, with lineage")
            HStack(spacing: 6) {
                TextField("New column name", text: $formulaName)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $formulaShape) {
                    ForEach([FactSchemaRegistry.ValueShape.number, .text, .money, .boolean, .date],
                            id: \.rawValue) { shape in
                        Text(shape.rawValue).tag(shape)
                    }
                }
                .labelsHidden().frame(width: 90)
            }
            TextField("Formula — e.g. Premium * 0.18  or  IF(Amount > 1000, \"high\", \"low\")",
                      text: $formulaText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(1...3)
            switch formulaFeedback(formulaText) {
            case .success(let fields):
                Label(fields.isEmpty ? "Valid — uses no columns"
                      : "Valid — reads: \(fields.joined(separator: ", "))",
                      systemImage: "checkmark.circle")
                    .font(.caption2).foregroundStyle(.green)
            case .failure(let error):
                Label(String(describing: error), systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
            Button("Add calculated column") {
                let spec = WorkbenchTransformSpec.calculatedColumn(
                    newField: formulaName.trimmingCharacters(in: .whitespaces),
                    shape: formulaShape,
                    formula: formulaText.trimmingCharacters(in: .whitespaces))
                runTransform(spec, rec: rec, label: "formula")
                formulaName = ""; formulaText = ""
            }
            .controlSize(.small).buttonStyle(.borderedProminent)
            .disabled(formulaName.trimmingCharacters(in: .whitespaces).isEmpty
                      || !isValidFormula(formulaText))
            .help("Computes one value per row and saves the column — every derived cell records exactly which cells fed it")

            Divider()
            Text("KEEP ROWS WHERE…").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Condition — e.g. Amount > 1000 AND Status = \"open\"",
                      text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            if case .failure(let error) = formulaFeedback(filterText) {
                Label(String(describing: error), systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Button("Apply filter view") {
                runTransform(.filter(predicate: filterText.trimmingCharacters(in: .whitespaces)),
                             rec: rec, label: "filter: \(filterText)")
            }
            .controlSize(.small)
            .disabled(!isValidFormula(filterText))
            .help("Shows only matching rows — a view, not a deletion; clear it any time")

            DisclosureGroup {
                Text("Operators: + − * /  ·  = <> < <= > >=  ·  AND OR NOT  ·  & (join text)\nFunctions: IF, COALESCE, ISBLANK, ABS, ROUND, FLOOR, CEIL, SQRT, MOD, MIN, MAX, NUMBER, LEN, UPPER, LOWER, TRIM, CONCAT, CONTAINS, STARTSWITH, ENDSWITH, TEXT, PERCENT, DATEDIFF, YEAR, MONTH, DAY\nRefer to columns by name; quote text values.")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Formula reference").font(.caption2)
            }
        }
    }

    private func isValidFormula(_ source: String) -> Bool {
        if case .success = formulaFeedback(source) { return true }
        return false
    }

    private func scenarioPanel(_ rec: WorkbenchDatasetRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Scenarios — what-if, never touching the base")
            if let active = activeScenario {
                HStack(spacing: 6) {
                    Text(active.scenario.title).font(.caption.weight(.semibold))
                    Spacer()
                    Button { scenarioUndo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!active.canUndo).help("Undo the last scenario change")
                    Button { scenarioRedo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!active.canRedo).help("Redo")
                    Button { activeScenario = nil } label: { Image(systemName: "eye.slash") }
                        .help("Stop viewing this scenario (it stays saved)")
                }
                .buttonStyle(.plain)
                TextField("Why this what-if? (recorded with each override)", text: $overrideReason)
                    .textFieldStyle(.roundedBorder).font(.caption)
                let diff = activeProjection()?.diff() ?? []
                if !diff.isEmpty {
                    Text("\(diff.count) value(s) differ from the base").font(.caption2).foregroundStyle(.orange)
                }
                promotionSection(rec, active: active)
            } else {
                HStack(spacing: 6) {
                    TextField("New scenario title", text: $scenarioTitle)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Button("Create") { createScenario(rec) }
                        .controlSize(.small)
                        .disabled(scenarioTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(scenarios.filter { $0.status == .active }) { sc in
                    Button {
                        openScenario(sc.id)
                    } label: {
                        Label(sc.title, systemImage: "square.stack.3d.up").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: Scenario promotion — a what-if only becomes real through a review

    @ViewBuilder
    private func promotionSection(_ rec: WorkbenchDatasetRecord, active: WorkbenchScenarioRecord) -> some View {
        let applied = active.appliedOperations
        let reviewedOps = Set(active.reviews.map(\.operationID))
        if !applied.isEmpty {
            DisclosureGroup {
                ForEach(applied) { op in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: reviewedOps.contains(op.id)
                                  ? "checkmark.seal" : "square.stack.3d.up")
                                .font(.caption2)
                                .foregroundStyle(reviewedOps.contains(op.id) ? .green : .orange)
                            Text(operationSummary(op, rec: rec))
                                .font(.caption2)
                                .lineLimit(2)
                            Spacer()
                            if !reviewedOps.contains(op.id) {
                                Button("Review…") {
                                    reviewingOpID = reviewingOpID == op.id ? nil : op.id
                                    reviewReason = ""
                                } .controlSize(.mini)
                                .help("Decide whether this what-if becomes a recorded correction or finding — the human decision is what makes it real")
                            }
                        }
                        if reviewingOpID == op.id {
                            reviewForm(active: active, op: op)
                        }
                    }
                }
                ForEach(active.reviews) { review in
                    HStack(spacing: 6) {
                        Image(systemName: review.decision == .accepted ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.caption2)
                            .foregroundStyle(review.decision == .accepted ? .green : .red)
                        Text("\(review.decision.rawValue) → \(review.destination.rawValue) by \(review.reviewer)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("Promote what-ifs (\(applied.count) change\(applied.count == 1 ? "" : "s"), \(active.reviews.count) reviewed)")
                    .font(.caption2)
            }
        }
    }

    private func operationSummary(_ op: WorkbenchScenarioOperation, rec: WorkbenchDatasetRecord) -> String {
        let fieldName = op.fieldID.flatMap { fid in rec.fields.first { $0.id == fid }?.name }
        switch op.kind {
        case .rowExclusion: return "Excluded a row\(op.reason.map { " — \($0)" } ?? "")"
        case .rowInclusion: return "Re-included a row"
        default:
            let change = "\(op.beforeValue ?? "—") → \(op.afterValue ?? "—")"
            return "\(fieldName ?? "?"): \(change)\(op.reason.map { " — \($0)" } ?? "")"
        }
    }

    private func reviewForm(active: WorkbenchScenarioRecord, op: WorkbenchScenarioOperation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Becomes", selection: $reviewDestination) {
                Text("User correction").tag(WorkbenchScenarioPromotionDestination.userCorrection)
                Text("Working finding").tag(WorkbenchScenarioPromotionDestination.workingFinding)
                Text("Method-run input").tag(WorkbenchScenarioPromotionDestination.methodRunInput)
                Text("Claim review").tag(WorkbenchScenarioPromotionDestination.claimReview)
                Text("Work-product input").tag(WorkbenchScenarioPromotionDestination.workProductInput)
            }
            .font(.caption2)
            TextField("Why? (required — this reason goes on the record)", text: $reviewReason)
                .textFieldStyle(.roundedBorder).font(.caption)
            HStack {
                Button("Accept") { promote(active: active, op: op, decision: .accepted) }
                    .controlSize(.mini).buttonStyle(.borderedProminent)
                    .disabled(reviewReason.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Reject") { promote(active: active, op: op, decision: .rejected) }
                    .controlSize(.mini)
                    .disabled(reviewReason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func promote(active: WorkbenchScenarioRecord, op: WorkbenchScenarioOperation,
                         decision: WorkbenchScenarioReviewDecision) {
        guard let repo = appState.workbenchScenarios else { return }
        errorMessage = nil
        let reason = reviewReason.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                activeScenario = try await repo.promoteThroughReview(
                    scenarioID: active.scenario.id, operationID: op.id,
                    destination: reviewDestination, decision: decision,
                    reviewer: actorName, reason: reason, resultingReference: nil,
                    expectedRevision: active.scenario.revision, at: Date())
                reviewingOpID = nil
            } catch { errorMessage = "Could not record the review: \(error)" }
        }
    }

    private func qualityPanel(_ report: WorkbenchDataQualityReport, mode: WorkbenchDatasetMode) -> some View {
        let surfaced = WorkbenchModePresentation.warningsToSurface(mode: mode, report: report)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel(report.isClean ? "Quality — clean" : "Quality — \(surfaced.count) warning(s)")
                Spacer()
                Button { showQuality = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            ForEach(surfaced.prefix(12)) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: warning.severity == .blocking ? "xmark.octagon.fill"
                          : warning.severity == .caution ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(warning.severity == .blocking ? .red
                                         : warning.severity == .caution ? .orange : .secondary)
                        .font(.caption)
                    Text(warning.message).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Small pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(8)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func display(_ value: WorkbenchValue) -> String {
        switch value {
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .text(let s): return s
        case .boolean(let b): return b ? "true" : "false"
        case .date(let d): return d.formatted(date: .abbreviated, time: .omitted)
        case .null: return "—"
        }
    }

    private func activeProjection() -> WorkbenchScenarioProjection? {
        guard let record, let active = activeScenario else { return nil }
        return WorkbenchScenarioProjection.build(base: record, appliedOps: active.appliedOperations)
    }

    private func modeBinding(_ rec: WorkbenchDatasetRecord) -> Binding<WorkbenchDatasetMode> {
        Binding(
            get: { rec.dataset.mode },
            set: { newMode in
                guard let repo = appState.workbenchDatasets else { return }
                Task {
                    do {
                        let updated = try await repo.setMode(datasetID: rec.dataset.id, mode: newMode,
                                                             expectedRevision: rec.dataset.revision,
                                                             actor: actorName, at: Date())
                        record = updated
                    } catch { errorMessage = "Could not switch mode: \(error)" }
                }
            })
    }

    // MARK: - Actions

    private func loadCatalog() async {
        if let repo = appState.workspaces {
            workspaces = (try? await repo.all(includeArchived: false)) ?? []
            if selectedWorkspace == nil { selectedWorkspace = workspaces.first?.id }
        }
        await loadDatasets()
    }

    /// First run: no workspace exists yet — create the default one rather
    /// than dead-ending on a disabled Create/Import button.
    private func ensureWorkspace() async -> Workspace.ID? {
        if let id = selectedWorkspace { return id }
        guard let repo = appState.workspaces else { return nil }
        let ws = Workspace(title: "General")
        try? await repo.upsert(ws)
        workspaces = (try? await repo.all(includeArchived: false)) ?? [ws]
        selectedWorkspace = workspaces.first?.id
        return selectedWorkspace
    }

    private func loadDatasets() async {
        guard let repo = appState.workbenchDatasets, let wsID = selectedWorkspace else { return }
        let ids = (try? await repo.datasetIDs(workspaceID: wsID)) ?? []
        var list: [WorkbenchDataset] = []
        for id in ids {
            if let ds = try? await repo.dataset(id: id) { list.append(ds) }
        }
        datasets = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func createDataset() {
        guard let repo = appState.workbenchDatasets else { return }
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        Task {
            do {
                guard let wsID = await ensureWorkspace() else { return }
                let rec = try await repo.createDataset(workspaceID: wsID, title: title,
                                                       mode: newMode, actor: actorName, at: Date())
                newTitle = ""
                record = rec
                await loadSatellites(rec.dataset.id)
                if let starter = selectedStarter {
                    await applyStarter(starter, to: rec)
                    selectedStarter = nil
                }
            } catch { errorMessage = "Could not create the dataset: \(error)" }
        }
    }

    private func open(_ id: UUID) {
        guard let repo = appState.workbenchDatasets else { return }
        errorMessage = nil
        Task {
            record = try? await repo.fetch(datasetID: id)
            selectedCell = nil
            aggregateResult = nil
            rowOrder = nil; projectionLabel = nil
            activeScenario = nil
            showQuality = false
            await loadSatellites(id)
        }
    }

    private func close() {
        record = nil
        activeScenario = nil
        Task { await loadDatasets() }
    }

    private func loadSatellites(_ datasetID: UUID) async {
        transformations = (try? await appState.workbenchTransforms?.transformations(datasetID: datasetID)) ?? []
        if let scRepo = appState.workbenchScenarios {
            let ids = (try? await scRepo.scenarioIDs(datasetID: datasetID)) ?? []
            var list: [WorkbenchScenario] = []
            for id in ids { if let sc = try? await scRepo.scenario(id: id) { list.append(sc) } }
            scenarios = list.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func reload(_ datasetID: UUID) async {
        guard let repo = appState.workbenchDatasets else { return }
        record = try? await repo.fetch(datasetID: datasetID)
        await loadSatellites(datasetID)
        if let active = activeScenario, let scRepo = appState.workbenchScenarios {
            activeScenario = try? await scRepo.fetch(scenarioID: active.scenario.id)
        }
    }

    private func addField(_ rec: WorkbenchDatasetRecord) {
        guard let repo = appState.workbenchDatasets else { return }
        let name = newFieldName.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        Task {
            do {
                record = try await repo.addField(datasetID: rec.dataset.id, name: name, valueShape: newFieldShape,
                                                 expectedRevision: rec.dataset.revision, actor: actorName, at: Date())
                newFieldName = ""
            } catch { errorMessage = "Could not add the field: \(error)" }
        }
    }

    /// Apply the forensic net-worth workpaper: add any missing input columns,
    /// then apply the derived formula columns in order. Each mutation bumps the
    /// dataset revision, so the latest record is threaded through (addField
    /// returns it; applyTransform is followed by a fetch). Idempotent — columns
    /// that already exist are skipped, so re-running never duplicates.
    private func applyNetWorthTemplate(_ rec: WorkbenchDatasetRecord) {
        guard let datasets = appState.workbenchDatasets,
              let transforms = appState.workbenchTransforms else { return }
        errorMessage = nil
        Task {
            do {
                var current = rec
                for col in ForensicNetWorthTemplate.inputColumns
                where !current.fields.contains(where: { $0.name == col.name }) {
                    current = try await datasets.addField(
                        datasetID: current.dataset.id, name: col.name, valueShape: col.shape,
                        expectedRevision: current.dataset.revision, actor: actorName, at: Date())
                }
                for spec in ForensicNetWorthTemplate.transformSpecs {
                    if case .calculatedColumn(let name, _, _) = spec,
                       current.fields.contains(where: { $0.name == name }) { continue }
                    _ = try await transforms.applyTransform(
                        datasetID: current.dataset.id, spec: spec,
                        expectedRevision: current.dataset.revision, actor: actorName, at: Date())
                    if let refreshed = try await datasets.fetch(datasetID: current.dataset.id) {
                        current = refreshed
                    }
                }
                record = current
            } catch {
                errorMessage = "Could not apply the net-worth workpaper: \(error)"
            }
        }
    }

    /// Apply a persona starter template: add any missing input columns, then
    /// apply derived formula columns in order. Threads the latest record through
    /// each revision bump. Idempotent — existing columns are skipped, so
    /// applying the same template twice never duplicates. Shared by the create
    /// panel (any mode) and the Advanced structure panel.
    private func applyStarter(_ template: DataLabStarterTemplate, to rec: WorkbenchDatasetRecord) async {
        guard let datasets = appState.workbenchDatasets,
              let transforms = appState.workbenchTransforms else { return }
        do {
            var current = rec
            for col in template.inputColumns
            where !current.fields.contains(where: { $0.name == col.name }) {
                current = try await datasets.addField(
                    datasetID: current.dataset.id, name: col.name, valueShape: col.shape,
                    expectedRevision: current.dataset.revision, actor: actorName, at: Date())
            }
            for spec in template.transformSpecs {
                if case .calculatedColumn(let name, _, _) = spec,
                   current.fields.contains(where: { $0.name == name }) { continue }
                _ = try await transforms.applyTransform(
                    datasetID: current.dataset.id, spec: spec,
                    expectedRevision: current.dataset.revision, actor: actorName, at: Date())
                if let refreshed = try await datasets.fetch(datasetID: current.dataset.id) {
                    current = refreshed
                }
            }
            record = current
        } catch {
            errorMessage = "Could not apply the \(template.displayName) template: \(error)"
        }
    }

    private func addRow(_ rec: WorkbenchDatasetRecord) {
        guard let repo = appState.workbenchDatasets else { return }
        errorMessage = nil
        Task {
            do {
                record = try await repo.addRow(datasetID: rec.dataset.id,
                                               expectedRevision: rec.dataset.revision, actor: actorName, at: Date())
            } catch { errorMessage = "Could not add the row: \(error)" }
        }
    }

    private func saveCell(_ rec: WorkbenchDatasetRecord, selection: (rowID: UUID, fieldID: UUID)) {
        guard let repo = appState.workbenchDatasets else { return }
        errorMessage = nil
        let value = cellEditor
        Task {
            do {
                record = try await repo.setCell(datasetID: rec.dataset.id, rowID: selection.rowID,
                                                fieldID: selection.fieldID, kind: .userEntered,
                                                value: value.isEmpty ? nil : value, status: .humanConfirmed,
                                                expectedRevision: rec.dataset.revision, actor: actorName, at: Date())
            } catch { errorMessage = "Could not save the cell: \(error)" }
        }
    }

    private func runPreset(_ preset: WorkbenchAnalysisPreset, rec: WorkbenchDatasetRecord) {
        errorMessage = nil
        do {
            let spec = try WorkbenchModePresetCatalog.compile(preset.kind, parameters: presetParams)
            runTransform(spec, rec: rec, label: preset.title)
        } catch { errorMessage = "Fill the analysis inputs first: \(error)" }
    }

    /// Compute (pure) for immediate display AND persist through the transform
    /// authority so the analysis carries durable lineage.
    private func runTransform(_ spec: WorkbenchTransformSpec, rec: WorkbenchDatasetRecord, label: String) {
        Task {
            do {
                let base = activeProjection()?.projectedRecord() ?? rec
                let outcome = try WorkbenchTransformEngine.compute(spec, over: base)
                switch outcome {
                case .aggregate(let result):
                    aggregateResult = result
                case .projection(let result):
                    rowOrder = result.orderedRowIDs
                    projectionLabel = label
                    aggregateResult = nil
                case .column, .unsupported:
                    aggregateResult = nil
                }
                // Persist lineage on the BASE dataset (scenario views are display-only).
                if activeScenario == nil, let transforms = appState.workbenchTransforms {
                    _ = try await transforms.applyTransform(datasetID: rec.dataset.id, spec: spec,
                                                            expectedRevision: rec.dataset.revision,
                                                            actor: actorName, at: Date())
                    await reload(rec.dataset.id)
                }
            } catch { errorMessage = "The analysis failed: \(error)" }
        }
    }

    // MARK: Scenarios

    private func createScenario(_ rec: WorkbenchDatasetRecord) {
        guard let repo = appState.workbenchScenarios else { return }
        let title = scenarioTitle.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        Task {
            do {
                let created = try await repo.createScenario(datasetID: rec.dataset.id, title: title,
                                                            actor: actorName, at: Date())
                scenarioTitle = ""
                activeScenario = created
                await loadSatellites(rec.dataset.id)
            } catch { errorMessage = "Could not create the scenario: \(error)" }
        }
    }

    private func openScenario(_ id: UUID) {
        guard let repo = appState.workbenchScenarios else { return }
        Task { activeScenario = try? await repo.fetch(scenarioID: id) }
    }

    private func applyOverride(_ rec: WorkbenchDatasetRecord, selection: (rowID: UUID, fieldID: UUID)) {
        guard let repo = appState.workbenchScenarios, let active = activeScenario else { return }
        errorMessage = nil
        let value = cellEditor
        let reason = overrideReason.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                activeScenario = try await repo.applyOperation(
                    scenarioID: active.scenario.id, kind: .valueOverride,
                    rowID: selection.rowID, fieldID: selection.fieldID,
                    afterValue: value.isEmpty ? nil : value,
                    reason: reason.isEmpty ? nil : reason,
                    expectedRevision: active.scenario.revision, actor: actorName, at: Date())
            } catch { errorMessage = "Could not record the override: \(error)" }
        }
    }

    private func scenarioUndo() {
        guard let repo = appState.workbenchScenarios, let active = activeScenario else { return }
        Task {
            activeScenario = try? await repo.undo(scenarioID: active.scenario.id,
                                                  expectedRevision: active.scenario.revision,
                                                  actor: actorName, at: Date())
        }
    }

    private func scenarioRedo() {
        guard let repo = appState.workbenchScenarios, let active = activeScenario else { return }
        Task {
            activeScenario = try? await repo.redo(scenarioID: active.scenario.id,
                                                  expectedRevision: active.scenario.revision,
                                                  actor: actorName, at: Date())
        }
    }

    // MARK: Quality + export

    private func loadQuality(_ rec: WorkbenchDatasetRecord) async {
        guard let analyzer = appState.workbenchDataQuality else { return }
        quality = try? await analyzer.report(datasetID: rec.dataset.id,
                                             scenarioID: activeScenario?.scenario.id)
        showQuality = quality != nil
    }

    // MARK: Chart (see the numbers, Tableau-style — provenance-backed data only)

    @ViewBuilder
    private func chartPanel(_ rec: WorkbenchDatasetRecord) -> some View {
        let numericFields = rec.fields
            .sorted { $0.ordinal < $1.ordinal }
            .filter { $0.valueShape == .number || $0.valueShape == .money || $0.valueShape == .duration }
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Chart")
            if let agg = aggregateResult, !agg.groups.isEmpty {
                // Chart the analysis result — one bar per group.
                Chart(Array(agg.groups.enumerated()), id: \.offset) { _, group in
                    BarMark(
                        x: .value("Group", group.resultKey ?? "all"),
                        y: .value(agg.function.rawValue, numeric(group.value) ?? 0))
                    .foregroundStyle(.tint)
                }
                .frame(height: 160)
                Text("Charting the \(agg.function.rawValue) result above.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if numericFields.isEmpty {
                Text("Add a number field (or run an analysis) to chart this dataset.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                let textFields = rec.fields.sorted { $0.ordinal < $1.ordinal }
                    .filter { $0.valueShape != .number && $0.valueShape != .money }
                fieldPicker("Value", $chartValueField, numericFields.map(\.name))
                fieldPicker("Label", $chartLabelField, textFields.map(\.name))
                let points = chartPoints(rec, valueField: chartValueField, labelField: chartLabelField)
                if points.isEmpty {
                    Text("Pick a value field to draw the chart.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Chart(Array(points.enumerated()), id: \.offset) { _, point in
                        BarMark(x: .value("Row", point.label),
                                y: .value(chartValueField ?? "Value", point.value))
                        .foregroundStyle(.tint)
                    }
                    .frame(height: 160)
                }
            }
        }
    }

    private func chartPoints(_ rec: WorkbenchDatasetRecord,
                             valueField: String?, labelField: String?) -> [(label: String, value: Double)] {
        guard let valueName = valueField,
              let vField = rec.fields.first(where: { $0.name == valueName }) else { return [] }
        let lField = labelField.flatMap { name in rec.fields.first { $0.name == name } }
        let projection = activeProjection()
        var rows = rec.rows.sorted { $0.ordinal < $1.ordinal }
        if let projection { rows = rows.filter { !projection.excludedRows.contains($0.id) } }
        var cellByKey: [String: WorkbenchCell] = [:]
        for cell in rec.cells { cellByKey["\(cell.rowID.uuidString)|\(cell.fieldID.uuidString)"] = cell }
        return rows.enumerated().compactMap { index, row in
            let raw = projection?.projectedValue(rowID: row.id, fieldID: vField.id)
                ?? cellByKey["\(row.id.uuidString)|\(vField.id.uuidString)"]?.value
            guard let raw, let value = Double(raw.replacingOccurrences(of: ",", with: "")) else { return nil }
            let label = lField.flatMap { lf in
                projection?.projectedValue(rowID: row.id, fieldID: lf.id)
                    ?? cellByKey["\(row.id.uuidString)|\(lf.id.uuidString)"]?.value
            } ?? "Row \(index + 1)"
            return (label, value)
        }
    }

    private func numeric(_ value: WorkbenchValue) -> Double? {
        if case .number(let d) = value { return d }
        return nil
    }

    // MARK: Import (Excel/Numbers → CSV → dataset)

    private func importCSV(_ url: URL) {
        guard let repo = appState.workbenchDatasets else { return }
        errorMessage = nil
        Task {
            do {
                guard let wsID = await ensureWorkspace() else { return }
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                let grid = WorkbenchCSV.parse(text)
                guard let header = grid.first, !header.isEmpty else {
                    errorMessage = "The file has no header row — the first row must name the columns."
                    return
                }
                let title = url.deletingPathExtension().lastPathComponent
                var rec = try await repo.createDataset(workspaceID: wsID, title: title,
                                                       mode: .simple, actor: actorName, at: Date())
                var fieldIDs: [UUID] = []
                for name in header {
                    let clean = name.trimmingCharacters(in: .whitespaces)
                    rec = try await repo.addField(datasetID: rec.dataset.id,
                                                  name: clean.isEmpty ? "Column \(fieldIDs.count + 1)" : clean,
                                                  valueShape: .text,
                                                  expectedRevision: rec.dataset.revision,
                                                  actor: actorName, at: Date())
                    if let field = rec.fields.max(by: { $0.ordinal < $1.ordinal }) { fieldIDs.append(field.id) }
                }
                for line in grid.dropFirst() {
                    rec = try await repo.addRow(datasetID: rec.dataset.id,
                                                expectedRevision: rec.dataset.revision,
                                                actor: actorName, at: Date())
                    guard let row = rec.rows.max(by: { $0.ordinal < $1.ordinal }) else { continue }
                    for (i, fieldID) in fieldIDs.enumerated() where i < line.count && !line[i].isEmpty {
                        rec = try await repo.setCell(datasetID: rec.dataset.id, rowID: row.id, fieldID: fieldID,
                                                     kind: .userEntered, value: line[i], status: .sourceAsserted,
                                                     expectedRevision: rec.dataset.revision,
                                                     actor: actorName, at: Date())
                    }
                }
                record = rec
                await loadSatellites(rec.dataset.id)
            } catch { errorMessage = "Could not import the file: \(error)" }
        }
    }

    // MARK: Export (CSV / Excel / Word / PDF — every export posts an EXP document)

    private enum ExportFormat: String { case csv, xlsx, docx, pdf }

    private func export(_ rec: WorkbenchDatasetRecord, format: ExportFormat) {
        #if os(macOS)
        errorMessage = nil
        let projection = activeProjection()
        let data: Data?
        switch format {
        case .csv:
            data = WorkbenchCSV.render(rec, projection: projection).data(using: .utf8)
        case .xlsx:
            data = DocumentExporter.xlsx(grid: WorkbenchCSV.grid(rec, projection: projection))
        case .docx:
            data = DocumentExporter.docx([reportRecord(rec, projection: projection)])
        case .pdf:
            data = DocumentExporter.pdf([reportRecord(rec, projection: projection)])
        }
        guard let data else { errorMessage = "Could not build the \(format.rawValue.uppercased()) file."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = rec.dataset.title.replacingOccurrences(of: "/", with: "-")
            + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            errorMessage = "Could not write the file: \(error)"
            return
        }
        // The SAP habit: what left the app gets a number you can quote.
        Task {
            if let workCenter = appState.workCenter {
                let doc = try? await workCenter.capture(
                    type: "EXP",
                    title: "\(rec.dataset.title) — \(format.rawValue.uppercased()) export",
                    values: ["Dataset": rec.dataset.title,
                             "Format": format.rawValue.uppercased(),
                             "Rows": String(rec.rows.count),
                             "Revision": String(rec.dataset.revision),
                             "Scenario": activeScenario?.scenario.title ?? "",
                             "File": url.lastPathComponent],
                    actor: actorName, at: Date())
                lastExportNumber = doc?.docNumber
            }
        }
        #endif
    }

    private func reportRecord(_ rec: WorkbenchDatasetRecord,
                              projection: WorkbenchScenarioProjection?) -> ExportRecord {
        ExportRecord(title: rec.dataset.title,
                     sourceType: "dataset",
                     text: WorkbenchReport.render(rec, projection: projection, quality: quality))
    }
}

#if DEBUG
#Preview("DataLab — catalog") {
    DataLabView()
        .environment(AppState())
        .frame(width: 1040, height: 720)
}
#endif
