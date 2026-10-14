//
//  CaptureView.swift
//  Kalsmritikosh
//
//  W3-6 — capture into an intake folder inside the app's own container. Drop
//  files or paste text here; each item is saved into Intake/<date>/ with a
//  custody line (when, where it came from, SHA-256 of the saved bytes) appended
//  to intake-custody.jsonl (beside the folder), and the intake folder is read like any source.
//  The app makes no connection. Share / Services / Safari extensions (owner
//  step: new targets in Xcode) are meant to drop into this same folder.
//

import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import os

nonisolated enum CaptureIntake {
    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kalsmritikosh/Intake", isDirectory: true)
    }

    struct Saved: Sendable { let file: URL; let sha256: String }

    /// Save bytes into today's intake folder and append a custody line. Never overwrites.
    static func save(_ data: Data, name: String, origin: String) throws -> Saved {
        guard let root = folder else { throw CocoaError(.fileNoSuchFile) }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var target = dir.appendingPathComponent(safe.isEmpty ? "Captured" : safe)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let ext = (safe as NSString).pathExtension, stem = (safe as NSString).deletingPathExtension
            target = dir.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        try data.write(to: target, options: .withoutOverwriting)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let line: [String: String] = ["capturedAt": ISO8601DateFormatter().string(from: Date()), "origin": origin,
                                      "file": target.path, "sha256": digest, "bytes": String(data.count)]
        if let json = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            // Beside the intake folder, not in it, so the log is not read as a document.
            let log = root.deletingLastPathComponent().appendingPathComponent("intake-custody.jsonl")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let h = try FileHandle(forWritingTo: log)
            try h.seekToEnd(); try h.write(contentsOf: json + Data("\n".utf8)); try h.close()
        }
        return Saved(file: target, sha256: digest)
    }
}

struct CaptureView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var title = ""
    @State private var log: [String] = []
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture").font(.title3.bold())
            Text("Drop files here, or paste text, to add them to your archive. Each item is saved in the app's intake folder with a custody record (time, origin, SHA-256). Nothing goes online.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .frame(height: 110)
                .overlay(Text("Drop files").foregroundStyle(.secondary))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            Task { @MainActor in captureFile(url) }
                        }
                    }
                    return true
                }
            TextField("Title for pasted text", text: $title)
            TextEditor(text: $text).font(.body).frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Save text") { captureText() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Read intake now") { Task { await readIntake() } }
                Button("Show intake folder") { if let f = CaptureIntake.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
            }
            List(log, id: \.self) { Text($0).font(.caption2) }.frame(minHeight: 90)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
    }

    private func captureFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let s = try CaptureIntake.save(data, name: url.lastPathComponent, origin: "drop: \(url.path)")
            log.insert("Saved \(s.file.lastPathComponent) · sha256 \(s.sha256.prefix(12))…", at: 0)
            Task { await readIntake() }
        } catch {
            KalsmritikoshLog.app.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            log.insert("Could not save \(url.lastPathComponent): \(error.localizedDescription)", at: 0)
        }
    }

    private func captureText() {
        let name = (title.trimmingCharacters(in: .whitespaces).isEmpty ? "Note" : title) + ".txt"
        do {
            let s = try CaptureIntake.save(Data(text.utf8), name: name, origin: "pasted text")
            log.insert("Saved \(s.file.lastPathComponent) · sha256 \(s.sha256.prefix(12))…", at: 0)
            text = ""; title = ""
            Task { await readIntake() }
        } catch {
            KalsmritikoshLog.app.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            log.insert("Could not save the text: \(error.localizedDescription)", at: 0)
        }
    }

    /// Register the intake folder as a source once, then read new items.
    private func readIntake() async {
        guard let folder = CaptureIntake.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registered = appState.bookmarks.roots.contains { root in
            guard let url = try? appState.bookmarks.resolve(root) else { return false }
            defer { appState.bookmarks.stopAccessing(url) }
            return url.standardizedFileURL == folder.standardizedFileURL
        }
        if !registered {
            do { try appState.bookmarks.register(url: folder) }
            catch {
                KalsmritikoshLog.app.error("Intake source failed: \(error.localizedDescription, privacy: .public)")
                log.insert("Could not add the intake folder as a source.", at: 0)
                return
            }
        }
        let n = await appState.ingestAllRoots()
        log.insert("Read \(n) new file(s).", at: 0)
    }
}
