//
//  PDFMarksController.swift
//  Kalsmritikosh
//
//  X-3 — marks on a PDF shown in the source viewer: highlight, underline, strike out and
//  notes. Marks are drawn as PDFKit annotations on the document in memory only; they are
//  stored in the ledger (PDFMarksRepository) and the original file is never written.
//  "Export annotated copy" writes a NEW PDF with the marks embedded, plus a Markdown list.
//

#if canImport(PDFKit)
import AppKit
import PDFKit
import CryptoKit
import os

@MainActor @Observable
final class PDFMarksController {
    let objectID: UUID
    let sourceURL: URL
    private let repository: PDFMarksRepository
    @ObservationIgnored weak var view: PDFView?

    private(set) var marks: [PDFMark] = []
    var color = "yellow"
    var noteText = ""
    var message: String?

    static let colors = ["yellow", "green", "blue", "pink"]
    /// Tag on annotations this controller draws, so a reload can replace exactly those.
    static let tagPrefix = "kalsmritikosh-mark:"

    init(objectID: UUID, sourceURL: URL, repository: PDFMarksRepository) {
        self.objectID = objectID
        self.sourceURL = sourceURL
        self.repository = repository
    }

    func attach(_ view: PDFView) {
        guard self.view !== view else { return }
        self.view = view
        Task { await reload() }
    }

    func reload() async {
        do {
            marks = try await repository.marks(for: objectID)
        } catch {
            KalsmritikoshLog.app.error("PDF marks read failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        if let document = view?.document { Self.draw(marks, on: document) }
    }

    // MARK: - Drawing

    static func nsColor(_ name: String, alpha: CGFloat) -> NSColor {
        let base: NSColor
        switch name {
        case "green": base = .systemGreen
        case "blue": base = .systemBlue
        case "pink": base = .systemPink
        default: base = .systemYellow
        }
        return base.withAlphaComponent(alpha)
    }

    /// The PDFKit annotations for one mark (one per line rectangle; a note is one icon).
    static func annotations(for mark: PDFMark) -> [PDFAnnotation] {
        let tag = tagPrefix + mark.id.uuidString
        switch mark.kind {
        case .note:
            guard let r = mark.rects.first else { return [] }
            let a = PDFAnnotation(bounds: CGRect(x: r.minX, y: r.minY, width: 22, height: 22), forType: .text, withProperties: nil)
            a.contents = mark.contents
            a.color = nsColor(mark.color, alpha: 1)
            a.userName = tag
            return [a]
        case .highlight, .underline, .strikeout:
            let subtype: PDFAnnotationSubtype = mark.kind == .highlight ? .highlight : (mark.kind == .underline ? .underline : .strikeOut)
            return mark.rects.map { r in
                let a = PDFAnnotation(bounds: r, forType: subtype, withProperties: nil)
                a.color = nsColor(mark.color, alpha: mark.kind == .highlight ? 0.45 : 1)
                if let c = mark.contents { a.contents = c }
                a.userName = tag
                return a
            }
        }
    }

    /// Replace this app's drawn marks on `document` with `marks` (in memory only).
    static func draw(_ marks: [PDFMark], on document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where (a.userName ?? "").hasPrefix(tagPrefix) { page.removeAnnotation(a) }
        }
        for mark in marks {
            guard mark.page >= 0, mark.page < document.pageCount, let page = document.page(at: mark.page) else { continue }
            for a in annotations(for: mark) { page.addAnnotation(a) }
        }
    }

    // MARK: - Making marks

    /// Mark the current selection: one mark per page it spans, one rectangle per line.
    func markSelection(_ kind: PDFMarkKind) async {
        guard let view, let document = view.document else { return }
        if document.isLocked { message = "This PDF is locked with a password, so it cannot be marked."; return }
        guard let selection = view.currentSelection, !(selection.string ?? "").isEmpty else {
            message = PDFMarksError.nothingToMark.localizedDescription; return
        }
        var perPage: [Int: (rects: [CGRect], text: [String])] = [:]
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let index = document.index(for: page)
            let r = line.bounds(for: page)
            guard r.width > 0, r.height > 0 else { continue }
            perPage[index, default: ([], [])].rects.append(r)
            if let t = line.string { perPage[index, default: ([], [])].text.append(t) }
        }
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            for (page, entry) in perPage.sorted(by: { $0.key < $1.key }) {
                try await repository.add(objectID: objectID, sourceURL: sourceURL.absoluteString, page: page, kind: kind,
                                         rects: entry.rects, color: color, quote: entry.text.joined(separator: " "),
                                         contents: note.isEmpty ? nil : note)
            }
            noteText = ""
            message = nil
            view.clearSelection()
        } catch {
            KalsmritikoshLog.app.error("PDF mark failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await reload()
    }

    /// A note at the start of the selection, or near the top of the page in view.
    func addNote() async {
        guard let view, let document = view.document else { return }
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { message = "Write the note first."; return }
        if document.isLocked { message = "This PDF is locked with a password, so it cannot be marked."; return }
        let page: PDFPage
        let anchor: CGRect
        if let sel = view.currentSelection, let p = sel.pages.first {
            page = p
            let b = sel.bounds(for: p)
            anchor = CGRect(x: max(0, b.minX - 24), y: b.maxY - 22, width: 22, height: 22)
        } else if let p = view.currentPage {
            page = p
            let box = p.bounds(for: .mediaBox)
            anchor = CGRect(x: box.minX + 24, y: box.maxY - 48, width: 22, height: 22)
        } else { return }
        do {
            try await repository.add(objectID: objectID, sourceURL: sourceURL.absoluteString, page: document.index(for: page),
                                     kind: .note, rects: [anchor], color: color, quote: view.currentSelection?.string,
                                     contents: text)
            noteText = ""
            message = nil
        } catch {
            KalsmritikoshLog.app.error("PDF note failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await reload()
    }

    func remove(_ mark: PDFMark) async {
        do { try await repository.remove(mark.id) } catch {
            KalsmritikoshLog.app.error("PDF mark remove failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await reload()
    }

    // MARK: - Export

    struct ExportResult: Sendable, Equatable {
        let pdf: URL
        let summary: URL
        let marks: Int
        let originalUnchanged: Bool
    }

    /// Write `<name> (annotated).pdf` and `<name> (marks).md` into `folder`. The original is
    /// opened read-only and its SHA-256 is compared before and after.
    static func exportAnnotatedCopy(of original: URL, marks: [PDFMark], into folder: URL) throws -> ExportResult {
        let before = try Data(contentsOf: original)
        guard let document = PDFDocument(data: before) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The PDF could not be read."])
        }
        if document.isLocked {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "This PDF is locked with a password."])
        }
        draw(marks, on: document)
        let stem = original.deletingPathExtension().lastPathComponent
        let pdfURL = folder.appendingPathComponent("\(stem) (annotated).pdf")
        let mdURL = folder.appendingPathComponent("\(stem) (marks).md")
        guard document.write(to: pdfURL) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The annotated copy could not be written."])
        }
        try summary(for: marks, title: original.lastPathComponent).write(to: mdURL, atomically: true, encoding: .utf8)
        let after = try Data(contentsOf: original)
        return ExportResult(pdf: pdfURL, summary: mdURL, marks: marks.count,
                            originalUnchanged: SHA256.hash(data: before) == SHA256.hash(data: after))
    }

    static func summary(for marks: [PDFMark], title: String) -> String {
        var lines = ["# Marks in \(title)", ""]
        for m in marks.sorted(by: { ($0.page, $0.createdAt) < ($1.page, $1.createdAt) }) {
            var line = "- Page \(m.page + 1) · \(m.kind.label)"
            if let q = m.quote, !q.isEmpty { line += ": \u{201C}\(q)\u{201D}" }
            if let c = m.contents, !c.isEmpty { line += " — \(c)" }
            lines.append(line)
        }
        if marks.isEmpty { lines.append("_No marks._") }
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
