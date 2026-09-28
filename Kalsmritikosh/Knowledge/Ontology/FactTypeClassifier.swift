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
        // HOST-* artifacts are deliberately unclassified here. A registry hive or
        // event log is not an invoice, contract or meeting; forcing it into one of
        // those would put a fabricated document type on machine evidence. Their
        // structure is already citable via the parser's typed blocks.
        case .spreadsheet, .image, .archive, .hostArtifact, .unknown:
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

    // MARK: - P3.2 · the taxonomy is OPEN at the edge
    //
    // `classify` returns nil for anything outside the curated `FactType` enum,
    // and the write path stores `_unclassified`. DataHealthCheck then counts
    // `fact_type != '_unclassified'` as "typed", so every out-of-taxonomy
    // document reads as a DEFECT. That conflates two completely different
    // states:
    //
    //   CLASSIFIER FAILED — a contract we should have recognised and did not.
    //                       A real defect; the rules need work.
    //   GENUINELY NOVEL   — a vehicle service record, a shipping manifest, a
    //                       school report. The curated enum is a commercial and
    //                       project-management taxonomy; these are not in it and
    //                       never will be, because the space of document kinds
    //                       is open. Calling this a defect means the health
    //                       panel goes red for the product working as intended
    //                       on a universal archive.
    //
    // WHERE A NAME FOR A NOVEL TYPE COMES FROM, HONESTLY. I will not guess a
    // human label — inventing "vehicleServiceRecord" from field names is the
    // model-style leap this codebase refuses. Instead the derived id is a
    // FINGERPRINT OF THE DOCUMENT'S OWN FIELD SET:
    //
    //      derived:chassisnumber+odometerreading+servicedate
    //
    // That is honest (it states only what the document contains), stable (the
    // same field set always yields the same id), and — the useful part —
    // GROUPING: two service records from different garages produce the SAME
    // derived id, so an emergent taxonomy forms from the data instead of from
    // a list somebody has to maintain. A human label can be attached later by
    // whoever knows the domain; the grouping works without one.
    //
    // Requires P3.1's open-field extractor to have produced field names. With
    // it off there are no discovered fields, so this correctly declines.

    /// A type the curated enum does not contain, named after its own contents.
    public struct OpenTypeResult: Sendable, Hashable {
        /// `derived:<field>+<field>+<field>` — stable and groupable.
        public let derivedTypeID: String
        public let confidence: Double
        public let reason: String
        /// The fields the fingerprint was built from, in the order used.
        public let signatureFields: [String]
    }

    /// How many fields form the signature. Three is the balance found by
    /// reasoning about the failure modes on both sides: one or two group far
    /// too loosely (every form has a "name" and a "date"), while five or more
    /// make the id so specific that two genuinely similar documents with one
    /// differing field never group — which defeats the whole purpose.
    public nonisolated static let signatureFieldCount = 3

    /// Fields too generic to identify a document KIND. A signature built from
    /// these describes nothing: "date+name+number" is every form ever printed.
    public nonisolated static let nonDistinguishingFields: Set<String> = [
        "date", "name", "number", "id", "amount", "total", "value", "type",
        "status", "address", "phone", "email", "reference", "remarks", "notes",
        "description", "subject", "title", "page", "signature", "place",
    ]

    /// The prefix that marks a derived type, so no reader can mistake one for
    /// a curated `FactType`. Queries can also find them all with a LIKE.
    public nonisolated static let derivedPrefix = "derived:"

    /// Name a novel document type from its discovered fields, or decline.
    ///
    /// Declines — rather than guessing — when the document offers too few
    /// distinguishing fields. An id built from nothing is worse than no id,
    /// because it would group unrelated documents together and look like
    /// knowledge.
    public nonisolated func classifyOpen(fieldIDs: [String]) -> OpenTypeResult? {
        guard KnowledgeModuleFlags.isEnabled(.openFactTypes) else { return nil }
        let distinguishing = fieldIDs
            .map { $0.lowercased() }
            .filter { !Self.nonDistinguishingFields.contains($0) }
            // Sorted, so field ORDER in the document cannot change the id. Two
            // forms listing the same fields in a different order are the same
            // kind of document.
            .sorted()
        // De-duplicate while keeping the sorted order.
        var unique: [String] = []
        for f in distinguishing where unique.last != f { unique.append(f) }

        guard unique.count >= Self.signatureFieldCount else { return nil }
        let signature = Array(unique.prefix(Self.signatureFieldCount))
        return OpenTypeResult(
            derivedTypeID: Self.derivedPrefix + signature.joined(separator: "+"),
            // Deliberately modest. This is a GROUPING, not a recognition: it
            // says "documents like this one", not "this is a service record".
            // Anything higher would invite downstream code to treat it as a
            // recognised type.
            confidence: 0.45,
            reason: "derived from \(unique.count) distinguishing field(s)",
            signatureFields: signature)
    }

    /// Why a row is untyped — so the health panel can stop calling a universal
    /// archive broken.
    public enum UntypedCause: String, Sendable {
        /// Curated rules matched nothing AND too few distinguishing fields to
        /// derive a type. Genuinely unknown; a real gap.
        case unclassifiable
        /// Curated rules matched nothing, but the document HAS a derivable
        /// field signature. Working as intended on an unanticipated domain.
        case novelType
        /// The open-type module is off, so no derivation was attempted. Absence
        /// of a type here means nothing was tried — which must never be read as
        /// "nothing was there".
        case notAttempted
    }

    /// Classify the ABSENCE of a curated type. Called only when `classify`
    /// returned nil.
    public nonisolated func untypedCause(fieldIDs: [String]) -> UntypedCause {
        guard KnowledgeModuleFlags.isEnabled(.openFactTypes) else { return .notAttempted }
        return classifyOpen(fieldIDs: fieldIDs) == nil ? .unclassifiable : .novelType
    }

    /// Whether a stored `fact_type` string is a derived id rather than a
    /// curated `FactType` raw value.
    public nonisolated static func isDerived(_ factType: String) -> Bool {
        factType.hasPrefix(derivedPrefix)
    }

    // MARK: - Helpers

    private nonisolated func stringMeta(_ object: KnowledgeObject, _ key: String) -> String? {
        guard let v = object.metadata[key] else { return nil }
        if case .string(let s) = v.value { return s }
        return nil
    }
}
