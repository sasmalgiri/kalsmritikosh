//
//  GroupsAndSimilarityTests.swift
//  KalsmritikoshTests
//
//  X-2 your own folders (groups, replicants, mirror, group: search) and X-1 See Also and
//  filing suggestions.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("X-2 Your own folders")
struct GroupRepositoryTests {
    @Test("A tree of groups, a document in two of them, members including sub-groups")
    func treeAndReplicants() async throws {
        let dir = try ParityFixture.tempFolder("grp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let repo = GroupRepository(database: db)
        let doc = try await ParityFixture.document(db, name: "a.txt", text: "Alpha contract.").id
        let other = try await ParityFixture.document(db, name: "b.txt", text: "Bravo invoice.").id

        let legal = try await repo.create(name: "Legal")
        let contracts = try await repo.create(name: "Contracts", parent: legal)
        let finance = try await repo.create(name: "Finance")
        try await repo.add(doc, to: contracts)
        try await repo.add(doc, to: finance)          // replicant: same document, second place
        try await repo.add(other, to: finance)

        #expect(try await repo.groups(containing: doc).map(\.name) == ["Contracts", "Finance"])
        #expect(try await repo.members(of: legal).isEmpty)
        #expect(try await repo.members(of: legal, includingSubgroups: true) == [doc])
        #expect(Set(try await repo.members(of: finance)) == [doc, other])
        let tree = try await repo.all()
        #expect(tree.map(\.name) == ["Legal", "Contracts", "Finance"])           // parent before child
        #expect(tree.first { $0.name == "Finance" }?.memberCount == 2)
        #expect(try await repo.unfiled().isEmpty)
    }

    @Test("Refusals: empty name, a taken name among siblings, a move into its own branch, a missing document")
    func refusals() async throws {
        let dir = try ParityFixture.tempFolder("grp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let repo = GroupRepository(database: db)
        let a = try await repo.create(name: "A")
        let b = try await repo.create(name: "B", parent: a)
        await #expect(throws: GroupRepositoryError.emptyName) { try await repo.create(name: "  ") }
        await #expect(throws: GroupRepositoryError.nameTaken("a")) { try await repo.create(name: "a") }
        _ = try await repo.create(name: "A", parent: b)                         // same name, different parent: fine
        await #expect(throws: GroupRepositoryError.wouldCreateCycle) { try await repo.move(a, under: b) }
        await #expect(throws: GroupRepositoryError.wouldCreateCycle) { try await repo.move(a, under: a) }
        await #expect(throws: GroupRepositoryError.documentNotFound) { try await repo.add(UUID(), to: a) }
    }

    @Test("Removing a group removes its branch; restoring brings it back with its members")
    func retireRestore() async throws {
        let dir = try ParityFixture.tempFolder("grp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let repo = GroupRepository(database: db)
        let doc = try await ParityFixture.document(db, name: "a.txt", text: "Alpha.").id
        let top = try await repo.create(name: "Top")
        let sub = try await repo.create(name: "Sub", parent: top)
        try await repo.add(doc, to: sub)
        try await repo.retire(top)
        #expect(try await repo.all().isEmpty)
        #expect(try await repo.unfiled() == [doc])
        await #expect(throws: GroupRepositoryError.parentRetired) { try await repo.add(doc, to: sub) }
        try await repo.restore(top)
        #expect(try await repo.all().map(\.name) == ["Top", "Sub"])
        #expect(try await repo.members(of: sub) == [doc])
        // A sub-group removed on its own is not brought back by restoring its parent later.
        try await repo.retire(sub)
        try await repo.retire(top)
        try await repo.restore(top)
        #expect(try await repo.all().map(\.name) == ["Top"])
    }

    @Test("Taking a document out and moving it never touches its other groups")
    func removeAndMove() async throws {
        let dir = try ParityFixture.tempFolder("grp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let repo = GroupRepository(database: db)
        let doc = try await ParityFixture.document(db, name: "a.txt", text: "Alpha.").id
        let a = try await repo.create(name: "A"), b = try await repo.create(name: "B"), c = try await repo.create(name: "C")
        try await repo.add(doc, to: a); try await repo.add(doc, to: b)
        try await repo.moveDocument(doc, from: a, to: c)
        #expect(Set(try await repo.groups(containing: doc).map(\.name)) == ["B", "C"])
        try await repo.remove(doc, from: b)
        #expect(try await repo.groups(containing: doc).map(\.name) == ["C"])
        try await repo.add(doc, to: b)                 // adding back restores the stamped row
        #expect(Set(try await repo.groups(containing: doc).map(\.name)) == ["B", "C"])
    }

    @Test("Folder paths relative to a source root")
    func relativeFolders() {
        #expect(GroupRepository.relativeFolders(of: "/r/x/y/f.pdf", under: "/r") == ["x", "y"])
        #expect(GroupRepository.relativeFolders(of: "/r/f.pdf", under: "/r") == [])
        #expect(GroupRepository.relativeFolders(of: "/other/f.pdf", under: "/r") == nil)
        #expect(GroupRepository.relativeFolders(of: "/rx/f.pdf", under: "/r") == nil)   // not fooled by a prefix
    }

    @Test("Building groups from folders: re-runs add only what is new and respect the person's edits")
    func mirror() async throws {
        let dir = try ParityFixture.tempFolder("grp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let repo = GroupRepository(database: db)
        let a = try await ParityFixture.document(db, name: "a", text: "a").id
        let b = try await ParityFixture.document(db, name: "b", text: "b").id
        let c = try await ParityFixture.document(db, name: "c", text: "c").id
        let docs: [(objectID: UUID, path: String)] = [(a, "/root/Cases/2024/a.pdf"), (b, "/root/Cases/b.pdf"), (c, "/root/c.pdf")]
        let first = try await repo.mirror(rootName: "Root", rootPath: "/root", documents: docs)
        #expect(first.groupsCreated == 3)          // Root, Cases, 2024
        #expect(first.membershipsAdded == 3)
        #expect(try await repo.all().map(\.name) == ["Root", "Cases", "2024"])

        // The person renames a group, takes a document out and removes a group.
        let cases = try #require(try await repo.all().first { $0.name == "Cases" })
        let year = try #require(try await repo.all().first { $0.name == "2024" })
        try await repo.rename(cases.id, to: "Matters")
        try await repo.remove(b, from: cases.id)
        try await repo.retire(year.id)

        let again = try await repo.mirror(rootName: "Root", rootPath: "/root", documents: docs)
        #expect(again.groupsCreated == 0)
        #expect(again.membershipsAdded == 0)        // b is not put back; a's group stays removed
        #expect(again.skippedRetired == 1)
        #expect(try await repo.all().map(\.name) == ["Root", "Matters"])
    }

    @Test("group: in advanced search covers sub-groups; a removed group is not searched")
    func groupSearch() async throws {
        let dir = try ParityFixture.tempFolder("grp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let repo = GroupRepository(database: db)
        let a = try await ParityFixture.document(db, name: "a", text: "alpha clause").id
        let b = try await ParityFixture.document(db, name: "b", text: "bravo clause").id
        _ = try await ParityFixture.document(db, name: "c", text: "charlie clause")
        let legal = try await repo.create(name: "Legal")
        let sub = try await repo.create(name: "Leases", parent: legal)
        try await repo.add(a, to: legal); try await repo.add(b, to: sub)
        let chunks = ChunksRepository(database: db)
        let compiled = AdvancedSearchCompiler.compile("group:Legal")
        #expect(compiled.filters.first?.field == .group)
        #expect(Set(try await chunks.objectsMatchingAdvanced(compiled)) == [a, b])
        #expect(try await chunks.objectsMatchingAdvanced(AdvancedSearchCompiler.compile("folder:Leases")) == [b])
        #expect(Set(try await chunks.objectsMatchingAdvanced(AdvancedSearchCompiler.compile("-group:Leases group:Legal"))) == [a])
        try await repo.retire(legal)
        #expect(try await chunks.objectsMatchingAdvanced(AdvancedSearchCompiler.compile("group:Legal")).isEmpty)
    }
}

@Suite("X-1 See Also and filing suggestions")
struct DocumentSimilarityTests {
    private func setUp() async throws -> (Database, URL, [String: UUID]) {
        let dir = try ParityFixture.tempFolder("sim")
        let db = try await ParityFixture.database(in: dir)
        var ids: [String: UUID] = [:]
        let specs: [(String, Int, Int?)] = [("law1", 0, 1), ("law2", 0, 2), ("law3", 0, 3), ("bio1", 4, 5), ("bio2", 4, 6)]
        for (name, axis, mix) in specs {
            let d = try await ParityFixture.document(db, name: name, text: "\(name) passage one\n\n\(name) passage two")
            for c in d.chunks { try await ParityFixture.embed(db, chunk: c, ParityFixture.vector(axis: axis, mix: mix)) }
            ids[name] = d.id
        }
        _ = try await ParityFixture.document(db, name: "plain", text: "never embedded")
        return (db, dir, ids)
    }

    @Test("See Also ranks the documents alike, excludes the document itself, and gives a reason")
    func seeAlso() async throws {
        let (db, dir, ids) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = DocumentSimilarity(database: db, modelID: "test-model")
        guard case .results(let r) = try await engine.seeAlso(ids["law1"]!) else { Issue.record("no results"); return }
        #expect(!r.contains { $0.objectID == ids["law1"] })
        #expect(Set(r.prefix(2).map(\.objectID)) == [ids["law2"]!, ids["law3"]!])
        #expect(r.first?.reason != nil)
        // Deterministic.
        guard case .results(let again) = try await engine.seeAlso(ids["law1"]!) else { return }
        #expect(again.map(\.objectID) == r.map(\.objectID))
    }

    @Test("Near-duplicates are left out of See Also; a scope filter is honoured")
    func exclusions() async throws {
        let (db, dir, ids) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.exec("INSERT INTO near_duplicate_members (object_id, group_id, similarity, computed_at) VALUES (?, 'g', 0.99, 0), (?, 'g', 0.99, 0);",
                          [.uuid(ids["law1"]!), .uuid(ids["law2"]!)])
        let engine = DocumentSimilarity(database: db, modelID: "test-model")
        let blocked = ids["law3"]!
        guard case .results(let r) = try await engine.seeAlso(ids["law1"]!, allowed: { $0 != blocked }) else { return }
        #expect(!r.contains { $0.objectID == ids["law2"] })
        #expect(!r.contains { $0.objectID == blocked })
    }

    @Test("A document with no embedded passage is 'not yet', never 'nothing alike'")
    func notYetEmbedded() async throws {
        let (db, dir, _) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try #require(try await db.query("SELECT ko.id FROM knowledge_objects ko WHERE content = 'never embedded';", []).first?.uuid(0))
        let engine = DocumentSimilarity(database: db, modelID: "test-model")
        guard case .notYetEmbedded = try await engine.seeAlso(plain) else { Issue.record("expected notYetEmbedded"); return }
        guard case .notYetEmbedded = try await DocumentSimilarity(database: db, modelID: "test-model", thresholds: (0.5, 0.025))
            .suggestFiling(plain) else { Issue.record("expected notYetEmbedded"); return }
        // A model nobody calibrated filing for gets no suggestions, never a guess.
        guard case .notCalibrated = try await engine.suggestFiling(plain) else { Issue.record("expected notCalibrated"); return }
    }

    @Test("Filing suggests the group the document resembles, and nothing below the floor")
    func filing() async throws {
        let (db, dir, ids) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = GroupRepository(database: db)
        let legal = try await groups.create(name: "Legal")
        let science = try await groups.create(name: "Science")
        try await groups.add(ids["law1"]!, to: legal); try await groups.add(ids["law2"]!, to: legal)
        try await groups.add(ids["bio1"]!, to: science); try await groups.add(ids["bio2"]!, to: science)
        let engine = DocumentSimilarity(database: db, modelID: "test-model", thresholds: (0.5, 0.025))
        guard case .results(let s) = try await engine.suggestFiling(ids["law3"]!) else { Issue.record("no suggestion"); return }
        #expect(s.first?.name == "Legal")
        #expect(!s.contains { $0.name == "Science" })           // far below the floor
        // A document already in every candidate gets no suggestion.
        guard case .noConfidentSuggestion = try await engine.suggestFiling(ids["law1"]!) else {
            Issue.record("law1 is in Legal and far from Science: nothing to suggest"); return
        }
    }

    @Test("The cached vector is rebuilt when the document's passages change")
    func cacheInvalidation() async throws {
        let (db, dir, ids) = try await setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = DocumentSimilarity(database: db, modelID: "test-model")
        let before = try #require(try await engine.vector(for: ids["law1"]!))
        let chunk = UUID()
        try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(chunk), .uuid(ids["law1"]!), .integer(9), .text("new"), .integer(0), .integer(3), .real(0)])
        try await ParityFixture.embed(db, chunk: chunk, ParityFixture.vector(axis: 7))
        let after = try #require(try await engine.vector(for: ids["law1"]!))
        #expect(DocumentSimilarity.cosine(before, after) < 0.999)
    }

    @Test("Maths: normalised mean and cosine")
    func maths() {
        let m = DocumentSimilarity.normalisedMean([[1, 0], [0, 1]])!
        #expect(abs(m[0] - 0.7071) < 0.001 && abs(m[1] - 0.7071) < 0.001)
        #expect(DocumentSimilarity.normalisedMean([]) == nil)
        #expect(DocumentSimilarity.normalisedMean([[1, 0], [1]]) == nil)
        #expect(DocumentSimilarity.normalisedMean([[0, 0]]) == nil)
        #expect(abs(DocumentSimilarity.cosine([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(DocumentSimilarity.cosine([1, 0], [0, 1]) == 0)
        #expect(DocumentSimilarity.cosine([1], [1, 2]) == 0)
    }
}
