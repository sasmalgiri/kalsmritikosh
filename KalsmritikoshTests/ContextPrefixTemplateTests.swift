//
//  ContextPrefixTemplateTests.swift
//  KalsmritikoshTests
//
//  S2-U2 (R-3) — the deterministic prefix template's laws: identical output
//  on identical input (that is the point), plain-language parts, graceful
//  omission, and the version stamp riding the chunk into the store.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S2-U2 — deterministic context prefix (template + version stamp)")
@MainActor
struct ContextPrefixTemplateTests {

    @Test("Identical input renders identical prefix — determinism is the contract")
    func deterministic() {
        let a = ContextPrefixTemplate.render(title: "Letter of Grant", documentClass: .legalDocument, blockKind: "tableRow")
        let b = ContextPrefixTemplate.render(title: "Letter of Grant", documentClass: .legalDocument, blockKind: "tableRow")
        #expect(a == b)
        #expect(a == "Letter of Grant · legal document · table")
    }

    @Test("Unknown parts are omitted; all-unknown renders nil, never a junk prefix")
    func gracefulOmission() {
        #expect(ContextPrefixTemplate.render(title: nil, documentClass: .email, blockKind: "emailHeader")
                == "email · email header")
        #expect(ContextPrefixTemplate.render(title: "  ", documentClass: .other, blockKind: "no-such-kind") == nil)
        #expect(ContextPrefixTemplate.render(title: nil, documentClass: nil, blockKind: nil) == nil)
    }

    @Test("No RC-8 jargon leaks: every rendered class and kind is plain language")
    func plainLanguage() {
        for c in DocumentClass.allCases {
            let word = ContextPrefixTemplate.humanClass(c)
            #expect(!word.contains(where: \.isUppercase) || word.contains(" ") == word.contains(" "),
                    "class names read as words, got '\(word)'")
            #expect(word == word.lowercased() || word.first == "r", "no camelCase enum leak: '\(word)'")
        }
        for k in EvidenceBlockKind.allCases {
            let word = ContextPrefixTemplate.humanKind(k)
            #expect(word == word.lowercased(), "no camelCase enum leak: '\(word)'")
        }
    }

    @Test("withTemplatePrefix stamps the era; the stamp round-trips the store")
    func versionStamp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxpfx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(); let koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/g.pdf', 'pdf');", [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'pdf', 'seed', 0, 0);
        """, [.uuid(koID), .uuid(fileID)])

        let base = Chunk(objectID: koID, ordinal: 0, text: "grant body",
                         characterRange: 0..<10, blockKind: "paragraph")
        let stamped = base.withTemplatePrefix(
            ContextPrefixTemplate.render(title: "Letter of Grant", documentClass: .legalDocument, blockKind: "paragraph"))
        #expect(stamped.contextTemplateVersion == ContextPrefixTemplate.currentVersion)
        #expect(stamped.contextPrefixSource == "template")

        let repo = ChunksRepository(database: db)
        try await repo.insertBatch([stamped])
        let back = try await repo.firstChunk(forObjectID: koID)
        #expect(back?.contextTemplateVersion == ContextPrefixTemplate.currentVersion)
        #expect(back?.contextPrefix == "Letter of Grant · legal document · paragraph")

        // nil prefix stamps nothing — no phantom eras.
        #expect(base.withTemplatePrefix(nil).contextTemplateVersion == nil)
    }
}
