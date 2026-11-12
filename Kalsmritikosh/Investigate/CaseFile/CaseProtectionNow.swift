//
//  CaseProtectionNow.swift
//  Kalsmritikosh
//
//  Smart-map S16 (SEC-06) — whether cited material is privileged NOW, read through its whole lineage. The export
//  eligibility (`InvestigationDataLabService.eligibleSourceVersions`) reads labels put on a source VERSION; a document is
//  also marked privileged on its FILE (the usual route), on one of its RECORDS (knowledge objects), or coded privileged
//  in review. Any of those, live (not revoked / not removed), makes the citation privileged here. Read inside the
//  caller's savepoint at the moment of use (release, send), so protection added after a draft was built stops it.
//

import Foundation

public nonisolated enum CaseProtectionNow {

    /// How many of `versions` (source version ids) and `objects` (record ids cited without a version) are privileged now.
    static func privilegedCount(_ db: isolated Database, versions: Set<UUID>, objects: Set<UUID>) throws -> Int {
        var count = 0
        for v in versions where try versionPrivileged(db, v) { count += 1 }
        for o in objects where try objectPrivileged(db, o) { count += 1 }
        return count
    }

    /// The version itself, its file, any record of its file, or a review code on any record of its file.
    static func versionPrivileged(_ db: isolated Database, _ version: UUID) throws -> Bool {
        let v = version.uuidString.uppercased()
        return try !db.query("""
            SELECT 1 FROM source_versions sv
             WHERE upper(sv.id) = ? AND (
                   EXISTS (SELECT 1 FROM sensitive_scope_assignments a
                            WHERE a.revoked_at IS NULL AND a.privileged = 1
                              AND ((a.target_kind = 'sourceVersion' AND upper(a.target_id) = upper(sv.id))
                                OR (a.target_kind = 'file' AND upper(a.target_id) = upper(sv.logical_source_id))))
                OR EXISTS (SELECT 1 FROM knowledge_objects ko JOIN sensitive_scope_assignments a ON upper(a.target_id) = upper(ko.id)
                            WHERE upper(ko.file_id) = upper(sv.logical_source_id) AND a.target_kind = 'knowledgeObject'
                              AND a.revoked_at IS NULL AND a.privileged = 1)
                OR EXISTS (SELECT 1 FROM knowledge_objects ko JOIN review_codes rc ON upper(rc.object_id) = upper(ko.id)
                            WHERE upper(ko.file_id) = upper(sv.logical_source_id) AND rc.code = 'privileged' AND rc.removed_at IS NULL))
             LIMIT 1;
            """, [.text(v)]).isEmpty
    }

    /// A record cited without a version: its own label or review code, or its file's label.
    static func objectPrivileged(_ db: isolated Database, _ object: UUID) throws -> Bool {
        let o = object.uuidString.uppercased()
        return try !db.query("""
            SELECT 1 WHERE
                   EXISTS (SELECT 1 FROM sensitive_scope_assignments a
                            WHERE a.revoked_at IS NULL AND a.privileged = 1 AND a.target_kind = 'knowledgeObject' AND upper(a.target_id) = ?)
                OR EXISTS (SELECT 1 FROM review_codes rc WHERE upper(rc.object_id) = ? AND rc.code = 'privileged' AND rc.removed_at IS NULL)
                OR EXISTS (SELECT 1 FROM knowledge_objects ko JOIN sensitive_scope_assignments a ON upper(a.target_id) = upper(ko.file_id)
                            WHERE upper(ko.id) = ? AND a.target_kind = 'file' AND a.revoked_at IS NULL AND a.privileged = 1);
            """, [.text(o), .text(o), .text(o)]).isEmpty
    }
}
