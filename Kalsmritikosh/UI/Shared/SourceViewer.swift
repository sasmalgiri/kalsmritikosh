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

    @Environment(AppState.self) private var appState
    @State private var authorized: Bool? = nil

    public init(url: URL, koID: UUID, range: SourceRange? = nil) {
        self.url = url
        self.koID = koID
        self.range = range
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
            authorized = await appState.screenAuthorizer?.authorize(koID, boundary: .globalOwner)
        }
    }

    // MARK: - Content group (only shown when authorized)

    @ViewBuilder
    private var contentGroup: some View {
        if url.pathExtension.lowercased() == "pdf" {
            pdfBody
        } else if isPlainTextLike {
            textBody
        } else {
            fallbackBody
        }
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
        PDFInlineView(url: url, page: range?.pageNumber, characterRange: range?.characterRange)
            .overlay(alignment: .topTrailing) { revealButton.padding(8) }
        #else
        fallbackBody
        #endif
    }

    // MARK: - Text mode

    @ViewBuilder
    private var textBody: some View {
        TextInlineView(url: url, characterRange: range?.characterRange)
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
        } label: {
            Image(systemName: "arrow.up.right.square")
        }
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

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        scrollAndHighlight(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        scrollAndHighlight(view)
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
