//
//  FactTypeClassifier.swift
//  Kalsmritikosh
//
//  G3.7 — rule-based labeller. Given an Entity / Event / KO, infer
//  which `FactType` from Ontology.v1 it represents. Pure, deterministic,
//  no LLM. The classifier returns nil when no rule matches with
//  enough confidence — the row stays unlabeled and the LLM-assisted
//  slot extractor (G3.14, future) is the escape hatch.
//
//  Classification strategy:
//  - For Entity: pick FactType from Entity.kind (person/org/project/
//    deliverable). Entity.kind is the existing canonical taxonomy;
//    we just remap the names.
//  - For Event: classify by Event.kind. contractSigned →
//    .contract, contractModified → .amendment, invoiceIssued →
//    .invoice, deliveryDelayed / deliveryCompleted → .delivery,
//    meetingHeld → .meeting, emailReceived/emailSent → .email,
//    taskAssigned → .decision (commitments are decisions for v1
//    purposes; v2 can split out Commitment as its own FactType).
//  - For KnowledgeObject: classify by sourceType.category, then
//    refine via env.pdf.detected_doc_class (set by
//    PDFDocumentEnvironment). email → .email, pdf with class
//    "contract" → .contract, etc.
//
//  Every classifier hit also carries a confidence score in [0, 1]
//  so downstream (OntologyValidator + write path) can choose to skip
//  low-confidence labels.
//

import Foundation

public struct FactTypeClassifier: Sendable {
    public struct Result: Sendable, Hashable {
        public let type: FactType
        public let confidence: Double
        public let reason: String

        public nonisolated init(type: FactType, confidence: Double, reason: String) {
            self.type = type
            self.confidence = max(0, min(1, confidence))
            self.reason = reason
        }
    }

    public nonisolated init() {}

    // MARK: - Entity

    public nonisolated func classify(entity: Entity) -> Result? {
        // Name-based override — NLTagger frequently tags "Project Delta"
        // (and other "Project XYZ" names) as ORGANIZATION because the
        // capitalization pattern matches a company. The "Project Foo"
        // convention is strong enough to override the NER tag. Without
        // this override, fact_bonds never reference the project entity
        // (BondConstructor.projectEntityIDs filters on .project) and
        // BondWalker seeded from "Project Delta" finds zero outgoing
        // typed bonds — Walk cov. collapses to 0 in every multi-hop
        // eval row. (Confirmed via Run Full Diagnostics 2026-06-24:
        // entities[organization:5, person:10] — zero projects.)
        let value = entity.value.trimmingCharacters(in: .whitespaces)
        if value.range(of: #"^Project\s+\p{Lu}"#, options: .regularExpression) != nil {
            return Result(type: .project, confidence: 0.85, reason: "name matches 'Project <Capital>' override")
        }

        switch entity.kind {
        case .person:
            return Result(type: .person, confidence: 0.95, reason: "entity.kind=person")
        case .emailAddress:
            // v1 Person stand-in: every email address represents some
            // Person. Confidence is 0.55 — just above the default
            // minConfidence floor (0.5) so the backfill labels these,
            // but well below the 0.95 of a real Person mention. This
            // is what makes WalkExplainer render the "Email →
            // sent_by → Person" path when the bond's `to` side is
            // an emailAddress entity (which it always is on the
            // EmailLoader path). v2 may promote emailAddress to a
            // separate EmailAddress FactType and lift sender_person
            // resolution into G3.14 slot extraction.
            return Result(type: .person, confidence: 0.55, reason: "entity.kind=emailAddress (Person stand-in)")
        case .organization, .vendor, .client:
            return Result(type: .organization, confidence: 0.95, reason: "entity.kind=\(entity.kind.rawValue)")
        case .project:
            return Result(type: .project, confidence: 0.95, reason: "entity.kind=project")
        case .deliverable:
            // Best v1 fit: deliverable maps to Delivery.
            return Result(type: .delivery, confidence: 0.80, reason: "entity.kind=deliverable")
        default:
            // date / monetaryAmount / location / other — not promoted to
            // typed FactType in v1. v2 may add Money / Location as
            // first-class types.
            return nil
        }
    }

    // MARK: - Event

    public nonisolated func classify(event: Event) -> Result? {
        switch event.kind {
        case .contractSigned:
            return Result(type: .contract, confidence: 0.95, reason: "event.kind=contractSigned")
        case .contractModified:
            return Result(type: .amendment, confidence: 0.90, reason: "event.kind=contractModified")
        case .invoiceIssued, .invoicePaid:
            return Result(type: .invoice, confidence: 0.92, reason: "event.kind=\(event.kind.rawValue)")
        case .deliveryDelayed, .deliveryCompleted:
            return Result(type: .delivery, confidence: 0.92, reason: "event.kind=\(event.kind.rawValue)")
        case .meetingHeld:
            return Result(type: .meeting, confidence: 0.90, reason: "event.kind=meetingHeld")
        case .emailReceived, .emailSent:
            return Result(type: .email, confidence: 0.95, reason: "event.kind=\(event.kind.rawValue)")
        case .taskAssigned:
            // G2-COMMITMENTS-REFRESH events. v1 ontology has no
            // dedicated Commitment type; Decision is the closest fit
            // (a commitment IS a kind of recorded decision). Confidence
            // is medium since we may want a Commitment type in v2.
            return Result(type: .decision, confidence: 0.60, reason: "event.kind=taskAssigned (mapped to Decision)")
        case .other:
            return nil
        }
    }

    // MARK: - KnowledgeObject

    public nonisolated func classify(knowledgeObject: KnowledgeObject) -> Result? {
        // KOs are documents-level facts. The most reliable signal is
        // the loader's sourceType.category, refined by any
        // env.pdf.detected_doc_class metadata that PDFDocumentEnvironment
        // already wrote (G2-ENVIRONMENTS).
        let detectedDocClass = stringMeta(knowledgeObject, "env.pdf.detected_doc_class")
        switch knowledgeObject.sourceType.category {
        case .email:
            return Result(type: .email, confidence: 0.95, reason: "sourceType.category=email")
        case .document, .presentation:
            if let docClass = detectedDocClass {
                switch docClass {
                case "invoice":
                    return Result(type: .invoice, confidence: 0.85, reason: "env.pdf.detected_doc_class=invoice")
                case "contract":
                    return Result(type: .contract, confidence: 0.85, reason: "env.pdf.detected_doc_class=contract")
                case "amendment":
                    return Result(type: .amendment, confidence: 0.85, reason: "env.pdf.detected_doc_class=amendment")
                case "meeting_minutes":
                    return Result(type: .meeting, confidence: 0.80, reason: "env.pdf.detected_doc_class=meeting_minutes")
                case "receipt":
                    return Result(type: .invoice, confidence: 0.70, reason: "env.pdf.detected_doc_class=receipt → mapped to Invoice")
                default:
                    return nil
                }
            }
            return nil
        case .audio, .video:
            // Transcripts are usually meetings or interviews. Default
            // to meeting at medium confidence; future v2 may add
            // Interview / Conversation types.
            return Result(type: .meeting, confidence: 0.50, reason: "sourceType.category=transcript (default → Meeting)")
        case .spreadsheet, .image, .archive, .unknown:
            return nil
        case .chat:
            // Chat exports / iMessage threads behave like email
            // threads ontologically — conversations between people.
            return Result(type: .email, confidence: 0.70, reason: "sourceType.category=chat")
        case .browserHistory:
            // Browser history doesn't fit any fact type cleanly;
            // leave it unclassified and let the extractor enrich
            // per-visit when it ships.
            return nil
        }
    }

    // MARK: - Helpers

    private nonisolated func stringMeta(_ object: KnowledgeObject, _ key: String) -> String? {
        guard let v = object.metadata[key] else { return nil }
        if case .string(let s) = v.value { return s }
        return nil
    }
}
