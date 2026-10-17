//
//  CaptureServices.swift
//  Kalsmritikosh
//
//  W3-6 — the Services menu ("Save to Kalsmritikosh"), declared under NSServices in
//  Info.plist. Selected text (plain, rich or HTML — e.g. part of a web page in
//  Safari, or an email in Mail) and files chosen in Finder are saved into the
//  capture intake with a custody line, then read. Nothing goes online: what is
//  saved is exactly what the other app handed over.
//
//  The menu item is declared statically, so macOS shows it even while the
//  "Share and capture" module is off; the handler then refuses with a message
//  saying so (macOS shows it) instead of saving anything.
//

import AppKit
import UniformTypeIdentifiers
import os

nonisolated enum CapturePasteboard {
    struct Item: Sendable, Equatable { let data: Data; let name: String; let origin: String }

    /// What a Services pasteboard carries, as intake items: file URLs first (each file's bytes),
    /// otherwise the richest text form offered — HTML, then RTF, then plain text.
    static func items(from pboard: NSPasteboard, readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> [Item] {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { url in
                guard let data = try? readFile(url) else { return nil }
                return Item(data: data, name: url.lastPathComponent, origin: "Services menu: \(url.path)")
            }
        }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "-")
        if let html = pboard.data(forType: .html), !html.isEmpty {
            return [Item(data: html, name: "Clipping \(stamp).html", origin: "Services menu: selected HTML")]
        }
        if let rtf = pboard.data(forType: .rtf), !rtf.isEmpty {
            return [Item(data: rtf, name: "Clipping \(stamp).rtf", origin: "Services menu: selected rich text")]
        }
        if let text = pboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [Item(data: Data(text.utf8), name: "Clipping \(stamp).txt", origin: "Services menu: selected text")]
        }
        return []
    }
}

@MainActor
final class CaptureServiceProvider: NSObject {
    static let shared = CaptureServiceProvider()
    weak var appState: AppState?

    func install(appState: AppState) {
        self.appState = appState
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // The Share extension's hand-over inbox: drained now and whenever the app comes forward.
        Task { await appState.receiveSharedItems() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let state = self?.appState else { return }
                Task { await state.receiveSharedItems() }
            }
        }
    }

    /// NSMessage "saveToKalsmritikosh" in Info.plist.
    @objc func saveToKalsmritikosh(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard ProductModuleFlags.isEnabled(.captureExtensions) else {
            error.pointee = "“Share and capture” is switched off. Turn it on in Kalsmritikosh ▸ Settings ▸ Modules." as NSString
            return
        }
        let items = CapturePasteboard.items(from: pboard)
        guard !items.isEmpty else {
            error.pointee = "Nothing to save: the selection held no text or files Kalsmritikosh can keep." as NSString
            return
        }
        var saved = 0
        for item in items {
            do { _ = try CaptureIntake.save(item.data, name: item.name, origin: item.origin); saved += 1 }
            catch { KalsmritikoshLog.app.error("Services capture failed: \(error.localizedDescription, privacy: .public)") }
        }
        guard saved > 0 else {
            error.pointee = "Kalsmritikosh could not save the selection (see the app log)." as NSString
            return
        }
        if let appState { Task { _ = await appState.readCaptureIntake() } }
    }
}
