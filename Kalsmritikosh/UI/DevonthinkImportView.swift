//
//  DevonthinkImportView.swift
//  Kalsmritikosh
//
//  W3-1 — read a DEVONthink database package (.dtBase2) in place. DEVONthink keeps
//  each imported document as an ordinary file under `Files.noindex/` inside the
//  package; that folder is added as a read-only source (the package is never
//  written to), Finder tags on those files become the user's tags, and an
//  accounting compares files on disk with files in the ledger.
//
//  Not imported: DEVONthink's group tree and its own metadata, which live in
//  DEVONthink's undocumented `.dtMeta` files; indexed (not imported) items, which
//  live outside the package — add those folders in Sources directly. The package
//  layout is exercised against a simulated database (DevonthinkPackageTests).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

nonisolated struct DevonthinkPackage: Sendable {
    let package: URL
    let filesRoot: URL
    let files: [URL]

    /// The stored-files folder inside a package, or nil when this is not a DEVONthink database.
    static func open(_ package: URL) -> DevonthinkPackage? {
        guard package.pathExtension.lowercased() == "dtbase2" else { return nil }
        let root = package.appendingPathComponent("Files.noindex", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(u)
            }
        }
        return DevonthinkPackage(package: package, filesRoot: root, files: files)
    }

    /// Finder tags on a stored file.
    static func finderTags(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// Stored files on disk compared with the files the ledger holds (paths standardized).
    struct Accounting: Sendable, Equatable {
        let total: Int
        let inLedger: Int
        let missing: [String]          // file names not yet read, sorted

        var summary: String {
            missing.isEmpty
                ? "All \(total) stored documents are in the ledger."
                : "\(inLedger) of \(total) stored documents are in the ledger. Not yet read (\(missing.count)): "
                    + missing.prefix(5).joined(separator: ", ") + (missing.count > 5 ? "…" : "")
        }
    }

    func accounting(ledgerPaths: Set<String>) -> Accounting {
        let onDisk = Set(files.map { $0.standardizedFileURL.path })
        let inLedger = onDisk.intersection(ledgerPaths)
        let missing = onDisk.subtracting(inLedger).map { ($0 as NSString).lastPathComponent }.sorted()
        return Accounting(total: onDisk.count, inLedger: inLedger.count, missing: missing)
    }
}

struct DevonthinkImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var pkg: DevonthinkPackage?
    @State private var picked: URL?
    @State private var status: String?
    @State private var accounting: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a DEVONthink database").font(.title3.bold())
            Text("Choose a DEVONthink database (.dtBase2). Its stored documents are read where they are — nothing is copied out of or written into the database. Finder tags become your tags. DEVONthink's group folders are not read; indexed items outside the database should be added in Sources.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Choose database…") { choose() }.disabled(working)
            if let pkg {
                Text("\(pkg.package.lastPathComponent): \(pkg.files.count) stored documents.").font(.callout)
                HStack {
                    Button(working ? "Working…" : "Add and read") { Task { await importPackage() } }.disabled(working)
                    Button("Apply Finder tags") { Task { await applyTags() } }.disabled(working || appState.tagsRepository == nil)
                    Button("Check every file is accounted for") { Task { await account() } }.disabled(working)
                }
                if appState.tagsRepository == nil { Text("Tags is switched off in Settings → Modules.").font(.caption).foregroundStyle(.orange) }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let accounting { Text(accounting).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 340)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a DEVONthink database (.dtBase2)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        picked = url
        pkg = DevonthinkPackage.open(url)
        status = pkg == nil ? "This is not a DEVONthink database package (no Files.noindex folder inside a .dtBase2)." : nil
        accounting = nil
    }

    private func importPackage() async {
        guard let pkg, let picked else { return }
        working = true; defer { working = false }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        do {
            try appState.bookmarks.register(url: pkg.filesRoot)
            status = "Added as a source. Reading \(pkg.files.count) documents…"
            let n = await appState.ingestAllRoots()
            status = "Read \(n) file(s). Use “Check every file is accounted for” when reading finishes."
        } catch {
            KalsmritikoshLog.app.error("DEVONthink source failed: \(error.localizedDescription, privacy: .public)")
            status = "Could not add the database as a source: \(error.localizedDescription)"
        }
    }

    private func ledgerFiles() async -> [String: UUID] {
        guard let pkg, let db = appState.database else { return [:] }
        let rows = (try? await db.query("""
            SELECT f.url, ko.id FROM files f LEFT JOIN knowledge_objects ko ON ko.file_id = f.id WHERE f.url LIKE ?;
            """, [.text(pkg.filesRoot.absoluteString + "%")])) ?? []
        var out: [String: UUID] = [:]
        for r in rows {
            guard let s = r.string(0), let u = URL(string: s) else { continue }
            // Only files that produced a document count as read.
            if let id = r.uuid(1) { out[u.standardizedFileURL.path] = id }
        }
        return out
    }

    private func applyTags() async {
        guard let pkg, let picked, let tags = appState.tagsRepository else { return }
        working = true; defer { working = false }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let ledger = await ledgerFiles()
        var applied = 0, tagged = 0
        for f in pkg.files {
            let names = DevonthinkPackage.finderTags(f)
            guard !names.isEmpty, let id = ledger[f.standardizedFileURL.path] else { continue }
            tagged += 1
            for n in names {
                if let t = try? await tags.tag(named: n) { try? await tags.attach(tagID: t, to: .object, id); applied += 1 }
            }
        }
        status = "Applied \(applied) tag(s) to \(tagged) document(s)."
    }

    private func account() async {
        guard let pkg else { return }
        let ledger = await ledgerFiles()
        accounting = pkg.accounting(ledgerPaths: Set(ledger.keys)).summary
    }
}
