//
//  DerivedProducerVersions.swift
//  Kalsmritikosh
//
//  V1 (v1.1 Stage 1) — the derived producers' declared versions, registered
//  in one place so the staleness predicate has a single authority.
//
//  THE TRAP THIS FILE DEFUSES (owner binding 2026-09-01): initial declared
//  versions are 0, and NULL ≡ 0 ≡ current — nothing in the archive reads as
//  stale until a LOGIC CHANGE bumps a version (V2's patent-pack capture
//  groups are the first). If these had started at 1 over a NULL archive, the
//  staleness predicate would have marked all sources stale on day one, the
//  honest "older rules" line would have invited a full drain that rewrites
//  the archive with UNCHANGED logic, and V5's one-rewrite discipline would
//  have broken before V2 opened. The "N sources processed with older rules —
//  refresh" line must be able to read ZERO the day it lands.
//
//  Staleness predicate (per table): COALESCE(producer_version, 0) != current.
//

public nonisolated enum DerivedProducerVersions {
    /// DomainFactExtractor + its packs (generic_facts.producer_version).
    /// Bump when extraction LOGIC changes what a stored fact would contain.
    ///   0→1 (V2): capture-group extraction — identifiers store the bare
    ///        normalized atom, dates store precision-aware ISO.
    ///   1→2 (V3 3c): the WRITER BINDING — an identifier fact now carries a
    ///        canonical subject (subjectID → its anchor entity). A v2 fact
    ///        contains the anchor link a v1 fact lacks, so the stored
    ///        representation changed and the era advances. The V5 drain rewrites
    ///        v1 rows to bind their subjects.
    /// v3 — W-4 (owner witness): the patent pack's prefix law + canon
    /// validity gate; the drain re-extracts every document's facts and the
    /// register re-mints its anchors. No re-ingest.
    /// v4 — A1.1: the role table (applicant/inventor extraction); the drain
    /// re-extracts and the register carries the roles. No re-ingest.
    /// v5 — W-5.1 (implement-all U-2): the ROLE-VALUE GATE — clause-shaped
    /// role captures ("am writing to state…") are rejected at write, so a
    /// v4 store can hold junk role facts a v5 producer cannot emit; the
    /// drain re-extracts and the junk dies with its era. No re-ingest.
    /// v6 — the MAILBOX SUBJECT: a multi-message file's facts are derived per
    ///        message under that message's Subject (FactSubjectPartitioner),
    ///        not once under the mailbox's file name; a thread KO drains over
    ///        its own messages and gets its evidence links repaired. A v5 store
    ///        files every mailbox fact under "Sent"; the drain re-extracts.
    ///        No re-ingest.
    /// v7 — L2 UNIVERSAL HYGIENE: FactValuePlausibility rejects transport headers,
    ///        style declarations, MIME parameter lists and form placeholders;
    ///        OpenFieldExtractor no longer mints list enumerators ("1. …",
    ///        "16th year") as labels and keeps the Latin word of a bilingual
    ///        label. A v6 store holds "contenttype: multipart/mixed; boundary=…"
    ///        and "1useofpermanentmagnets"; the drain re-extracts. No re-ingest.
    /// v8 — L3 DOCUMENT SUBJECT: a document headed by a person's name (a résumé,
    ///        a bio-data sheet) files its facts under that person, not the file
    ///        name; the drain re-extracts. No re-ingest.
    /// v9 — P2 payments: a payee stops at masked/numeric runs and payment
    ///        furniture on one-line OCR receipts; an OCR-lost rupee sign ("·10,000")
    ///        is recovered in payment confirmations. The drain re-extracts.
    /// v10 — P1.4 UNTITLED MESSAGE: a mailbox message with no Subject files its
    ///        facts under its first attachment's name, else its opening line —
    ///        never the mailbox file name ("Sent"); a receipt/invoice (or a
    ///        stem-labelled payment screenshot) naming one counterparty files
    ///        under that counterparty. The drain re-extracts.
    /// v11 — P4.4: identifier attestation counts evidence blocks (the W-5.6
    ///        re-fielding of "Patent No. ‹application number›" never fired on
    ///        a merged ledger). A current-era ledger never drains, so the bump
    ///        is what carries the fix to it. The drain re-extracts.
    public static let facts = 11

    /// Entity extraction + EntityQualityGate (entities.producer_version).
    /// First bump 0→1 (V3 3c): the gate hardening (3b) plus the new anchor
    /// entities — the entity population a v1 producer emits differs from v0
    /// (junk classes gated out; identifier anchors added), so the era advances.
    ///   1→2 (GO2R U0-b): email display names now come from the RFC 2822
    ///        address-list parser with edge punctuation stripped — a v1
    ///        producer emitted ", Akhilesh Sharma" and "'Arindam Das'" person
    ///        entities from To: lists (witnessed live on the owner's archive);
    ///        a v2 producer cannot. The targeted register refresh rewrites
    ///        v1 person values in place (strip + collision-merge, never
    ///        delete) and stamps them v2.
    public static let entities = 2

    /// Event extraction (events.producer_version).
    /// First bump 0→1 (V3 3c): milestone events now thread onto the identifier
    /// ANCHOR (backfillLegalMilestones passes anchor ids), so a v1 event's
    /// participant set can contain the anchor a v0 event never referenced. The
    /// V5 drain rebuilds milestones to apply the threading to the live archive.
    ///   1→2 (W-5.3, implement-all U-2): the event-title normalizer — a v1
    ///        email event's title is the raw subject ("Fwd: Fwd: intimation…");
    ///        a v2 title is the stripped happening. The drain rewrites titles;
    ///        the subject stays on the source document for citation.
    ///   2→3 (P1.10, 2026-09-27): same-source repeats collapse to one event
    ///        (EventDeduper) — the owner copy held 121 repeats of 595, each
    ///        fanning out into claims. The drain re-derives; no re-ingest.
    ///   3→4 (P4.4, 2026-09-27): milestone dates are UTC-midnight calendar
    ///        days (were the day before on an IST machine) with stable ids.
    ///        The bump is what makes a current ledger drain and rebuild them.
    public static let events = 4
}
