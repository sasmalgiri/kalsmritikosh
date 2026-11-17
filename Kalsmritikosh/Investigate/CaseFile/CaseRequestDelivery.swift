//
//  CaseRequestDelivery.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (ADAPT-10, local part) — an evidence request's delivery, kept honest with the case's existing
//  external-effect record (AUTO-10): prepared (drafted or copied — nothing says it went), handed over by the person
//  (outcome not yet known), then confirmed sent or confirmed not sent. Handing over again is refused while an earlier
//  hand-over's outcome is unknown, so an uncertain delivery is reconciled before any retry; after a restore a prepared
//  delivery must be confirmed first (RECOVERY-05). The app sends nothing itself: live submission needs a supported
//  integration (ADAPT-07). One request is one delivery to one recipient — preparing it again changes nothing.
//

import Foundation

public nonisolated enum CaseRequestDelivery {
    /// The purpose that ties a delivery to its request.
    public static func purpose(_ r: EvidenceRequest) -> String { "Evidence request \(r.id.uuidString.lowercased()): \(r.description)" }

    /// What the screen says about a request's delivery.
    public static func line(_ effect: CaseExternalEffect?) -> String {
        guard let e = effect else { return "Not prepared for sending. A draft that was copied is not recorded as sent." }
        switch e.state {
        case .prepared: return "Prepared for \(e.channel) — not handed over. Copying the text does not send it."
        case .handedOver: return "Handed over (\(e.channel)) — whether it arrived is not yet known. Confirm it before sending again."
        case .confirmedSent: return "Confirmed sent (\(e.channel))."
        case .confirmedNotSent: return "Confirmed not sent — it may be handed over again."
        }
    }
}

extension CaseAutomationService {

    /// Prepare the request for sending to its custodian through `channel` (letter, email, portal): the recipient is
    /// authorised for this request's content once, and the delivery is one external effect, however often prepared.
    @discardableResult
    public func prepareRequestDelivery(caseID: UUID, request file: EvidenceRequestFile, channel: String, text: String, actor: String,
                                       at date: Date = Date()) async throws -> CaseExternalEffect {
        let r = file.request
        let recipient = (r.custodian ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else { throw CaseAutomationError.wrongState("Name the custodian first — the request says who holds it.") }
        let scope = "Evidence request: \(r.description)"
        let existing = try await activeRecipientID(caseID: caseID, recipient: recipient, channel: channel, contentScope: scope)
        let recipientID: UUID
        if let existing { recipientID = existing } else {
            recipientID = try await authorizeRecipient(caseID: caseID, recipient: recipient, channel: channel, contentScope: scope, actor: actor, at: date)
        }
        return try await prepareExternalEffect(caseID: caseID, recipientID: recipientID, purpose: CaseRequestDelivery.purpose(r), content: text,
                                               actor: actor, at: date)
    }

    /// The request's delivery, when one was prepared (the latest).
    public func requestDelivery(caseID: UUID, request: EvidenceRequest) async throws -> CaseExternalEffect? {
        let p = CaseRequestDelivery.purpose(request)
        return try await externalEffects(caseID: caseID).last { $0.purpose == p }
    }
}
