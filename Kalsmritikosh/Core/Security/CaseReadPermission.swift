//
//  CaseReadPermission.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — permission to send a case's documents to the person's AI reader is
//  asked ONCE PER CASE (App Store guideline 5.1.2(i): say where personal data goes to a third-party AI
//  and get explicit permission), not on every question. What was allowed is pinned to a fingerprint of
//  the exact document set that may be sent (each cleared document and its source versions): a document
//  added to the case, a new version, or a document that becomes sendable changes the fingerprint and
//  the person is asked again. Optionally a permission also lapses after a set time (default: never —
//  until the case's documents change).
//
//  The Online provider checks the same store at the send boundary, recomputing the fingerprint from
//  the request's own clearance — a caller cannot send a document set the person did not allow.
//

import Foundation
import CryptoKit
import os

public nonisolated struct CaseReadPermission: Codable, Sendable, Equatable {
    public let caseID: UUID
    public let fingerprint: String
    public let grantedAt: Date
    public let documentCount: Int
    /// Where the person allowed the documents to go (the Online provider: own key directly to Anthropic,
    /// or an AI plan through the publisher's relay). A permission for one destination never covers the
    /// other: switching asks again (candidate review LS3). nil = a permission stored before this field.
    public let destination: String?
    /// S10 (AI-03) — the model the person allowed the documents to be read by, and a digest of their own key (never the key;
    /// nil for an AI plan, whose account the destination already names). Replacing the key or choosing another model asks
    /// again. nil on a permission stored before S10: it asks again once, when the current identity is tracked.
    public let model: String?
    public let credentialDigest: String?
    public init(caseID: UUID, fingerprint: String, grantedAt: Date, documentCount: Int, destination: String? = nil,
                model: String? = nil, credentialDigest: String? = nil) {
        self.caseID = caseID; self.fingerprint = fingerprint; self.grantedAt = grantedAt; self.documentCount = documentCount
        self.destination = destination; self.model = model; self.credentialDigest = credentialDigest
    }

    /// A short, salted digest of an own key: enough to tell that the key was replaced, useless for recovering it.
    public static func credentialDigest(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let d = SHA256.hash(data: Data(("kalsmritikosh.caseRead.key.v1|" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return String(d.prefix(16))
    }

    /// The fingerprint of a document set: SHA-256 over the sorted, length-prefixed (document, versions)
    /// pairs, keyed by the case. Order-independent; any added, removed or re-versioned document changes it.
    public static func fingerprint(caseID: UUID, versions: [UUID: Set<UUID>]) -> String {
        func field(_ k: String, _ v: String) -> String { "\(k):\(v.utf8.count):\(v)\n" }
        var canonical = field("v", "caseread-v1") + field("case", caseID.uuidString) + field("count", String(versions.count))
        for id in versions.keys.map(\.uuidString).sorted() {
            canonical += field("doc", id)
            let vs = (UUID(uuidString: id).flatMap { versions[$0] } ?? []).map(\.uuidString).sorted()
            for v in vs { canonical += field("sv", v) }
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The document set a case permission was given for, carried (task-local) into the sends a case makes
/// from PASSAGES of those documents — a case too large to read whole, or an analysis that falls back to
/// passages. The person allowed these documents once for the case; a send whose every passage comes from
/// them, at a permitted version, under a clearance bound to the same case, is covered by that permission
/// and shows no second per-send preview. Everything else of the send still runs (masking, protected
/// identities, the daily limit, re-clearance at the send, the record before the send).
///
/// The provider trusts nothing here on its own: it recomputes the fingerprint from `versions` and checks
/// it against the stored permission, so a caller cannot widen the set the person allowed.
public nonisolated struct CaseReadPermittedSet: Sendable, Equatable {
    public let caseID: UUID
    /// Each permitted document → its permitted source versions (the case read's own clearance).
    public let versions: [UUID: Set<UUID>]
    public init(caseID: UUID, versions: [UUID: Set<UUID>]) { self.caseID = caseID; self.versions = versions }

    @TaskLocal public static var current: CaseReadPermittedSet?

    public var fingerprint: String { CaseReadPermission.fingerprint(caseID: caseID, versions: versions) }

    /// Whether every document `clearance` clears is one of these, at a permitted version, and the
    /// clearance is bound to this case. A clearance without versions or binding is never covered.
    public func covers(_ clearance: CloudSourceClearance) -> Bool {
        guard let binding = clearance.binding, binding.scopeID == caseID, !clearance.clearedObjectIDs.isEmpty else { return false }
        return clearance.clearedObjectIDs.allSatisfy { id in
            guard let permitted = versions[id], let sent = clearance.versions[id], !sent.isEmpty else { return false }
            return sent.isSubset(of: permitted)
        }
    }
}

/// LN1 (Package B 2026-11-06) — the case a question is being asked in, for the sends that carry no source
/// clearance (the question interpreter and rewriter send only the question). The outbound record of such a
/// send carries the case's marker, so erasing the case also replaces the question text it sent. Set by the
/// case answer service around a question asked in a case; nil everywhere else. It widens nothing: it only
/// labels the record.
public nonisolated enum CaseSendScope {
    @TaskLocal public static var caseID: UUID?
}

/// Where case permissions are kept. Live: the app's defaults (a preference of the person, not ledger
/// data — erasing a case also revokes it, and "Stop AI for this case" in the case file). Tests: in memory.
public final nonisolated class CaseReadPermissionStore: Sendable {
    private let load: @Sendable (UUID) -> CaseReadPermission?
    private let save: @Sendable (CaseReadPermission?, UUID) -> Void
    /// How long a permission lasts; nil = until the case's documents change (the default).
    private let maxAge: @Sendable () -> TimeInterval?
    /// The destination the documents would go to now (nil = not tracked, tests).
    private let destination: @Sendable () -> String?
    /// S10 (AI-03) — the model and own-key digest the documents would be read with now (nil = not tracked, tests).
    private let account: @Sendable () -> (model: String?, credentialDigest: String?)?

    public init(load: @escaping @Sendable (UUID) -> CaseReadPermission?,
                save: @escaping @Sendable (CaseReadPermission?, UUID) -> Void,
                maxAge: @escaping @Sendable () -> TimeInterval? = { nil },
                destination: @escaping @Sendable () -> String? = { nil },
                account: @escaping @Sendable () -> (model: String?, credentialDigest: String?)? = { nil }) {
        self.load = load; self.save = save; self.maxAge = maxAge; self.destination = destination; self.account = account
    }

    /// The permission for exactly this document set and this destination, still in force at `now`.
    public func isGranted(caseID: UUID, fingerprint: String, now: Date = Date()) -> Bool {
        guard let p = load(caseID), p.fingerprint == fingerprint else { return false }
        if let age = maxAge(), now.timeIntervalSince(p.grantedAt) > age { return false }
        // LS3 — allowed for the own key (directly to Anthropic) is not allowed for an AI plan (through the
        // publisher's relay), nor the other way round: the person is asked again.
        if let current = destination(), p.destination != current { return false }
        // S10 (AI-03) — allowed for one model and one own key is not allowed for another: replacing the key or choosing
        // another model asks again (the document set and destination alone did not).
        if let now = account() {
            if p.model != now.model { return false }
            if p.credentialDigest != now.credentialDigest { return false }
        }
        return true
    }

    /// Why a stored permission does not cover a send now (nil: it does, or none is stored). For the consent sheet and the
    /// assistant's refusal: the person is told what changed.
    public func lapsedReason(caseID: UUID, fingerprint: String, now: Date = Date()) -> String? {
        guard let p = load(caseID) else { return nil }
        if p.fingerprint != fingerprint { return "the case's documents changed since you allowed them" }
        if let age = maxAge(), now.timeIntervalSince(p.grantedAt) > age { return "the permission lapsed after the time you set" }
        if let current = destination(), p.destination != current { return "the AI destination changed (own key ↔ AI plan)" }
        if let a = account() {
            if p.model != a.model { return "the AI model changed" }
            if p.credentialDigest != a.credentialDigest { return "the API key was replaced" }
        }
        return nil
    }

    public func permission(caseID: UUID) -> CaseReadPermission? { load(caseID) }

    /// S10 (AI-03) — what a permission would be bound to if given now (destination, model, own-key digest). The consent
    /// sheet compares it before and after the person answers: a change while the sheet was open voids that answer.
    public func currentIdentity() -> String {
        let a = account()
        return [destination() ?? "-", a?.model ?? "-", a?.credentialDigest ?? "-"].joined(separator: "|")
    }

    public func grant(caseID: UUID, fingerprint: String, documentCount: Int, at: Date = Date()) {
        let a = account()
        save(CaseReadPermission(caseID: caseID, fingerprint: fingerprint, grantedAt: at, documentCount: documentCount,
                                destination: destination(), model: a?.model, credentialDigest: a?.credentialDigest), caseID)
    }

    public func revoke(caseID: UUID) { save(nil, caseID) }
    /// LS4 — the person withdrew the AI permission of one case ("Stop AI for this case", or erasing the case).
    /// (A separate name from `revoke`, which ci/guards/sensitive-scope-mutation-bypass.sh reserves.)
    public func withdraw(caseID: UUID) { save(nil, caseID) }

    // MARK: - Live and test stores

    static let keyPrefix = "kalsmritikosh.caseRead.permission."
    /// Days after which a case permission lapses (unset or 0 = until the case's documents change).
    public static let reaskAfterDaysKey = "kalsmritikosh.caseRead.reaskAfterDays"

    public static let live = CaseReadPermissionStore(
        load: { id in
            #if DEBUG
            if UIWalkSimulatedPlan.isActive { return UIWalkSimulatedPlan.permissions.withLock { $0[id] } }   // GUI walk: memory only
            #endif
            guard let data = UserDefaults.standard.data(forKey: keyPrefix + id.uuidString) else { return nil }
            do { return try JSONDecoder().decode(CaseReadPermission.self, from: data) } catch {
                KalsmritikoshLog.app.error("case read permission unreadable: \(String(describing: error), privacy: .public)")
                return nil
            }
        },
        save: { p, id in
            #if DEBUG
            if UIWalkSimulatedPlan.isActive { UIWalkSimulatedPlan.permissions.withLock { $0[id] = p }; return }   // GUI walk: memory only
            #endif
            guard let p else { UserDefaults.standard.removeObject(forKey: keyPrefix + id.uuidString); return }
            do { UserDefaults.standard.set(try JSONEncoder().encode(p), forKey: keyPrefix + id.uuidString) } catch {
                KalsmritikoshLog.app.error("case read permission not saved: \(String(describing: error), privacy: .public)")
            }
        },
        maxAge: {
            let days = UserDefaults.standard.integer(forKey: reaskAfterDaysKey)
            return days > 0 ? TimeInterval(days) * 86_400 : nil
        },
        destination: { OnlineSettings.kind.rawValue },
        account: {
            let kind = OnlineSettings.kind
            // An AI plan's account is the destination itself (its signed subscription renews); an own key is bound.
            return (OnlineSettings.model, kind == .included ? nil : CaseReadPermission.credentialDigest(OnlineSettings.apiKey(for: kind)))
        })

    /// An in-memory store (tests, simulations).
    public static func inMemory(maxAge: TimeInterval? = nil,
                                destination: @escaping @Sendable () -> String? = { nil },
                                account: @escaping @Sendable () -> (model: String?, credentialDigest: String?)? = { nil }) -> CaseReadPermissionStore {
        let box = OSAllocatedUnfairLock(initialState: [UUID: CaseReadPermission]())
        return CaseReadPermissionStore(load: { id in box.withLock { $0[id] } },
                                       save: { p, id in box.withLock { $0[id] = p } },
                                       maxAge: { maxAge }, destination: destination, account: account)
    }
}
