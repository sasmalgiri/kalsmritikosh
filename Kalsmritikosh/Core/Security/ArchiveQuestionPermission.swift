//
//  ArchiveQuestionPermission.swift
//  Kalsmritikosh
//
//  AI split AI-49 (owner decision 2026-11-24, recommended default; reversible) — a question asked OUTSIDE a case asks the
//  person ONCE PER QUESTION: "The AI may read documents it finds for this question (privileged and restricted are never
//  sent), up to N documents, about X credits." After Allow, the archive agent's steps for that question run without
//  another preview. Everything else of each send still runs: the cloud gate's clearance (privileged / restricted never
//  cleared), masking, protected identities, the daily and monthly limits, the re-clearance at the send boundary, and the
//  outbound record written before the send.
//
//  The provider trusts nothing here on its own: the permission must be one the person granted (kept in memory, for this
//  question only, ended when the answer is done), for the same AI destination, model and key; the send's clearance must be
//  an unscoped archive-reading clearance from the cloud gate (never a case's); and the distinct documents sent under the
//  question may never exceed the cap the person was shown.
//

import Foundation
import os

public nonisolated struct ArchiveQuestionPermission: Sendable, Equatable {
    /// One asked question (a new id each time a question is asked).
    public let questionID: UUID
    /// The most documents the person allowed the AI to read for this question.
    public let maxDocuments: Int
    public init(questionID: UUID = UUID(), maxDocuments: Int) { self.questionID = questionID; self.maxDocuments = maxDocuments }

    /// The question this task tree is answering (set around the archive agent's run only).
    @TaskLocal public static var current: ArchiveQuestionPermission?

    /// The clearance purpose of an archive reading (ArchiveAgent's sends). A clearance for any other purpose is never covered.
    public static let purpose = "archive.reading"
    /// A question's permission lasts at most this long (a question's agent run is minutes; then it is asked again).
    public static let maxAge: TimeInterval = 30 * 60

    struct Grant: Sendable {
        let maxDocuments: Int
        let identity: String
        let grantedAt: Date
        var sent: Set<UUID>
    }
    private static let grants = OSAllocatedUnfairLock<[UUID: Grant]>(initialState: [:])

    /// The person allowed this question (`identity`: the AI destination, model and key digest it was allowed for).
    public static func grant(_ p: ArchiveQuestionPermission, identity: String, at: Date = Date()) {
        grants.withLock { $0[p.questionID] = Grant(maxDocuments: p.maxDocuments, identity: identity, grantedAt: at, sent: []) }
    }

    /// The question is answered (or abandoned): its permission ends.
    public static func end(_ p: ArchiveQuestionPermission) {
        _ = grants.withLock { $0.removeValue(forKey: p.questionID) }
    }

    /// Whether this question still holds a permission (tests and the agent's own check).
    public static func isGranted(_ p: ArchiveQuestionPermission) -> Bool { grants.withLock { $0[p.questionID] != nil } }

    /// The distinct documents sent under this question so far.
    public static func documentsSent(_ p: ArchiveQuestionPermission) -> Int { grants.withLock { $0[p.questionID]?.sent.count ?? 0 } }

    /// Whether a document send is covered by the question's permission — and, when it is, the documents are counted
    /// against the cap. Covered only when: the permission was granted and is not older than `maxAge`; the AI destination,
    /// model and key are the ones it was granted for; the send carries documents under an unscoped archive-reading
    /// clearance from the cloud gate (never a case's, never without a gate to re-check); and the distinct documents sent
    /// under the question, these included, stay within the cap.
    static func covers(_ p: ArchiveQuestionPermission?, clearance: CloudSourceClearance?, carriesDocuments: Bool,
                       identity: String, now: Date = Date()) -> Bool {
        guard let p, carriesDocuments, let clearance, clearance.binding == nil, clearance.gate != nil,
              clearance.purpose == purpose, !clearance.clearedObjectIDs.isEmpty else { return false }
        return grants.withLock { all in
            guard var g = all[p.questionID], g.maxDocuments == p.maxDocuments, g.identity == identity,
                  now.timeIntervalSince(g.grantedAt) <= maxAge else { return false }
            let union = g.sent.union(clearance.clearedObjectIDs)
            guard union.count <= g.maxDocuments else { return false }
            g.sent = union
            all[p.questionID] = g
            return true
        }
    }
}
