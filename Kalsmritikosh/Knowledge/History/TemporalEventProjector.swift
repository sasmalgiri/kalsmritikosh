//
//  TemporalEventProjector.swift
//  Kalsmritikosh
//
//  HIST-023 (Universal History program, Phase 4). Deterministically projects the
//  collected material into the temporal layer:
//    • Assertions + GenericFacts → TemporalClaims (facts true over time).
//    • Events + TemporalClaims   → HistoryItems (the universal unit).
//  Rules (§13): deterministic mappings only; source references PRESERVED; projection
//  is IDEMPOTENT and content-hash deduplicated (re-projecting yields the same ids);
//  a model-proposed input never becomes canonical truth (status carried through);
//  undated material stays undated (no guessed dates). LLM-free.
//

import Foundation
import CryptoKit

public struct TemporalEventProjector: Sendable {
    public let extractorID: String
    public let extractorVersion: String
    /// Injected clock (tests pass a fixed date so projected `createdAt` is stable).
    public let now: Date

    public init(extractorID: String = "TemporalEventProjector", extractorVersion: String = "1", now: Date) {
        self.extractorID = extractorID; self.extractorVersion = extractorVersion; self.now = now
    }

    // MARK: - Claims from assertions + generic facts

    public func projectClaims(from material: HistoryMaterial) -> [TemporalClaim] {
        guard let subjectID = material.subject.canonicalEntityID else { return [] }
        var byID: [UUID: TemporalClaim] = [:]

        for a in material.assertions {
            let predicate = HistoryPredicate.normalize(a.predicate)
            let object = Self.claimValue(from: a.object)
            let cid = Self.claimID(subject: subjectID, predicate: predicate, object: object)
            byID[cid] = TemporalClaim(
                id: cid, subjectID: subjectID, predicate: predicate, object: object,
                status: Self.status(from: a.provenance), confidence: a.confidence,
                sourceObjectIDs: a.evidenceObjectIDs, sourceBlockIDs: a.evidenceBlockIDs,
                assertionIDs: [a.id], extractorID: extractorID, extractorVersion: extractorVersion, createdAt: now)
        }

        for f in material.genericFacts {
            let predicate = Self.predicate(forField: f.field)
            let object = ClaimValue.literal(f.value)
            let cid = Self.claimID(subject: subjectID, predicate: predicate, object: object)
            // If an assertion already produced this exact claim, merge the fact's
            // evidence in rather than duplicating (idempotent / content-hash key).
            if let existing = byID[cid] {
                byID[cid] = TemporalClaim(
                    id: cid, subjectID: subjectID, predicate: predicate, object: object,
                    validFrom: existing.validFrom, validTo: existing.validTo, observedAt: existing.observedAt,
                    status: existing.status, confidence: max(existing.confidence, f.confidence),
                    sourceObjectIDs: existing.sourceObjectIDs,
                    sourceBlockIDs: Array(Set(existing.sourceBlockIDs).union(f.sourceBlockIDs)),
                    assertionIDs: existing.assertionIDs, genericFactIDs: existing.genericFactIDs + [f.id],
                    extractorID: extractorID, extractorVersion: extractorVersion, createdAt: now)
            } else {
                byID[cid] = TemporalClaim(
                    id: cid, subjectID: subjectID, predicate: predicate, object: object,
                    status: f.status, confidence: f.confidence,
                    sourceBlockIDs: f.sourceBlockIDs, genericFactIDs: [f.id],
                    extractorID: extractorID, extractorVersion: extractorVersion, createdAt: now)
            }
        }
        return byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - History items from events + claims

    public func projectItems(from material: HistoryMaterial, claims: [TemporalClaim]) -> [HistoryItem] {
        let subject = material.subject.subject
        var byID: [UUID: HistoryItem] = [:]

        // Direct event projection — events already carry dates.
        for e in material.events {
            let start = TemporalValue(start: e.date, end: e.endDate, precision: e.datePrecision,
                                      originalText: nil, confidence: e.dateConfidence)
            let hid = Self.itemID(kind: "event", key: e.id.uuidString)
            byID[hid] = HistoryItem(
                id: hid, subject: subject, kind: Self.itemKind(for: e.kind),
                title: e.title, description: e.summary, start: start,
                actors: e.entityIDs,
                evidenceStatus: Self.status(from: e.status), confidence: e.confidence.value,
                evidence: [EvidenceReference(objectID: e.sourceObjectID, eventID: e.id)],
                derivedFrom: [DerivedReference(kind: .event, id: e.id)])
        }

        // Claim projection — a claim becomes a period / state / milestone item.
        for c in claims {
            let hid = Self.itemID(kind: "claim", key: c.id.uuidString)
            let evidence = c.sourceObjectIDs.map { EvidenceReference(objectID: $0) }
            byID[hid] = HistoryItem(
                id: hid, subject: subject, kind: Self.itemKind(forPredicate: c.predicate, hasEnd: c.validTo != nil),
                title: Self.title(for: c), description: nil,
                start: c.validFrom, end: c.validTo,
                evidenceStatus: c.status, confidence: c.confidence,
                evidence: evidence,
                derivedFrom: [DerivedReference(kind: .temporalClaim, id: c.id)])
        }
        return byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Deterministic mappings

    static func claimValue(from o: Assertion.Object) -> ClaimValue {
        switch o {
        case .entity(let id): return .entity(id)
        case .event(let id):  return .literal(id.uuidString)
        case .literal(let s): return .literal(s)
        }
    }

    static func status(from p: Assertion.Provenance) -> EvidenceStatus {
        switch p {
        case .sourceAsserted:            return .sourceAsserted
        case .directlyObserved:          return .directlyObserved
        case .deterministicallyDerived:  return .deterministicallyDerived
        case .inferred:                  return .inferred
        }
    }

    static func status(from s: EventStatus) -> EvidenceStatus {
        switch s {
        case .observed:      return .directlyObserved
        case .asserted:      return .sourceAsserted
        case .derived:       return .deterministicallyDerived
        case .inferred:      return .inferred
        case .contradicted:  return .contradicted
        case .unsupported:   return .unsupported
        case .reviewed:      return .humanConfirmed
        case .rejected:      return .humanRejected
        }
    }

    /// Common GenericFact fields → neutral predicates; unknown → normalized field.
    static func predicate(forField field: String) -> String {
        switch field.lowercased() {
        case "employer", "worked_at", "company":     return HistoryPredicate.workedFor
        case "role", "designation", "position", "title": return HistoryPredicate.heldRole
        case "education", "educated_at", "university", "college": return HistoryPredicate.educatedAt
        case "degree", "qualification":              return HistoryPredicate.completedDegree
        case "location", "address", "city":          return HistoryPredicate.locatedAt
        case "amount", "paid":                       return HistoryPredicate.paid
        case "status":                               return HistoryPredicate.status
        default:                                     return HistoryPredicate.normalize(field)
        }
    }

    static func itemKind(for k: Event.Kind) -> HistoryItemKind {
        switch k {
        case .emailSent, .emailReceived:             return .communication
        case .contractSigned, .contractModified:     return .legalMilestone
        case .invoiceIssued, .invoicePaid:           return .financialTransaction
        case .meetingHeld, .taskAssigned, .deliveryDelayed, .deliveryCompleted, .other:
            return .event
        }
    }

    static func itemKind(forPredicate p: String, hasEnd: Bool) -> HistoryItemKind {
        switch p {
        case HistoryPredicate.workedFor, HistoryPredicate.heldRole, HistoryPredicate.memberOf,
             HistoryPredicate.residedAt, HistoryPredicate.owned, HistoryPredicate.directed:
            return hasEnd ? .period : .stateStart
        case HistoryPredicate.associatedWith, HistoryPredicate.relatedTo, HistoryPredicate.representedBy:
            return .relationshipStart
        case HistoryPredicate.signed, HistoryPredicate.filed, HistoryPredicate.published,
             HistoryPredicate.granted, HistoryPredicate.approved, HistoryPredicate.rejected:
            return .legalMilestone
        case HistoryPredicate.paid, HistoryPredicate.received:
            return .financialTransaction
        case HistoryPredicate.communicatedWith:
            return .communication
        case HistoryPredicate.status:
            return .stateChange
        default:
            return .event
        }
    }

    static func title(for c: TemporalClaim) -> String {
        "\(c.predicate.replacingOccurrences(of: "_", with: " ")): \(c.object.displayText)"
    }

    // MARK: - Content-hash ids (idempotent projection)

    static func claimID(subject: Entity.ID, predicate: String, object: ClaimValue) -> UUID {
        deterministicID("claim|\(subject.uuidString)|\(predicate)|\(object.displayText)")
    }
    static func itemID(kind: String, key: String) -> UUID {
        deterministicID("item|\(kind)|\(key)")
    }
    static func deterministicID(_ signature: String) -> UUID {
        let digest = SHA256.hash(data: Data(signature.utf8))
        var bytes = [UInt8](digest.prefix(16))
        // RFC-4122-ish stamp so it's a well-formed UUID (version/variant bits).
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid)
    }
}
