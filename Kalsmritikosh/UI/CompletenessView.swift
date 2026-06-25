//
//  CompletenessView.swift
//  Kalsmritikosh
//
//  Per-file ingest-health report. Lists every KnowledgeObject the
//  ledger knows about with the metrics each loader stamps at ingest
//  time: pages parsed, OCR pages used, quoted bytes removed, stream
//  count for legacy binaries, message count for archives. Surfaces
//  the silent-failure modes — files that landed as low-confidence
//  stubs, OOXML files that emitted zero pages, mojibake-rescue PDFs
//  with high OCR usage — so the user can spot a botched ingest at a
//  glance.
//

import SwiftUI

public struct CompletenessView: View {
    @Environment(AppState.self) private var appState
    @State private var rows: [CompletenessRow] = []
    @State private var filter: Filter = .all
    @State private var loading = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task {
            await reload()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Completeness")
                        .font(.title2.bold())
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(loading)
            }
            // Filter chips highlight the silent-failure cohorts.
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        HStack(spacing: 4) {
                            Text(f.label).font(.caption)
                            Text("\(count(for: f))").font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            filter == f
                                ? Color.accentColor.opacity(0.2)
                                : Color.secondary.opacity(0.1),
                            in: .capsule
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }

    private var summary: String {
        let total = rows.count
        guard total > 0 else { return "No files ingested yet." }
        let stubs = rows.filter(\.isStub).count
        let lowConfidence = rows.filter { $0.confidence.value < 0.4 }.count
        let ocrUsed = rows.filter { ($0.ocrPagesUsed ?? 0) > 0 }.count
        return "\(total) files · \(stubs) stub\(stubs == 1 ? "" : "s") · \(lowConfidence) low-confidence · \(ocrUsed) used OCR"
    }

    private func count(for filter: Filter) -> Int {
        rows.filter { filter.matches($0) }.count
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty && !loading {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No KnowledgeObjects yet.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(rows.filter { filter.matches($0) }) { row in
                rowView(row)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func rowView(_ row: CompletenessRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(for: row.sourceType))
                    .foregroundStyle(.tint)
                Text(row.sourceFile.lastPathComponent)
                    .font(.body)
                Spacer()
                confidencePill(row.confidence)
            }
            // Metric strip — only the fields that actually apply for
            // this loader render; everything else stays out so the
            // row doesn't fill with "N/A".
            HStack(spacing: 12) {
                Text(row.sourceType.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let loader = row.loader {
                    Text("loader: \(loader)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(formatBytes(row.contentBytes)) text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let pages = row.pageCount {
                    Text("\(pages) page\(pages == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let ocr = row.ocrPagesUsed, ocr > 0 {
                    Text("\(ocr) OCR")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let q = row.quotedBytesRemoved, q > 0 {
                    Text("-\(formatBytes(q)) quoted")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let streams = row.streamsScanned {
                    Text("\(streams) streams")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let msgs = row.messageCount {
                    Text("\(msgs) message\(msgs == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if row.isStub {
                    Text("STUB")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
            Text(row.sourceFile.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }

    private func confidencePill(_ confidence: Confidence) -> some View {
        let label: String
        let color: Color
        switch confidence.value {
        case 0.7...: label = "high"; color = .green
        case 0.4..<0.7: label = "med"; color = .orange
        default: label = "low"; color = .red
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }

    private func icon(for type: SourceType) -> String {
        switch type.category {
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .email: return "envelope"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .archive: return "archivebox"
        case .unknown: return "doc"
        }
    }

    // MARK: - Data

    private func reload() async {
        guard let objects = appState.objects else { return }
        loading = true
        defer { loading = false }
        rows = (try? await objects.completenessRows(limit: 2000)) ?? []
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / (1024.0 * 1024.0))
    }

    // MARK: - Filter

    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case stubs
        case lowConfidence
        case ocrUsed
        case bigQuote

        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .stubs: return "Stubs"
            case .lowConfidence: return "Low confidence"
            case .ocrUsed: return "OCR used"
            case .bigQuote: return "Quote-heavy"
            }
        }

        func matches(_ row: CompletenessRow) -> Bool {
            switch self {
            case .all: return true
            case .stubs: return row.isStub
            case .lowConfidence: return row.confidence.value < 0.4
            case .ocrUsed: return (row.ocrPagesUsed ?? 0) > 0
            case .bigQuote: return (row.quotedBytesRemoved ?? 0) > 4096
            }
        }
    }
}
