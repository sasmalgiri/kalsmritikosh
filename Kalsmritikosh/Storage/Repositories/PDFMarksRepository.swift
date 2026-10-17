//
//  PDFMarksRepository.swift
//  Kalsmritikosh
//
//  X-3 — highlights, underlines, strike-outs and notes on PDFs (schema v149). Marks live in
//  the ledger beside the PDF; the original file is never written. A mark on text also gets a
//  W2-1 annotation (quote + note) so it appears in Highlights; removing the mark stamps both.
//

import Foundation
import CoreGraphics

public nonisolated enum PDFMarkKind: String, Sendable, CaseIterable, Identifiable {
    case highlight, underline, strikeout, note
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strike out"
        case .note: return "Note"
        }
    }
}

public nonisolated struct PDFMark: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let objectID: UUID
    /// 0-based page index.
    public let page: Int
    public let kind: PDFMarkKind
    /// Page-space rectangles, one per marked line (a note has one: where it sits).
    public let rects: [CGRect]
    public let color: String
    public let quote: String?
    public let contents: String?
    public let annotationID: UUID?
    public let createdAt: Date
}

public enum PDFMarksError: Error, LocalizedError, Equatable {
    case nothingToMark
    public var errorDescription: String? {
        switch self {
        case .nothingToMark: return "Select some text in the PDF first (or click where the note should go)."
        }
    }
}

public actor PDFMarksRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    static func encode(_ rects: [CGRect]) -> String {
        let arr = rects.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] }
        return (try? String(data: JSONSerialization.data(withJSONObject: arr), encoding: .utf8)) ?? "[]"
    }

    static func decode(_ json: String) -> [CGRect] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else { return [] }
        return arr.compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    }

    /// Record a mark. A text mark with a quote also becomes a W2-1 annotation.
    @discardableResult
    public func add(objectID: UUID, sourceURL: String?, page: Int, kind: PDFMarkKind, rects: [CGRect],
                    color: String = "yellow", quote: String?, contents: String?) async throws -> UUID {
        let clean = rects.filter { $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite }
        guard !clean.isEmpty, page >= 0 else { throw PDFMarksError.nothingToMark }
        let trimmedQuote = quote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContents = contents?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedContents?.isEmpty == false ? trimmedContents : nil
        let id = UUID()
        // A text mark also becomes a W2-1 annotation, in the same savepoint so neither can
        // exist without the other. Always a plain note: a visual mark (even a strike-out) is
        // not a confirmation or correction of the evidence — that stays a choice in Highlights.
        let annotationID: UUID? = (kind != .note && trimmedQuote?.isEmpty == false) ? UUID() : nil
        let now = Date()
        try await database.withSavepoint("pdf_mark_add") { db in
            if let annotationID, let q = trimmedQuote {
                try db.exec("""
                    INSERT INTO annotations (id, object_id, chunk_id, source_url, quote, note, color, stance, created_at)
                    VALUES (?, ?, NULL, ?, ?, ?, ?, 'note', ?);
                    """, [.uuid(annotationID), .uuid(objectID), .optionalText(sourceURL), .text(q),
                          .optionalText(note), .text(color), .date(now)])
            }
            try db.exec("""
                INSERT INTO pdf_marks (id, object_id, page, kind, rects_json, color, quote, contents, annotation_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [.uuid(id), .uuid(objectID), .integer(Int64(page)), .text(kind.rawValue), .text(Self.encode(clean)),
                      .text(color), .optionalText(trimmedQuote), .optionalText(note),
                      annotationID.map { .uuid($0) } ?? .null, .date(now)])
        }
        return id
    }

    /// Live marks of a document, page by page in the order they were made.
    public func marks(for objectID: UUID) async throws -> [PDFMark] {
        let rows = try await database.query("""
            SELECT id, page, kind, rects_json, color, quote, contents, annotation_id, created_at
            FROM pdf_marks WHERE object_id = ? AND removed_at IS NULL ORDER BY page, created_at, id;
            """, [.uuid(objectID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let kind = r.string(2).flatMap(PDFMarkKind.init) else { return nil }
            return PDFMark(id: id, objectID: objectID, page: Int(r.int(1) ?? 0), kind: kind,
                           rects: Self.decode(r.string(3) ?? "[]"), color: r.string(4) ?? "yellow",
                           quote: r.string(5), contents: r.string(6), annotationID: r.uuid(7),
                           createdAt: Date(timeIntervalSince1970: r.double(8) ?? 0))
        }
    }

    /// Change a note's text (the linked annotation follows).
    public func setContents(_ id: UUID, _ text: String?) async throws {
        try await database.withSavepoint("pdf_mark_contents") { db in
            try db.exec("UPDATE pdf_marks SET contents = ? WHERE id = ? AND removed_at IS NULL;", [.optionalText(text), .uuid(id)])
            try db.exec("""
                UPDATE annotations SET note = ? WHERE id = (SELECT annotation_id FROM pdf_marks WHERE id = ?) AND removed_at IS NULL;
                """, [.optionalText(text), .uuid(id)])
        }
    }

    /// Remove a mark (and its annotation) by stamping; nothing is deleted.
    public func remove(_ id: UUID) async throws {
        let now = Date()
        try await database.withSavepoint("pdf_mark_remove") { db in
            try db.exec("""
                UPDATE annotations SET removed_at = ? WHERE id = (SELECT annotation_id FROM pdf_marks WHERE id = ?) AND removed_at IS NULL;
                """, [.date(now), .uuid(id)])
            try db.exec("UPDATE pdf_marks SET removed_at = ? WHERE id = ? AND removed_at IS NULL;", [.date(now), .uuid(id)])
        }
    }
}
