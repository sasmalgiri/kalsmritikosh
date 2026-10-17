//
//  NotesStoreTests.swift
//  KalsmritikoshTests
//
//  P-2 — your own Markdown notes: create, save with versions, restore, rename, trash and
//  put back. Nothing is ever destroyed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P-2 Your own notes")
struct NotesStoreTests {
    private func makeStore() throws -> (NotesStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (NotesStore(base: base), base)
    }

    @Test("A new note is a Markdown file headed by its title, in the Notes folder")
    func create() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try store.create(title: "Meeting: plan / budget")
        #expect(url.lastPathComponent == "Meeting- plan - budget.md")
        #expect(url.deletingLastPathComponent().standardizedFileURL == store.notesFolder.standardizedFileURL)
        #expect(try store.read(url) == "# Meeting: plan / budget\n\n")
        #expect(store.list().map(\.title) == ["Meeting- plan - budget"])
        #expect(throws: NotesStore.NotesError.self) { _ = try store.create(title: "Meeting: plan / budget") }
        #expect(throws: NotesStore.NotesError.self) { _ = try store.create(title: "   ") }
    }

    @Test("Every changing save keeps the text it replaces; an unchanged save writes nothing")
    func versions() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try store.create(title: "Draft")
        #expect(try store.save("one", to: url))
        #expect(try !store.save("one", to: url))
        #expect(try store.save("two", to: url))
        #expect(try store.read(url) == "two")
        let kept = try store.versions(of: url).map { try String(contentsOf: $0.url, encoding: .utf8) }
        #expect(Set(kept) == ["# Draft\n\n", "one"])
        // Versions are outside the Notes folder, so they are never read as documents.
        #expect(store.list().count == 1)
    }

    @Test("Restoring a version keeps the current text as a version too")
    func restore() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try store.create(title: "R")
        try store.save("first", to: url)
        try store.save("second", to: url)
        let first = try #require(try store.versions(of: url).first {
            try String(contentsOf: $0.url, encoding: .utf8) == "first"
        })
        try store.restore(first, to: url)
        #expect(try store.read(url) == "first")
        let kept = try store.versions(of: url).map { try String(contentsOf: $0.url, encoding: .utf8) }
        #expect(kept.contains("second"))
    }

    @Test("Deleting moves a note to the trash, and it can be put back")
    func trash() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try store.create(title: "Gone")
        try store.save("keep me", to: url)
        let inTrash = try store.delete(url)
        #expect(store.list().isEmpty)
        #expect(try String(contentsOf: inTrash, encoding: .utf8) == "keep me")
        #expect(store.trashed().map(\.title) == ["Gone"])
        // The name is taken meanwhile: putting back chooses a free name, never overwrites.
        _ = try store.create(title: "Gone")
        let back = try store.restoreFromTrash(inTrash)
        #expect(back.lastPathComponent == "Gone 2.md")
        #expect(try store.read(back) == "keep me")
        #expect(store.trashed().isEmpty)
    }

    @Test("Renaming moves the note's versions with it")
    func rename() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try store.create(title: "Old")
        try store.save("edited", to: url)
        let renamed = try store.rename(url, to: "New")
        #expect(renamed.lastPathComponent == "New.md")
        #expect(try store.read(renamed) == "edited")
        #expect(store.versions(of: renamed).count == 1)
        #expect(throws: NotesStore.NotesError.self) { _ = try store.rename(renamed, to: "") }
    }

    @Test("Only files in the Notes folder can be saved, deleted or renamed")
    func refusesOtherFiles() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("elsewhere.md")
        try Data("x".utf8).write(to: outside)
        #expect(throws: NotesStore.NotesError.self) { try store.save("y", to: outside) }
        #expect(throws: NotesStore.NotesError.self) { try store.delete(outside) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "x")
    }

    @Test("The preview renders Markdown and keeps line breaks")
    func preview() {
        let s = MyNotesView.rendered("**bold** line\nnext")
        #expect(String(s.characters) == "bold line\nnext")
    }
}
