//
//  AnnotationsRepository.swift
//  Kalsmritikosh
//
//  W2-1 — highlights and notes as an overlay (schema v145 `annotations`). The
//  source is never edited. An annotation is anchored to its document AND to the
//  source file plus the exact quoted text, so after a re-ingest of an unchanged
//  source (new object id, same file, same text) it re-attaches by quote.
//  Removal stamps removed_at; nothing is deleted.
//

import Foundation

/// How the person's note relates to the passage — maps onto the evidence vocabulary.
public nonisolated enum AnnotationStance: String, Sendable, CaseIterable, Identifiable {
    case note, confirms, corrects
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .note: return "Note"
        case .confirms: return "I confirm this"
        case .corrects: return "I correct this"
        }
    }
    /// The evidence status the note carries (`nil` = a plain note, not evidence).
    public var evidenceStatus: EvidenceStatus? {
        switch self {
        case .note: return nil
        case .confirms: return .humanConfirmed
        case .corrects: return .humanCorrected
        }
    }
}

public nonisolated struct Annotation: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let objectID: UUID
    public let sourceURL: String?
    public let quote: String
    public let note: String?
    public let color: String
    public let stance: AnnotationStance
    public let createdAt: Date
}

public actor AnnotationsRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func add(objectID: UUID, sourceURL: String?, quote: String, note: String?,
                    color: String = "yellow", stance: AnnotationStance = .note) async throws -> UUID {
        let id = UUID()
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await database.exec("""
            INSERT INTO annotations (id, object_id, chunk_id, source_url, quote, note, color, stance, created_at)
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?);
            """, [.uuid(id), .uuid(objectID), sourceURL.map { .text($0) } ?? .null, .text(quote),
                  (trimmedNote?.isEmpty == false ? trimmedNote : nil).map { .text($0) } ?? .null,
                  .text(color), .text(stance.rawValue), .date(Date())])
        return id
    }

    /// Annotations for a document: anchored to it directly, or — after a re-ingest gave the
    /// same file a new object id — to its source file, kept only if the quote is still present.
    public func forDocument(objectID: UUID, sourceURL: String?, currentText: String?) async throws -> [Annotation] {
        var rows = try await database.query(
            "SELECT \(Self.columns) FROM annotations WHERE removed_at IS NULL AND object_id = ? ORDER BY created_at;",
            [.uuid(objectID)])
        if let sourceURL {
            let moved = try await database.query(
                "SELECT \(Self.columns) FROM annotations WHERE removed_at IS NULL AND source_url = ? AND object_id != ? ORDER BY created_at;",
                [.text(sourceURL), .uuid(objectID)])
            rows += moved.filter { r in
                guard let text = currentText, let q = r.string(4) else { return false }
                return text.contains(q)
            }
        }
        return rows.compactMap(Self.decode)
    }

    public func all(limit: Int = 2000) async throws -> [Annotation] {
        try await database.query(
            "SELECT \(Self.columns) FROM annotations WHERE removed_at IS NULL ORDER BY created_at DESC LIMIT ?;",
            [.integer(Int64(limit))]).compactMap(Self.decode)
    }

    public func remove(_ id: UUID) async throws {
        try await database.exec("UPDATE annotations SET removed_at = ? WHERE id = ?;", [.date(Date()), .uuid(id)])
    }

    static let columns = "id, object_id, source_url, color, quote, note, stance, created_at"

    static func decode(_ r: SQLRow) -> Annotation? {
        guard let id = r.uuid(0), let object = r.uuid(1), let quote = r.string(4) else { return nil }
        return Annotation(id: id, objectID: object, sourceURL: r.string(2), quote: quote, note: r.string(5),
                          color: r.string(3) ?? "yellow",
                          stance: AnnotationStance(rawValue: r.string(6) ?? "") ?? .note,
                          createdAt: Date(timeIntervalSince1970: r.double(7) ?? 0))
    }
}
