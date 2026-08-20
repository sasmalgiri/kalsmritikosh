//
//  WorkCenterEngine.swift
//  Kalsmritikosh
//
//  WORK-CENTER — the SAP-style guided workflow engine, ported from the
//  owner's maxmailin Work Center (owner request 2026-08-17) and adapted to
//  THIS project's personas and surfaces. The pattern: a workflow is a
//  numbered DOCUMENT (WF-2026-0001) whose ordered operations each capture
//  typed form fields (with per-field help), are guarded by STATUS GATES
//  (defensibility holes become structurally impossible, with plain-language
//  locked reasons), launch the REAL surface where the work happens, and —
//  on confirmation — post their own numbered document (IMP/RPT/PRD/…) so
//  every completed step is quotable and findable later.
//
//  This file is PURE model + policy (no store, no UI) — gate evaluation,
//  field validation, and the five built-in recipes grounded in canonical
//  frameworks (NIST 800-86, EDRM, ICIJ-style verification, systematic
//  review, personal records lifecycle). Persistence lives in
//  WorkCenterRepository over the single ledger (migration v105).
//

import Foundation

// MARK: - Fields

public nonisolated struct WCField: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case text, longText, number, choice, bool, date, dateRange }
    public var id: String { key }
    public let key: String
    public let label: String
    public let kind: Kind
    /// The per-field help text shown under the input — the "why" of the field.
    public let help: String
    public var placeholder: String = ""
    public var required: Bool = false
    public var options: [String] = []
}

// MARK: - Operations & gates

public nonisolated struct WCOperation: Identifiable, Equatable, Sendable {
    public var id: Int { seq }
    public let seq: Int
    public let key: String
    public let title: String
    /// One-line hint shown on the step rail and header.
    public let hint: String
    /// The document-type CODE this step posts on confirmation (nil = record-only).
    public let postsDocType: String?
    /// The surface where the user DOES this step's work (a RootView
    /// Destination rawValue — resolved by the UI, kept as a string here so
    /// the engine stays layering-clean).
    public var launchesSurface: String? = nil
    public var fields: [WCField] = []
    /// Preconditions that must hold before this step may be confirmed.
    public var gates: [WCGate] = []
}

public nonisolated struct WCGate: Equatable, Sendable {
    public enum Rule: Equatable, Sendable {
        case operationConfirmed(seq: Int)
        case fieldPresent(seq: Int, key: String)
        case fieldEquals(seq: Int, key: String, value: String)
    }
    public let rule: Rule
    /// Plain-language reason shown while the gate is closed.
    public let reason: String
}

/// Pure gate evaluation — unit-tested, no store/UI.
public nonisolated enum WCGatePolicy {
    public struct RunState: Sendable {
        public let confirmed: Set<Int>
        public let fieldValues: [Int: [String: String]]
        public init(confirmed: Set<Int>, fieldValues: [Int: [String: String]]) {
            self.confirmed = confirmed; self.fieldValues = fieldValues
        }
    }

    /// The reasons this operation is currently locked (empty = open).
    public static func lockedReasons(_ op: WCOperation, state: RunState) -> [String] {
        op.gates.compactMap { gate in
            let satisfied: Bool
            switch gate.rule {
            case .operationConfirmed(let seq):
                satisfied = state.confirmed.contains(seq)
            case .fieldPresent(let seq, let key):
                satisfied = !((state.fieldValues[seq]?[key] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .fieldEquals(let seq, let key, let value):
                satisfied = (state.fieldValues[seq]?[key] ?? "") == value
            }
            return satisfied ? nil : gate.reason
        }
    }
}

/// Pure validation — required fields must be non-empty. Returns missing labels.
public nonisolated enum WCFieldValidation {
    public static func missingRequired(_ fields: [WCField], values: [String: String]) -> [String] {
        fields.filter(\.required)
            .filter { (values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.label)
    }
}

// MARK: - Definitions

public nonisolated struct WCWorkflowDefinition: Identifiable, Equatable, Sendable {
    public let defID: String
    public let name: String
    /// Persona label this recipe is tuned for (informational — any persona may run any recipe).
    public let persona: String
    /// One-line purpose shown on the catalog card.
    public let purpose: String
    public let operations: [WCOperation]
    public var id: String { defID }
}

// MARK: - Document numbering (pure formatting; counters live in the ledger)

public nonisolated enum WCDocumentNumber {
    /// SAP-style: TYPE-YEAR-#### (WF-2026-0012).
    public static func format(type: String, year: Int, sequence: Int) -> String {
        String(format: "%@-%d-%04d", type.uppercased(), year, sequence)
    }
}

/// Display metadata for the document-type codes the recipes post.
public nonisolated enum WCDocType {
    public static func displayName(_ code: String) -> String {
        switch code {
        case "WF":  return "Workflow Run"
        case "IMP": return "Intake"
        case "PRS": return "Preservation"
        case "RPT": return "Report"
        case "PRD": return "Production"
        case "PUB": return "Publication Package"
        case "EDN": return "Edition"
        case "ARC": return "Archive Pack"
        case "VAR": return "Variant"
        case "EXP": return "Export"
        case "INT": return "Interview / Statement"
        case "REQ": return "Records Request"
        case "LOG": return "Research Log Entry"
        case "CAL": return "Content Calendar Entry"
        case "SVL": return "Surveillance Log Entry"
        case "ALG": return "Allegation & Finding"
        default:    return code
        }
    }
    public static func icon(_ code: String) -> String {
        switch code {
        case "WF":  return "point.3.filled.connected.trianglepath.dotted"
        case "IMP": return "square.and.arrow.down"
        case "PRS": return "checkmark.shield"
        case "RPT": return "doc.badge.clock"
        case "PRD": return "shippingbox"
        case "PUB": return "newspaper"
        case "EDN": return "text.book.closed"
        case "ARC": return "archivebox"
        case "VAR": return "square.stack.3d.up"
        case "EXP": return "square.and.arrow.up"
        case "INT": return "person.wave.2"
        case "REQ": return "envelope.badge.clock"
        case "LOG": return "magnifyingglass.circle"
        case "CAL": return "calendar.badge.clock"
        case "SVL": return "binoculars"
        case "ALG": return "scalemass"
        default:    return "doc"
        }
    }
}

// MARK: - The catalog — five recipes in THIS project's domain

public nonisolated enum WCCatalog {

    public static var all: [WCWorkflowDefinition] {
        [evidenceIntake, production, storyBuild, systematicReview, lifeRecords]
    }

    /// EVERY documented persona job as a full-rigor guided workflow, generated
    /// deterministically from its JobDocumentation row (no per-job authoring).
    /// Kept OUT of `all` so the Work Center home still shows the five curated
    /// recipes; these are launched from the job itself and resolved on demand.
    /// One guided workflow for EVERY launchable persona job (all 10 personas).
    public static let jobWorkflows: [WCWorkflowDefinition] =
        PersonaJobCatalogComposer.allJobs.map(WCJobWorkflowFactory.make)

    /// Resolve a definition by id — a curated recipe OR a generated job workflow.
    public static func definition(_ defID: String) -> WCWorkflowDefinition? {
        all.first { $0.defID == defID } ?? jobWorkflows.first { $0.defID == defID }
    }

    /// The generated guided workflow for a launchable persona job.
    public static func jobWorkflow(forJob job: PersonaJob) -> WCWorkflowDefinition? {
        let id = WCJobWorkflowFactory.defID(forJobKey: job.id)
        return jobWorkflows.first { $0.defID == id }
    }

    // Builders (same helpers as the source system).
    private static func op(_ seq: Int, _ key: String, _ title: String, _ hint: String,
                           posts doc: String? = nil, launches: String? = nil,
                           _ fields: [WCField] = [], gates: [WCGate] = []) -> WCOperation {
        WCOperation(seq: seq, key: key, title: title, hint: hint,
                    postsDocType: doc, launchesSurface: launches, fields: fields,
                    gates: afterPrevious(seq) + gates)
    }
    /// The default sequential gate: each step waits on the one before it.
    private static func afterPrevious(_ seq: Int) -> [WCGate] {
        seq <= 1 ? [] : [WCGate(rule: .operationConfirmed(seq: seq - 1),
                                reason: "Finish step \(seq - 1) first.")]
    }
    private static func f(_ key: String, _ label: String, _ kind: WCField.Kind, _ help: String,
                          placeholder: String = "", required: Bool = false,
                          options: [String] = []) -> WCField {
        WCField(key: key, label: label, kind: kind, help: help,
                placeholder: placeholder, required: required, options: options)
    }

    /// Investigator — NIST 800-86 style intake-to-report over the ledger.
    public static let evidenceIntake = WCWorkflowDefinition(
        defID: "builtin.investigator.intake", name: "Evidence Intake & Review",
        persona: "Investigator",
        purpose: "Take in a document set as evidence and work it end to end — receive, preserve, examine, analyze, report — with the chain of custody written for you.",
        operations: [
            op(1, "receive", "Receive & Identify",
               "Record the matter and custodian; ingest the source. Posts an Intake document.",
               posts: "IMP", launches: "sources", [
                f("caseNumber", "Case / Matter number", .text,
                  "Links this evidence to the investigation. Use your own case-numbering scheme.",
                  placeholder: "CASE-2026-0001", required: true),
                f("custodian", "Custodian / owner", .text,
                  "Whose documents or account this evidence came from.",
                  placeholder: "j.doe@corp.com", required: true),
                f("sourceLocation", "Source location", .text,
                  "Where the data resided — folder, device, mailbox, cloud tenant.",
                  placeholder: "Shared drive / Documents"),
                f("receivedOn", "Received on", .date,
                  "The date the material came into your custody — anchors the chain."),
                f("purpose", "Purpose of collection", .longText,
                  "Why this evidence is being collected — the authority or request behind it."),
               ]),
            op(2, "preserve", "Preserve & Verify",
               "The vault hashes every source (SHA-256); verify the custody chain is intact.",
               launches: "audit", [
                f("method", "Acquisition method", .choice,
                  "How the material entered the ledger without altering the source.",
                  required: true,
                  options: ["In-place ingest (watched folder)", "Copy into vault", "Export from cloud/service", "Device transfer"]),
                f("integrityChecked", "Integrity chain verified", .bool,
                  "Turn on after running Verify integrity on the Audit screen — the tamper-evident seal over custody."),
                f("sealNote", "Seal / storage note", .text,
                  "Where the originals are kept and how they're protected."),
               ]),
            op(3, "examine", "Examine & Code",
               "Review facts, set statuses, flag items of interest.",
               launches: "findings", [
                f("itemsOfInterest", "Items of interest", .number,
                  "How many facts/documents you flagged as relevant this pass."),
                f("codingNotes", "Examination notes", .longText,
                  "What you looked for and what stood out — the examiner's contemporaneous notes."),
               ]),
            op(4, "analyze", "Analyze",
               "Work the connections, contradictions, and gaps across the set.",
               launches: "connections", [
                f("findingsSummary", "Findings summary", .longText,
                  "The threads, conflicts, and gaps this analysis surfaced."),
                f("anomalies", "Anomalies present", .bool,
                  "Turn on if the set shows tampering, missing records, or timeline anomalies worth noting."),
               ]),
            op(5, "report", "Document & Report",
               "Assemble the cited report for the case file. Posts a Report document.",
               posts: "RPT", launches: "handoff", [
                f("findings", "Findings summary", .longText,
                  "The conclusions this run supports — written for the case file, cited to evidence.",
                  required: true),
               ], gates: [
                WCGate(rule: .fieldPresent(seq: 2, key: "method"),
                       reason: "Record the acquisition method in Preserve & Verify — a report can't rest on unverified custody."),
               ]),
        ])

    /// Lawyer — EDRM-style review-to-production with the privilege gate.
    public static let production = WCWorkflowDefinition(
        defID: "builtin.lawyer.production", name: "Production Run",
        persona: "Lawyer / Professional Reviewer",
        purpose: "Review a document set, log privilege, redact, and produce — with the privilege log enforced before anything leaves.",
        operations: [
            op(1, "assemble", "Assemble Set",
               "Scope the matter and the documents under review.",
               launches: "sources", [
                f("matter", "Matter name", .text,
                  "The litigation or matter this production serves.",
                  placeholder: "Acme v. Roe", required: true),
                f("requestNo", "Request / RFP reference", .text,
                  "The discovery request this responds to."),
                f("reviewer", "Reviewer", .text,
                  "Who is coding this set (goes on the defensibility record)."),
               ]),
            op(2, "review", "Review & Code",
               "Responsive / non-responsive; set fact statuses.",
               launches: "review", [
                f("responsive", "Responsive count", .number,
                  "Documents coded responsive to the request."),
                f("confidentiality", "Confidentiality designation", .choice,
                  "Highest confidentiality applied in this set.",
                  options: ["None", "Confidential", "Highly Confidential — AEO"]),
               ]),
            op(3, "privilege", "Privilege Log",
               "Annotate every privileged document — the defensibility gate.",
               launches: "review", [
                f("privCount", "Privileged count", .number,
                  "Documents withheld as privileged."),
                f("privBasis", "Privilege basis", .choice,
                  "The ground for withholding — recorded in the privilege log.",
                  options: ["Attorney-Client", "Work Product", "Both", "Not applicable"]),
                f("logComplete", "Privilege log complete", .bool,
                  "Turn on only when every privileged doc has an annotation explaining the basis."),
               ]),
            op(4, "redact", "Redact & Validate",
               "Apply and validate redactions before anything is produced.",
               launches: "handoff", [
                f("redactions", "Redactions applied", .number,
                  "How many documents required redaction."),
                f("redactionValidated", "Redaction validated", .bool,
                  "Turn on after text + visual redaction validation passes."),
               ]),
            op(5, "produce", "Produce",
               "Export the cited production set — report == receipt. Posts a Production document.",
               posts: "PRD", launches: "handoff", [
                f("productionName", "Production set name", .text,
                  "Label for this production volume.", placeholder: "PROD001", required: true),
               ], gates: [
                WCGate(rule: .fieldEquals(seq: 3, key: "logComplete", value: "Yes"),
                       reason: "Complete the privilege log first — producing before every privileged doc is annotated is the gap opposing counsel finds."),
               ]),
        ])

    /// Journalist — ICIJ-style verification with right-of-reply enforced.
    public static let storyBuild = WCWorkflowDefinition(
        defID: "builtin.journalist.story", name: "Story Build",
        persona: "Journalist",
        purpose: "Take a document set from ingest to a verified, publishable package — with right of reply enforced before publication.",
        operations: [
            op(1, "ingest", "Ingest & Verify Provenance",
               "Import the leak/FOIA set with its provenance note. Posts an Intake document.",
               posts: "IMP", launches: "sources", [
                f("dataset", "Dataset name", .text,
                  "What this set is and where it came from.",
                  placeholder: "Acme filings 2026", required: true),
                f("provenance", "Provenance", .longText,
                  "How you obtained it and why you trust it — the provenance note."),
               ]),
            op(2, "leads", "Find Leads",
               "Search and identify the threads worth pursuing.",
               launches: "search", [
                f("lead", "Lead description", .longText,
                  "The thread you're chasing and why it matters."),
               ]),
            op(3, "verify", "Verify Claims",
               "Every claim checked against evidence; conflicts preserved, not averaged.",
               launches: "findings", [
                f("claims", "Claims verified", .number,
                  "How many cited claims you verified this pass."),
                f("conflicts", "Open conflicts", .number,
                  "Contradictions still unresolved — they publish as conflicts, never guesses."),
               ]),
            op(4, "reply", "Right of Reply",
               "Record subjects contacted and their responses.",
               launches: "review", [
                f("subjectsContacted", "Subjects contacted", .number,
                  "Everyone named adversely who was offered a chance to respond."),
                f("replyRecorded", "Replies recorded", .bool,
                  "Turn on when every response (or non-response after fair deadline) is on the record."),
               ]),
            op(5, "publish", "Publication Package",
               "Assemble the verified, cited package. Posts a Publication document.",
               posts: "PUB", launches: "handoff", [
                f("headline", "Working title", .text,
                  "The story this package supports.", required: true),
               ], gates: [
                WCGate(rule: .fieldEquals(seq: 4, key: "replyRecorded", value: "Yes"),
                       reason: "Record right of reply first — publishing without offering a response is the gap that sinks the story."),
               ]),
        ])

    /// Researcher — protocol-led systematic review to an annotated edition.
    public static let systematicReview = WCWorkflowDefinition(
        defID: "builtin.researcher.review", name: "Systematic Review",
        persona: "Researcher / Historian",
        purpose: "From research protocol to annotated edition — screened, extracted, synthesized, and cited end to end.",
        operations: [
            op(1, "protocol", "Protocol",
               "Fix the research question and corpus before evidence is touched.",
               launches: "sources", [
                f("question", "Research question", .longText,
                  "The question this review answers — fixed before screening to prevent drift.",
                  required: true),
                f("criteria", "Inclusion criteria", .longText,
                  "What qualifies a source for this review."),
                f("window", "Records window", .dateRange,
                  "The period this review covers — sources outside it are out of scope."),
               ]),
            op(2, "screen", "Screen Corpus",
               "Screen sources in/out by the recorded criteria.",
               launches: "search", [
                f("included", "Sources included", .number, "Sources passing the criteria."),
                f("excluded", "Sources excluded", .number, "Sources screened out (reversible)."),
               ]),
            op(3, "extract", "Extract & Code",
               "Extract coded findings, each citing an evidence block.",
               launches: "findings", [
                f("findingsCount", "Findings extracted", .number,
                  "Coded findings recorded this pass."),
               ]),
            op(4, "synthesize", "Synthesize",
               "Compare accounts; both sides of every conflict preserved.",
               launches: "matrix", [
                f("synthesis", "Synthesis notes", .longText,
                  "The picture the evidence supports — and where accounts diverge."),
               ]),
            op(5, "edition", "Annotated Edition",
               "Assemble the edition with a sealed receipt. Posts an Edition document.",
               posts: "EDN", launches: "handoff", [
                f("editionTitle", "Edition title", .text, "The work this run produces.", required: true),
               ], gates: [
                WCGate(rule: .fieldPresent(seq: 1, key: "question"),
                       reason: "Fix the research question in Protocol first — an edition without a protocol is a scrapbook."),
               ]),
        ])

    /// Individual — the personal records lifecycle, in plain language.
    public static let lifeRecords = WCWorkflowDefinition(
        defID: "builtin.individual.records", name: "Life Records Checkup",
        persona: "Individual",
        purpose: "Gather your records, verify them, resolve what disagrees, and produce a safe pack to keep or share.",
        operations: [
            op(1, "gather", "Gather",
               "Point the app at the folders holding your records.",
               launches: "sources", [
                f("scope", "What this checkup covers", .text,
                  "The life area this run is about — property, insurance, identity, family.",
                  placeholder: "Insurance & property papers", required: true),
               ]),
            op(2, "verifyDocs", "Verify Documents",
               "Check the custody chain — originals hashed and intact.",
               launches: "audit", [
                f("verified", "Integrity verified", .bool,
                  "Turn on after Verify integrity passes on the Audit screen."),
               ]),
            op(3, "organize", "Organize & Label",
               "Confirm the people, dates, and documents were understood correctly.",
               launches: "knowledge", [
                f("corrections", "Corrections made", .number,
                  "Names/dates you fixed while reviewing."),
               ]),
            op(4, "resolve", "Resolve Conflicts",
               "Where records disagree, decide which is current — both kept on file.",
               launches: "timeline", [
                f("resolved", "Conflicts resolved", .number,
                  "Disagreements you settled (the record keeps both sides)."),
               ]),
            op(5, "pack", "Share / Archive Pack",
               "Produce a redacted pack to share, or a sealed archive to keep. Posts an Archive document.",
               posts: "ARC", launches: "handoff", [
                f("packName", "Pack name", .text, "What to call this pack.", required: true),
               ]),
        ])
}

// MARK: - Generated per-job workflows

/// Turns each self-describing `JobDocumentation` row (the SAP-style coverage
/// matrix) into a FULL-RIGOR guided workflow so every documented job gains a
/// step-by-step Work Center flow with no per-job hand authoring:
///  • the job's ordered `workflow` becomes "open the tool and do it" steps,
///  • its `requiredInputs` become typed fields captured up front,
///  • its `humanDecisions` become REQUIRED confirm-gates (the app never makes
///    the call for the user), and
///  • its `workProducts` are posted as a numbered document at the end, gated on
///    those decisions being made.
/// Deterministic and persona-neutral — identical input always yields the same
/// definition, so it stays in lockstep with the coverage matrix.
public nonisolated enum WCJobWorkflowFactory {

    /// Stable definition id, keyed by the launchable PersonaJob id
    /// (e.g. "job.inv.case-intake").
    public static func defID(forJobKey jobID: String) -> String { "job.\(jobID)" }

    /// One guided workflow per launchable job: RICH when the job has a
    /// JobDocumentation row, otherwise SYNTHESIZED from its own title/detail/kind
    /// — so every persona job gets a real step-by-step flow.
    public static func make(_ job: PersonaJob) -> WCWorkflowDefinition {
        if let doc = doc(for: job) { return makeRich(job: job, doc: doc) }
        return makeFromDescriptor(job)
    }

    private static func makeRich(job: PersonaJob, doc: JobDocumentation) -> WCWorkflowDefinition {
        var ops: [WCOperation] = []
        let workSteps = steps(of: doc.workflow)

        // 1) The "do the work" steps, each opening the real surface for it.
        for (i, text) in workSteps.enumerated() {
            let seq = i + 1
            var fields: [WCField] = []
            if i == 0 {
                // Capture the job's required inputs up front (first one required).
                for (j, input) in doc.requiredInputs.enumerated() {
                    fields.append(WCField(
                        key: "in\(j)", label: input, kind: inputKind(input),
                        help: "Have this ready — the job needs it.", required: j == 0))
                }
            }
            fields.append(WCField(
                key: "notes\(seq)", label: "What you did", kind: .longText,
                help: "Optional — note what you did in this step; it's saved on the run."))
            ops.append(WCOperation(
                seq: seq, key: "s\(seq)", title: title(text),
                hint: stepHint(text, methods: doc.methods, first: i == 0),
                postsDocType: nil, launchesSurface: surface(for: text, methods: doc.methods),
                fields: fields, gates: afterPrevious(seq)))
        }

        // 2) The human decision(s) — the calls the app must never make.
        let decisions = doc.humanDecisions.isEmpty ? ["I've reviewed this job's steps"] : doc.humanDecisions
        let decideSeq = ops.count + 1
        let neverNote = doc.prohibitedConclusions.isEmpty ? ""
            : " This job never: \(doc.prohibitedConclusions.joined(separator: " · "))."
        ops.append(WCOperation(
            seq: decideSeq, key: "decide", title: "Your decision",
            hint: "These calls are yours — the app won't make them for you.\(neverNote)",
            postsDocType: nil, launchesSurface: nil,
            fields: decisions.enumerated().map { j, d in
                WCField(key: "decision\(j)", label: d, kind: .bool,
                        help: "A human-in-the-loop decision — turn on once you've made this call.",
                        required: true)
            },
            gates: afterPrevious(decideSeq)))

        // 3) Produce the work product — posts a numbered document, gated on the
        //    decisions above actually being made.
        let produceSeq = decideSeq + 1
        let code = docCode(for: doc.workProducts)
        let productLabel = doc.workProducts.first ?? "Work product"
        var produceGates = afterPrevious(produceSeq)
        for (j, d) in decisions.enumerated() {
            produceGates.append(WCGate(
                rule: .fieldEquals(seq: decideSeq, key: "decision\(j)", value: "Yes"),
                reason: "Make your decision first: \(d)."))
        }
        ops.append(WCOperation(
            seq: produceSeq, key: "produce", title: "Produce: \(productLabel)",
            hint: "Assemble the work product for the record. Posts a numbered \(WCDocType.displayName(code)) document.",
            postsDocType: code, launchesSurface: "handoff",
            fields: [
                WCField(key: "productName", label: "\(productLabel) name", kind: .text,
                        help: "Name this so it's findable in the Documents register.", required: true),
                WCField(key: "summary", label: "Summary", kind: .longText,
                        help: "What this work product concludes — written for the record, cited to your evidence."),
            ],
            gates: produceGates))

        return WCWorkflowDefinition(
            defID: defID(forJobKey: job.id), name: job.title,
            persona: doc.persona, purpose: purpose(doc), operations: ops)
    }

    /// Synthesized workflow for a job with NO JobDocumentation row: do the work
    /// (the job's own description) → your decision → produce a numbered document.
    private static func makeFromDescriptor(_ job: PersonaJob) -> WCWorkflowDefinition {
        var ops: [WCOperation] = []
        ops.append(WCOperation(
            seq: 1, key: "s1", title: job.title,
            hint: "\(job.detail) Open the tool and do the work, then confirm this step.",
            postsDocType: nil, launchesSurface: surface(forKind: job.kind),
            fields: [WCField(key: "notes1", label: "What you did", kind: .longText,
                             help: "Optional — note what you did; it's saved on the run.")],
            gates: []))
        let decideSeq = 2
        let decisionLabel = decision(forKind: job.kind)
        ops.append(WCOperation(
            seq: decideSeq, key: "decide", title: "Your decision",
            hint: "This call is yours — the app won't make it for you.",
            postsDocType: nil, launchesSurface: nil,
            fields: [WCField(key: "decision0", label: decisionLabel, kind: .bool,
                             help: "A human-in-the-loop decision — turn on once you've made this call.",
                             required: true)],
            gates: afterPrevious(decideSeq)))
        let produceSeq = 3
        let code = docCode(forKind: job.kind)
        ops.append(WCOperation(
            seq: produceSeq, key: "produce", title: "Produce: \(job.title) record",
            hint: "Assemble the work product for the record. Posts a numbered \(WCDocType.displayName(code)) document.",
            postsDocType: code, launchesSurface: "handoff",
            fields: [
                WCField(key: "productName", label: "Record name", kind: .text,
                        help: "Name this so it's findable in the Documents register.", required: true),
                WCField(key: "summary", label: "Summary", kind: .longText,
                        help: "What this concludes — written for the record, cited to your evidence."),
            ],
            gates: afterPrevious(produceSeq) + [
                WCGate(rule: .fieldEquals(seq: decideSeq, key: "decision0", value: "Yes"),
                       reason: "Make your decision first: \(decisionLabel).")
            ]))
        return WCWorkflowDefinition(
            defID: defID(forJobKey: job.id), name: job.title,
            persona: personaLabel(job.persona), purpose: job.detail, operations: ops)
    }

    /// Find the JobDocumentation row for a launchable job. The persona label is
    /// embedded in the applicationID (…persona.investigator); titles match the
    /// coverage-matrix name.
    private static func doc(for job: PersonaJob) -> JobDocumentation? {
        let appID = job.persona.lowercased()
        return JobDocumentationCatalog.all.first { d in
            appID.contains(personaKey(d.persona))
                && d.name.caseInsensitiveCompare(job.title) == .orderedSame
        }
    }

    private static func personaKey(_ label: String) -> String {
        (label.split(separator: "/").first.map(String.init) ?? label)
            .trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    /// Best-effort readable persona label from the id's last component.
    private static func personaLabel(_ applicationID: String) -> String {
        let last = applicationID.split(separator: ".").last.map(String.init) ?? applicationID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// Default surface per capability kind (a RootView Destination rawValue).
    private static func surface(forKind kind: PersonaJobKind) -> String {
        switch kind {
        case .caseIntake:          return "sources"
        case .ask:                 return "ask"
        case .methods:             return "matrix"
        case .dataLab:             return "dataLab"
        case .subjectDossier:      return "dossier"
        case .identityResolution:  return "knowledge"
        case .analysis:            return "matrix"
        case .sourceReliability:   return "review"
        case .contradictionGap:    return "review"
        case .causalAnalysis:      return "connections"
        case .linkage:             return "connections"
        case .capaRegister:        return "handoff"
        case .effectivenessReview: return "review"
        case .evidenceCustody:     return "audit"
        case .findings:            return "handoff"
        case .closure:             return "handoff"
        }
    }

    private static func decision(forKind kind: PersonaJobKind) -> String {
        switch kind {
        case .findings:   return "Approve this work product for the record"
        case .closure:    return "Confirm closure (a human decision)"
        case .caseIntake: return "Confirm the scope"
        default:          return "Confirm the result before producing"
        }
    }

    private static func docCode(forKind kind: PersonaJobKind) -> String {
        switch kind {
        case .evidenceCustody: return "PRS"
        case .closure:         return "EXP"
        default:               return "RPT"
        }
    }

    // MARK: helpers

    /// Split the documented workflow ("a; b; c") into ordered steps; a single
    /// phrase with no separators is one step.
    static func steps(of workflow: String) -> [String] {
        let parts = workflow.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [workflow.trimmingCharacters(in: .whitespaces)] : parts
    }

    private static func title(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The default sequential gate: each step waits on the one before it.
    private static func afterPrevious(_ seq: Int) -> [WCGate] {
        seq <= 1 ? [] : [WCGate(rule: .operationConfirmed(seq: seq - 1),
                                reason: "Finish step \(seq - 1) first.")]
    }

    private static func stepHint(_ text: String, methods: [String], first: Bool) -> String {
        let m = methods.isEmpty ? "" : " Methods: \(methods.joined(separator: ", "))."
        return first
            ? "Capture what the job needs, then open the tool to do the work.\(m)"
            : "Do this in the app, then confirm the step.\(m)"
    }

    private static func inputKind(_ input: String) -> WCField.Kind {
        let l = input.lowercased()
        if l.contains("date range") || l.contains("range") { return .dateRange }
        if l.contains("date") { return .date }
        return .text
    }

    private static func purpose(_ doc: JobDocumentation) -> String {
        let produces = doc.workProducts.isEmpty ? "" : " Produces \(doc.workProducts.joined(separator: ", "))."
        return "\(doc.workflow).\(produces)"
    }

    /// Map a step to the real surface where its work happens (a RootView
    /// Destination rawValue). Best-effort by keyword; a wrong guess only opens a
    /// different screen — it never blocks the step.
    private static func surface(for text: String, methods: [String]) -> String {
        let l = (text + " " + methods.joined(separator: " ")).lowercased()
        func has(_ ks: [String]) -> Bool { ks.contains { l.contains($0) } }
        if has(["custody", "preserve", "integrity", "chain", "audit"]) { return "audit" }
        if has(["timeline", "chronolog", "tick", "period"]) { return "timeline" }
        if has(["relationship", "graph", "network", "prosopograph", "linkage", "source map"]) { return "connections" }
        if has(["transaction", "asset", "flow", "calcul"]) { return "dataLab" }
        if has(["contradiction", "gap", "conflict", "reconcile", "reply", "response"]) { return "review" }
        if has(["search", "lead", "screen", "catalogue"]) { return "search" }
        if has(["5w1h", "worksheet", "matrix", "hypothes", "compare", "interpret", "synthes", "score"]) { return "matrix" }
        if has(["verify", "fact", "claim", "criticism", "reliab", "extract", "quote"]) { return "findings" }
        if has(["identity", "authority", "unify", "resolve", "entities", "metadata", "knowledge", "organize", "label"]) { return "knowledge" }
        if has(["report", "produce", "publish", "package", "edition", "export", "closure", "close", "pack", "binder", "assemble", "deliver", "handoff", "decision"]) { return "handoff" }
        return "sources"
    }

    /// Choose an existing document-type code for the job's work product.
    private static func docCode(for products: [String]) -> String {
        let l = products.joined(separator: " ").lowercased()
        if l.contains("pack") || l.contains("binder") || l.contains("archive") { return "ARC" }
        if l.contains("publication") || l.contains("package") { return "PUB" }
        if l.contains("edition") { return "EDN" }
        if l.contains("interview") || l.contains("statement") { return "INT" }
        if l.contains("request") || l.contains("foia") { return "REQ" }
        if l.contains("receipt") || l.contains("export") { return "EXP" }
        return "RPT"
    }
}
