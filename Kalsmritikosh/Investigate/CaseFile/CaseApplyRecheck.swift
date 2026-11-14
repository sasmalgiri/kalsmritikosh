//
//  CaseApplyRecheck.swift
//  Kalsmritikosh
//
//  Smart-map S16 (ARCH-09) — work prepared outside a write (an AI run's configured effects, an accepted AI proposal, a
//  job-result row carried into the case) is checked again INSIDE the savepoint that applies it, not only before. The
//  caller binds a check for the duration of the apply (`CaseApplyRecheck.$current`); every case-file write and every map
//  link write runs it inside its own savepoint before its body, so a document that left the case, a source version that
//  was replaced or erased, or a job result superseded while the work was in flight refuses the write and leaves nothing.
//  Compensating writes (cancelling a half-made action) run with the check unbound.
//

import Foundation

public nonisolated enum CaseApplyRecheck {
    public typealias Check = @Sendable (isolated Database, UUID) throws -> Void

    /// The check bound for the current apply (nil: an ordinary write, only the per-write gate applies).
    @TaskLocal public static var current: Check? = nil

    /// Why applying is refused now.
    public struct Refused: Error, Equatable, LocalizedError {
        public let reason: String
        public var errorDescription: String? { "Not applied: \(reason) Nothing was changed." }
    }

    /// Run the bound check inside the caller's savepoint.
    static func run(_ db: isolated Database, caseID: UUID) throws {
        guard let check = current else { return }
        try check(db, caseID)
    }

    /// Run `body` with the check unbound (a compensating write must not be refused by the check that failed).
    static func unbound<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        try await $current.withValue(nil) { try await body() }
    }

    // MARK: Checks

    /// Every input version is still in the case's scope and still the current version of its document (AI proposals).
    public static func inputsCurrent(_ versions: [UUID]) -> Check {
        { db, caseID in
            for v in versions {
                guard try CaseFileRepository.versionInCase(db, v, caseID: caseID) else {
                    throw Refused(reason: "a document it rests on is no longer in the case.")
                }
                let current = try db.query("SELECT is_current FROM source_versions WHERE id IN (?, ?, ?);",
                                           [.text(v.uuidString), .text(v.uuidString.lowercased()), .uuid(v)]).first?.int(0)
                if current != 1 { throw Refused(reason: current == nil ? "a document it rests on was erased." : "a document it rests on has a newer version.") }
            }
        }
    }

    /// The case's automation policy is still at `version` (configured execution applies only under the policy it ran under).
    public static func policyUnchanged(_ version: Int) -> Check {
        { db, caseID in
            let now = try CaseAutomationPolicyStore.current(db, caseID: caseID).version
            if now != version { throw Refused(reason: "the case's AI policy changed (version \(version) → \(now)).") }
        }
    }

    /// The carried job result is still the case's current, intact revision of that job, and every reference that resolved
    /// when the row was read still resolves (a reference that did not resolve then is carried as it was, marked).
    public static func carriedRowIntact(resultID: UUID, jobID: String, digest: String, references: [CaseTypedReference]) -> Check {
        { db, caseID in
            guard let row = try db.query("SELECT case_id, job_id, state, payload_sha256, created_at FROM job_results WHERE id = ? LIMIT 1;",
                                         [.uuid(resultID)]).first else {
                throw Refused(reason: "the job result it came from is no longer saved.")
            }
            guard row.uuid(0) == caseID, row.string(1) == jobID, row.string(3) == digest else {
                throw Refused(reason: "the job result it came from changed after it was read.")
            }
            guard row.string(2) != JobResultState.superseded.rawValue else {
                throw Refused(reason: "the job result it came from was superseded by a newer run.")
            }
            let newest = try db.query("""
                SELECT id FROM job_results WHERE case_id = ? AND job_id = ? AND state <> 'superseded' ORDER BY created_at DESC LIMIT 1;
                """, [.uuid(caseID), .text(jobID)]).first?.uuid(0)
            guard newest == resultID else { throw Refused(reason: "a newer run of this job was saved; carry from the current result.") }
            try referencesStillResolve(references)(db, caseID)
        }
    }

    /// Each reference that was available when the work was prepared is still available now.
    public static func referencesStillResolve(_ references: [CaseTypedReference]) -> Check {
        { db, caseID in
            for r in references where r.availability == .available || r.availability == .positionUnavailable {
                guard let v = r.sourceVersionID else { continue }
                let source = CaseMapSourceRef(sourceVersionID: v, objectID: r.objectID, blockID: r.locator.blockID, documentName: nil,
                                              quote: r.locator.note == nil ? "-" : nil)
                let now = try CaseTypedReferences.resolve(db, caseID: caseID, holder: r.holder, source: source, provenance: r.provenance,
                                                          scopeFingerprint: r.scopeFingerprint).availability
                switch now {
                case .available, .positionUnavailable: continue
                default: throw Refused(reason: "a cited source changed while it was being carried (\(now.label)).")
                }
            }
        }
    }

    /// Several checks, in order.
    public static func all(_ checks: [Check]) -> Check {
        { db, caseID in for c in checks { try c(db, caseID) } }
    }
}
