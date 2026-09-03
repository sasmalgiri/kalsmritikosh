//
//  EventMarkerTable.swift
//  Kalsmritikosh
//
//  V4 (D-17 Part A, EV-1) — the event trigger markers AS DATA, class-gated.
//
//  THE DEFECT THIS CLOSES: the marker list lived inline in RuleEventExtractor
//  and fired on ANY document, so a patent-office letter that mentions fees
//  ("invoice number …") or owners ("owner:") produced commercial boilerplate
//  events — the live archive's event distribution was ≥90% one kind and the
//  patent's story drowned. The table makes the policy EXPLICIT and per-kind:
//  commercial markers never fire on a legal document or certificate, where the
//  legal extractor (PatentLegalEventExtractor) is PRIMARY. Email header events
//  (emailSent/emailReceived) are UNIVERSAL — they come from structured headers,
//  not body markers, and are not in this table.
//
public struct EventMarkerRule: Sendable {
    public let kind: Event.Kind
    public let markers: [String]
    /// Document classes this rule must NEVER fire on. Expressed as an exclusion
    /// (not an allowlist) so a future class defaults to today's behavior and the
    /// gate stays exactly as narrow as the ruling: legal/certificate documents
    /// get their events from the legal extractor, not commercial boilerplate.
    public let excludedClasses: Set<DocumentClass>
}

public enum EventMarkerTable {

    /// The classes where commercial body-marker rules are silenced (EV-1).
    public static let commercialExclusions: Set<DocumentClass> = [.legalDocument, .certificate]

    public static let rules: [EventMarkerRule] = [
        EventMarkerRule(kind: .contractSigned,
                        markers: ["signed this agreement", "executed on", "signature page"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .contractModified,
                        markers: ["amendment to", "amended on", "addendum"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .invoiceIssued,
                        markers: ["invoice issued", "invoice dated", "invoice number"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .invoicePaid,
                        markers: ["payment received", "paid in full", "payment confirmed"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .meetingHeld,
                        markers: ["minutes of meeting", "we met on", "kickoff meeting"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .taskAssigned,
                        markers: ["assigned to", "action item:", "owner:"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .deliveryDelayed,
                        markers: ["delivery delayed", "shipment delay", "behind schedule"],
                        excludedClasses: commercialExclusions),
        EventMarkerRule(kind: .deliveryCompleted,
                        markers: ["delivery completed", "delivered on", "shipment received"],
                        excludedClasses: commercialExclusions),
    ]

    /// The rules that may fire on a document of `documentClass`.
    public static func rules(for documentClass: DocumentClass) -> [EventMarkerRule] {
        rules.filter { !$0.excludedClasses.contains(documentClass) }
    }
}
