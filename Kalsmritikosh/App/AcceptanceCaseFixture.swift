//
//  AcceptanceCaseFixture.swift
//  Kalsmritikosh
//
//  Investigator workflow review 2026-10-30 — "one realistic acceptance case": a supplier alleged to
//  have been paid twice. One invoice and two e-mail copies of it; one bank debit of ₹10,000 and a
//  refund of ₹2,000; two witness accounts that disagree about approval; a sentence that names one
//  person before the actual speaker; a namesake with no role; a later innocent explanation; a missing
//  attachment ("see the attached receipt" with none) and an unreadable scan; two repeated service
//  reports and an unrelated memo sharing a confidentiality footer.
//
//  The documents are bundled fixtures (Resources/Fixtures/AcceptanceSupplierPayment). The unreadable
//  scan is generated here as a one-page PDF with no text. `AcceptanceCaseTests` runs the case through
//  the production services; the DEBUG launch argument `--acceptance-case` boots the GUI on a disposable
//  ledger with the folder registered, so the same case can be walked through the UI. Absent from release.
//

#if DEBUG   // App Store completion §5 — the acceptance fixture and its launch argument are compiled out of Release
import Foundation
import CoreGraphics
import os

public nonisolated enum AcceptanceCaseFixture {
    public static let folderName = "AcceptanceSupplierPayment"
    public static let scanName = "scan-receipt-unreadable.pdf"
    public static let fixtureNames = [
        "invoice-INV-2041.md", "email-invoice-resend-1.eml", "email-invoice-resend-2.eml", "bank-statement-7718-march.md",
        "statement-asha-rao.md", "statement-vikram-rao.md", "memo-staff-picnic.md", "note-innocent-explanation.md",
        "report-generator-service-1.md", "report-generator-service-2.md",
    ]
    /// The document that arrives after the case is opened (the innocent explanation) — kept out of the
    /// first intake so the explicit "Review new documents" path is exercised.
    public static let laterDocument = "note-innocent-explanation.md"

    /// Copy the fixture documents into `folder` (created if needed), excluding `excluding`, and write
    /// the unreadable scan beside them. Returns the file URLs written, by name.
    @discardableResult
    public static func materialise(from sourceFolder: URL, into folder: URL, excluding: Set<String> = []) throws -> [String: URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [String: URL] = [:]
        for name in fixtureNames where !excluding.contains(name) {
            let dst = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: sourceFolder.appendingPathComponent(name), to: dst)
            out[name] = dst
        }
        let scan = folder.appendingPathComponent(scanName)
        try blankPDF().write(to: scan)
        out[scanName] = scan
        return out
    }

    /// A one-page PDF with no text at all — a scan whose text layer never existed.
    public static func blankPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 0.92, alpha: 1)
        ctx.fill(CGRect(x: 60, y: 500, width: 490, height: 220))
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    /// The bundled fixture folder, when this build carries it: a real directory, or the flattened
    /// resources materialised into the app container (as the demo archive does).
    public static func bundledFolder() -> URL? {
        if let dir = Bundle.main.url(forResource: folderName, withExtension: nil, subdirectory: "Fixtures") { return dir }
        if let dir = Bundle.main.url(forResource: folderName, withExtension: nil),
           (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return dir }
        let fm = FileManager.default
        let sources: [(String, URL)] = fixtureNames.compactMap { n in Bundle.main.url(forResource: n, withExtension: nil).map { (n, $0) } }
        guard sources.count == fixtureNames.count else { return nil }
        do {
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("DemoArchive", isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            for (name, src) in sources {
                let dst = base.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            return base
        } catch {
            KalsmritikoshLog.app.error("Acceptance case folder could not be prepared: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// DEBUG-only GUI checkpoint: `--acceptance-case` boots against a disposable ledger with the
/// acceptance case's folder (minus the later document) registered as its only root, so the UI
/// journey starts from a clean workspace that already holds the case's documents. The later document
/// is written beside the folder as `later/note-innocent-explanation.md` for the person to add.
@MainActor
enum AcceptanceCaseGUIFixture {
    static let launchArgument = "--acceptance-case"
    static var isRequested: Bool { CommandLine.arguments.contains(launchArgument) }

    static var databaseURL: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("acceptance-case.sqlite") }
    static var folder: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("acceptance-case-documents", isDirectory: true) }

    static func boot(_ appState: AppState) async {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix)) }
        try? fm.removeItem(at: folder)
        guard let bundled = AcceptanceCaseFixture.bundledFolder() else {
            KalsmritikoshLog.app.error("Acceptance case: fixtures are not in this build")
            await appState.boot(databaseURL: databaseURL)
            return
        }
        do {
            try AcceptanceCaseFixture.materialise(from: bundled, into: folder, excluding: [AcceptanceCaseFixture.laterDocument])
            let later = folder.deletingLastPathComponent().appendingPathComponent("acceptance-case-later", isDirectory: true)
            try? fm.removeItem(at: later)
            try fm.createDirectory(at: later, withIntermediateDirectories: true)
            try fm.copyItem(at: bundled.appendingPathComponent(AcceptanceCaseFixture.laterDocument),
                            to: later.appendingPathComponent(AcceptanceCaseFixture.laterDocument))
            try appState.bookmarks.register(url: folder)
            KalsmritikoshLog.app.info("Acceptance case: documents at \(folder.path, privacy: .public); later document at \(later.path, privacy: .public)")
        } catch {
            KalsmritikoshLog.app.error("Acceptance case: could not prepare the documents: \(error.localizedDescription, privacy: .public)")
        }
        await appState.boot(databaseURL: databaseURL)
    }
}
#endif
