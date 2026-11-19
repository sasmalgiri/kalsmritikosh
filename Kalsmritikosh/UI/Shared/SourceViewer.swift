//
//  SourceViewer.swift
//  Kalsmritikosh
//
//  Inline source viewer with cited-range highlighting. Three modes:
//  PDFKit (for .pdf), an attributed text view (for plain text and
//  markdown), and a Finder/Quick Look fallback for everything else.
//  The caller hands over a URL plus an optional SourceRange — the
//  view scrolls to + highlights the cited passage so the user can
//  verify evidence without leaving the app.
//
//  OPS-003D.1: pass koID to enable the fail-closed screen-scope gate.
//  Authorization is checked once per koID change; loading shows a
//  spinner, denied shows a locked placeholder — no content renders
//  before the check completes.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
import AVKit

/// Identifies a single authorization task for `.task(id:)`.
/// Combining the target UUID with the policy revision means SwiftUI re-runs the
/// authorization task whenever a scope assignment is created or revoked while the
/// view is open — open viewers revalidate in real time.
private struct AuthorizationTaskID: Equatable, Hashable {
    let targetID: UUID
    let policyRevision: Int
}

public struct SourceViewer: View {
    let url: URL
    /// KO identity is mandatory — every source view requires an authorization check
    /// before any content is rendered. OPS-003D.1.1: removed the optional bypass path.
    let koID: UUID
    let range: SourceRange?
    /// §1.3 — the cited words. When present the viewer FINDS them in the
    /// rendered text (whitespace/case tolerant) and highlights that; the
    /// character range is only the fallback, because chunk offsets index the
    /// normalised text, not the raw file.
    let quote: String?
    /// The exact matched words to mark inside the quote (a screened name); nil marks the quote.
    let focus: String?
    /// S14 part 3 (SRC-01) — the cited place: a recording opens at the cited time, an image shows the cited region
    /// outlined, a PDF opens at the cited page when no range is given.
    let place: CitedSourceResolver.CitedPlace?

    @Environment(AppState.self) private var appState
    @State private var authorized: Bool? = nil
    /// X-3 — marks on this PDF (only when "Rich text notes and PDF marks" is on).
    @State private var marks: PDFMarksController?

    public init(url: URL, koID: UUID, range: SourceRange? = nil, quote: String? = nil, focus: String? = nil,
                place: CitedSourceResolver.CitedPlace? = nil) {
        self.url = url
        self.koID = koID
        self.range = range
        self.quote = quote
        self.focus = focus
        self.place = place
    }

    public var body: some View {
        Group {
            switch authorized {
            case false:
                blockedPlaceholder
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                contentGroup
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task(id: AuthorizationTaskID(targetID: koID,
                                      policyRevision: appState.sensitiveScopeRevision)) {
            authorized = nil   // enter pending (ProgressView) before the authorization check
            authorized = await appState.screenAuthorizer?.authorize(koID, boundary: .globalOwner)
        }
    }

    // MARK: - Content group (only shown when authorized)

    private var contentGroup: some View {
        VStack(spacing: 0) {
            // SRC-02 — whether the passage is the source's own text, recognised (OCR), transcribed or generated.
            ExtractionProvenanceBadgeLoader(objectID: koID, quote: quote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
            documentBody
            // IN-03 / SRC-05 / SRC-06 / IN-09 — where the document came from (parents, intake, conversions),
            // per-page reading status, and the password route; collapsed so the document keeps the space.
            DisclosureGroup("Where this came from") {
                ScrollView { SourceProvenanceChainView(knowledgeObjectID: koID).padding(10) }
                    .frame(maxHeight: 260)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .accessibilityIdentifier("sourceViewer.provenance")
        }
    }

    @ViewBuilder
    private var documentBody: some View {
        if url.pathExtension.lowercased() == "pdf" {
            pdfBody
        } else if case .recordingTime(let start, let end)? = place {
            CitedRecordingView(url: url, start: start, end: end)
                .overlay(alignment: .topTrailing) { revealButton.padding(8) }
        } else if case .imageRegion(let x, let y, let w, let h)? = place {
            CitedImageRegionView(url: url, box: CGRect(x: x, y: y, width: w, height: h))
                .overlay(alignment: .topTrailing) { revealButton.padding(8) }
        } else if case .sheetCell? = place, let place {
            CitedSheetOrSlideView(url: url, place: place)
                .overlay(alignment: .topTrailing) { revealButton.padding(8) }
        } else if case .slide? = place, let place {
            CitedSheetOrSlideView(url: url, place: place)
                .overlay(alignment: .topTrailing) { revealButton.padding(8) }
        } else if isPlainTextLike {
            textBody
        } else {
            fallbackBody
        }
    }

    private var citedPage: Int? {
        if case .page(let n)? = place { return n }
        return nil
    }

    private var isPlainTextLike: Bool {
        let ext = url.pathExtension.lowercased()
        return ["txt", "md", "markdown", "csv", "log", "json", "xml", "html", "eml"].contains(ext)
    }

    // MARK: - Blocked placeholder

    private var blockedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Source restricted")
                .font(.headline)
            Text("This content is not available at the current access level.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - PDF mode

    @ViewBuilder
    private var pdfBody: some View {
        #if canImport(PDFKit)
        VStack(spacing: 0) {
            PDFInlineView(url: url, page: range?.pageNumber ?? citedPage, characterRange: range?.characterRange, quote: quote, focus: focus,
                          onView: { view in marks?.attach(view) })
                .overlay(alignment: .topTrailing) { revealButton.padding(8) }
            if let marks { PDFMarksBar(controller: marks, original: url) }
        }
        .task(id: koID) {
            if ProductModuleFlags.isEnabled(.richDocuments), let db = appState.database {
                marks = PDFMarksController(objectID: koID, sourceURL: url, repository: PDFMarksRepository(database: db))
            } else {
                marks = nil
            }
        }
        #else
        fallbackBody
        #endif
    }

    // MARK: - Text mode

    @ViewBuilder
    private var textBody: some View {
        TextInlineView(url: url, characterRange: range?.characterRange, quote: quote, focus: focus)
            .overlay(alignment: .topTrailing) { revealButton.padding(8) }
    }

    // MARK: - Finder fallback (binaries, archives, audio, etc.)

    private var fallbackBody: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text(url.lastPathComponent).font(.title3)
            Text(url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let quote, !quote.isEmpty {
                // No inline renderer for this format — show the cited words
                // themselves so the user knows exactly what to look for.
                Text("\u{201C}\(String(quote.prefix(400)))\u{201D}")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: 480, alignment: .leading)
                    .background(Color.yellow.opacity(0.18), in: .rect(cornerRadius: 8))
                    .textSelection(.enabled)
            }
            if let range, let chars = range.characterRange {
                // Best we can do without inline rendering — show the
                // offset so the user can find it manually.
                Text("Cited bytes \(chars.lowerBound)–\(chars.upperBound)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { reveal() }
                Button("Open") { open() }
            }
        }
        .padding()
    }

    private var revealButton: some View {
        Menu {
            Button("Reveal in Finder", action: reveal)
            Button("Open externally", action: open)
        } label: { Label("Open", systemImage: "arrow.up.right.square").labelStyle(.iconOnly) }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func reveal() {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
    private func open() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - PDFKit inline view + selection highlight

#if canImport(PDFKit)
private struct PDFInlineView: NSViewRepresentable {
    let url: URL
    let page: Int?
    let characterRange: Range<Int>?
    let quote: String?
    var focus: String? = nil
    /// X-3 — hands the view to the marks controller (which draws marks in memory only).
    var onView: ((PDFView) -> Void)? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        scrollAndHighlight(view)
        onView?(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        scrollAndHighlight(view)
        onView?(view)
    }

    /// Scroll to the cited page (1-indexed in our model, 0-indexed
    /// in PDFKit) and use PDFKit's findString to draw a selection
    /// over the cited text. We can't translate the chunker's
    /// character offsets into a PDF text-extraction range
    /// faithfully — PDFs don't have a stable character coordinate —
    /// so when characterRange is set we extract the page's plaintext,
    /// slice it, and search for the resulting snippet. Imperfect on
    /// repeated phrases, but close enough for evidence verification.
    private func scrollAndHighlight(_ view: PDFView) {
        guard let document = view.document else { return }
        // §1.3 — quote first: find the cited words on whichever page holds
        // them (starting at the cited page) and select exactly that text.
        if (quote?.isEmpty == false) || (focus?.isEmpty == false) {
            let start = max(0, min((page ?? 1) - 1, document.pageCount - 1))
            let order = Array(start..<document.pageCount) + Array(0..<start)
            for i in order {
                guard let pdfPage = document.page(at: i), let text = pdfPage.string,
                      let hit = TextInlineView.hit(quote: quote, focus: focus, in: text),
                      let selection = pdfPage.selection(for: hit) else { continue }
                view.go(to: pdfPage)
                view.setCurrentSelection(selection, animate: true)
                view.scrollSelectionToVisible(nil)
                return
            }
        }
        // PageNumber in our SourceRange is 1-indexed for human use.
        let pageIndex = max(0, (page ?? 1) - 1)
        guard pageIndex < document.pageCount,
              let target = document.page(at: pageIndex) else { return }
        view.go(to: target)

        guard let range = characterRange,
              range.lowerBound >= 0,
              range.upperBound > range.lowerBound,
              let fullText = target.string,
              !fullText.isEmpty else {
            return
        }
        let lower = min(range.lowerBound, max(0, fullText.count - 1))
        let upper = min(range.upperBound, fullText.count)
        guard upper > lower else { return }
        let startIdx = fullText.index(fullText.startIndex, offsetBy: lower)
        let endIdx = fullText.index(fullText.startIndex, offsetBy: upper)
        let snippet = String(fullText[startIdx..<endIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard snippet.count >= 6 else { return }   // too short to disambiguate
        // Cap the search snippet — PDFKit's findString gets slow on
        // very long anchors, and PDFs often break long phrases
        // across spans we can't match exactly.
        let needle = String(snippet.prefix(120))
        if let found = document.findString(needle, withOptions: [.caseInsensitive]).first {
            view.setCurrentSelection(found, animate: true)
            view.scrollSelectionToVisible(nil)
        }
    }
}
#endif

// MARK: - Plain text inline view + range highlight

private struct TextInlineView: NSViewRepresentable {
    let url: URL
    let characterRange: Range<Int>?
    let quote: String?
    let focus: String?

    /// What to mark: the focus words inside the quoted passage when a focus is given (a screened
    /// name is too short for `locate` on its own), else the quote.
    static func hit(quote: String?, focus: String?, in text: String) -> NSRange? {
        if let focus, !focus.isEmpty, let r = CitedPassageLocator.locate(focus: focus, near: quote, in: text) { return r }
        if let quote, !quote.isEmpty { return CitedPassageLocator.locate(quote, in: text) }
        return nil
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 8, height: 8)
            populate(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        populate(tv)
    }

    /// Load the file, render it monospaced, paint the cited range
    /// with a yellow background + bold weight, then scroll to it.
    /// Files larger than ~5 MB are truncated so the text view stays
    /// snappy — citations should still land near the start in
    /// practice, but a truncation banner makes it explicit.
    private func populate(_ tv: NSTextView) {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Fallback: latin-1 covers most legacy logs / emails.
            raw = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        }
        let truncated: String
        let didTruncate: Bool
        if raw.count > 5_000_000 {
            let cutIdx = raw.index(raw.startIndex, offsetBy: 5_000_000)
            truncated = String(raw[..<cutIdx]) + "\n\n…[file truncated at 5 MB]"
            didTruncate = true
        } else {
            truncated = raw
            didTruncate = false
        }
        let attributed = NSMutableAttributedString(
            string: truncated,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        // §1.3 — the quoted words win over raw offsets (see SourceViewer.quote).
        if let hit = Self.hit(quote: quote, focus: focus, in: truncated),
           NSMaxRange(hit) <= attributed.length {
            attributed.addAttributes(
                [
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35),
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
                ],
                range: hit
            )
            tv.textStorage?.setAttributedString(attributed)
            tv.scrollRangeToVisible(hit)
            tv.setSelectedRange(hit)
            return
        }
        if let range = characterRange,
           range.lowerBound >= 0,
           range.upperBound <= truncated.count,
           range.upperBound > range.lowerBound {
            let nsRange = NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
            if NSMaxRange(nsRange) <= attributed.length {
                attributed.addAttributes(
                    [
                        .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35),
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
                    ],
                    range: nsRange
                )
                tv.textStorage?.setAttributedString(attributed)
                tv.scrollRangeToVisible(nsRange)
                tv.setSelectedRange(nsRange)
                return
            }
        }
        tv.textStorage?.setAttributedString(attributed)
        if didTruncate {
            // Park the cursor at top so user starts at file header.
            tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
}

public struct EvidenceViewer: View {
    let citation: VerifiedAnswer.Citation
    @Environment(AppState.self) private var appState
    @State private var authorized: Bool? = nil

    public init(citation: VerifiedAnswer.Citation) { self.citation = citation }

    public var body: some View {
        Group {
            switch authorized {
            case false:
                restrictedBody
            case nil:
                ProgressView()
                    .padding()
                    .frame(minWidth: 460, minHeight: 220)
            default:
                contentBody
            }
        }
        .task(id: AuthorizationTaskID(targetID: citation.objectID,
                                      policyRevision: appState.sensitiveScopeRevision)) {
            authorized = nil   // enter pending (ProgressView) before the authorization check
            authorized = await appState.screenAuthorizer?.authorize(citation.objectID, boundary: .globalOwner)
        }
    }

    private var contentBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.bubble")
                Text("Evidence").font(.headline)
                Spacer()
            }
            Text(citation.snippet)
                .font(.callout)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            Text("Source KO: \(citation.objectID.uuidString.prefix(8))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 460, minHeight: 220)
    }

    private var restrictedBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Evidence restricted")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 460, minHeight: 220)
    }
}


// MARK: - S14 part 3 (SRC-01): a recording at the cited time, an image with the cited region

/// A recording opened AT the cited time (paused there, so the person presses play), with the cited span named.
private struct CitedRecordingView: View {
    let url: URL
    let start: Double
    let end: Double?
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Opened at the cited time \(CitedSourceResolver.timecode(start))" + (end.map { "–\(CitedSourceResolver.timecode($0))" } ?? ""),
                  systemImage: "waveform")
                .font(.callout).padding(.horizontal, 10).padding(.top, 6)
                .accessibilityIdentifier("sourceViewer.citedTime")
            if let player { VideoPlayer(player: player) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: url) {
            let p = AVPlayer(url: url)
            await p.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player = p
        }
        .onDisappear { player?.pause() }
    }
}

/// An image with the cited region outlined (Vision's normalised box, origin bottom-left).
private struct CitedImageRegionView: View {
    let url: URL
    let box: CGRect
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The cited region is outlined", systemImage: "rectangle.dashed").font(.callout)
                .padding(.horizontal, 10).padding(.top, 6)
                .accessibilityIdentifier("sourceViewer.citedRegion")
            if let image {
                GeometryReader { geo in
                    let fitted = Self.fit(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: fitted.width, height: fitted.height)
                        Rectangle().stroke(Color.yellow, lineWidth: 3).background(Color.yellow.opacity(0.15))
                            .frame(width: box.width * fitted.width, height: box.height * fitted.height)
                            .offset(x: box.minX * fitted.width, y: (1 - box.maxY) * fitted.height)
                            .accessibilityLabel("Cited region")
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if failed {
                Text("The image could not be shown here; use Open to view it.").font(.callout).foregroundStyle(.secondary).padding()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let data = await Task.detached(priority: .userInitiated) { [url] in try? Data(contentsOf: url) }.value
            let loaded = data.flatMap(NSImage.init(data:))
            image = loaded
            failed = loaded == nil
        }
    }

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - S18 (SRC-01): a spreadsheet at the cited sheet/row/cell, a presentation at the cited slide

/// The cited sheet with the cited row and cell selected, or the cited slide — read from the opened (cited) version
/// by the intake's own parser (CitedPlaceReader). A place missing from the file is said, never replaced.
private struct CitedSheetOrSlideView: View {
    let url: URL
    let place: CitedSourceResolver.CitedPlace
    @State private var content: CitedPlaceReader.Content?

    var body: some View {
        Group {
            switch content {
            case .sheet(let sheet)?: sheetView(sheet)
            case .slide(let slide)?: slideView(slide)
            case .missing(let why)?:
                Label(why + " The document opens at its start; find the place by the cited words.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).padding()
                    .accessibilityIdentifier("sourceViewer.citedPlaceMissing")
            case nil: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) { content = await CitedPlaceReader.read(url: url, place: place) }
    }

    private func sheetView(_ sheet: CitedPlaceReader.SheetPlace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Self.sheetCaption(sheet), systemImage: "tablecells").font(.callout)
                .padding(.horizontal, 10).padding(.top, 6)
                .accessibilityIdentifier("sourceViewer.citedCell")
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(sheet.rows, id: \.index) { row in
                            GridRow {
                                Text("\(row.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(minWidth: 36, alignment: .trailing).padding(4)
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { column, value in
                                    let inRow = row.index == sheet.selectedRow
                                    Self.sheetCell(value, isCell: inRow && column == sheet.selectedColumn, inCitedRow: inRow)
                                }
                            }
                            .id(row.index)
                        }
                    }
                    .padding(6)
                }
                .onAppear { if let r = sheet.selectedRow { proxy.scrollTo(r, anchor: .center) } }
            }
        }
    }

    /// One spreadsheet cell; kept out of the grid's body because the inline form timed out the CI type checker.
    private static func sheetCell(_ value: String, isCell: Bool, inCitedRow: Bool) -> some View {
        let fill: Color
        if isCell { fill = Color.yellow.opacity(0.45) } else if inCitedRow { fill = Color.yellow.opacity(0.15) } else { fill = Color.clear }
        let edge: Color = isCell ? Color.orange : Color.secondary.opacity(0.2)
        let label: String = isCell ? "Cited cell: \(value)" : value
        return Text(value).font(.callout).lineLimit(2)
            .frame(minWidth: 80, maxWidth: 240, alignment: .leading).padding(4)
            .background(fill)
            .border(edge, width: isCell ? 2 : 0.5)
            .accessibilityLabel(label)
    }

    static func sheetCaption(_ sheet: CitedPlaceReader.SheetPlace) -> String {
        var place = "Sheet “\(sheet.sheet)”"
        if let r = sheet.selectedRow {
            if let c = sheet.selectedColumn {
                place += ", cell \(XLSXExporter.columnLetters(c))\(r + 1)"
            } else {
                place += ", row \(r + 1)"
            }
        }
        return "Opened at the cited place: " + place + " (\(sheet.totalRows) rows in the sheet)"
    }

    private func slideView(_ slide: CitedPlaceReader.SlidePlace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Opened at the cited slide \(slide.number) of \(slide.count)", systemImage: "rectangle.on.rectangle")
                    .font(.callout).accessibilityIdentifier("sourceViewer.citedSlide")
                if let title = slide.title { Text(title).font(.title3.bold()).textSelection(.enabled) }
                ForEach(Array(slide.body.enumerated()), id: \.offset) { _, line in Text(line).textSelection(.enabled) }
                if let notes = slide.notes {
                    Divider()
                    Text("Speaker notes").font(.caption).foregroundStyle(.secondary)
                    Text(notes).font(.callout).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
