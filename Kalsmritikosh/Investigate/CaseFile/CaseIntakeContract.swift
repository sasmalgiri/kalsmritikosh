//
//  CaseIntakeContract.swift
//  Kalsmritikosh
//
//  Smart-map IN-01 / IN-05 / IN-11 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04) — the one
//  inclusion/provenance contract every intake path into a case produces (schema v178, `case_intake_items`):
//
//  • A document from the case's workspace or from a channel (folder read, file chosen, drop, Share menu, capture, device
//    import) and a typed entry or message each get exactly one record: the channel, where it came from, WHO SUPPLIED it,
//    WHO ENTERED it, WHO IT CLAIMS TO BE WRITTEN BY, WHEN IT WAS CAPTURED (nil = not known, never invented) and WHEN IT
//    WAS ACTUALLY RECEIVED — five separate facts (IN-11).
//  • The scope itself stays in investigation_case_sources (one authority); this records the first decision once — by
//    a person, or by a NAMED trusted-source policy (`case_intake_policies`, IN-05). The database refuses a policy
//    decision that does not name an active policy of the same case.
//  • A typed account is a typed entry: it never becomes a document, and nothing here can set the person-only "verified"
//    mark (CaseFactAttestation) — a typed witness account stays an investigator's entry until a person verifies it.
//
//  Team submissions are not a channel here: they need authenticated multi-user identity and a shared submission service
//  (blocker recorded in the completion matrix). Everything else is local.
//

import Foundation

/// What a trusted-source policy authorises.
public nonisolated enum CaseIntakePolicyRule: String, Sendable, Codable, CaseIterable, Hashable {
    /// The documents the case's workspace held when the case was opened (and what is inside them) — nothing added later.
    case workspaceAtOpening
    /// Documents that arrive through one channel after the policy was made (e.g. items shared to the app).
    case channelArrivals
}

/// A named trusted-source policy of one case. Withdrawn with a reason, never edited.
public nonisolated struct CaseIntakePolicy: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let caseID: UUID
    public let name: String
    public let rule: CaseIntakePolicyRule
    public let channel: IntakeChannel
    /// workspaceAtOpening: only documents added to the workspace (and versions read) up to this time.
    public let coversUntil: Date?
    public let createdBy: String
    public let createdAt: Date
    public let withdrawnBy: String?
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
}

/// The five attribution facts of an item (IN-11), each separate.
public nonisolated struct CaseIntakeAttribution: Sendable, Equatable, Hashable {
    /// Who handed the material over (a witness, a department, a client). Nil: not recorded.
    public var suppliedBy: String?
    /// Who entered it into the app.
    public var enteredBy: String
    /// Who the material says wrote it (its claimed author). Nil: not stated.
    public var claimedAuthor: String?
    /// When the material itself was made or captured (a photo taken, a letter dated). Nil: not known.
    public var capturedAt: Date?
    /// The capture time in the source's own words ("early March 2026").
    public var capturedText: String?
    /// When the app actually received it.
    public var receivedAt: Date

    public init(enteredBy: String, receivedAt: Date, suppliedBy: String? = nil, claimedAuthor: String? = nil,
                capturedAt: Date? = nil, capturedText: String? = nil) {
        self.enteredBy = enteredBy; self.receivedAt = receivedAt; self.suppliedBy = suppliedBy
        self.claimedAuthor = claimedAuthor; self.capturedAt = capturedAt; self.capturedText = capturedText
    }

    /// Trimmed, blanks as nil; the person entering is required.
    func cleaned() throws -> CaseIntakeAttribution {
        func opt(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        guard let who = opt(enteredBy) else { throw CaseIntakeError.blankActor }
        return CaseIntakeAttribution(enteredBy: who, receivedAt: receivedAt, suppliedBy: opt(suppliedBy),
                                     claimedAuthor: opt(claimedAuthor), capturedAt: capturedAt, capturedText: opt(capturedText))
    }
}

public nonisolated enum CaseIntakeContentForm: String, Sendable, Codable, Hashable {
    /// A document (a source version) — the original bytes are kept by custody.
    case sourceDocument
    /// Typed into the case by a person (a journal entry): not a document, not evidence of itself.
    case typedEntry
}

public nonisolated enum CaseIntakeDecision: String, Sendable, Codable, Hashable { case included, excluded }
public nonisolated enum CaseIntakeDecider: String, Sendable, Codable, Hashable { case person, policy }

/// One case-intake contract record.
public nonisolated struct CaseIntakeItem: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let caseID: UUID
    public let channel: IntakeChannel
    public let form: CaseIntakeContentForm
    public let sourceVersionID: UUID?
    public let recordKind: String?
    public let recordID: String?
    public let label: String
    public let provenance: String
    public let ingestRunID: UUID?
    public let attribution: CaseIntakeAttribution
    public let recordedAt: Date
    public let decision: CaseIntakeDecision?
    public let decidedVia: CaseIntakeDecider?
    public let decidedBy: String?
    public let decidedAt: Date?
    public let decisionNote: String?
    public let policyID: UUID?
}

public nonisolated enum CaseIntakeError: Error, Sendable, Equatable, LocalizedError {
    case caseNotFound(UUID)
    case blankActor
    case blankName
    case blankReason
    case policyNotFound(UUID)
    case policyWithdrawn(UUID)
    /// A typed channel (manual entry, message) cannot bring a document, and a document channel cannot carry a typed entry.
    case wrongChannel(IntakeChannel)
    case versionNotFound(UUID)
    case itemNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .caseNotFound: return "The case was not found."
        case .blankActor: return "Say who is entering this."
        case .blankName: return "Give the policy a name."
        case .blankReason: return "Give a reason."
        case .policyNotFound: return "That trusted-source policy was not found."
        case .policyWithdrawn: return "That trusted-source policy has been withdrawn, so it authorises nothing."
        case .wrongChannel(let c): return "\(c.label) cannot carry this kind of item."
        case .versionNotFound: return "That document version is not in the archive."
        case .itemNotFound: return "That intake record was not found."
        }
    }
}

/// Synchronous writers/readers used inside other repositories' savepoints.
public nonisolated enum CaseIntakeRecords {
    static let columns = """
        id, case_id, channel, content_form, source_version_id, record_kind, record_id, label, provenance, ingest_run_id,
        supplied_by, entered_by, claimed_author, captured_at, captured_text, received_at, recorded_at,
        decision, decided_via, decided_by, decided_at, decision_note, policy_id
        """

    static func label(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > 80 ? String(t.prefix(79)) + "…" : (t.isEmpty ? "Entry" : t)
    }

    /// IN-01 / IN-11 — the contract record of a typed entry (a journal note or chronology entry typed by a person, or a message
    /// entered). Written in the SAME savepoint as the entry; the person who typed it decided to put it in the case.
    static func insertTypedEntry(_ db: isolated Database, caseID: UUID, recordID: UUID, text: String, channel: IntakeChannel,
                                 attribution: CaseIntakeAttribution, at date: Date) throws {
        guard channel.isTyped else { throw CaseIntakeError.wrongChannel(channel) }
        let a = try attribution.cleaned()
        let provenance = channel == .message
            ? "Message entered into the case by \(a.enteredBy)" + (a.suppliedBy.map { ", supplied by \($0)" } ?? "")
            : "Typed into the case by \(a.enteredBy)" + (a.suppliedBy.map { ", supplied by \($0)" } ?? "")
        try db.exec("""
            INSERT INTO case_intake_items (\(columns))
            VALUES (?,?,?,'typedEntry',NULL,'journal',?,?,?,NULL,?,?,?,?,?,?,?,'included','person',?,?,NULL,NULL);
            """, [.uuid(UUID()), .uuid(caseID), .text(channel.rawValue), .text(recordID.uuidString), .text(label(text)), .text(provenance),
                  .optionalText(a.suppliedBy), .text(a.enteredBy), .optionalText(a.claimedAuthor), .optionalDate(a.capturedAt),
                  .optionalText(a.capturedText), .date(a.receivedAt), .date(date), .text(a.enteredBy), .date(date)])
    }

    static func decode(_ r: SQLRow) -> CaseIntakeItem? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let channel = r.string(2).flatMap(IntakeChannel.init(rawValue:)),
              let form = r.string(3).flatMap(CaseIntakeContentForm.init(rawValue:)), let label = r.string(7),
              let provenance = r.string(8), let enteredBy = r.string(11), let received = r.date(15), let recorded = r.date(16) else { return nil }
        let attribution = CaseIntakeAttribution(enteredBy: enteredBy, receivedAt: received, suppliedBy: r.string(10),
                                                claimedAuthor: r.string(12), capturedAt: r.date(13), capturedText: r.string(14))
        return CaseIntakeItem(id: id, caseID: caseID, channel: channel, form: form, sourceVersionID: r.uuid(4), recordKind: r.string(5),
                              recordID: r.string(6), label: label, provenance: provenance, ingestRunID: r.uuid(9), attribution: attribution,
                              recordedAt: recorded, decision: r.string(17).flatMap(CaseIntakeDecision.init(rawValue:)),
                              decidedVia: r.string(18).flatMap(CaseIntakeDecider.init(rawValue:)), decidedBy: r.string(19),
                              decidedAt: r.date(20), decisionNote: r.string(21), policyID: r.uuid(22))
    }

    static func decodePolicy(_ r: SQLRow) -> CaseIntakePolicy? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let name = r.string(2),
              let rule = r.string(3).flatMap(CaseIntakePolicyRule.init(rawValue:)),
              let channel = r.string(4).flatMap(IntakeChannel.init(rawValue:)), let by = r.string(6), let at = r.date(7) else { return nil }
        return CaseIntakePolicy(id: id, caseID: caseID, name: name, rule: rule, channel: channel, coversUntil: r.date(5),
                                createdBy: by, createdAt: at, withdrawnBy: r.string(8), withdrawnAt: r.date(9), withdrawnReason: r.string(10))
    }

    static let policyColumns = "id, case_id, name, rule, channel, covers_until, created_by, created_at, withdrawn_by, withdrawn_at, withdrawn_reason"
}

/// The case-intake ledger: trusted-source policies and the contract records of what each case took in.
public actor CaseIntakeLedger {
    private let database: Database
    public init(database: Database) { self.database = database }

    // MARK: - Policies (IN-05)

    public func policies(caseID: UUID) async throws -> [CaseIntakePolicy] {
        try await database.query("SELECT \(CaseIntakeRecords.policyColumns) FROM case_intake_policies WHERE case_id = ? ORDER BY created_at, rowid;",
                                 [.uuid(caseID)]).compactMap(CaseIntakeRecords.decodePolicy)
    }

    public func policy(_ id: UUID) async throws -> CaseIntakePolicy? {
        try await database.query("SELECT \(CaseIntakeRecords.policyColumns) FROM case_intake_policies WHERE id = ?;", [.uuid(id)])
            .first.flatMap(CaseIntakeRecords.decodePolicy)
    }

    /// Every active channel-arrival policy, across cases.
    public func activeArrivalPolicies() async throws -> [CaseIntakePolicy] {
        try await database.query("""
            SELECT \(CaseIntakeRecords.policyColumns) FROM case_intake_policies
            WHERE rule = 'channelArrivals' AND withdrawn_at IS NULL ORDER BY created_at, rowid;
            """, []).compactMap(CaseIntakeRecords.decodePolicy)
    }

    /// The case's opening policy: created the first time (covering what the workspace holds at `date`); the same one after
    /// that. Nil when it was withdrawn — a withdrawn opening policy is never silently re-created with a later cut-off.
    public func openingPolicy(caseID: UUID, actor: String, at date: Date) async throws -> CaseIntakePolicy? {
        try await openingPolicyRecord(caseID: caseID, actor: actor, at: date)?.policy
    }

    /// The opening policy and whether this call created it (the moment it was first recorded is the moment its coverage was
    /// fixed). Nil when it was withdrawn.
    public func openingPolicyRecord(caseID: UUID, actor: String, at date: Date) async throws -> (policy: CaseIntakePolicy, createdNow: Bool)? {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseIntakeError.blankActor }
        let id = UUID()
        let policyID: UUID? = try await database.withSavepoint("cip_open_\(id.uuidString.prefix(8))") { db in
            let existing = try db.query("SELECT id, withdrawn_at FROM case_intake_policies WHERE case_id = ? AND rule = 'workspaceAtOpening' ORDER BY created_at LIMIT 1;",
                                        [.uuid(caseID)]).first
            if let existing {
                return existing.isNull(1) ? existing.uuid(0) : nil
            }
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).isEmpty else { throw CaseIntakeError.caseNotFound(caseID) }
            try db.exec("""
                INSERT INTO case_intake_policies (id, case_id, name, rule, channel, covers_until, created_by, created_at)
                VALUES (?,?,?,'workspaceAtOpening','workspace',?,?,?);
                """, [.uuid(id), .uuid(caseID), .text("Documents in the case's workspace when the case was opened"), .date(date), .text(who), .date(date)])
            return id
        }
        guard let policyID, let made = try await policy(policyID) else { return nil }
        return (made, policyID == id)
    }

    /// The source versions a policy has included in its case (its recorded decisions).
    public func versionsIncluded(byPolicy policyID: UUID) async throws -> Set<UUID> {
        Set(try await database.query("""
            SELECT source_version_id FROM case_intake_items WHERE policy_id = ? AND decided_via = 'policy' AND source_version_id IS NOT NULL;
            """, [.uuid(policyID)]).compactMap { $0.uuid(0) })
    }

    /// A person's trusted-source policy: documents that arrive through `channel` from now on are included in the case
    /// automatically, each inclusion naming this policy. Only arrivals after `date` are covered (never retroactive).
    public func createArrivalPolicy(caseID: UUID, name: String, channel: IntakeChannel, actor: String, at date: Date) async throws -> CaseIntakePolicy {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseIntakeError.blankActor }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaseIntakeError.blankName }
        guard !channel.isTyped, channel != .workspace else { throw CaseIntakeError.wrongChannel(channel) }
        let id = UUID()
        try await database.withSavepoint("cip_new_\(id.uuidString.prefix(8))") { db in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).isEmpty else { throw CaseIntakeError.caseNotFound(caseID) }
            try db.exec("""
                INSERT INTO case_intake_policies (id, case_id, name, rule, channel, covers_until, created_by, created_at)
                VALUES (?,?,?,'channelArrivals',?,NULL,?,?);
                """, [.uuid(id), .uuid(caseID), .text(title), .text(channel.rawValue), .text(who), .date(date)])
            try Self.logAction(db, caseID: caseID, actor: who, action: "intakePolicyCreated", detail: "\(title) (\(channel.label))", at: date)
        }
        guard let made = try await policy(id) else { throw CaseIntakeError.policyNotFound(id) }
        return made
    }

    /// Withdraw a policy with a reason. Inclusions it authorised stay (each is recorded); it authorises nothing more.
    public func withdrawPolicy(_ id: UUID, reason: String, actor: String, at date: Date) async throws {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseIntakeError.blankActor }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw CaseIntakeError.blankReason }
        try await database.withSavepoint("cip_wd_\(id.uuidString.prefix(8))") { db in
            guard let row = try db.query("SELECT case_id, withdrawn_at, name FROM case_intake_policies WHERE id = ?;", [.uuid(id)]).first,
                  let caseID = row.uuid(0) else { throw CaseIntakeError.policyNotFound(id) }
            guard row.isNull(1) else { throw CaseIntakeError.policyWithdrawn(id) }
            try db.exec("UPDATE case_intake_policies SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;",
                        [.text(who), .date(date), .text(why), .uuid(id)])
            try Self.logAction(db, caseID: caseID, actor: who, action: "intakePolicyWithdrawn", detail: "\(row.string(2) ?? ""): \(why)", at: date)
        }
    }

    // MARK: - Items (IN-01 / IN-11)

    /// The contract record of a document offered to the case (idempotent per case and version: a second arrival of the same
    /// version returns the first record — its receipt stays in the batch that read it).
    public func recordSourceArrival(caseID: UUID, sourceVersionID: UUID, channel: IntakeChannel, label: String, provenance: String,
                                    ingestRunID: UUID?, attribution: CaseIntakeAttribution, at date: Date) async throws -> CaseIntakeItem {
        guard !channel.isTyped else { throw CaseIntakeError.wrongChannel(channel) }
        let a = try attribution.cleaned()
        let id = UUID()
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanProvenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemID: UUID = try await database.withSavepoint("cii_arr_\(id.uuidString.prefix(8))") { db in
            if let existing = try db.query("SELECT id FROM case_intake_items WHERE case_id = ? AND source_version_id = ?;",
                                           [.uuid(caseID), .uuid(sourceVersionID)]).first?.uuid(0) {
                return existing
            }
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).isEmpty else { throw CaseIntakeError.caseNotFound(caseID) }
            guard try !db.query("SELECT 1 FROM source_versions WHERE id = ?;", [.uuid(sourceVersionID)]).isEmpty else { throw CaseIntakeError.versionNotFound(sourceVersionID) }
            try db.exec("""
                INSERT INTO case_intake_items (\(CaseIntakeRecords.columns))
                VALUES (?,?,?,'sourceDocument',?,NULL,NULL,?,?,?,?,?,?,?,?,?,?,NULL,NULL,NULL,NULL,NULL,NULL);
                """, [.uuid(id), .uuid(caseID), .text(channel.rawValue), .uuid(sourceVersionID),
                      .text(cleanLabel.isEmpty ? "Source \(sourceVersionID.uuidString.prefix(8))" : cleanLabel),
                      .text(cleanProvenance.isEmpty ? channel.label : cleanProvenance), ingestRunID.map { SQLValue.uuid($0) } ?? .null,
                      .optionalText(a.suppliedBy), .text(a.enteredBy), .optionalText(a.claimedAuthor), .optionalDate(a.capturedAt),
                      .optionalText(a.capturedText), .date(a.receivedAt), .date(date)])
            return id
        }
        guard let recorded = try await self.item(itemID) else { throw CaseIntakeError.itemNotFound(itemID) }
        return recorded
    }

    /// Record the first decision on an item, once. A later decision (the person changing their mind through the case's
    /// scope controls) is a case event; this keeps how the item first entered. Returns false when it was already decided.
    @discardableResult
    public func recordDecision(itemID: UUID, decision: CaseIntakeDecision, via: CaseIntakeDecider, policyID: UUID?,
                               actor: String, note: String?, at date: Date) async throws -> Bool {
        let who = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw CaseIntakeError.blankActor }
        if via == .policy {
            guard let policyID else { throw CaseIntakeError.policyNotFound(itemID) }
            guard let p = try await policy(policyID) else { throw CaseIntakeError.policyNotFound(policyID) }
            guard p.isActive else { throw CaseIntakeError.policyWithdrawn(policyID) }
        }
        return try await database.withSavepoint("cii_dec_\(itemID.uuidString.prefix(8))") { db in
            guard let row = try db.query("SELECT decided_at FROM case_intake_items WHERE id = ?;", [.uuid(itemID)]).first else {
                throw CaseIntakeError.itemNotFound(itemID)
            }
            guard row.isNull(0) else { return false }
            try db.exec("""
                UPDATE case_intake_items SET decision = ?, decided_via = ?, decided_by = ?, decided_at = ?, decision_note = ?, policy_id = ?
                WHERE id = ? AND decided_at IS NULL;
                """, [.text(decision.rawValue), .text(via.rawValue), .text(who), .date(date), .optionalText(note),
                      via == .policy ? (policyID.map { SQLValue.uuid($0) } ?? .null) : .null, .uuid(itemID)])
            return true
        }
    }

    public func item(_ id: UUID) async throws -> CaseIntakeItem? {
        try await database.query("SELECT \(CaseIntakeRecords.columns) FROM case_intake_items WHERE id = ?;", [.uuid(id)])
            .first.flatMap(CaseIntakeRecords.decode)
    }

    public func items(caseID: UUID) async throws -> [CaseIntakeItem] {
        try await database.query("SELECT \(CaseIntakeRecords.columns) FROM case_intake_items WHERE case_id = ? ORDER BY received_at, rowid;",
                                 [.uuid(caseID)]).compactMap(CaseIntakeRecords.decode)
    }

    /// The contract record of a typed entry, by the journal entry it records.
    public func typedEntry(caseID: UUID, journalID: UUID) async throws -> CaseIntakeItem? {
        try await database.query("SELECT \(CaseIntakeRecords.columns) FROM case_intake_items WHERE case_id = ? AND record_kind = 'journal' AND record_id = ?;",
                                 [.uuid(caseID), .text(journalID.uuidString)]).first.flatMap(CaseIntakeRecords.decode)
    }

    // MARK: - Reads the workspace intake needs

    /// When each file was added to the workspace (file id → time).
    public func workspaceAddedAt(_ workspaceID: UUID) async throws -> [UUID: Date] {
        var out: [UUID: Date] = [:]
        for r in try await database.query("SELECT file_id, added_at FROM workspace_sources WHERE workspace_id = ?;", [.uuid(workspaceID)]) {
            if let f = r.uuid(0), let at = r.date(1) { out[f] = at }
        }
        return out
    }

    /// When each version was received into the archive (version → its intake time).
    public func receivedAt(_ versions: [UUID]) async throws -> [UUID: Date] {
        let unique = Array(Set(versions))
        guard !unique.isEmpty else { return [:] }
        var out: [UUID: Date] = [:]
        for start in stride(from: 0, to: unique.count, by: 400) {
            let chunk = Array(unique[start..<min(start + 400, unique.count)])
            let rows = try await database.query("""
                SELECT id, coalesce(intake_recorded_at, created_at) FROM source_versions WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")));
                """, chunk.map { .uuid($0) })
            for r in rows { if let v = r.uuid(0), let at = r.date(1) { out[v] = at } }
        }
        return out
    }

    // MARK: - Internals

    /// The case's action log line for a policy change (the same log every case write uses).
    static func logAction(_ db: isolated Database, caseID: UUID, actor: String, action: String, detail: String, at date: Date) throws {
        let next = (try db.query("SELECT COALESCE(MAX(sequence), 0) FROM case_actions WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? 0) + 1
        try db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                    [.uuid(UUID()), .uuid(caseID), .integer(next), .text(actor), .text(action), .text(String(detail.prefix(500))), .date(date)])
    }
}
