//
//  ParityFixture.swift
//  KalsmritikoshTests
//
//  Shared set-up for the X-1…X-6 tests: a migrated ledger in a temp folder, documents with
//  a file, a text and passages, and passage embeddings.
//

import Foundation
@testable import Kalsmritikosh

enum ParityFixture {
    static func tempFolder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func database(in folder: URL) async throws -> Database {
        let db = try Database(url: folder.appendingPathComponent("ledger.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    /// One document: a file row (with `fileHash`), its knowledge object and one passage per
    /// paragraph of `text`. Returns the document id and its passage ids.
    @discardableResult
    static func document(_ db: Database, name: String, text: String, fileHash: String? = nil,
                         path: String? = nil) async throws -> (id: UUID, chunks: [UUID]) {
        let fileID = UUID(), koID = UUID()
        let hash = fileHash ?? SyncCrypto.sha256Hex(Data(text.utf8))
        let url = URL(fileURLWithPath: path ?? "/tmp/parity/\(name)").absoluteString
        try await db.exec("INSERT INTO files (id, url, source_type, size_bytes, modified_at, content_hash) VALUES (?,?,?,?,?,?);",
                          [.uuid(fileID), .text(url), .text("text"), .integer(Int64(text.utf8.count)), .real(0), .text(hash)])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(text), .real(Date().timeIntervalSince1970), .real(0)])
        var chunks: [UUID] = []
        var offset = 0
        for (i, para) in text.components(separatedBy: "\n\n").enumerated() where !para.isEmpty {
            let id = UUID()
            try await db.exec("""
                INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at) VALUES (?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(koID), .integer(Int64(i)), .text(para), .integer(Int64(offset)),
                      .integer(Int64(offset + para.count)), .real(0)])
            offset += para.count + 2
            chunks.append(id)
        }
        return (koID, chunks)
    }

    static func embed(_ db: Database, chunk: UUID, _ vector: [Float], model: String = "test-model") async throws {
        let (q, scale) = VectorQuantization.quantize(vector)
        try await db.exec("""
            INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at) VALUES (?,?,?,?,?,?,?);
            """, [.uuid(chunk), .text(model), .text("1"), .integer(Int64(vector.count)), .blob(q), .real(scale),
                  .real(Date().timeIntervalSince1970)])
    }

    /// A unit-ish vector pointing mostly along `axis` (of `dims`), with a little of `other`.
    static func vector(axis: Int, dims: Int = 8, mix other: Int? = nil, amount: Float = 0.2) -> [Float] {
        var v = [Float](repeating: 0.01, count: dims)
        v[axis] = 1
        if let other { v[other] = amount }
        return v
    }
}
