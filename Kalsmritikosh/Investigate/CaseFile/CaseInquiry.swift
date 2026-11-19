//
//  CaseInquiry.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (REASON-15) — a line of inquiry kept as one canonical record beside its explanation
//  (investigation_hypotheses, unchanged): what it predicts, the observation that would tell it apart, the assumptions it
//  rests on and the methods that raised it; and the append-only decisions on it — pursued, deferred, rejected, merged
//  (reversibly: a later "reopened" undoes a merge or a rejection) or reopened, each with its reason and the fingerprint of
//  the evidence it was made on. A rerun over unchanged evidence never brings a rejected or deferred line back; a changed
//  source may, and says why.
//

import Foundation

public nonisolated struct CaseInquiryLine: Sendable, Equatable {
    public let hypothesisID: UUID
    public let caseID: UUID
    public var predictions: String
    public var discriminator: String
    public var assumptions: String
    public var methods: [String]
    public let revision: Int
    public let updatedBy: String
    public let updatedAt: Date
}

public nonisolated struct CaseInquiryDecision: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case pursued, deferred, rejected, merged, reopened
        public var label: String {
            switch self {
            case .pursued: return "Pursued"
            case .deferred: return "Deferred"
            case .rejected: return "Set aside"
            case .merged: return "Merged into another line"
            case .reopened: return "Reopened"
            }
        }
    }
    public let id: UUID
    public let caseID: UUID
    public let hypothesisID: UUID
    public let decision: Kind
    public let mergedInto: UUID?
    public let reason: String
    public let basisFingerprint: String?
    public let decidedBy: String
    public let decidedAt: Date
}

public nonisolated enum CaseInquiryState {
    /// The decision in force for a line (the latest), nil when none was recorded.
    public static func current(_ decisions: [CaseInquiryDecision], line: UUID) -> CaseInquiryDecision? {
        decisions.filter { $0.hypothesisID == line }.max { ($0.decidedAt, $0.id.uuidString) < ($1.decidedAt, $1.id.uuidString) }
    }

    /// Whether a line set aside (rejected, deferred or merged) should be offered again now: never on unchanged evidence;
    /// when the evidence it was decided on changed, with the exact reason. nil: keep it as decided.
    public static func resurface(_ decisions: [CaseInquiryDecision], line: UUID, currentFingerprint: String?) -> String? {
        guard let d = current(decisions, line: line), [.rejected, .deferred, .merged].contains(d.decision) else { return nil }
        guard let then = d.basisFingerprint, let now = currentFingerprint, then != now else { return nil }
        return "It was \(d.decision.label.lowercased()) on \(d.decidedAt.formatted(date: .abbreviated, time: .omitted)) (\(d.reason)); "
            + "the evidence it was decided on has changed since, so it is offered again for review."
    }
}

nonisolated private final class InquiryBox: @unchecked Sendable { var value: Int; init(_ v: Int) { value = v } }

extension CaseFileRepository {

    /// Record (or revise) what a line of inquiry predicts, what would tell it apart, what it assumes and which methods raised it.
    @discardableResult
    public func recordInquiryLine(caseID: UUID, hypothesisID: UUID, predictions: String, discriminator: String, assumptions: String,
                                  methods: [String], actor: String, at date: Date = Date()) async throws -> Int {
        let who = try Self.clean(actor, "Actor")
        let methodsJSON = String(decoding: (try? JSONEncoder().encode(methods)) ?? Data("[]".utf8), as: UTF8.self)
        let box = InquiryBox(1)
        try await write("cf_inq", caseID: caseID, actor: who, action: "inquiryLineRecorded", detail: hypothesisID.uuidString, at: date) { db in
            guard try !db.query("SELECT 1 FROM investigation_hypotheses WHERE id = ? AND case_id = ?;", [.uuid(hypothesisID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("explanation")
            }
            let rev = Int(try db.query("SELECT revision FROM case_inquiry_lines WHERE hypothesis_id = ?;", [.uuid(hypothesisID)]).first?.int(0) ?? 0) + 1
            box.value = rev
            try db.exec("""
                INSERT INTO case_inquiry_lines (hypothesis_id, case_id, predictions, discriminator, assumptions, methods_json, revision, updated_by, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(hypothesis_id) DO UPDATE SET predictions = excluded.predictions, discriminator = excluded.discriminator,
                    assumptions = excluded.assumptions, methods_json = excluded.methods_json, revision = excluded.revision,
                    updated_by = excluded.updated_by, updated_at = excluded.updated_at;
                """, [.uuid(hypothesisID), .uuid(caseID), .text(predictions), .text(discriminator), .text(assumptions), .text(methodsJSON),
                      .integer(Int64(rev)), .text(who), .date(date)])
        }
        return box.value
    }

    public func inquiryLines(caseID: UUID) async throws -> [CaseInquiryLine] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT hypothesis_id, case_id, predictions, discriminator, assumptions, methods_json, revision, updated_by, updated_at
            FROM case_inquiry_lines WHERE case_id = ? ORDER BY updated_at, hypothesis_id;
            """, [.uuid(caseID)]).compactMap { r in
            guard let h = r.uuid(0), let c = r.uuid(1), let by = r.string(7), let at = r.date(8) else { return nil }
            let methods = (r.string(5).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? []
            return CaseInquiryLine(hypothesisID: h, caseID: c, predictions: r.string(2) ?? "", discriminator: r.string(3) ?? "",
                                   assumptions: r.string(4) ?? "", methods: methods, revision: Int(r.int(6) ?? 1), updatedBy: by, updatedAt: at)
        }
    }

    /// Record a decision on a line, append-only. A merge names the line it joins (in this case, not itself).
    @discardableResult
    public func decideInquiry(caseID: UUID, hypothesisID: UUID, decision: CaseInquiryDecision.Kind, mergedInto: UUID? = nil, reason: String,
                              basisFingerprint: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        if decision == .merged {
            guard let target = mergedInto, target != hypothesisID else { throw CaseWorkError.notInCase("line to merge into") }
        }
        let id = UUID()
        try await write("cf_inqd", caseID: caseID, actor: who, action: "inquiry" + decision.rawValue.capitalized, detail: why, at: date) { db in
            for h in [hypothesisID] + [mergedInto].compactMap({ $0 }) {
                guard try !db.query("SELECT 1 FROM investigation_hypotheses WHERE id = ? AND case_id = ?;", [.uuid(h), .uuid(caseID)]).isEmpty else {
                    throw CaseWorkError.notInCase("explanation")
                }
            }
            try db.exec("""
                INSERT INTO case_inquiry_decisions (id, case_id, hypothesis_id, decision, merged_into, reason, basis_fingerprint, decided_by, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(hypothesisID), .text(decision.rawValue), mergedInto.map { .uuid($0) } ?? .null, .text(why),
                      .optionalText(Self.blankToNil(basisFingerprint)), .text(who), .date(date)])
        }
        return id
    }

    public func inquiryDecisions(caseID: UUID) async throws -> [CaseInquiryDecision] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, hypothesis_id, decision, merged_into, reason, basis_fingerprint, decided_by, decided_at
            FROM case_inquiry_decisions WHERE case_id = ? ORDER BY decided_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let h = r.uuid(2), let k = r.string(3).flatMap(CaseInquiryDecision.Kind.init(rawValue:)),
                  let why = r.string(5), let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseInquiryDecision(id: id, caseID: c, hypothesisID: h, decision: k, mergedInto: r.uuid(4), reason: why,
                                       basisFingerprint: r.string(6), decidedBy: by, decidedAt: at)
        }
    }
}
