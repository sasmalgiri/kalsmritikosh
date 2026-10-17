//
//  NotesStore.swift
//  Kalsmritikosh
//
//  P-2 — notes you write yourself, in Markdown. A note is a plain `.md` file in the app's
//  Notes folder, and that folder is read like any other source, so a note becomes a document
//  in the ledger through the ordinary pipeline (formats die at ingestion; nothing downstream
//  knows a note from a file).
//
//  Nothing is ever destroyed here:
//   * every save that changes a note first copies the previous text to NoteVersions/,
//     and restoring a version saves the current text as a version too;
//   * deleting a note moves its file to NoteTrash/, from where it can be put back.
//  The versions and trash folders sit beside the Notes folder, not inside it, so they are
//  not read as documents.
//

import Foundation
import AppKit
import os

nonisolated struct NotesStore: Sendable {
    /// The folder that holds `Notes/`, `NoteVersions/` and `NoteTrash/`.
    let base: URL

    static var standard: NotesStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { NotesStore(base: $0.appendingPathComponent("Kalsmritikosh", isDirectory: true)) }
    }

    var notesFolder: URL { base.appendingPathComponent("Notes", isDirectory: true) }
    var versionsFolder: URL { base.appendingPathComponent("NoteVersions", isDirectory: true) }
    var trashFolder: URL { base.appendingPathComponent("NoteTrash", isDirectory: true) }

    struct Note: Sendable, Identifiable, Hashable {
        let url: URL
        let title: String
        let modified: Date
        var id: URL { url }
    }

    struct Version: Sendable, Identifiable, Hashable {
        let url: URL
        let savedAt: Date
        var id: URL { url }
    }

    enum NotesError: LocalizedError {
        case emptyTitle
        case exists(String)
        case notANote

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "A note needs a title."
            case .exists(let t): return "A note called \u{201C}\(t)\u{201D} already exists."
            case .notANote: return "That file is not one of your notes."
            }
        }
    }

    private var fm: FileManager { .default }

    // MARK: - Notes

    /// Every note, most recently changed first.
    func list() -> [Note] {
        notes(in: notesFolder)
    }

    /// Every note in the trash, most recently deleted first.
    func trashed() -> [Note] {
        notes(in: trashFolder)
    }

    private func notes(in folder: URL) -> [Note] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        return files.filter { Self.noteExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Note(url: url, title: url.deletingPathExtension().lastPathComponent, modified: date)
            }
            .sorted { $0.modified == $1.modified ? $0.title < $1.title : $0.modified > $1.modified }
    }

    /// X-3 — notes are Markdown or rich text (RTF; read in by the existing RTF parser).
    enum Format: String, Sendable, CaseIterable {
        case markdown = "md", richText = "rtf"
    }
    static let noteExtensions: Set<String> = Set(Format.allCases.map(\.rawValue))

    static func format(of note: URL) -> Format { Format(rawValue: note.pathExtension.lowercased()) ?? .markdown }

    /// A file name for `title`: path separators and colons become dashes.
    static func fileName(for title: String, format: Format = .markdown) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let noLeadingDot = cleaned.hasPrefix(".") ? "-" + cleaned.dropFirst() : Substring(cleaned)
        return String(noLeadingDot) + "." + format.rawValue
    }

    /// Create a note. Its first line is the title as a Markdown heading.
    func create(title: String, format: Format = .markdown) throws -> URL {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesError.emptyTitle }
        try fm.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        // A title already used by a note in the other format counts as taken.
        for f in Format.allCases where fm.fileExists(atPath: notesFolder.appendingPathComponent(Self.fileName(for: trimmed, format: f)).path) {
            throw NotesError.exists(trimmed)
        }
        let url = notesFolder.appendingPathComponent(Self.fileName(for: trimmed, format: format))
        let initial: Data
        switch format {
        case .markdown: initial = Data("# \(trimmed)\n\n".utf8)
        case .richText: initial = try Self.rtfData(Self.titled(trimmed))
        }
        try initial.write(to: url, options: .withoutOverwriting)
        return url
    }

    // MARK: - Rich text

    /// A rich note that starts with its title in bold.
    static func titled(_ title: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title + "\n\n")
        s.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: (title as NSString).length))
        return s
    }

    static func rtfData(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func readRich(_ note: URL) throws -> NSAttributedString {
        try NSAttributedString(data: Data(contentsOf: note), options: [.documentType: NSAttributedString.DocumentType.rtf],
                               documentAttributes: nil)
    }

    /// Save rich text (same versioning as `save(_:to:)`). False when nothing changed.
    @discardableResult
    func saveRich(_ text: NSAttributedString, to note: URL) throws -> Bool {
        try saveBytes(try Self.rtfData(text), to: note)
    }

    func read(_ note: URL) throws -> String {
        try String(contentsOf: note, encoding: .utf8)
    }

    /// Save new text. Returns false (and writes nothing) when the text is unchanged; otherwise
    /// the previous text is kept as a version first, then the note is replaced atomically.
    @discardableResult
    func save(_ text: String, to note: URL) throws -> Bool {
        try saveBytes(Data(text.utf8), to: note)
    }

    /// X-5 — replace a note's bytes (e.g. another device's newer text); the text it replaces
    /// is kept as a version. False when nothing changed.
    @discardableResult
    func replace(_ note: URL, with data: Data) throws -> Bool { try saveBytes(data, to: note) }

    /// X-5 — keep `data` as an earlier version of the note without changing the note (the text
    /// another device wrote at the same time as this one).
    func addVersion(_ data: Data, to note: URL) throws {
        try requireNote(note)
        try keepVersion(data, of: note)
    }

    /// X-5 — write a note that does not exist on this device yet.
    func adopt(name: String, data: Data) throws -> URL {
        try fm.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let url = notesFolder.appendingPathComponent(name)
        try requireNote(url)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func saveBytes(_ data: Data, to note: URL) throws -> Bool {
        try requireNote(note)
        let previous = try? Data(contentsOf: note)
        if previous == data { return false }
        if let previous { try keepVersion(previous, of: note) }
        try data.write(to: note, options: .atomic)
        return true
    }

    /// Rename a note; its versions move with it.
    func rename(_ note: URL, to title: String) throws -> URL {
        try requireNote(note)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesError.emptyTitle }
        let target = notesFolder.appendingPathComponent(Self.fileName(for: trimmed, format: Self.format(of: note)))
        if target.standardizedFileURL == note.standardizedFileURL { return note }
        guard !fm.fileExists(atPath: target.path) else { throw NotesError.exists(trimmed) }
        try fm.moveItem(at: note, to: target)
        let oldVersions = versionsDirectory(for: note), newVersions = versionsDirectory(for: target)
        if fm.fileExists(atPath: oldVersions.path) {
            try? fm.createDirectory(at: versionsFolder, withIntermediateDirectories: true)
            try fm.moveItem(at: oldVersions, to: newVersions)
        }
        return target
    }

    /// Move a note to the trash (never destroyed). Returns its place in the trash.
    @discardableResult
    func delete(_ note: URL) throws -> URL {
        try requireNote(note)
        try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        let target = uniqueURL(in: trashFolder, named: note.lastPathComponent)
        try fm.moveItem(at: note, to: target)
        return target
    }

    /// Put a trashed note back, under a free name if its old name is taken.
    @discardableResult
    func restoreFromTrash(_ trashed: URL) throws -> URL {
        guard trashed.deletingLastPathComponent().standardizedFileURL == trashFolder.standardizedFileURL else {
            throw NotesError.notANote
        }
        try fm.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let target = uniqueURL(in: notesFolder, named: trashed.lastPathComponent)
        try fm.moveItem(at: trashed, to: target)
        return target
    }

    // MARK: - Versions

    /// Earlier versions of a note, newest first.
    func versions(of note: URL) -> [Version] {
        let dir = versionsDirectory(for: note)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return files.filter { Self.noteExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let date = Self.versionDate(url) ??
                    ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                return Version(url: url, savedAt: date)
            }
            .sorted { $0.savedAt == $1.savedAt ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.savedAt > $1.savedAt }
    }

    /// Make an earlier version the current text. The text it replaces is kept as a version.
    func restore(_ version: Version, to note: URL) throws {
        _ = try saveBytes(try Data(contentsOf: version.url), to: note)
    }

    private func versionsDirectory(for note: URL) -> URL {
        versionsFolder.appendingPathComponent(note.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private static let stampFormat: Date.ISO8601FormatStyle = .iso8601
        .year().month().day().dateSeparator(.dash)
        .time(includingFractionalSeconds: true).timeSeparator(.omitted)

    private static func versionDate(_ url: URL) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = stem.split(separator: " ").first.map(String.init) ?? stem
        return try? stampFormat.parse(stamp)
    }

    private func keepVersion(_ data: Data, of note: URL) throws {
        let dir = versionsDirectory(for: note)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(Self.stampFormat)
        let target = uniqueURL(in: dir, named: "\(stamp).\(Self.format(of: note).rawValue)")
        try data.write(to: target, options: .withoutOverwriting)
    }

    // MARK: - Helpers

    private func requireNote(_ note: URL) throws {
        guard note.deletingLastPathComponent().standardizedFileURL == notesFolder.standardizedFileURL,
              Self.noteExtensions.contains(note.pathExtension.lowercased()) else { throw NotesError.notANote }
    }

    private func uniqueURL(in dir: URL, named name: String) -> URL {
        var target = dir.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        return target
    }
}

extension AppState {
    /// P-2 — make sure the Notes folder is a source, then read the note that changed.
    /// False when the folder could not be registered as a source.
    @discardableResult
    func readNote(_ note: URL) async -> Bool {
        guard let store = NotesStore.standard else { return false }
        let folder = store.notesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registered = bookmarks.roots.contains { root in
            guard let url = try? bookmarks.resolve(root) else { return false }
            defer { bookmarks.stopAccessing(url) }
            return url.standardizedFileURL == folder.standardizedFileURL
        }
        if !registered {
            do { try bookmarks.register(url: folder) }
            catch {
                KalsmritikoshLog.app.error("Notes source failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard FileManager.default.fileExists(atPath: note.path) else { return true }
        await ingestFiles([note])
        return true
    }
}
