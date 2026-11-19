//
//  CaseDocumentAttribution.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (IN-11, BRIEF-10; schema v196).
//  • Who supplied a case document, the author it claims and when it was captured as written — recorded by a person,
//    kept apart from who entered it and when it was received (the intake record, never edited). Append-only: a later
//    statement is a new row and the earlier ones stay; nothing here verifies the document or its author.
//  • Which version of a brief was given to whom and when, so "what changed since your version" starts from the reader's
//    own version.
//

import Foundation

public nonisolated struct CaseDocumentAttribution: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sourceVersionID: UUID
    public let suppliedBy: String?
    public let claimedAuthor: String?
    public let capturedText: String?
    public let note: String?
    public let recordedBy: String
    public let recordedAt: Date
    /// One line, each part named; never says the document is verified.
    public var line: String {
        var parts: [String] = []
        if let s = suppliedBy { parts.append("supplied by \(s)") }
        if let a = claimedAuthor { parts.append("claims to be by \(a)") }
        if let c = capturedText { parts.append("captured \(c) (as stated)") }
        var out = parts.joined(separator: "; ").capitalizedFirst + " — recorded by \(recordedBy), \(recordedAt.formatted(date: .abbreviated, time: .shortened))"
        if let n = note { out += ". \(n)" }
        return out + ". Not a verification of the document."
    }
}

public nonisolated struct CaseBriefHandover: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let briefID: UUID
    public let givenTo: String
    public let givenBy: String
    public let givenAt: Date
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension CaseFileRepository {

    /// IN-11 — record who supplied a document of this case, the author it claims, or when it was captured (at least one).
    @discardableResult
    public func recordDocumentAttribution(caseID: UUID, sourceVersionID: UUID, suppliedBy: String?, claimedAuthor: String?, capturedText: String?,
                                          note: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let s = Self.blankToNil(suppliedBy), a = Self.blankToNil(claimedAuthor), c = Self.blankToNil(capturedText)
        guard s != nil || a != nil || c != nil else { throw CaseFileError.blank("Who supplied it, its claimed author or when it was captured") }
        let id = UUID()
        try await write("cf_docattr", caseID: caseID, actor: who, action: "documentAttributionRecorded",
                        detail: [s.map { "supplied by \($0)" }, a.map { "author \($0)" }, c.map { "captured \($0)" }].compactMap { $0 }.joined(separator: "; "), at: date) { db in
            guard try Self.versionInCase(db, sourceVersionID, caseID: caseID) else { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_document_attributions (id, case_id, source_version_id, supplied_by, claimed_author, captured_text, note, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(sourceVersionID), .optionalText(s), .optionalText(a), .optionalText(c),
                      .optionalText(Self.blankToNil(note)), .text(who), .date(date)])
        }
        return id
    }

    /// Every statement recorded for the case's documents, oldest first (the latest for a document is its last).
    public func documentAttributions(caseID: UUID) async throws -> [CaseDocumentAttribution] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, source_version_id, supplied_by, claimed_author, captured_text, note, recorded_by, recorded_at
            FROM case_document_attributions WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let v = r.uuid(1), let by = r.string(6), let at = r.date(7) else { return nil }
            return CaseDocumentAttribution(id: id, sourceVersionID: v, suppliedBy: r.string(2), claimedAuthor: r.string(3), capturedText: r.string(4),
                                           note: r.string(5), recordedBy: by, recordedAt: at)
        }
    }

    /// BRIEF-10 — record that a version of a brief was given to a reader.
    @discardableResult
    public func recordBriefHandover(caseID: UUID, briefID: UUID, givenTo: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), to = try Self.clean(givenTo, "Who it was given to")
        let id = UUID()
        try await write("cf_bhand", caseID: caseID, actor: who, action: "briefGiven", detail: "to \(to)", at: date, allowedWhenClosed: true) { db in
            guard try !db.query("SELECT 1 FROM case_briefs WHERE id = ? AND case_id = ?;", [.uuid(briefID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("brief version")
            }
            try db.exec("INSERT INTO case_brief_handovers (id, case_id, brief_id, given_to, given_by, given_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .uuid(briefID), .text(to), .text(who), .date(date)])
        }
        return id
    }

    public func briefHandovers(caseID: UUID) async throws -> [CaseBriefHandover] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("SELECT id, brief_id, given_to, given_by, given_at FROM case_brief_handovers WHERE case_id = ? ORDER BY given_at, rowid;",
                                        [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let b = r.uuid(1), let to = r.string(2), let by = r.string(3), let at = r.date(4) else { return nil }
            return CaseBriefHandover(id: id, briefID: b, givenTo: to, givenBy: by, givenAt: at)
        }
    }

    /// The version last given to `reader` (the start of "what changed since your version").
    public static func lastGiven(_ handovers: [CaseBriefHandover], to reader: String) -> UUID? {
        handovers.last { $0.givenTo.caseInsensitiveCompare(reader.trimmingCharacters(in: .whitespaces)) == .orderedSame }?.briefID
    }
}
