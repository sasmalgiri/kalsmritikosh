//
//  AppPrinting.swift
//  Kalsmritikosh
//
//  UI journey run d (2026-10-30, D-5): the sandboxed app has no `com.apple.security.print`
//  entitlement, so `NSPrintOperation.run()` is refused by macOS. Owner decision (2026-11-02): no print
//  entitlement — every Print button opens a PRINT PREVIEW instead: the same frozen text laid out as
//  pages (a PDF drawn in the app, no printing system involved), with "Save as PDF…" so the person can
//  print the file from any app. Only a saved PDF is a release; closing the preview records nothing.
//

import Foundation
#if os(macOS)
import AppKit
import Security
import PDFKit
import UniformTypeIdentifiers
import os
#endif

@MainActor
enum AppPrinting {
    enum Outcome: Equatable {
        case printed, savedAsPDF, cancelled, notAvailable
        /// The content left the app (printed, or saved from the preview) — the caller records a release.
        var released: Bool { self == .printed || self == .savedAsPDF }
    }

    static let unavailableMessage = "The print preview could not be drawn. Export the document and print it from another app. Nothing was recorded."

    /// True when this process may print: not sandboxed, or sandboxed with the print entitlement.
    static let isEntitled: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let sandboxed = (SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool) ?? false
        guard sandboxed else { return true }
        return (SecTaskCopyValueForEntitlement(task, "com.apple.security.print" as CFString, nil) as? Bool) ?? false
        #else
        return false
        #endif
    }()

    /// Print `text`: the system print dialog when entitled, otherwise the print preview. Returns what
    /// happened; the caller records a release only when `released`.
    @discardableResult
    static func run(text: String, jobTitle: String, monospace: Bool = true, fontSize: CGFloat = 9) -> Outcome {
        #if os(macOS)
        let view = textView(text, monospace: monospace, fontSize: fontSize)
        guard isEntitled else { return preview(view, jobTitle: jobTitle) }
        let op = NSPrintOperation(view: view)
        op.jobTitle = jobTitle
        return op.run() ? .printed : .cancelled
        #else
        return .notAvailable
        #endif
    }

    #if os(macOS)
    /// A page-wide text view holding all of `text`, grown to its full height so it paginates.
    static func textView(_ text: String, monospace: Bool, fontSize: CGFloat) -> NSTextView {
        let info = NSPrintInfo.shared
        let width = max(300, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.font = monospace ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : NSFont.systemFont(ofSize: fontSize + 2)
        view.sizeToFit()
        return view
    }

    /// The pages as a PDF, drawn in the app (no printing system): the text view's text laid out into
    /// page-sized frames, one PDF page each, on the default paper size and margins.
    static func pdfData(_ view: NSTextView) -> Data? {
        guard let source = view.textStorage, source.length > 0 else { return nil }
        let info = NSPrintInfo.shared
        let page = CGRect(origin: .zero, size: info.paperSize)
        let margin = CGPoint(x: info.leftMargin, y: info.topMargin)
        let area = CGSize(width: page.width - info.leftMargin - info.rightMargin, height: page.height - info.topMargin - info.bottomMargin)
        let storage = NSTextStorage(attributedString: source)
        // Paper is white whatever the appearance: in Dark Mode the view's text colour is white, which drew
        // invisible pages (agent UI run on 82127048).
        storage.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: storage.length))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        var drawn = 0
        while drawn < layout.numberOfGlyphs {
            let container = NSTextContainer(size: area)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0 else { break }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: glyphs, at: margin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: margin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            drawn = NSMaxRange(glyphs)
        }
        context.closePDF()
        return data.length > 0 ? data as Data : nil
    }

    /// The print preview: the pages in a window, with Save as PDF… and Close.
    static func preview(_ view: NSTextView, jobTitle: String) -> Outcome {
        guard let data = pdfData(view), let document = PDFDocument(data: data) else {
            KalsmritikoshLog.ui.error("Print preview: the PDF could not be drawn for \(jobTitle, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Print preview not available"
            alert.informativeText = unavailableMessage
            alert.runModal()
            return .notAvailable
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Print preview — \(jobTitle)"
        // The pages as images, drawn now: a PDFView renders its tiles asynchronously and inside the modal
        // preview they never appeared (blank pages on screen while the saved PDF was correct — agent UI
        // runs on 82127048 and 8de27cf8).
        let pages = NSStackView()
        pages.orientation = .vertical
        pages.spacing = 12
        pages.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: NSSize(width: bounds.width * 1.5, height: bounds.height * 1.5), for: .mediaBox)
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.white.cgColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 612).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 612 * bounds.height / max(bounds.width, 1)).isActive = true
            imageView.setAccessibilityLabel("Page \(index + 1) of \(document.pageCount)")
            pages.addArrangedSubview(imageView)
        }
        let pdfView = NSScrollView()
        pdfView.hasVerticalScroller = true
        pdfView.drawsBackground = true
        pdfView.backgroundColor = .underPageBackgroundColor
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        pages.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(pages)
        NSLayoutConstraint.activate([
            pages.topAnchor.constraint(equalTo: flipped.topAnchor), pages.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            pages.centerXAnchor.constraint(equalTo: flipped.centerXAnchor),
            flipped.widthAnchor.constraint(greaterThanOrEqualTo: pages.widthAnchor),
        ])
        pdfView.documentView = flipped
        flipped.widthAnchor.constraint(equalTo: pdfView.contentView.widthAnchor).isActive = true
        let note = NSTextField(labelWithString: "Printing from this app is not available. Save the pages as a PDF and print the file from any app.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let handler = PreviewHandler(data: data, jobTitle: jobTitle, window: window)
        let save = NSButton(title: "Save as PDF…", target: handler, action: #selector(PreviewHandler.save))
        save.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: handler, action: #selector(PreviewHandler.close))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [note, NSView(), close, save])
        let stack = NSStackView(views: [pdfView, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 12)
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        window.contentView = stack
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return handler.saved ? .savedAsPDF : .cancelled
    }

    /// Top-down coordinates for the scrolled page stack (first page at the top).
    final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// Button targets for the modal preview window.
    final class PreviewHandler: NSObject {
        let data: Data, jobTitle: String
        weak var window: NSWindow?
        var saved = false
        init(data: Data, jobTitle: String, window: NSWindow) { self.data = data; self.jobTitle = jobTitle; self.window = window }

        @objc func save() {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = String(jobTitle.replacingOccurrences(of: "/", with: "-").prefix(80)) + ".pdf"
            panel.canCreateDirectories = true
            // A sheet on the preview window, not a second modal loop: from a screen already inside a modal
            // session (the ACH sheet) a nested runModal returned at once and nothing was saved (UI run).
            guard let window else { return }
            panel.beginSheetModal(for: window) { [self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    saved = true
                    NSApp.stopModal()
                } catch {
                    KalsmritikoshLog.ui.error("Print preview: saving the PDF failed: \(error.localizedDescription, privacy: .public)")
                    NSAlert(error: error).runModal()
                }
            }
        }

        @objc func close() { NSApp.stopModal() }
    }
    #endif
}
