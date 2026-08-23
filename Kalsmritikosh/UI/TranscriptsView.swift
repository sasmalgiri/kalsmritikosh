//
//  TranscriptsView.swift
//  Kalsmritikosh
//
//  Persona features (F8). Timestamped transcript workflow for audio/video
//  sources. Transcription runs ON DEMAND (on-device Apple Speech), producing
//  timecoded lines a user can search, jump-to-play, assign speakers to
//  (diarization is manual — uncertain speakers stay visible), mark as quotes,
//  and export with timecodes through the shared F3 engine. Low-confidence ASR
//  is shown, never treated as fact.
//

import SwiftUI
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif

public struct TranscriptsView: View {
    @Environment(AppState.self) private var appState

    @State private var sources: [FileRecord] = []
    @State private var counts: [UUID: Int] = [:]
    @State private var selected: FileRecord?
    @State private var segments: [TranscriptSegment] = []
    @State private var searchText = ""
    @State private var transcribing = false
    @State private var status: String?
    @State private var player: AVPlayer?
    @State private var renameFrom = ""
    @State private var renameTo = ""

    private let mediaTypes: Set<SourceType> = [.mp3, .wav, .m4a, .aac, .mp4, .mov]

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            sourceList.frame(width: 280)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reloadSources() }
    }

    // MARK: - Source list

    private var sourceList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text("Transcripts").font(Theme.display(20, .bold))
                Spacer()
                Button { Task { await reloadSources() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if sources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No audio or video sources").font(.callout).foregroundStyle(.secondary)
                    Text("Ingest an audio/video file, then transcribe it here.")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sources, id: \.id) { file in sourceRow(file) }
                    }
                    .padding(10)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func sourceRow(_ file: FileRecord) -> some View {
        Button {
            select(file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.sourceType == .mp4 || file.sourceType == .mov ? "film" : "waveform")
                    .foregroundStyle(.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                    if let c = counts[file.id] {
                        Text("\(c) segments").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("not transcribed").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected?.id == file.id ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let file = selected {
            VStack(alignment: .leading, spacing: 10) {
                detailHeader(file)
                if let status { Text(status).font(.caption2).foregroundStyle(.secondary) }
                if segments.isEmpty && !transcribing {
                    emptyTranscript(file)
                } else {
                    speakerBar(file)
                    searchBar
                    segmentList(file)
                }
            }
            .padding(16)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Select a source").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ file: FileRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).font(Theme.display(20, .bold)).lineLimit(1)
                Text("On-device Apple Speech · speakers are assigned manually")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { player?.play() } label: { Image(systemName: "play.fill") }
                .help("Play").controlSize(.small)
            Button { player?.pause() } label: { Image(systemName: "pause.fill") }
                .help("Pause").controlSize(.small)
            Button {
                Task { await transcribe(file) }
            } label: {
                if transcribing { ProgressView().controlSize(.small) }
                else { Label(segments.isEmpty ? "Transcribe" : "Re-transcribe", systemImage: "waveform.badge.mic") }
            }
            .disabled(transcribing)
            .guidance(GuidanceTip("Transcribe",
                                  what: "Transcribes the audio/video on-device and adds it to your searchable, citable archive.",
                                  enabledWhen: "Wait for the current transcription to finish."),
                      enabled: !transcribing)
            if !segments.isEmpty {
                Button { Task { await exportQuotes(file) } } label: {
                    Label("Export quotes", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }
        }
    }

    private func emptyTranscript(_ file: FileRecord) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 30)).foregroundStyle(.tint)
            Text("Not transcribed yet").font(.callout.weight(.medium))
            Text("Transcription runs on-device and produces timecoded lines you can search, play, and quote. It does not run during ingest.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func speakerBar(_ file: FileRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.wave.2").foregroundStyle(.secondary).imageScale(.small)
            TextField("Speaker (blank = unassigned)", text: $renameFrom).textFieldStyle(.roundedBorder).frame(width: 180)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            TextField("Rename / merge to…", text: $renameTo).textFieldStyle(.roundedBorder).frame(width: 180)
            Button("Apply") { Task { await renameSpeaker(file) } }
                .controlSize(.small)
                .disabled(renameTo.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search transcript…", text: $searchText).textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private func segmentList(_ file: FileRecord) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filteredSegments) { seg in segmentRow(file, seg) }
            }
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
    }

    private func segmentRow(_ file: FileRecord, _ seg: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { seek(to: seg.start) } label: {
                Text(seg.startTimecode).font(.caption.monospacedDigit()).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = seg.speaker, !speaker.isEmpty {
                    Text(speaker).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                } else {
                    Text("Speaker ?").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(seg.text).font(.callout).textSelection(.enabled)
                if seg.asrConfidence > 0 && seg.asrConfidence < 0.5 {
                    Label("low ASR confidence", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button { Task { await toggleQuote(seg) } } label: {
                Image(systemName: seg.markedQuote ? "quote.bubble.fill" : "quote.bubble")
                    .foregroundStyle(seg.markedQuote ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(seg.markedQuote ? "Unmark quote" : "Mark as quote")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(seg.markedQuote ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var filteredSegments: [TranscriptSegment] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return segments }
        return segments.filter { $0.text.lowercased().contains(q) }
    }

    // MARK: - Actions

    private func select(_ file: FileRecord) {
        selected = file
        status = nil
        player = AVPlayer(url: file.url)
        Task { await loadSegments(file) }
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player?.play()
    }

    private func reloadSources() async {
        let all = (try? await appState.files?.all()) ?? []
        let media = all.filter { mediaTypes.contains($0.sourceType) && $0.availability == .available }
        let transcribed = (try? await appState.transcripts?.transcribedSources()) ?? []
        var map: [UUID: Int] = [:]
        for t in transcribed { map[t.fileID] = t.count }
        await MainActor.run { self.sources = media; self.counts = map }
    }

    private func loadSegments(_ file: FileRecord) async {
        let segs = (try? await appState.transcripts?.segments(forSource: file.id)) ?? []
        await MainActor.run { self.segments = segs }
    }

    private func transcribe(_ file: FileRecord) async {
        await MainActor.run { transcribing = true; status = "Transcribing on-device…" }
        defer { Task { @MainActor in transcribing = false } }
        let engine = SpeechTranscriber()
        do {
            let asr = try await engine.transcribeSegments(audioAt: file.url)
            guard !asr.isEmpty else {
                await MainActor.run { status = "No speech recognized (or timings unavailable for this file)." }
                return
            }
            let now = Date()
            let segs = asr.enumerated().map { i, s in
                TranscriptSegment(
                    sourceFileID: file.id, sourceURL: file.url.absoluteString, ordinal: i,
                    start: s.start, end: s.end, text: s.text,
                    asrConfidence: s.confidence, engine: engine.engineID, createdAt: now
                )
            }
            try await appState.transcripts?.replaceSegments(forSource: file.id, segs)
            await MainActor.run { status = "Transcribed \(segs.count) segments." }
            await loadSegments(file)
            await reloadSources()
        } catch {
            await MainActor.run { status = "Transcription failed: \(error.localizedDescription)" }
        }
    }

    private func toggleQuote(_ seg: TranscriptSegment) async {
        try? await appState.transcripts?.setMarkedQuote(segmentID: seg.id, !seg.markedQuote)
        if let file = selected { await loadSegments(file) }
    }

    private func renameSpeaker(_ file: FileRecord) async {
        let to = renameTo.trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty else { return }
        let from = renameFrom.trimmingCharacters(in: .whitespaces)
        try? await appState.transcripts?.renameSpeaker(forSource: file.id, from: from.isEmpty ? nil : from, to: to)
        await MainActor.run { renameFrom = ""; renameTo = "" }
        await loadSegments(file)
    }

    private func exportQuotes(_ file: FileRecord) async {
        let quotes = (try? await appState.transcripts?.markedQuotes(forSource: file.id)) ?? []
        let source = segments.isEmpty ? file.url.lastPathComponent : file.url.lastPathComponent
        let citations = quotes.map { seg in
            CitationRecord(
                sourceVersionID: file.id,
                displayLabel: "\(source) @ \(seg.startTimecode)",
                sourceTitle: source,
                authorOrSender: seg.speaker,
                locator: CitationLocator(timecode: seg.startTimecode),
                isGeneratedSummary: false
            )
        }
        let rows = quotes.map { [$0.startTimecode, $0.speaker ?? "Speaker ?", $0.text] }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let manifest = ExportManifest(
            exportedAt: Date(), appVersion: appVersion, schemaVersion: SchemaMigrations.latestVersion,
            sourceVersionIDs: [file.id.uuidString],
            selectedFindingCount: quotes.count,
            citationMap: citations.map { CitationMapEntry(label: $0.displayLabel, resolved: true) },
            knownLimitations: [
                "Timecodes are from on-device ASR; low-confidence lines are flagged and are not treated as verbatim fact.",
                "Speaker labels are assigned manually — no automatic diarization."
            ]
        )
        let doc = ExportableDocument(
            title: "Quotes — \(source)",
            subtitle: "\(quotes.count) marked quote(s) with timecodes",
            table: ExportTable(title: "Quotes", columns: ["Time", "Speaker", "Quote"], rows: rows),
            citations: citations,
            citationStyle: .general,
            manifest: manifest
        )
        let text = WorkProductExporter.render(doc, as: .markdown)
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "quotes-\(file.url.deletingPathExtension().lastPathComponent).md"
        guard panel.runModal() == .OK, let url = panel.url else {
            await MainActor.run { status = "Export cancelled." }
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run { status = "Exported \(quotes.count) quotes to \(url.lastPathComponent)." }
        } catch {
            await MainActor.run { status = "Export failed: \(error.localizedDescription)" }
        }
        #endif
    }
}
