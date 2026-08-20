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
        // 1) Hand-authored, faithful-to-the-real-process steps win when present.
        if let a = WCAuthoredWorkflows.workflow(forJobID: job.id) {
            return WCWorkflowDefinition(defID: defID(forJobKey: job.id), name: job.title,
                                        persona: personaLabel(job.persona),
                                        purpose: a.purpose, operations: a.ops)
        }
        // 2) Otherwise the coverage-matrix documentation, 3) else a generic shell.
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

// MARK: - Authored (faithful) job workflows

/// Hand-authored, profession-accurate workflows for specific jobs — the real
/// ordered steps a practitioner follows by hand, digitized here. Keyed by
/// PersonaJob.id; when present these OVERRIDE both the coverage-matrix build and
/// the generic shell (see WCJobWorkflowFactory.make). Depth is adaptive: quick
/// jobs stay short, complex ones expand. Every step also gets the runner's
/// shared per-step Note + Attach-files affordances, so nothing here restates them.
public nonisolated enum WCAuthoredWorkflows {

    public static func workflow(forJobID id: String) -> (purpose: String, ops: [WCOperation])? {
        guard let a = catalog[id] else { return nil }
        return (a.purpose, a.ops)
    }

    // MARK: builders

    private struct Authored { let purpose: String; let ops: [WCOperation] }

    /// A step spec; the sequence number and the "finish the previous step first"
    /// gate are assigned automatically by `build`.
    private struct Step {
        let key: String; let title: String; let hint: String
        let opens: String?; let posts: String?; let fields: [WCField]
        init(_ key: String, _ title: String, _ hint: String,
             opens: String? = nil, posts: String? = nil, _ fields: [WCField] = []) {
            self.key = key; self.title = title; self.hint = hint
            self.opens = opens; self.posts = posts; self.fields = fields
        }
    }

    private static func build(_ purpose: String, _ steps: [Step]) -> Authored {
        var ops: [WCOperation] = []
        for (i, s) in steps.enumerated() {
            let seq = i + 1
            let gates: [WCGate] = seq <= 1 ? [] :
                [WCGate(rule: .operationConfirmed(seq: seq - 1), reason: "Finish step \(seq - 1) first.")]
            ops.append(WCOperation(seq: seq, key: s.key, title: s.title, hint: s.hint,
                                   postsDocType: s.posts, launchesSurface: s.opens,
                                   fields: s.fields, gates: gates))
        }
        return Authored(purpose: purpose, ops: ops)
    }

    private static func f(_ key: String, _ label: String, _ kind: WCField.Kind, _ help: String,
                          required: Bool = false, placeholder: String = "",
                          options: [String] = []) -> WCField {
        WCField(key: key, label: label, kind: kind, help: help,
                placeholder: placeholder, required: required, options: options)
    }

    // MARK: Compliance / HR Investigator (2026-08-20)

    private static let catalog: [String: Authored] = [

        "hr.complaint-intake": build(
            "Open a workplace/compliance case: record the complaint, fix the scope and authority, set the evidence in scope, then open the case file. An intake never decides the merits.",
            [
                Step("complaint", "Record the complaint", "Capture the complaint as received — in the complainant's own words.", opens: "sources", [
                    f("ref", "Complaint reference", .text, "Your own case/complaint number.", required: true, placeholder: "HR-2026-0001"),
                    f("receivedOn", "Received on", .date, "When the complaint came in — anchors the timeline."),
                    f("from", "Received from / how", .text, "Complainant and channel (hotline, email, manager)."),
                    f("summary", "What is alleged", .longText, "The allegation(s) in the complainant's words — not your assessment.", required: true),
                ]),
                Step("scope", "Define scope & authority", "Fix what this investigation covers and under whose authority.", opens: "sources", [
                    f("authority", "Authority", .choice, "The mandate this investigation runs under.", required: true, options: ["Company policy", "Regulatory requirement", "Management directive", "Legal instruction", "Other"]),
                    f("scope", "Scope statement", .longText, "What is in and out of scope — the boundary to stay within.", required: true),
                    f("window", "Time window", .dateRange, "The period the investigation covers."),
                ]),
                Step("inscope", "Set the evidence in scope", "Point the case at the authorized documents (mailboxes, drives, records).", opens: "sources", [
                    f("sources", "Sources in scope", .longText, "Which document sets are authorized — the hard evidence boundary."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "A human confirms scope and authority before any work. The app never decides the merits.", [
                    f("decision", "Scope confirmed?", .choice, "Confirm only when scope and authority are correct.", required: true, options: ["Confirmed", "Needs revision"]),
                    f("basis", "Note", .longText, "Anything to record about the scope decision."),
                ]),
                Step("open", "Open the case file", "Open the numbered case the rest of the jobs run against.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Case name", .text, "A findable name for this case.", required: true),
                ]),
            ]),

        "hr.ask": build(
            "Ask a question over the case's authorized documents and keep the cited answer on the record.",
            [
                Step("ask", "Ask the record", "Ask in plain language — the answer is grounded in the case's authorized evidence and cites it.", opens: "ask", [
                    f("question", "Your question", .longText, "What you need to know from the case file.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters so it's quotable later.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How this answer bears on the allegations."),
                ]),
            ]),

        "hr.allegations": build(
            "Frame each allegation with 5W1H, link the evidence, and record its status — an allegation is unproven until found.",
            [
                Step("list", "List the allegations", "Break the complaint into distinct, testable allegations.", opens: "findings", [
                    f("allegations", "Allegations", .longText, "One allegation per line — each specific enough to test.", required: true),
                ]),
                Step("frame", "Frame each with 5W1H", "For each allegation: who, what, when, where, why, how.", opens: "matrix", [
                    f("fiveW", "5W1H per allegation", .longText, "Who did what, to whom, when and where, and how you know.", required: true),
                ]),
                Step("evidence", "Link the evidence", "Attach or cite the documents that speak to each allegation.", opens: "findings", [
                    f("evidenceNote", "Evidence per allegation", .longText, "Which documents support or rebut each allegation."),
                ]),
                Step("status", "Record status (your decision)", "Record a status per allegation with its basis — never state a finding you can't support.", posts: "ALG", [
                    f("status", "Status per allegation", .longText, "Substantiated / not substantiated / unfounded / inconclusive — with basis for each.", required: true),
                ]),
            ]),

        "hr.parties": build(
            "Profile the complainant, respondent(s) and witnesses from cited evidence, and confirm each identity.",
            [
                Step("identify", "Identify the parties", "List everyone the case involves and their role.", opens: "dossier", [
                    f("parties", "Parties", .longText, "Complainant, respondent(s), witnesses — one per line with role.", required: true),
                ]),
                Step("profile", "Compile each profile", "Build each profile only from cited evidence.", opens: "dossier", [
                    f("profiles", "Profiles", .longText, "For each party: role, relationships, relevant cited facts."),
                ]),
                Step("confirm", "Confirm identities (your decision)", "Confirm each profile maps to the right real person.", [
                    f("basis", "Confirmation & basis", .longText, "Confirm each identity, or flag any you cannot — with basis.", required: true),
                ]),
                Step("produce", "Produce party profiles", "Assemble the profiles for the case file.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "hr.name-resolution": build(
            "Decide whether names/accounts are the same person: gather identifiers, compare across evidence, rule out look-alikes, then confirm or reject — reversible, never automatic.",
            [
                Step("gather", "Gather the identifiers", "Collect every name, email, username or account ID that might be the same person.", opens: "knowledge", [
                    f("identifiers", "Candidate identifiers", .longText, "All the identifiers in play — one per line.", required: true),
                ]),
                Step("compare", "Compare across the evidence", "See how each identifier appears across the documents.", opens: "knowledge", [
                    f("comparison", "Matching & conflicting signals", .longText, "Where the identifiers co-occur, and where they conflict."),
                ]),
                Step("ruleout", "Rule out coincidental matches", "Consider look-alikes (common names, shared devices) and exclude them.", opens: "review", [
                    f("ruledOut", "Look-alikes excluded", .longText, "Candidates you considered and ruled out, with the reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "A human decides identity. The app never auto-merges.", [
                    f("decision", "Decision", .choice, "Your identity decision — reversible later.", required: true, options: ["Confirm same person", "Reject — different people", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "The evidence behind your decision.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible identity decision to the case file.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this resolution record.", required: true),
                ]),
            ]),

        "hr.incident-timeline": build(
            "Build the incident chronology with relationship links, flagging gaps and conflicts — absence is not proof.",
            [
                Step("collect", "Collect dated events", "Gather every dated event, each with its source.", opens: "timeline", [
                    f("events", "Events", .longText, "Each event: date, what happened, source — one per line.", required: true),
                ]),
                Step("link", "Order & link", "Put events in order and link the parties involved.", opens: "connections", [
                    f("links", "Links", .longText, "Who was involved in what, and how events relate."),
                ]),
                Step("gaps", "Flag gaps & conflicts", "Note missing periods and conflicting dates — keep both sides.", opens: "review", [
                    f("gaps", "Gaps & conflicts", .longText, "Where the record is silent or accounts disagree."),
                ]),
                Step("produce", "Produce the chronology", "Assemble the cited chronology.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this chronology.", required: true),
                ]),
            ]),

        "hr.evidence-register": build(
            "Register the documentary evidence (emails, records, policies) with cited cells, and check it for gaps.",
            [
                Step("assemble", "Assemble the documents", "Gather the documents this register covers (attach any not yet ingested).", opens: "sources", [
                    f("scope", "What this covers", .text, "The document set this register indexes.", required: true),
                ]),
                Step("register", "Build the register", "Index each document with the columns that matter.", opens: "dataLab", [
                    f("columns", "Register columns & notes", .longText, "Date, author, type, relevance — every cell traceable to its source."),
                ]),
                Step("quality", "Check quality & gaps", "Flag missing, undated or unauthenticated items.", opens: "dataLab", [
                    f("quality", "Quality issues", .longText, "Anything missing or unverified a reviewer should know."),
                ]),
                Step("produce", "Produce the register", "Assemble the evidence register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "hr.statements": build(
            "Compare the parties' accounts point by point, preserving conflicts rather than averaging them — due process depends on it.",
            [
                Step("collect", "Collect the accounts", "Gather each party's statement (attach interview notes/recordings).", opens: "findings", [
                    f("accounts", "Accounts", .longText, "Each account, attributed and cited.", required: true),
                ]),
                Step("compare", "Compare point by point", "Line up the accounts on each disputed point.", opens: "matrix", [
                    f("comparison", "Agreement & conflict", .longText, "Where accounts agree, and where they conflict — keep both sides."),
                ]),
                Step("conflicts", "Record unresolved conflicts", "Note conflicts that remain open — never resolved by averaging.", opens: "review", [
                    f("conflicts", "Open conflicts", .longText, "Conflicts still unresolved, and why."),
                ]),
                Step("produce", "Produce the comparison", "Assemble the statement comparison.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this comparison.", required: true),
                ]),
            ]),

        "hr.credibility": build(
            "Assess the reliability and independence of each account — a rating is a judgement, never a fact.",
            [
                Step("list", "List the accounts", "List each account/source you'll assess.", opens: "review", [
                    f("sources", "Accounts", .longText, "Each account/source, one per line.", required: true),
                ]),
                Step("assess", "Assess each account", "Weigh consistency, corroboration, bias and opportunity to observe.", opens: "review", [
                    f("factors", "Assessment factors", .longText, "For each account: what strengthens or weakens its reliability."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low per account — a judgement, not proof."),
                ]),
                Step("decide", "Record your judgement (your decision)", "Own the ratings as your assessment.", [
                    f("basis", "Basis", .longText, "Confirm the ratings and note these are judgements, not findings.", required: true),
                ]),
                Step("produce", "Produce the assessment", "Assemble the credibility assessment.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this assessment.", required: true),
                ]),
            ]),

        "hr.interview-prep": build(
            "Prepare an interview grounded in the record: what to establish, non-leading questions tied to evidence, and the logistics and rights.",
            [
                Step("review", "Review the record", "See what the evidence already shows and what's missing.", opens: "ask", [
                    f("focus", "What to establish", .longText, "The points this interview needs to clarify or confirm.", required: true),
                ]),
                Step("questions", "Draft the questions", "Open, non-leading questions, each tied to specific evidence.", opens: "matrix", [
                    f("questions", "Questions", .longText, "The question list — grouped by topic, evidence-anchored.", required: true),
                ]),
                Step("logistics", "Plan logistics & rights", "Who, when, support person, and any notice/rights to state.", opens: "handoff", [
                    f("logistics", "Logistics & rights", .longText, "Arrangements and the rights/notice to give the interviewee."),
                ]),
                Step("produce", "Produce the interview plan", "Assemble the interview plan.", opens: "handoff", posts: "INT", [
                    f("title", "Title", .text, "Name this interview plan.", required: true),
                ]),
            ]),

        "hr.root-cause": build(
            "Find why it happened: Five Whys down the causal chain, Fishbone across cause categories, weigh the candidates, then record the human root-cause determination — the app never confirms a cause.",
            [
                Step("problem", "State the problem", "Define the confirmed issue precisely.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "The issue to explain — specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Trace cause to cause; stop where the evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Why → because → why → because … each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes by category.", opens: "matrix", [
                    f("categories", "Cause categories", .longText, "People / process / policy / systems / environment."),
                ]),
                Step("weigh", "Weigh the candidates", "Evidence for and against each candidate cause.", opens: "review", [
                    f("weighing", "For / against", .longText, "What supports or rules out each candidate cause."),
                ]),
                Step("determine", "Root-cause determination (your decision)", "A human determines the root cause(s). The app never confirms one.", [
                    f("determination", "Determination & basis", .longText, "The root cause(s) you determine, and why.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the root-cause analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "hr.evidence-custody": build(
            "Keep a defensible chain of custody: register each exhibit, record acquisition and integrity, log transfers, then seal the manifest.",
            [
                Step("register", "Register the exhibits", "List each item collected, with where it came from (attach the originals).", opens: "audit", [
                    f("exhibits", "Exhibits", .longText, "Each exhibit: what it is and its source.", required: true),
                ]),
                Step("acquire", "Acquisition & integrity", "Record how each item entered custody without being altered.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How the material was taken into custody.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from system/service", "Physical/device transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after running Verify integrity on the Audit screen."),
                ]),
                Step("transfers", "Log custody transfers", "Who held what, and when.", opens: "audit", [
                    f("transfers", "Custody transfers", .longText, "Each hand-off: from, to, when, why."),
                ]),
                Step("seal", "Seal the custody manifest", "Post the sealed custody manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this manifest.", required: true),
                ]),
            ]),

        "hr.findings-memo": build(
            "Reach findings on the balance of probabilities: recap scope, marshal the evidence per allegation, apply the standard, record findings with basis, note limitations, then produce the memo — never assert an unproven finding.",
            [
                Step("recap", "Restate scope & allegations", "Anchor the memo in the case's scope and allegations.", opens: "findings", [
                    f("recap", "Scope & allegations", .longText, "The allegations being decided and the scope they're decided within.", required: true),
                ]),
                Step("marshal", "Marshal the evidence", "For each allegation, line up the evidence for and against (attach key exhibits).", opens: "findings", [
                    f("evidence", "Evidence per allegation", .longText, "The cited evidence bearing on each allegation."),
                ]),
                Step("standard", "Apply the standard of proof", "Balance of probabilities — is each allegation more likely than not?", opens: "matrix", [
                    f("reasoning", "Reasoning", .longText, "How the evidence meets or falls short of the standard, per allegation."),
                ]),
                Step("findings", "Record findings (your decision)", "The human finding for each allegation, with its basis.", [
                    f("findings", "Findings", .longText, "Substantiated / not substantiated per allegation — with basis. Do not assert findings the evidence doesn't support.", required: true),
                ]),
                Step("limits", "Note limitations", "Record gaps, refusals and unresolved conflicts — honest closure.", opens: "review", [
                    f("limitations", "Limitations", .longText, "What remains uncertain or was outside reach."),
                ]),
                Step("produce", "Produce the findings memo", "Assemble the findings memo with its sealed receipt.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this memo.", required: true),
                ]),
            ]),

        "hr.corrective-actions": build(
            "Turn findings and root causes into tracked corrective and preventive actions with owners and due dates.",
            [
                Step("link", "Link actions to causes", "Tie each planned action to the finding or root cause it addresses.", opens: "findings", [
                    f("links", "Action ↔ cause", .longText, "Which finding/root cause each action responds to.", required: true),
                ]),
                Step("define", "Define the actions", "Specify each action, its type, owner and due date.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Each action: description, corrective vs preventive, owner, due date.", required: true),
                ]),
                Step("assign", "Agree owners & dates (your decision)", "Confirm each owner and due date is agreed.", [
                    f("basis", "Confirmation", .longText, "Confirm owners and dates, or note what's still open.", required: true),
                ]),
                Step("produce", "Produce the CAPA register", "Assemble the corrective-actions register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "hr.action-review": build(
            "Verify a completed action actually fixed the issue — never declare it effective without evidence.",
            [
                Step("select", "Select the action", "Pick the completed action you're reviewing.", opens: "handoff", [
                    f("action", "Action under review", .text, "Which corrective/preventive action.", required: true),
                ]),
                Step("evidence", "Gather post-action evidence", "Collect evidence of whether the issue recurred (attach it).", opens: "findings", [
                    f("evidence", "Post-action evidence", .longText, "What has (or hasn't) happened since the action."),
                ]),
                Step("judge", "Judge effectiveness (your decision)", "Decide, on the evidence, whether the action worked.", [
                    f("verdict", "Verdict", .choice, "Your evidence-based verdict.", required: true, options: ["Effective", "Partially effective", "Not effective"]),
                    f("basis", "Basis", .longText, "The evidence behind the verdict.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the effectiveness review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "hr.closure": build(
            "Close the case by an explicit human decision — unresolved items retained, and reopening preserves the prior closure.",
            [
                Step("recap", "Confirm findings & actions", "Check findings are approved and actions tracked to closure.", opens: "handoff", [
                    f("recap", "Closure recap", .longText, "State of findings, actions, and any items left open."),
                ]),
                Step("retention", "Retention & confidentiality", "Record where the file is kept and who may access it.", opens: "handoff", [
                    f("retention", "Retention & access", .longText, "Storage, retention period, and access restrictions."),
                ]),
                Step("decide", "Closure decision (your decision)", "A human closes or keeps the case open. The app never closes on its own.", [
                    f("decision", "Decision", .choice, "Close only when it's genuinely complete.", required: true, options: ["Close the case", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening later preserves this closure.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and sealed receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this closure record.", required: true),
                ]),
            ]),

        // MARK: Insurance Fraud (SIU) (2026-08-20)

        "siu.claim-intake": build(
            "Open a claim file for investigation: record the claim, fix the referral basis and scope, set the documents in scope, then open the file. Intake never concludes fraud.",
            [
                Step("claim", "Record the claim", "Capture the claim as presented at FNOL.", opens: "sources", [
                    f("claimNo", "Claim number", .text, "The insurer's claim reference.", required: true),
                    f("dateOfLoss", "Date of loss", .date, "When the loss is said to have occurred."),
                    f("policyNo", "Policy number", .text, "The policy the claim is made under."),
                    f("summary", "The claim", .longText, "Loss type, amount claimed, parties — as presented.", required: true),
                ]),
                Step("scope", "Referral basis & scope", "Why this claim is under investigation, and what the investigation covers.", opens: "sources", [
                    f("basis", "Referral basis", .choice, "What put this claim into SIU.", required: true, options: ["Red flags at FNOL", "Adjuster referral", "SIU trigger/rule", "Regulatory", "Other"]),
                    f("scope", "Scope statement", .longText, "What is in and out of scope for this investigation.", required: true),
                ]),
                Step("inscope", "Set the documents in scope", "Authorize the claim file, policy, prior claims and statements.", opens: "sources", [
                    f("sources", "Documents in scope", .longText, "The authorized document set — the evidence boundary."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "A human confirms scope before work begins.", [
                    f("decision", "Scope confirmed?", .choice, "Confirm only when correct.", required: true, options: ["Confirmed", "Needs revision"]),
                    f("note", "Note", .longText, "Anything to record about the decision."),
                ]),
                Step("open", "Open the claim file", "Open the numbered file the rest of the jobs run against.", opens: "handoff", posts: "IMP", [
                    f("caseName", "File name", .text, "A findable name for this claim file.", required: true),
                ]),
            ]),

        "siu.ask": build(
            "Ask a question over the claim's authorized documents and keep the cited answer on the record.",
            [
                Step("ask", "Ask the claim file", "Ask in plain language — the answer cites the claim's evidence.", opens: "ask", [
                    f("question", "Your question", .longText, "What you need to know from the claim file.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters to the investigation.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How this answer bears on the exposure."),
                ]),
            ]),

        "siu.red-flags": build(
            "Record fraud indicators with 5W1H and cite what supports each — red flags are indicators, never proof.",
            [
                Step("list", "List the indicators", "Every red flag observed in the file.", opens: "findings", [
                    f("indicators", "Indicators", .longText, "One indicator per line.", required: true),
                ]),
                Step("frame", "Frame each (5W1H)", "Who/what/when/where/how for each indicator.", opens: "matrix", [
                    f("fiveW", "5W1H per indicator", .longText, "The specifics behind each red flag."),
                ]),
                Step("cite", "Cite what supports each", "Tie each indicator to the document that raised it.", opens: "findings", [
                    f("evidence", "Evidence per indicator", .longText, "The document behind each indicator."),
                ]),
                Step("weigh", "Weigh the pattern (your decision)", "What the indicators collectively suggest — never conclude fraud here.", posts: "ALG", [
                    f("assessment", "Assessment", .longText, "Which indicators hold up and what they point to.", required: true),
                ]),
            ]),

        "siu.claimant-workup": build(
            "Work up the claimant/provider from cited in-scope evidence, and confirm the identity/associations.",
            [
                Step("identify", "Identify the subject", "Who you're working up and why.", opens: "dossier", [
                    f("subject", "Subject", .text, "Claimant, provider, or associate.", required: true),
                ]),
                Step("compile", "Compile the workup", "Background, prior history, relationships — each cited.", opens: "dossier", [
                    f("profile", "Workup", .longText, "Only what the in-scope evidence supports."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm identity and associations, with basis.", [
                    f("basis", "Confirmation & basis", .longText, "What you confirm and how you know.", required: true),
                ]),
                Step("produce", "Produce the workup", "Assemble the workup for the file.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this workup.", required: true),
                ]),
            ]),

        "siu.identity": build(
            "Decide whether names/aliases/entities are the same party: gather identifiers, compare, rule out look-alikes, then confirm or reject — reversible, human-gated.",
            [
                Step("gather", "Gather identifiers", "Names, aliases, entities, accounts that may be one party.", opens: "knowledge", [
                    f("identifiers", "Candidate identifiers", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across evidence", "How each identifier appears across the file.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Exclude coincidental matches, with reason.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "Candidates ruled out and why."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "A human decides identity. Never automatic.", [
                    f("decision", "Decision", .choice, "Reversible later.", required: true, options: ["Confirm same party", "Reject — different parties", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "The evidence behind it.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible identity decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "siu.loss-chronology": build(
            "Build the loss chronology with relationship links and payment flow, flagging gaps and conflicts.",
            [
                Step("events", "Collect dated events", "From FNOL to now, each event cited.", opens: "timeline", [
                    f("events", "Events", .longText, "Date, event, source — one per line.", required: true),
                ]),
                Step("links", "Order & link parties", "How claimants, providers and prior claims connect.", opens: "connections", [
                    f("links", "Links", .longText, "Relationships across the file."),
                ]),
                Step("payments", "Trace the payment flow", "Payments and settlements, dated and cited.", opens: "dataLab", [
                    f("payments", "Payment flow", .longText, "Where money moved and when."),
                ]),
                Step("gaps", "Flag gaps & conflicts", "Missing periods and conflicting dates.", opens: "review", [
                    f("gaps", "Gaps & conflicts", .longText, "Kept, not averaged."),
                ]),
                Step("produce", "Produce the chronology", "Assemble the cited chronology.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this chronology.", required: true),
                ]),
            ]),

        "siu.prior-claims": build(
            "Register prior and related claims with cited cells, and note any pattern.",
            [
                Step("assemble", "Assemble the claims", "Which prior/related claims to index (attach any not ingested).", opens: "sources", [
                    f("scope", "What this covers", .text, "The claims this register spans.", required: true),
                ]),
                Step("register", "Build the register", "Index each claim.", opens: "dataLab", [
                    f("columns", "Columns & notes", .longText, "Date, insurer, loss type, amount, outcome — cited."),
                ]),
                Step("pattern", "Note the pattern", "Repetition or links worth flagging.", opens: "dataLab", [
                    f("pattern", "Pattern", .longText, "What the register reveals — an observation, not a conclusion."),
                ]),
                Step("produce", "Produce the register", "Assemble the prior-claims register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "siu.statements": build(
            "Compare statements point by point, preserving conflicting accounts rather than averaging them.",
            [
                Step("collect", "Collect the statements", "Each statement, attributed and cited (attach recordings/notes).", opens: "findings", [
                    f("accounts", "Statements", .longText, "Each account.", required: true),
                ]),
                Step("compare", "Compare point by point", "On each disputed point.", opens: "matrix", [
                    f("comparison", "Agreement & conflict", .longText, "Both sides preserved."),
                ]),
                Step("conflicts", "Record unresolved conflicts", "Conflicts left open.", opens: "review", [
                    f("conflicts", "Open conflicts", .longText, "Never averaged."),
                ]),
                Step("produce", "Produce the comparison", "Assemble the comparison.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this comparison.", required: true),
                ]),
            ]),

        "siu.source-vetting": build(
            "Assess the reliability and independence of statements and documents — a rating is a judgement, not a fact.",
            [
                Step("list", "List the sources", "Each statement/document to vet.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Consistency, corroboration, bias, provenance.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low — a judgement."),
                ]),
                Step("decide", "Own the ratings (your decision)", "These are your judgements.", [
                    f("basis", "Basis", .longText, "Confirm the ratings, noting they're judgements.", required: true),
                ]),
                Step("produce", "Produce the assessment", "Assemble the vetting.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this assessment.", required: true),
                ]),
            ]),

        "siu.euo-prep": build(
            "Prepare an examination under oath grounded in the record: what to establish, sworn-exam questions, and logistics.",
            [
                Step("review", "Review the record", "What the EUO must establish or resolve.", opens: "ask", [
                    f("focus", "What to establish", .longText, "The points to cover.", required: true),
                ]),
                Step("questions", "Draft the questions", "Evidence-anchored questions for the examination.", opens: "matrix", [
                    f("questions", "Questions", .longText, "Grouped by topic.", required: true),
                ]),
                Step("logistics", "Plan logistics", "Notice, counsel, oath, scheduling.", opens: "handoff", [
                    f("logistics", "Logistics", .longText, "Arrangements and any rights/notice."),
                ]),
                Step("produce", "Produce the EUO plan", "Assemble the examination plan.", opens: "handoff", posts: "INT", [
                    f("title", "Title", .text, "Name this plan.", required: true),
                ]),
            ]),

        "siu.causation": build(
            "Trace how the loss occurred: Five Whys, Fishbone, then a human determination — never state fraud as a conclusion here.",
            [
                Step("problem", "State the loss", "The loss to explain, precisely.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "e.g. mechanism, timing, opportunity, documentation."),
                ]),
                Step("determine", "Determination (your decision)", "A human determines how the loss occurred.", [
                    f("determination", "Determination & basis", .longText, "How the loss occurred, on the evidence.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the causation analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "siu.custody": build(
            "Keep a defensible evidence locker: register exhibits, record acquisition and integrity, log transfers, then seal the manifest.",
            [
                Step("register", "Register the exhibits", "Each item collected, with source (attach originals).", opens: "audit", [
                    f("exhibits", "Exhibits", .longText, "What each item is and where it came from.", required: true),
                ]),
                Step("acquire", "Acquisition & integrity", "How each item entered custody unaltered.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from system/service", "Physical/device transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("transfers", "Log custody transfers", "Who held what, when.", opens: "audit", [
                    f("transfers", "Transfers", .longText, "Each hand-off."),
                ]),
                Step("seal", "Seal the manifest", "Post the sealed custody manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this manifest.", required: true),
                ]),
            ]),

        "siu.referral-report": build(
            "Assemble a referral-ready SIU report: recap, marshal the evidence, assess, recommend — a referral is a recommendation, never a finding of guilt.",
            [
                Step("recap", "Recap the claim & indicators", "Claim, scope, and the indicators found.", opens: "findings", [
                    f("recap", "Recap", .longText, "The picture so far.", required: true),
                ]),
                Step("marshal", "Marshal the evidence", "Evidence for and against material misrepresentation (attach exhibits).", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What the record supports — and what it doesn't."),
                ]),
                Step("assess", "Assess the exposure", "What the evidence establishes.", opens: "matrix", [
                    f("assessment", "Assessment", .longText, "Strengths and gaps."),
                ]),
                Step("decide", "Recommendation (your decision)", "Recommend a disposition — not a finding of guilt.", [
                    f("recommendation", "Recommendation", .choice, "Your recommendation.", required: true, options: ["Refer (SIU/NICB/DOI)", "Do not refer", "Continue investigation"]),
                    f("basis", "Basis", .longText, "The basis for the recommendation.", required: true),
                ]),
                Step("produce", "Produce the SIU report", "Assemble the report with its sealed receipt.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this report.", required: true),
                ]),
            ]),

        "siu.recovery-actions": build(
            "Track recovery, referral and follow-up actions to closure.",
            [
                Step("link", "Link actions to the exposure", "What each action addresses.", opens: "findings", [
                    f("links", "Action ↔ exposure", .longText, "Which finding/exposure each action responds to.", required: true),
                ]),
                Step("define", "Define the actions", "Action, owner, due date, type.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Recovery/referral/follow-up — with owner and due date.", required: true),
                ]),
                Step("assign", "Agree owners & dates (your decision)", "Confirm each is agreed.", [
                    f("basis", "Confirmation", .longText, "Confirm owners and dates.", required: true),
                ]),
                Step("produce", "Produce the actions register", "Assemble the register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "siu.action-review": build(
            "Verify a completed action actually resolved the exposure — never declare it resolved without evidence.",
            [
                Step("select", "Select the action", "Which completed action you're reviewing.", opens: "handoff", [
                    f("action", "Action", .text, "The action under review.", required: true),
                ]),
                Step("evidence", "Gather evidence", "Evidence of the outcome (attach it).", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What happened since."),
                ]),
                Step("judge", "Judge effectiveness (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Effective", "Partially effective", "Not effective"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "siu.closure": build(
            "Close the claim file by an explicit human decision — unresolved items retained, reopening preserves the prior closure.",
            [
                Step("recap", "Confirm outcome", "Report, actions, and any items left open.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the file."),
                ]),
                Step("retention", "Retention & confidentiality", "Where the file is kept and who may access it.", opens: "handoff", [
                    f("retention", "Retention & access", .longText, "Storage, retention, access."),
                ]),
                Step("decide", "Closure decision (your decision)", "A human closes or keeps the file open.", [
                    f("decision", "Decision", .choice, "Close only when complete.", required: true, options: ["Close the file", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves this closure.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Forensic Accountant (2026-08-20)

        "fa.engagement": build(
            "Open a forensic engagement: record the mandate, fix scope and standards, set records in scope, then open the engagement.",
            [
                Step("record", "Record the engagement", "What you're engaged to do.", opens: "sources", [
                    f("ref", "Engagement number", .text, "Your engagement/matter reference.", required: true),
                    f("client", "Retaining party", .text, "Who retained you (counsel, company, court)."),
                    f("mandate", "Mandate", .longText, "The question to answer — trace funds, quantify loss, opine.", required: true),
                ]),
                Step("scope", "Scope & standards", "The boundary and the standards you'll work to.", opens: "sources", [
                    f("scope", "Scope statement", .longText, "In and out of scope.", required: true),
                    f("standards", "Standards", .choice, "The professional standards this work follows.", options: ["AICPA / consulting standards", "Court-directed", "Internal policy", "Other"]),
                ]),
                Step("inscope", "Set records in scope", "Authorize ledgers, bank statements, invoices.", opens: "sources", [
                    f("sources", "Records in scope", .longText, "The authorized records — the evidence boundary."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "A human confirms scope before work.", [
                    f("decision", "Scope confirmed?", .choice, "Confirm only when correct.", required: true, options: ["Confirmed", "Needs revision"]),
                    f("note", "Note", .longText, "Anything to record."),
                ]),
                Step("open", "Open the engagement", "Open the numbered engagement.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Engagement name", .text, "A findable name.", required: true),
                ]),
            ]),

        "fa.ask": build(
            "Ask a question over the engagement's records and keep the cited answer on the record.",
            [
                Step("ask", "Ask the records", "The answer cites the engagement's evidence.", opens: "ask", [
                    f("question", "Your question", .longText, "What you need from the records.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it bears on the mandate."),
                ]),
            ]),

        "fa.funds-tracing": build(
            "Follow the money: identify accounts and parties, trace the transactions, map the flow, flag gaps and commingling, then produce the flow.",
            [
                Step("accounts", "Identify accounts & parties", "The accounts and entities in the flow.", opens: "connections", [
                    f("accounts", "Accounts & parties", .longText, "One per line.", required: true),
                ]),
                Step("trace", "Trace the transactions", "Source→destination movements, dated and cited.", opens: "dataLab", [
                    f("transactions", "Transactions", .longText, "Each movement traced to its source document."),
                ]),
                Step("map", "Map the flow & links", "How money moved between parties.", opens: "connections", [
                    f("flow", "Flow", .longText, "The path of the funds."),
                ]),
                Step("gaps", "Flag gaps & commingling", "Missing statements, commingled funds, unexplained transfers.", opens: "review", [
                    f("gaps", "Gaps", .longText, "Absence is not proof."),
                ]),
                Step("produce", "Produce the flow", "Assemble the funds-flow work product.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "fa.tracing-schedule": build(
            "Build tracing schedules where every cell cites its source, and reconcile to the ledgers.",
            [
                Step("assemble", "Assemble the records", "Which statements/ledgers this schedule spans (attach any not ingested).", opens: "sources", [
                    f("scope", "What this covers", .text, "The records indexed.", required: true),
                ]),
                Step("build", "Build the schedule", "Index each transaction.", opens: "dataLab", [
                    f("columns", "Columns & notes", .longText, "Date, payer, payee, amount, source doc — every cell cited."),
                ]),
                Step("reconcile", "Reconcile & note variances", "Tie to bank/ledger totals.", opens: "dataLab", [
                    f("reconcile", "Reconciliation", .longText, "Ties and variances."),
                ]),
                Step("produce", "Produce the schedule", "Assemble the tracing schedule.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this schedule.", required: true),
                ]),
            ]),

        "fa.payee-workup": build(
            "Work up a payee, vendor or counterparty from cited in-scope evidence, and confirm the entity.",
            [
                Step("identify", "Identify the entity", "Who/what you're working up.", opens: "dossier", [
                    f("subject", "Entity", .text, "Payee, vendor, counterparty.", required: true),
                ]),
                Step("compile", "Compile the workup", "Registration, ownership, relationships — each cited.", opens: "dossier", [
                    f("profile", "Workup", .longText, "Only what the evidence supports."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the entity and associations.", [
                    f("basis", "Confirmation & basis", .longText, "What you confirm and how.", required: true),
                ]),
                Step("produce", "Produce the workup", "Assemble the workup.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this workup.", required: true),
                ]),
            ]),

        "fa.entity-resolution": build(
            "Resolve shell names and aliases to one entity: gather identifiers, compare, rule out look-alikes, then confirm or reject — reversible, human-gated.",
            [
                Step("gather", "Gather identifiers", "Names, aliases, registrations that may be one entity.", opens: "knowledge", [
                    f("identifiers", "Candidate identifiers", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across evidence", "How each appears across the records.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Exclude coincidental matches.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "A human decides. Never automatic.", [
                    f("decision", "Decision", .choice, "Reversible later.", required: true, options: ["Confirm same entity", "Reject — different entities", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "The evidence behind it.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "fa.discrepancies": build(
            "Surface where the records disagree or are absent — absence is not proof.",
            [
                Step("collect", "Collect the records", "The records in question.", opens: "findings", [
                    f("items", "Records", .longText, "What you're comparing.", required: true),
                ]),
                Step("compare", "Compare", "Where the records disagree.", opens: "matrix", [
                    f("comparison", "Discrepancies", .longText, "Each disagreement, cited."),
                ]),
                Step("missing", "Note missing records", "What should exist but doesn't.", opens: "review", [
                    f("missing", "Missing", .longText, "Absence noted, not concluded from."),
                ]),
                Step("produce", "Produce the schedule", "Assemble the discrepancy schedule.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this schedule.", required: true),
                ]),
            ]),

        "fa.doc-reliability": build(
            "Assess the origin and reliability of ledgers, invoices and statements — a rating is a judgement, not a fact.",
            [
                Step("list", "List the records", "Each record to assess.", opens: "review", [
                    f("sources", "Records", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Origin, custody, corroboration.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low — a judgement."),
                ]),
                Step("decide", "Own the ratings (your decision)", "These are your judgements.", [
                    f("basis", "Basis", .longText, "Confirm the ratings.", required: true),
                ]),
                Step("produce", "Produce the assessment", "Assemble the assessment.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this assessment.", required: true),
                ]),
            ]),

        "fa.analysis": build(
            "Frame hypotheses and the evidence plan for the engagement (5W1H).",
            [
                Step("hypotheses", "State the hypotheses", "The explanations to test.", opens: "findings", [
                    f("hypotheses", "Hypotheses", .longText, "Each testable, one per line.", required: true),
                ]),
                Step("fiveW", "5W1H", "Over the engagement question.", opens: "matrix", [
                    f("fiveW", "5W1H", .longText, "Who/what/when/where/why/how."),
                ]),
                Step("plan", "Plan the evidence", "What each hypothesis needs.", opens: "review", [
                    f("plan", "Evidence plan", .longText, "Requests and tests per hypothesis."),
                ]),
                Step("produce", "Produce the worksheet", "Assemble the analysis worksheet.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this worksheet.", required: true),
                ]),
            ]),

        "fa.methods": build(
            "Run a structured method over the cited record — a method flags, it doesn't conclude.",
            [
                Step("pick", "Pick the method", "Which structured method.", opens: "matrix", [
                    f("method", "Method", .text, "e.g. Benford's law, ratio/variance analysis.", required: true),
                ]),
                Step("run", "Run it", "Inputs and what it surfaced.", opens: "dataLab", [
                    f("runNote", "Result", .longText, "What the method flagged — an indicator, not a conclusion."),
                ]),
                Step("produce", "Produce the method run", "Assemble the result.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this run.", required: true),
                ]),
            ]),

        "fa.root-cause": build(
            "Trace how the loss or misstatement occurred: Five Whys, Fishbone, then a human determination.",
            [
                Step("problem", "State the problem", "The loss/misstatement to explain.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "Controls, process, people, systems."),
                ]),
                Step("determine", "Determination (your decision)", "A human determines the root cause.", [
                    f("determination", "Determination & basis", .longText, "The root cause(s), on the evidence.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "fa.workpapers": build(
            "Keep custody-tracked workpapers: register originals, record acquisition and integrity, index, then seal.",
            [
                Step("register", "Register the originals", "Each source document, with provenance (attach).", opens: "audit", [
                    f("originals", "Originals", .longText, "What each item is and where it came from.", required: true),
                ]),
                Step("acquire", "Acquisition & integrity", "How each entered custody unaltered.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from system/service", "Physical/device transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("index", "Index the workpapers", "Cross-reference workpapers to the report.", opens: "audit", [
                    f("index", "Index", .longText, "Workpaper references."),
                ]),
                Step("seal", "Seal the workpaper set", "Post the sealed manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this set.", required: true),
                ]),
            ]),

        "fa.expert-report": build(
            "Assemble the expert report: restate the assignment, summarize methodology, marshal exhibits, state opinions, note assumptions and limitations, then produce — opine only within your expertise.",
            [
                Step("assignment", "Restate the assignment", "The question and scope you were engaged to opine on.", opens: "findings", [
                    f("assignment", "Assignment", .longText, "Precisely what you were asked.", required: true),
                ]),
                Step("methodology", "Summarize methodology", "The methods you applied and why.", opens: "matrix", [
                    f("methodology", "Methodology", .longText, "Approach and standards."),
                ]),
                Step("exhibits", "Marshal the exhibits", "The schedules and documents the opinion rests on (attach).", opens: "findings", [
                    f("exhibits", "Exhibits", .longText, "Each exhibit and what it shows."),
                ]),
                Step("opinions", "State opinions (your decision)", "Your opinions, each tied to exhibits.", [
                    f("opinions", "Opinions", .longText, "Within your expertise only — each supported.", required: true),
                ]),
                Step("limits", "Assumptions & limitations", "What you relied on and what you didn't reach.", opens: "review", [
                    f("limitations", "Assumptions & limits", .longText, "Data limitations and matters outside scope."),
                ]),
                Step("produce", "Produce the expert report", "Assemble the report with its sealed receipt.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this report.", required: true),
                ]),
            ]),

        "fa.recovery": build(
            "Track recovery and remediation actions to closure.",
            [
                Step("link", "Link actions to findings", "What each action addresses.", opens: "findings", [
                    f("links", "Action ↔ finding", .longText, "Which finding each action responds to.", required: true),
                ]),
                Step("define", "Define the actions", "Action, owner, due date.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Recovery/remediation — with owner and due date.", required: true),
                ]),
                Step("assign", "Agree owners & dates (your decision)", "Confirm each is agreed.", [
                    f("basis", "Confirmation", .longText, "Confirm owners and dates.", required: true),
                ]),
                Step("produce", "Produce the register", "Assemble the actions register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "fa.recovery-review": build(
            "Verify a completed action actually recovered or remediated — never declare success without evidence.",
            [
                Step("select", "Select the action", "Which completed action.", opens: "handoff", [
                    f("action", "Action", .text, "The action under review.", required: true),
                ]),
                Step("evidence", "Gather evidence", "Evidence of the outcome (attach it).", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What happened since."),
                ]),
                Step("judge", "Judge effectiveness (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Effective", "Partially effective", "Not effective"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "fa.closure": build(
            "Close the engagement by an explicit human decision — unresolved items retained, reopening preserves the prior closure.",
            [
                Step("recap", "Confirm deliverables", "Report, schedules, and any items left open.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the engagement."),
                ]),
                Step("retention", "Retention & confidentiality", "Where the workpapers are kept and who may access them.", opens: "handoff", [
                    f("retention", "Retention & access", .longText, "Storage, retention, access."),
                ]),
                Step("decide", "Closure decision (your decision)", "A human closes or keeps the engagement open.", [
                    f("decision", "Decision", .choice, "Close only when complete.", required: true, options: ["Close the engagement", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves this closure.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Genealogist / Family Historian — GPS (2026-08-20)

        "gen.research-plan": build(
            "Fix the research question and record scope before searching — the start of the Genealogical Proof Standard.",
            [
                Step("question", "State the research question", "The specific question — a person, event, or relationship.", opens: "sources", [
                    f("question", "Research question", .longText, "Specific and answerable.", required: true),
                ]),
                Step("known", "Known facts & scope", "What you already know and its sources; the time/place scope.", opens: "sources", [
                    f("known", "Known facts", .longText, "With sources."),
                    f("window", "Time & place", .dateRange, "The period this covers."),
                ]),
                Step("plan", "Plan the search", "Record types and repositories — reasonably exhaustive.", opens: "sources", [
                    f("plan", "Search plan", .longText, "Where to look and for what."),
                ]),
                Step("open", "Open the research question", "Open the numbered question to work.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Question name", .text, "A findable name.", required: true),
                ]),
            ]),

        "gen.ask": build(
            "Ask a question over your family records and keep the cited answer.",
            [
                Step("ask", "Ask the records", "The answer cites its document.", opens: "ask", [
                    f("question", "Your question", .longText, "What you want to know.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it bears on the research question."),
                ]),
            ]),

        "gen.research-log": build(
            "Keep the classic research log — every search, where, and what it yielded (including negative results).",
            [
                Step("searches", "Record each search", "What you searched and where.", opens: "dataLab", [
                    f("searches", "Searches", .longText, "Repository, source, date, terms — one per line.", required: true),
                ]),
                Step("results", "Record results", "What each search yielded.", opens: "dataLab", [
                    f("results", "Results", .longText, "Include negative results — they matter."),
                ]),
                Step("next", "Note next searches", "Leads and gaps to pursue.", opens: "review", [
                    f("next", "Next", .longText, "What to search next."),
                ]),
                Step("produce", "Produce the log entry", "Post the research log entry.", opens: "handoff", posts: "LOG", [
                    f("title", "Title", .text, "Name this log entry.", required: true),
                ]),
            ]),

        "gen.ancestor-profile": build(
            "Compile everything known about one ancestor, each fact cited.",
            [
                Step("identify", "Identify the ancestor", "Who this profile is about.", opens: "dossier", [
                    f("subject", "Ancestor", .text, "Name and rough dates.", required: true),
                ]),
                Step("compile", "Compile the profile", "Life events, relationships, places — each cited.", opens: "dossier", [
                    f("profile", "Profile", .longText, "Only what the evidence supports."),
                ]),
                Step("confirm", "Confirm the facts (your decision)", "Confirm each fact is evidenced.", [
                    f("basis", "Confirmation & basis", .longText, "What you confirm and how.", required: true),
                ]),
                Step("produce", "Produce the profile", "Assemble the ancestor profile.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this profile.", required: true),
                ]),
            ]),

        "gen.same-person": build(
            "Decide whether name variants are one person: gather them, compare across records, rule out look-alikes, then decide — reversible, you decide.",
            [
                Step("gather", "Gather the variants", "Every spelling/variant that may be one person.", opens: "knowledge", [
                    f("identifiers", "Name variants", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across records", "How each appears across the records.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals (dates, places, kin)."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Same-name different-person is common — exclude them.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "You decide identity. Never automatic.", [
                    f("decision", "Decision", .choice, "Reversible later.", required: true, options: ["Confirm same person", "Reject — different people", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "The evidence behind it.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "gen.family-lines": build(
            "Build family relationships and life timelines, correlate the evidence, every event cited.",
            [
                Step("events", "Collect dated events", "Births, marriages, deaths, moves — cited.", opens: "timeline", [
                    f("events", "Events", .longText, "Date, event, source — one per line.", required: true),
                ]),
                Step("links", "Establish relationships", "Parent/child/spouse links, each on evidence.", opens: "connections", [
                    f("relations", "Relationships", .longText, "Each link and its evidence."),
                ]),
                Step("conflicts", "Note conflicts", "Dates or relationships that disagree — both kept.", opens: "review", [
                    f("conflicts", "Conflicts", .longText, "What disagrees."),
                ]),
                Step("correlate", "Correlate the evidence", "How independent sources fit together.", opens: "matrix", [
                    f("correlate", "Correlation", .longText, "Where sources agree."),
                ]),
                Step("produce", "Produce the family lines", "Assemble the lines & timeline.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "gen.conflicts": build(
            "Resolve records that disagree — both kept on file (GPS element 4).",
            [
                Step("collect", "Collect the conflicting records", "The records that disagree.", opens: "findings", [
                    f("items", "Records", .longText, "What conflicts.", required: true),
                ]),
                Step("compare", "Compare them", "How they disagree — both preserved.", opens: "matrix", [
                    f("comparison", "Comparison", .longText, "The conflict, side by side."),
                ]),
                Step("resolve", "Resolve (your decision)", "Your reasoned resolution — both records stay on file.", [
                    f("resolution", "Resolution & reasoning", .longText, "Which you favor and why.", required: true),
                ]),
                Step("produce", "Produce the resolution", "Assemble the conflict resolution.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "gen.source-analysis": build(
            "Classify each source — original or derivative, primary or secondary information, direct or indirect evidence (a classification is a judgement).",
            [
                Step("list", "List the sources", "Each source to analyze.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("classify", "Classify each", "Original/derivative; primary/secondary; direct/indirect.", opens: "review", [
                    f("classify", "Classification", .longText, "For each source, on the GPS axes."),
                ]),
                Step("decide", "Own the classification (your decision)", "These are your judgements.", [
                    f("basis", "Basis", .longText, "Confirm the classifications.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the source analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "gen.evidence-notes": build(
            "Correlate evidence across records with 5W1H worksheets.",
            [
                Step("gather", "Gather the evidence", "The records bearing on the question.", opens: "findings", [
                    f("items", "Evidence", .longText, "What you're correlating.", required: true),
                ]),
                Step("fiveW", "5W1H", "Across the records.", opens: "matrix", [
                    f("fiveW", "5W1H", .longText, "Who/what/when/where/why/how."),
                ]),
                Step("correlate", "Correlate", "Where independent sources agree.", opens: "review", [
                    f("correlate", "Correlation", .longText, "The picture the evidence supports."),
                ]),
                Step("produce", "Produce the notes", "Assemble the correlation notes.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "gen.methods": build(
            "Work a structured checklist toward reasonably exhaustive research.",
            [
                Step("pick", "Pick the checklist", "Which method/checklist.", opens: "matrix", [
                    f("method", "Checklist", .text, "e.g. record-type coverage, locality guide.", required: true),
                ]),
                Step("run", "Work through it", "What you covered and found.", opens: "review", [
                    f("runNote", "Coverage", .longText, "What's covered and what remains."),
                ]),
                Step("produce", "Produce the checklist", "Assemble the result.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this checklist.", required: true),
                ]),
            ]),

        "gen.migration": build(
            "Trace why an ancestor moved or changed names — Five Whys / Fishbone over cited records, then a human determination.",
            [
                Step("problem", "State what to explain", "The move or change to explain.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Trace the causes", "Cause to cause; stop where the records stop.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported (economic, legal, family)."),
                ]),
                Step("weigh", "Weigh the candidates", "Evidence for and against each explanation.", opens: "review", [
                    f("weighing", "For / against", .longText, "What supports or rules out each."),
                ]),
                Step("determine", "Determination (your decision)", "Your reasoned explanation — never presented as certain beyond the evidence.", [
                    f("determination", "Determination & basis", .longText, "The most likely cause(s), on the evidence.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "gen.originals": build(
            "Keep custody-tracked originals and write full citations so every citation reopens its exact source.",
            [
                Step("register", "Register the originals", "Each source with provenance (attach the images/records).", opens: "audit", [
                    f("originals", "Originals", .longText, "What each item is and where it came from.", required: true),
                ]),
                Step("integrity", "Record integrity", "Hash/verify the originals.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from archive/service", "Physical/scan transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("cite", "Write full citations", "A complete citation per source.", opens: "audit", [
                    f("citations", "Citations", .longText, "So each reopens its exact source."),
                ]),
                Step("seal", "Seal the source list", "Post the sealed citation/originals manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this manifest.", required: true),
                ]),
            ]),

        "gen.proof-argument": build(
            "Write the Genealogical Proof Standard argument: state the question and conclusion, summarize the evidence, show reasonably exhaustive research, resolve conflicts, write the reasoned conclusion, then produce.",
            [
                Step("question", "Question & conclusion", "The question and the conclusion you'll argue.", opens: "findings", [
                    f("question", "Question & conclusion", .longText, "Both stated up front.", required: true),
                ]),
                Step("evidence", "Summarize the evidence", "The relevant evidence, cited.", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What supports the conclusion."),
                ]),
                Step("exhaustive", "Reasonably exhaustive research", "Show the search was thorough.", opens: "review", [
                    f("exhaustive", "Coverage", .longText, "Why the research is reasonably exhaustive."),
                ]),
                Step("resolve", "Resolve conflicts", "Conflicting evidence and how resolved.", opens: "matrix", [
                    f("conflicts", "Conflict resolution", .longText, "Both sides, and your resolution."),
                ]),
                Step("conclusion", "Write the conclusion (your decision)", "The soundly-reasoned, written conclusion.", [
                    f("conclusion", "Conclusion", .longText, "Your reasoned proof.", required: true),
                ]),
                Step("produce", "Produce the proof argument", "Assemble the argument with its sealed receipt.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this proof argument.", required: true),
                ]),
            ]),

        "gen.to-do": build(
            "Track follow-up searches and record orders to closure.",
            [
                Step("link", "Link to-dos to the question", "What each search will answer.", opens: "findings", [
                    f("links", "To-do ↔ question", .longText, "Which gap each addresses.", required: true),
                ]),
                Step("define", "Define the to-dos", "Search/record order, where, priority.", opens: "handoff", [
                    f("todos", "To-dos", .longText, "Each with repository and priority.", required: true),
                ]),
                Step("produce", "Produce the to-do list", "Assemble the research to-dos.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this list.", required: true),
                ]),
            ]),

        "gen.to-do-review": build(
            "Verify a completed search actually answered the question — never assume it did.",
            [
                Step("select", "Select the completed search", "Which to-do you're reviewing.", opens: "handoff", [
                    f("action", "Search", .text, "The completed search.", required: true),
                ]),
                Step("evidence", "What it yielded", "The result and whether it answered the question.", opens: "findings", [
                    f("evidence", "Result", .longText, "What the search produced."),
                ]),
                Step("judge", "Did it answer? (your decision)", "On the result.", [
                    f("verdict", "Verdict", .choice, "Did it answer the question?", required: true, options: ["Answered", "Partially", "Did not answer"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "gen.close-question": build(
            "Close or reopen the research question by explicit decision — the conclusion and its evidence retained.",
            [
                Step("recap", "Confirm the proof", "Conclusion, evidence, and any open leads.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the question."),
                ]),
                Step("decide", "Closure decision (your decision)", "You close or keep the question open.", [
                    f("decision", "Decision", .choice, "Close only when the proof holds.", required: true, options: ["Close the question", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves this closure.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Content Creator (2026-08-20)

        "cc.project-intake": build(
            "Open a content project and set which sources it may draw on.",
            [
                Step("frame", "Frame the project", "What this piece is about.", opens: "sources", [
                    f("title", "Working title", .text, "The piece's working title.", required: true),
                    f("premise", "Premise", .longText, "What it's about and for whom.", required: true),
                ]),
                Step("sources", "Set the sources in scope", "Which research/sources it may use.", opens: "sources", [
                    f("sources", "Sources in scope", .longText, "The authorized source set."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "Confirm what the piece can draw on.", [
                    f("decision", "Scope confirmed?", .choice, "Confirm only when correct.", required: true, options: ["Confirmed", "Needs revision"]),
                ]),
                Step("open", "Open the project", "Open the numbered project.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Project name", .text, "A findable name.", required: true),
                ]),
            ]),

        "cc.ask": build(
            "Ask a question across the project's sources and keep the cited answer.",
            [
                Step("ask", "Ask your research", "The answer cites its source.", opens: "ask", [
                    f("question", "Your question", .longText, "What you want to know.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it serves the piece."),
                ]),
            ]),

        "cc.angle": build(
            "Shape the hook and outline from what the sources actually support.",
            [
                Step("angle", "Find the angle", "The hook — what's new/interesting and supported.", opens: "findings", [
                    f("angle", "Angle", .longText, "The hook, grounded in the sources.", required: true),
                ]),
                Step("outline", "Outline (5W1H)", "Section outline, each point evidence-anchored.", opens: "matrix", [
                    f("outline", "Outline", .longText, "The structure of the piece."),
                ]),
                Step("check", "Check against the sources", "Anything the outline claims the sources don't yet support.", opens: "review", [
                    f("check", "Unsupported claims", .longText, "Gaps to fill before writing."),
                ]),
                Step("produce", "Produce the outline", "Assemble the angle & outline.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this outline.", required: true),
                ]),
            ]),

        "cc.script-prep": build(
            "Draft interview questions and talking points over the cited record.",
            [
                Step("focus", "What to cover", "What the script/interview needs to establish.", opens: "ask", [
                    f("focus", "Focus", .longText, "The points to cover.", required: true),
                ]),
                Step("questions", "Draft questions & talking points", "Open, non-leading, evidence-anchored.", opens: "matrix", [
                    f("questions", "Questions / points", .longText, "Grouped by topic.", required: true),
                ]),
                Step("logistics", "Plan the shoot/interview", "Guest, format, timing.", opens: "handoff", [
                    f("logistics", "Logistics", .longText, "Practical arrangements."),
                ]),
                Step("produce", "Produce the script/prep", "Assemble the prep.", opens: "handoff", posts: "INT", [
                    f("title", "Title", .text, "Name this prep.", required: true),
                ]),
            ]),

        "cc.guest-workup": build(
            "Background a guest or subject before you feature them, citing exact evidence.",
            [
                Step("identify", "Identify the guest/subject", "Who you're backgrounding.", opens: "dossier", [
                    f("subject", "Guest / subject", .text, "Name and role.", required: true),
                ]),
                Step("compile", "Compile the background", "Bio, prior statements, relationships — each cited.", opens: "dossier", [
                    f("profile", "Background", .longText, "Only what the evidence supports."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the key facts before you feature them.", [
                    f("basis", "Confirmation & basis", .longText, "What you confirm and how.", required: true),
                ]),
                Step("produce", "Produce the background", "Assemble the workup.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this workup.", required: true),
                ]),
            ]),

        "cc.identity": build(
            "Confirm names, handles and entities are the same party: gather, compare, rule out, then decide — reversible, human-gated.",
            [
                Step("gather", "Gather the handles", "Names, handles, accounts that may be one party.", opens: "knowledge", [
                    f("identifiers", "Candidate identifiers", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across sources", "How each appears across the research.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Exclude coincidental matches.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "You decide. Never automatic.", [
                    f("decision", "Decision", .choice, "Reversible later.", required: true, options: ["Confirm same party", "Reject — different parties", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "The evidence behind it.", required: true),
                ]),
                Step("record", "Record the decision", "Post the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "cc.research-table": build(
            "Build a data-backed table for the piece — every cell drills to its source.",
            [
                Step("assemble", "Assemble the sources", "What this table is built from (attach any not ingested).", opens: "sources", [
                    f("scope", "What this covers", .text, "The data this table spans.", required: true),
                ]),
                Step("build", "Build the table", "Each row/column cited.", opens: "dataLab", [
                    f("columns", "Columns & notes", .longText, "What each column is and its source."),
                ]),
                Step("check", "Check the numbers", "Sanity-check totals and outliers.", opens: "dataLab", [
                    f("check", "Checks", .longText, "Anything a reader should be warned about."),
                ]),
                Step("produce", "Produce the table", "Assemble the research table.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this table.", required: true),
                ]),
            ]),

        "cc.timeline": build(
            "Build the story's timeline and how the people and orgs connect.",
            [
                Step("events", "Collect the events", "Dated events, each cited.", opens: "timeline", [
                    f("events", "Events", .longText, "Date, event, source — one per line.", required: true),
                ]),
                Step("links", "Map the connections", "How people and orgs relate.", opens: "connections", [
                    f("links", "Connections", .longText, "Each link and its evidence."),
                ]),
                Step("produce", "Produce the timeline", "Assemble the timeline & connections.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "cc.fact-check": build(
            "Check each claim against evidence — conflicting accounts preserved, never averaged.",
            [
                Step("collect", "List the claims", "Each claim the piece makes.", opens: "findings", [
                    f("claims", "Claims", .longText, "One per line.", required: true),
                ]),
                Step("verify", "Verify each claim", "Evidence and status per claim.", opens: "matrix", [
                    f("verify", "Verification", .longText, "Supported / unsupported / disputed — with the source."),
                ]),
                Step("conflicts", "Preserve conflicts", "Conflicting accounts, kept side by side.", opens: "review", [
                    f("conflicts", "Conflicts", .longText, "Never averaged."),
                ]),
                Step("produce", "Produce the fact-check", "Assemble the fact-check board.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this board.", required: true),
                ]),
            ]),

        "cc.source-vetting": build(
            "Assess how reliable and independent each source is before you rely on it — a rating is a judgement, not a fact.",
            [
                Step("list", "List the sources", "Each source to vet.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Independence, track record, corroboration.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low — a judgement."),
                ]),
                Step("decide", "Own the ratings (your decision)", "These are your judgements.", [
                    f("basis", "Basis", .longText, "Confirm the ratings.", required: true),
                ]),
                Step("produce", "Produce the vetting", "Assemble the source vetting.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this vetting.", required: true),
                ]),
            ]),

        "cc.explainer": build(
            "Explain how something came about — Five Whys / Fishbone over cited evidence, then a human takeaway.",
            [
                Step("problem", "What to explain", "The thing to explain.", opens: "findings", [
                    f("problem", "Question", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "The factors at play."),
                ]),
                Step("takeaway", "Write the takeaway (your decision)", "The explanation you'll present — grounded, not overstated.", [
                    f("takeaway", "Takeaway & basis", .longText, "How it came about, on the evidence.", required: true),
                ]),
                Step("produce", "Produce the explainer", "Assemble the explainer.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this explainer.", required: true),
                ]),
            ]),

        "cc.rights-locker": build(
            "Keep sources and clips with integrity hashes and their rights/clearance status.",
            [
                Step("register", "Register the sources & clips", "Each item with provenance (attach originals).", opens: "audit", [
                    f("items", "Items", .longText, "What each item is and where it came from.", required: true),
                ]),
                Step("integrity", "Record integrity", "Hash/verify each item.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from platform/service", "Physical/device transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("rights", "Record rights/clearance", "Clearance status per item.", opens: "audit", [
                    f("rights", "Rights status", .longText, "Owned / licensed / fair-use / pending — per item."),
                ]),
                Step("seal", "Seal the locker", "Post the sealed rights/custody manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this manifest.", required: true),
                ]),
            ]),

        "cc.publish-package": build(
            "Assemble the cited, rights-cleared package: assemble the piece, verify every claim is cited, confirm rights cleared, choose the export format, then produce.",
            [
                Step("assemble", "Assemble the piece", "The near-final piece with its citations.", opens: "findings", [
                    f("assemble", "The piece", .longText, "Draft with citations.", required: true),
                ]),
                Step("verify", "Verify every claim is cited", "Each claim maps to a vetted source.", opens: "matrix", [
                    f("verify", "Citation check", .longText, "Any claim not yet cited."),
                ]),
                Step("rights", "Confirm rights cleared (your decision)", "Everything used is cleared.", [
                    f("rights", "Rights", .choice, "Clearance status.", required: true, options: ["All cleared", "Outstanding items"]),
                    f("note", "Note", .longText, "Any outstanding clearances."),
                ]),
                Step("format", "Choose export format", "How to export the package.", opens: "handoff", [
                    f("format", "Export format", .choice, "The deliverable format.", options: ["Word (.docx)", "PDF", "Both"]),
                ]),
                Step("produce", "Produce the package", "Assemble the cited package and export.", opens: "handoff", posts: "PUB", [
                    f("title", "Title", .text, "Name this package.", required: true),
                ]),
            ]),

        "cc.corrections": build(
            "Track corrections, rights clearances and follow-ups through to done.",
            [
                Step("link", "Link items to the issue", "What each correction/clearance addresses.", opens: "findings", [
                    f("links", "Item ↔ issue", .longText, "Which claim or clip each addresses.", required: true),
                ]),
                Step("define", "Define the items", "Correction/clearance/follow-up, owner, due.", opens: "handoff", [
                    f("items", "Items", .longText, "Each with owner and due date.", required: true),
                ]),
                Step("produce", "Produce the tracker", "Assemble the corrections tracker.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this tracker.", required: true),
                ]),
            ]),

        "cc.performance": build(
            "Verify a correction or clearance actually resolved the issue it was for.",
            [
                Step("select", "Select the item", "Which correction/clearance you're reviewing.", opens: "handoff", [
                    f("action", "Item", .text, "The item under review.", required: true),
                ]),
                Step("evidence", "Gather evidence", "Evidence the issue is resolved.", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What changed since."),
                ]),
                Step("judge", "Resolved? (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Resolved", "Partially", "Not resolved"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "cc.wrap": build(
            "Archive or wrap the project by an explicit human decision — sources and package retained.",
            [
                Step("recap", "Confirm the package", "Published package, corrections, and any open items.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the project."),
                ]),
                Step("retention", "Retention & rights", "Where sources/clips are kept and their rights status.", opens: "handoff", [
                    f("retention", "Retention & rights", .longText, "Storage, retention, clearances."),
                ]),
                Step("decide", "Wrap decision (your decision)", "You wrap or keep the project open.", [
                    f("decision", "Decision", .choice, "Wrap only when done.", required: true, options: ["Archive / wrap", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves this wrap.", required: true),
                ]),
                Step("produce", "Produce the wrap record", "Post the wrap record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Investigator (2026-08-20)

        "inv.case-intake": build(
            "Open a case and set its authorized evidence scope: record the mandate, fix scope and window, set the sources in scope, confirm, then open the case. Intake never decides the merits.",
            [
                Step("mandate", "Record the mandate", "The authority and the question this case answers.", opens: "sources", [
                    f("caseNo", "Case number", .text, "Your case reference.", required: true),
                    f("mandate", "Mandate", .longText, "The authority behind the case and what it must resolve.", required: true),
                    f("custodian", "Custodian", .text, "Whose records/accounts the evidence comes from."),
                ]),
                Step("scope", "Define scope & window", "The boundary and the period the case covers.", opens: "sources", [
                    f("scope", "Scope statement", .longText, "In and out of scope.", required: true),
                    f("window", "Time window", .dateRange, "The period under investigation."),
                ]),
                Step("inscope", "Set the sources in scope", "Authorize the in-scope source set — the hard evidence boundary.", opens: "sources", [
                    f("sources", "Sources in scope", .longText, "The authorized sources."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "A human confirms scope before work.", [
                    f("decision", "Scope confirmed?", .choice, "Confirm only when correct.", required: true, options: ["Confirmed", "Needs revision"]),
                    f("note", "Note", .longText, "Anything to record."),
                ]),
                Step("open", "Open the case", "Open the numbered case.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Case name", .text, "A findable name.", required: true),
                ]),
            ]),

        "inv.ask": build(
            "Ask a question over the case's authorized evidence and keep the cited answer.",
            [
                Step("ask", "Ask (case-scoped)", "The answer is grounded in the case's authorized evidence only.", opens: "ask", [
                    f("question", "Your question", .longText, "What you need to know.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it bears on the case."),
                ]),
            ]),

        "inv.methods": build(
            "Run a professional method over case-authorized evidence — a method structures analysis, it doesn't conclude.",
            [
                Step("pick", "Pick the method", "Which structured method to run.", opens: "matrix", [
                    f("method", "Method", .text, "e.g. 5W1H, hypothesis matrix, link analysis.", required: true),
                ]),
                Step("run", "Run it", "Inputs and what it produced.", opens: "matrix", [
                    f("runNote", "Result", .longText, "What the method structured or surfaced."),
                ]),
                Step("produce", "Produce the method run", "Assemble the result.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this run.", required: true),
                ]),
            ]),

        "inv.data-lab": build(
            "Prepare an authorized-only dataset over the shared Workbench, with cited cells and a quality check.",
            [
                Step("assemble", "Assemble the data", "Which authorized records this dataset draws on.", opens: "sources", [
                    f("scope", "What this covers", .text, "The data in scope.", required: true),
                ]),
                Step("build", "Build the dataset", "Columns and derived values, each cited.", opens: "dataLab", [
                    f("columns", "Columns & notes", .longText, "What each column is and its source."),
                ]),
                Step("quality", "Check quality", "Missing/stale/unsupported values.", opens: "dataLab", [
                    f("quality", "Quality issues", .longText, "Anything a reader should be warned about."),
                ]),
                Step("produce", "Produce the dataset", "Assemble the dataset.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this dataset.", required: true),
                ]),
            ]),

        "inv.subject-dossier": build(
            "Work up a subject from cited in-scope evidence, and confirm the identity.",
            [
                Step("identify", "Identify the subject", "Who you're working up.", opens: "dossier", [
                    f("subject", "Subject", .text, "Name and role.", required: true),
                ]),
                Step("compile", "Compile the dossier", "Background, relationships, relevant facts — each cited.", opens: "dossier", [
                    f("profile", "Dossier", .longText, "Only what the evidence supports."),
                ]),
                Step("confirm", "Confirm identity (your decision)", "Confirm the dossier maps to the right subject.", [
                    f("basis", "Confirmation & basis", .longText, "What you confirm and how.", required: true),
                ]),
                Step("produce", "Produce the dossier", "Assemble the subject workup.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this dossier.", required: true),
                ]),
            ]),

        "inv.identity-resolution": build(
            "Resolve identity via the shared reversible merge: gather identifiers, compare, rule out look-alikes, then confirm or reject — human-gated, never automatic.",
            [
                Step("gather", "Gather identifiers", "Names, aliases, accounts that may be one entity.", opens: "knowledge", [
                    f("identifiers", "Candidate identifiers", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across evidence", "How each appears across the case.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Exclude coincidental matches.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "A human decides. Reversible later.", [
                    f("decision", "Decision", .choice, "Your identity decision.", required: true, options: ["Confirm same entity", "Reject — different", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "The evidence behind it.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "inv.analysis": build(
            "Work the analytical spine: brainstorm leads, answer 5W1H, plan the evidence, then score hypotheses for/against — never auto-won.",
            [
                Step("brainstorm", "Brainstorm leads", "Ideas, hypotheses and leads to pursue.", opens: "findings", [
                    f("ideas", "Leads & hypotheses", .longText, "One per line.", required: true),
                ]),
                Step("fiveW", "5W1H worksheet", "Answer each from evidence, or mark unknown.", opens: "matrix", [
                    f("fiveW", "5W1H", .longText, "Who/what/when/where/why/how — cited or unknown."),
                ]),
                Step("plan", "Evidence collection plan", "What evidence each hypothesis needs.", opens: "review", [
                    f("plan", "Evidence plan", .longText, "Requests per hypothesis — never assert evidence exists."),
                ]),
                Step("matrix", "Hypothesis matrix", "Score hypotheses on evidence for and against.", opens: "matrix", [
                    f("matrixNote", "For / against", .longText, "The matrix — human-confirmed, never auto-won."),
                ]),
                Step("produce", "Produce the worksheet", "Assemble the analysis worksheet.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this worksheet.", required: true),
                ]),
            ]),

        "inv.source-reliability": build(
            "Assess the reliability of each case source — a rating is a judgement, never a fact.",
            [
                Step("list", "List the sources", "Each source/custodian to assess.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Reliability and independence factors.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low — a judgement."),
                ]),
                Step("decide", "Own the ratings (your decision)", "These are your judgements.", [
                    f("basis", "Basis", .longText, "Confirm the ratings.", required: true),
                ]),
                Step("produce", "Produce the schedule", "Assemble the reliability schedule.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this schedule.", required: true),
                ]),
            ]),

        "inv.contradiction-gap": build(
            "Review in-scope contradictions and gaps — both sides preserved, and absence is not proof.",
            [
                Step("collect", "Collect the claims", "The claims under review.", opens: "findings", [
                    f("claims", "Claims", .longText, "What you're testing.", required: true),
                ]),
                Step("contradictions", "Surface contradictions", "Where claims conflict.", opens: "matrix", [
                    f("contradictions", "Contradictions", .longText, "Both sides preserved, never averaged."),
                ]),
                Step("gaps", "Surface gaps", "Missing evidence.", opens: "review", [
                    f("gaps", "Gaps", .longText, "Absence is not proof."),
                ]),
                Step("produce", "Produce the desk report", "Assemble the contradiction & gap report.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this report.", required: true),
                ]),
            ]),

        "inv.causal-analysis": build(
            "Trace how something came about: Five Whys, Fishbone, weigh candidates, then a human determination.",
            [
                Step("problem", "State the problem", "The issue to explain.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "The factors at play."),
                ]),
                Step("determine", "Determination (your decision)", "A human determines the cause. The app never confirms one.", [
                    f("determination", "Determination & basis", .longText, "The cause(s), on the evidence.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "inv.linkage": build(
            "Build the timeline, link chart, and transaction/asset flow, flagging gaps and conflicts.",
            [
                Step("events", "Collect dated events", "Each event with its source.", opens: "timeline", [
                    f("events", "Events", .longText, "Date, event, source — one per line.", required: true),
                ]),
                Step("links", "Build the link chart", "People, objects, locations, events.", opens: "connections", [
                    f("links", "Links", .longText, "How entities connect, on evidence."),
                ]),
                Step("flow", "Transaction / asset flow", "Trace movements of money or assets.", opens: "dataLab", [
                    f("flow", "Flow", .longText, "Dated, cited movements."),
                ]),
                Step("gaps", "Flag gaps & conflicts", "Missing periods and conflicts.", opens: "review", [
                    f("gaps", "Gaps & conflicts", .longText, "Kept, not averaged."),
                ]),
                Step("produce", "Produce the linkage", "Assemble the linkage work product.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "inv.capa-register": build(
            "Record corrective/preventive actions linked to causes, tracked to a human close.",
            [
                Step("link", "Link actions to causes", "What each action addresses.", opens: "findings", [
                    f("links", "Action ↔ cause", .longText, "Which finding/cause each action responds to.", required: true),
                ]),
                Step("define", "Define the actions", "Action, owner, due date, type.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Corrective/preventive — with owner and due date.", required: true),
                ]),
                Step("assign", "Agree owners & dates (your decision)", "Confirm each is agreed.", [
                    f("basis", "Confirmation", .longText, "Confirm owners and dates.", required: true),
                ]),
                Step("produce", "Produce the register", "Assemble the CAPA register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "inv.effectiveness-review": build(
            "Review whether a CAPA action worked — never declare it effective without evidence.",
            [
                Step("select", "Select the action", "Which completed action.", opens: "handoff", [
                    f("action", "Action", .text, "The action under review.", required: true),
                ]),
                Step("evidence", "Gather evidence", "Evidence of the outcome (attach it).", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What happened since."),
                ]),
                Step("judge", "Judge effectiveness (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Effective", "Partially effective", "Not effective"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "inv.evidence-custody": build(
            "Maintain the evidence locker: register exhibits, record acquisition and integrity, log transfers, then seal.",
            [
                Step("register", "Register the exhibits", "Each item, with source (attach originals).", opens: "audit", [
                    f("exhibits", "Exhibits", .longText, "What each item is and where it came from.", required: true),
                ]),
                Step("acquire", "Acquisition & integrity", "How each entered custody unaltered.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from system/service", "Physical/device transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("transfers", "Log transfers", "Who held what, when.", opens: "audit", [
                    f("transfers", "Transfers", .longText, "Each hand-off."),
                ]),
                Step("seal", "Seal the manifest", "Post the sealed custody manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this manifest.", required: true),
                ]),
            ]),

        "inv.findings": build(
            "Assemble the case report: recap scope, marshal the evidence, assess, record findings, note limitations, then produce — never assert unproven findings.",
            [
                Step("recap", "Recap scope & questions", "Anchor the report.", opens: "findings", [
                    f("recap", "Scope & questions", .longText, "What's being reported and within what scope.", required: true),
                ]),
                Step("marshal", "Marshal the evidence", "The cited evidence for each question (attach exhibits).", opens: "findings", [
                    f("evidence", "Evidence", .longText, "For and against each point."),
                ]),
                Step("assess", "Assess", "What the evidence supports.", opens: "matrix", [
                    f("assessment", "Assessment", .longText, "Strengths and gaps."),
                ]),
                Step("findings", "Record findings (your decision)", "The human findings, each supported.", [
                    f("findings", "Findings", .longText, "Do not assert findings the evidence doesn't support.", required: true),
                ]),
                Step("limits", "Note limitations", "Gaps and unresolved items — honest closure.", opens: "review", [
                    f("limitations", "Limitations", .longText, "What remains uncertain."),
                ]),
                Step("produce", "Produce the case report", "Assemble the report with its sealed receipt.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this report.", required: true),
                ]),
            ]),

        "inv.closure": build(
            "Close or reopen the case by an explicit human decision — unresolved items retained, reopening preserves the prior closure.",
            [
                Step("recap", "Confirm the outcome", "Report, actions, open items.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the case."),
                ]),
                Step("retention", "Retention & confidentiality", "Where the file is kept and who may access it.", opens: "handoff", [
                    f("retention", "Retention & access", .longText, "Storage, retention, access."),
                ]),
                Step("decide", "Closure decision (your decision)", "A human closes or reopens.", [
                    f("decision", "Decision", .choice, "Close only when complete.", required: true, options: ["Close the case", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves this closure.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Researcher / Historian (2026-08-20)

        "res.protocol": build(
            "Fix the research question, scope, and authorized corpus before evidence is touched — the protocol that prevents drift.",
            [
                Step("question", "State the research question", "The question this review answers.", opens: "sources", [
                    f("question", "Research question", .longText, "Fixed before screening.", required: true),
                ]),
                Step("criteria", "Inclusion criteria & window", "What qualifies a source, and the period covered.", opens: "sources", [
                    f("criteria", "Inclusion criteria", .longText, "What's in and out."),
                    f("window", "Records window", .dateRange, "The period this covers."),
                ]),
                Step("corpus", "Set the authorized corpus", "The sources the review may draw on.", opens: "sources", [
                    f("corpus", "Corpus", .longText, "The authorized corpus."),
                ]),
                Step("open", "Open the protocol", "Open the numbered research matter.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Protocol name", .text, "A findable name.", required: true),
                ]),
            ]),

        "res.corpus-catalogue": build(
            "Catalogue every authorized source with provenance.",
            [
                Step("assemble", "Assemble the sources", "The sources to catalogue.", opens: "sources", [
                    f("scope", "What this covers", .text, "The corpus spanned.", required: true),
                ]),
                Step("catalogue", "Catalogue with provenance", "Each source: origin, date, custody.", opens: "dataLab", [
                    f("columns", "Catalogue columns", .longText, "Provenance per source."),
                ]),
                Step("confirm", "Confirm inclusion (your decision)", "Confirm each source belongs in the corpus.", [
                    f("basis", "Confirmation", .longText, "What you include and why — never assert authenticity you can't support.", required: true),
                ]),
                Step("produce", "Produce the catalogue", "Assemble the corpus catalogue.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this catalogue.", required: true),
                ]),
            ]),

        "res.metadata": build(
            "Record structured metadata per source — your working finding aid, cited to the source.",
            [
                Step("assemble", "Choose the sources", "Which sources to describe.", opens: "sources", [
                    f("scope", "What this covers", .text, "The sources described.", required: true),
                ]),
                Step("describe", "Record the metadata", "Structured fields per source.", opens: "dataLab", [
                    f("metadata", "Metadata", .longText, "Each field cited to the source — never invented."),
                ]),
                Step("confirm", "Confirm the metadata (your decision)", "Confirm each entry is evidenced.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the finding aid", "Assemble the finding aid.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this finding aid.", required: true),
                ]),
            ]),

        "res.transcription": build(
            "Transcribe and code source text with locators — unheard words are never asserted.",
            [
                Step("source", "Choose the source", "The audio/image/text to transcribe.", opens: "sources", [
                    f("source", "Source", .text, "What you're transcribing.", required: true),
                ]),
                Step("transcribe", "Transcribe & code", "Transcribe with locators and code passages.", opens: "findings", [
                    f("transcript", "Transcript & codes", .longText, "Mark anything uncertain — never assert unheard words."),
                ]),
                Step("verify", "Verify corrections (your decision)", "Confirm the corrected transcript.", [
                    f("basis", "Confirmation", .longText, "What you corrected and confirmed.", required: true),
                ]),
                Step("produce", "Produce the transcript", "Assemble the corrected transcript.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this transcript.", required: true),
                ]),
            ]),

        "res.authority-control": build(
            "Unify names/terms to canonical authorities — reversible and human-reviewed, never auto-unified.",
            [
                Step("gather", "Gather the variants", "Names/terms that may be one authority.", opens: "knowledge", [
                    f("identifiers", "Variants", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare usages", "How each variant is used across the corpus.", opens: "knowledge", [
                    f("comparison", "Usages", .longText, "Matching and conflicting usages."),
                ]),
                Step("ruleout", "Rule out false unifications", "Exclude distinct entities that share a name.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm the authority (your decision)", "A human confirms. Reversible.", [
                    f("decision", "Decision", .choice, "Your decision.", required: true, options: ["Unify", "Keep separate", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("record", "Record the authority", "Post the reversible authority decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "res.source-criticism": build(
            "Assess origin, bias, and reliability of sources — never declare truth from a single source.",
            [
                Step("list", "List the sources", "Each source to criticize.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Origin, purpose, bias, reliability.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Assessment", .longText, "Your assessment — a judgement."),
                ]),
                Step("decide", "Own the assessment (your decision)", "These are judgements.", [
                    f("basis", "Basis", .longText, "Confirm the assessment.", required: true),
                ]),
                Step("produce", "Produce the source criticism", "Assemble the notes.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "res.screening": build(
            "Screen sources in or out by recorded, reversible criteria — PRISMA-style.",
            [
                Step("criteria", "Confirm the criteria", "The recorded inclusion/exclusion criteria.", opens: "review", [
                    f("criteria", "Criteria", .longText, "By which each source is screened.", required: true),
                ]),
                Step("screen", "Screen the corpus", "Include/exclude each source.", opens: "search", [
                    f("decisions", "Screening decisions", .longText, "Each source in/out, with reason — reversible."),
                ]),
                Step("confirm", "Confirm screening (your decision)", "Confirm the screen — never auto-exclude silently.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the screening log", "Assemble the screening log.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this log.", required: true),
                ]),
            ]),

        "res.extraction": build(
            "Extract coded findings, each citing an evidence block.",
            [
                Step("codebook", "Confirm the codebook", "The codes you'll extract against.", opens: "review", [
                    f("codebook", "Codebook", .longText, "The codes and their definitions.", required: true),
                ]),
                Step("extract", "Extract & code", "Code passages into structured findings.", opens: "findings", [
                    f("findings", "Coded findings", .longText, "Each finding cites its evidence block — never fabricated."),
                ]),
                Step("confirm", "Confirm the codes (your decision)", "Confirm the coding.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the coded dataset", "Assemble the coded dataset.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this dataset.", required: true),
                ]),
            ]),

        "res.chronology": build(
            "Build a periodised timeline — undated events labelled, each cited.",
            [
                Step("events", "Collect dated events", "Each event with its source.", opens: "timeline", [
                    f("events", "Events", .longText, "Date (or 'undated'), event, source.", required: true),
                ]),
                Step("period", "Periodise", "Group events into periods.", opens: "matrix", [
                    f("periods", "Periods", .longText, "The periodisation and its rationale."),
                ]),
                Step("confirm", "Confirm inclusion (your decision)", "Confirm periods and inclusions — never invent dates.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the chronology", "Assemble the chronology.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this chronology.", required: true),
                ]),
            ]),

        "res.prosopography": build(
            "Compile a collective biography of a group, each cell cited.",
            [
                Step("define", "Define the group", "Who's in the collective biography.", opens: "dossier", [
                    f("group", "Group", .longText, "The members and inclusion basis.", required: true),
                ]),
                Step("compile", "Compile the entries", "Each member's fields, cited.", opens: "dossier", [
                    f("entries", "Entries", .longText, "Only what the evidence supports."),
                ]),
                Step("confirm", "Confirm the entries (your decision)", "Confirm each entry is evidenced.", [
                    f("basis", "Confirmation", .longText, "What you confirm — never assert unknown biography.", required: true),
                ]),
                Step("produce", "Produce the prosopography", "Assemble the table.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this table.", required: true),
                ]),
            ]),

        "res.interpretation": build(
            "Compare competing interpretations — both accounts preserved, no winner picked for you.",
            [
                Step("collect", "Collect the interpretations", "The competing readings.", opens: "findings", [
                    f("interps", "Interpretations", .longText, "Each interpretation and its proponents.", required: true),
                ]),
                Step("compare", "Compare on the evidence", "How each fits the evidence.", opens: "matrix", [
                    f("comparison", "Comparison", .longText, "Support and tension for each — both preserved."),
                ]),
                Step("confirm", "Record your reading (your decision)", "Your interpretation, argued — never presented as the only one.", [
                    f("reading", "Your reading & basis", .longText, "Which you favor and why.", required: true),
                ]),
                Step("produce", "Produce the comparison", "Assemble the comparison.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "res.alternative": build(
            "Explore evidence-bounded counterfactuals — a scenario, never presented as fact, and never mutating the ledger.",
            [
                Step("scope", "Bound the counterfactual", "The what-if and its evidence bounds.", opens: "findings", [
                    f("scenario", "Scenario", .longText, "The counterfactual to explore.", required: true),
                ]),
                Step("build", "Build the scenario", "Trace it over cited events.", opens: "dataLab", [
                    f("trace", "Scenario trace", .longText, "What the evidence permits — and doesn't."),
                ]),
                Step("bounds", "State the bounds (your decision)", "Where the scenario leaves the evidence.", [
                    f("bounds", "Bounds & caveats", .longText, "Presented as scenario, not fact.", required: true),
                ]),
                Step("produce", "Produce the note", "Assemble the alternative-history note.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this note.", required: true),
                ]),
            ]),

        "res.bibliography": build(
            "Verify every citation reopens its exact source, and seal the bibliography.",
            [
                Step("gather", "Gather the citations", "The citations to audit.", opens: "audit", [
                    f("citations", "Citations", .longText, "Each citation to verify.", required: true),
                ]),
                Step("verify", "Verify each resolves", "Open each citation to its exact source.", opens: "audit", [
                    f("verifyNote", "Verification", .longText, "Which resolve and which are broken — never assert an unresolved cite."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the audit.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("seal", "Seal the bibliography", "Post the sealed bibliography/audit.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this bibliography.", required: true),
                ]),
            ]),

        "res.edition": build(
            "Assemble an annotated edition: fix the protocol link, marshal sources, annotate, then produce the edition — source text never silently altered.",
            [
                Step("protocol", "Anchor to the protocol", "The research question this edition answers.", opens: "findings", [
                    f("protocol", "Protocol link", .longText, "The question and scope.", required: true),
                ]),
                Step("sources", "Marshal the sources", "The selected sources for the edition.", opens: "findings", [
                    f("sources", "Selected sources", .longText, "What the edition is built from."),
                ]),
                Step("annotate", "Annotate", "Your notes and apparatus.", opens: "matrix", [
                    f("notes", "Annotations", .longText, "Source text preserved; annotations clearly yours."),
                ]),
                Step("approve", "Approve the edition (your decision)", "A human approves the edition.", [
                    f("approval", "Approval & basis", .longText, "What you approve — source text never silently altered.", required: true),
                ]),
                Step("produce", "Produce the edition", "Assemble the annotated edition with its receipt.", opens: "handoff", posts: "EDN", [
                    f("title", "Title", .text, "Name this edition.", required: true),
                ]),
            ]),

        "res.ask": build(
            "Ask a question over the authorized corpus and keep the cited answer.",
            [
                Step("ask", "Ask the corpus", "The answer cites its source.", opens: "ask", [
                    f("question", "Your question", .longText, "What you want to know.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it serves the research."),
                ]),
            ]),

        "res.methods": build(
            "Run a structured method over the matter.",
            [
                Step("pick", "Pick the method", "Which structured method.", opens: "matrix", [
                    f("method", "Method", .text, "e.g. 5W1H, hypothesis matrix, root cause.", required: true),
                ]),
                Step("run", "Run it", "Inputs and what it produced.", opens: "matrix", [
                    f("runNote", "Result", .longText, "What it structured or surfaced."),
                ]),
                Step("produce", "Produce the method run", "Assemble the result.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this run.", required: true),
                ]),
            ]),

        "res.causal": build(
            "Trace why an event unfolded — Five Whys / Fishbone over cited evidence, then a human determination.",
            [
                Step("problem", "State what to explain", "The event to explain.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "The factors at play."),
                ]),
                Step("determine", "Determination (your decision)", "A human determines the cause.", [
                    f("determination", "Determination & basis", .longText, "On the evidence.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "res.errata": build(
            "Track corrections to the edition as corrective actions to closure.",
            [
                Step("link", "Link errata to the edition", "What each correction fixes.", opens: "findings", [
                    f("links", "Erratum ↔ edition", .longText, "The passage each corrects.", required: true),
                ]),
                Step("define", "Define the corrections", "Correction, owner, status.", opens: "handoff", [
                    f("actions", "Corrections", .longText, "Each with owner and target."),
                ]),
                Step("produce", "Produce the errata register", "Assemble the register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "res.errata-review": build(
            "Verify a published correction actually resolved the issue.",
            [
                Step("select", "Select the correction", "Which erratum.", opens: "handoff", [
                    f("action", "Correction", .text, "The correction under review.", required: true),
                ]),
                Step("evidence", "Check the outcome", "Whether it resolved the issue.", opens: "findings", [
                    f("evidence", "Outcome", .longText, "What changed."),
                ]),
                Step("judge", "Resolved? (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Resolved", "Partially", "Not resolved"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "res.matter-closure": build(
            "Close the research matter by an explicit decision — sealed and reopenable with history.",
            [
                Step("recap", "Confirm the outputs", "Edition, findings, open leads.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the matter."),
                ]),
                Step("decide", "Closure decision (your decision)", "You close or keep it open.", [
                    f("decision", "Decision", .choice, "Close only when complete.", required: true, options: ["Close the matter", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves history.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Journalist (2026-08-20)

        "jrn.story-intake": build(
            "Define the story question, scope, and authorized sources, then open the story file.",
            [
                Step("premise", "Frame the story", "The story question and why it matters.", opens: "sources", [
                    f("premise", "Story premise", .longText, "What you're investigating.", required: true),
                ]),
                Step("scope", "Scope & sources", "What's in scope and which sources it draws on.", opens: "sources", [
                    f("scope", "Scope", .longText, "The boundary.", required: true),
                    f("sources", "Sources in scope", .longText, "Leaks, filings, records authorized."),
                ]),
                Step("confirm", "Confirm the premise (your decision)", "A human confirms the framing — intake never decides the story's truth.", [
                    f("decision", "Confirmed?", .choice, "Confirm only when framed.", required: true, options: ["Confirmed", "Needs revision"]),
                ]),
                Step("open", "Open the story file", "Open the numbered story.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Story name", .text, "A findable name.", required: true),
                ]),
            ]),

        "jrn.claim-board": build(
            "Track every claim and its verification status — checked, unchecked, disputed.",
            [
                Step("list", "List the claims", "Every claim the story rests on.", opens: "findings", [
                    f("claims", "Claims", .longText, "One per line.", required: true),
                ]),
                Step("status", "Set each status", "Checked / unchecked / disputed, with the source.", opens: "matrix", [
                    f("status", "Status per claim", .longText, "Never publish an unverified claim."),
                ]),
                Step("evidence", "Cite the support", "The evidence behind each checked claim.", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What supports each."),
                ]),
                Step("produce", "Produce the board", "Assemble the fact-check board.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this board.", required: true),
                ]),
            ]),

        "jrn.source-map": build(
            "Map sources, people, and relationships.",
            [
                Step("collect", "List the sources & people", "Who and what the story involves.", opens: "findings", [
                    f("nodes", "Sources & people", .longText, "One per line.", required: true),
                ]),
                Step("map", "Map the relationships", "How they connect and what each supports.", opens: "connections", [
                    f("links", "Relationships", .longText, "Each link, on evidence — protect confidential sources."),
                ]),
                Step("produce", "Produce the source map", "Assemble the map.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this map.", required: true),
                ]),
            ]),

        "jrn.source-reliability": build(
            "Assess source reliability and independence — a rating is a judgement, not a fact.",
            [
                Step("list", "List the sources", "Each source to rate.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Track record, independence, motive.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low — a judgement."),
                ]),
                Step("decide", "Own the ratings (your decision)", "These are judgements.", [
                    f("basis", "Basis", .longText, "Confirm the ratings.", required: true),
                ]),
                Step("produce", "Produce the schedule", "Assemble the reliability schedule.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this schedule.", required: true),
                ]),
            ]),

        "jrn.interview-plan": build(
            "Identify reporting gaps and plan the interviews to fill them.",
            [
                Step("gaps", "Identify the gaps", "What the reporting still needs.", opens: "review", [
                    f("gaps", "Reporting gaps", .longText, "What's unanswered.", required: true),
                ]),
                Step("questions", "Draft the questions", "Questions tied to each gap.", opens: "matrix", [
                    f("questions", "Questions", .longText, "Open and evidence-anchored — never assert the answers."),
                ]),
                Step("produce", "Produce the interview plan", "Assemble the plan.", opens: "handoff", posts: "INT", [
                    f("title", "Title", .text, "Name this plan.", required: true),
                ]),
            ]),

        "jrn.quote-book": build(
            "Collect quotes cited to their exact source — a quote is never altered.",
            [
                Step("collect", "Collect the quotes", "Each quote with its speaker and context.", opens: "findings", [
                    f("quotes", "Quotes", .longText, "Verbatim, with source locator.", required: true),
                ]),
                Step("verify", "Verify each locator", "Each quote reopens its exact source.", opens: "review", [
                    f("verifyNote", "Verification", .longText, "Confirm wording and context — never alter a quote."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm quote and context.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the quote book", "Assemble the quote book.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this quote book.", required: true),
                ]),
            ]),

        "jrn.transcript": build(
            "Correct transcripts with locators — unheard words are never asserted.",
            [
                Step("source", "Choose the source", "The recording/transcript.", opens: "sources", [
                    f("source", "Source", .text, "What you're correcting.", required: true),
                ]),
                Step("correct", "Correct with locators", "Fix the transcript against the audio.", opens: "findings", [
                    f("transcript", "Corrected transcript", .longText, "Mark uncertain passages — never invent speech."),
                ]),
                Step("confirm", "Confirm corrections (your decision)", "Confirm the corrected transcript.", [
                    f("basis", "Confirmation", .longText, "What you corrected.", required: true),
                ]),
                Step("produce", "Produce the transcript", "Assemble the corrected transcript.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this transcript.", required: true),
                ]),
            ]),

        "jrn.chronology": build(
            "Build the story's tick-tock — the reconstructed timeline (undated labelled, cited).",
            [
                Step("events", "Collect dated events", "Each event with its source.", opens: "timeline", [
                    f("events", "Events", .longText, "Date (or 'undated'), event, source.", required: true),
                ]),
                Step("order", "Order & link", "Sequence and connect the events.", opens: "connections", [
                    f("links", "Links", .longText, "How events and people relate."),
                ]),
                Step("confirm", "Confirm inclusion (your decision)", "Confirm the tick-tock — never invent dates.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the tick-tock", "Assemble the timeline.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this timeline.", required: true),
                ]),
            ]),

        "jrn.fact-verification": build(
            "Verify claims against evidence — conflicting accounts preserved, never averaged.",
            [
                Step("collect", "List the claims", "Claims to verify.", opens: "findings", [
                    f("claims", "Claims", .longText, "One per line.", required: true),
                ]),
                Step("verify", "Verify each", "Against the evidence.", opens: "matrix", [
                    f("verify", "Verification", .longText, "Verified / not / disputed — with source; never mark verified without evidence."),
                ]),
                Step("conflicts", "Preserve conflicts", "Conflicting accounts kept.", opens: "review", [
                    f("conflicts", "Conflicts", .longText, "Never averaged."),
                ]),
                Step("produce", "Produce the verification log", "Assemble the log.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this log.", required: true),
                ]),
            ]),

        "jrn.reporting-gap": build(
            "Track what's still unanswered — absence is not proof of wrongdoing.",
            [
                Step("list", "List the open questions", "What the reporting hasn't answered.", opens: "review", [
                    f("gaps", "Open questions", .longText, "One per line.", required: true),
                ]),
                Step("prioritize", "Prioritize", "What matters most to resolve.", opens: "matrix", [
                    f("priority", "Priorities", .longText, "Order and why — absence never implies wrongdoing."),
                ]),
                Step("produce", "Produce the register", "Assemble the open-questions register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "jrn.right-of-reply": build(
            "Log subjects named adversely and their responses — publishing without offering a reply is the gap that sinks the story.",
            [
                Step("identify", "Identify the subjects", "Everyone named adversely.", opens: "dossier", [
                    f("subjects", "Subjects", .longText, "One per line.", required: true),
                ]),
                Step("contact", "Record the outreach", "How and when each was offered a chance to respond.", opens: "review", [
                    f("contact", "Outreach", .longText, "Channel, date, and deadline given."),
                ]),
                Step("responses", "Record responses (your decision)", "Each reply, or non-response after a fair deadline.", [
                    f("responses", "Responses", .longText, "On the record — never omit a reply.", required: true),
                ]),
                Step("produce", "Produce the reply log", "Assemble the right-of-reply log.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this log.", required: true),
                ]),
            ]),

        "jrn.publication": build(
            "Record the human publication decision — never automated.",
            [
                Step("recap", "Recap verification & legal", "Verification status and any legal review.", opens: "handoff", [
                    f("recap", "Recap", .longText, "What's checked, what's outstanding."),
                ]),
                Step("decide", "Publication decision (your decision)", "A human makes the go/no-go call.", [
                    f("decision", "Decision", .choice, "Never automated.", required: true, options: ["Publish", "Hold", "Do not publish"]),
                    f("reason", "Rationale", .longText, "The basis for the decision.", required: true),
                ]),
                Step("produce", "Produce the decision record", "Post the publication decision.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),

        "jrn.correction-history": build(
            "Track post-publication corrections — the record is never rewritten silently.",
            [
                Step("collect", "List the corrections", "Each correction and what prompted it.", opens: "findings", [
                    f("corrections", "Corrections", .longText, "One per line, with new evidence.", required: true),
                ]),
                Step("record", "Record each transparently", "What changed and when.", opens: "review", [
                    f("history", "Correction history", .longText, "Transparent — never rewrite the record silently."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the correction history.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the correction log", "Assemble the log.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this log.", required: true),
                ]),
            ]),

        "jrn.publication-package": build(
            "Assemble the verified publication package: verify every claim is cited, confirm right of reply, then produce the package.",
            [
                Step("assemble", "Assemble the package", "The near-final story with citations.", opens: "findings", [
                    f("assemble", "The package", .longText, "Draft with its citations.", required: true),
                ]),
                Step("verify", "Verify every claim is cited", "Each claim maps to verified evidence.", opens: "matrix", [
                    f("verify", "Citation check", .longText, "Any unverified claim."),
                ]),
                Step("reply", "Confirm right of reply (your decision)", "Everyone named adversely was offered a reply.", [
                    f("reply", "Right of reply", .choice, "Status.", required: true, options: ["All offered a reply", "Outstanding"]),
                    f("note", "Note", .longText, "Any outstanding outreach."),
                ]),
                Step("produce", "Produce the package", "Assemble the cited package with its receipt.", opens: "handoff", posts: "PUB", [
                    f("title", "Title", .text, "Name this package.", required: true),
                ]),
            ]),

        "jrn.ask": build(
            "Ask a question over the story's sources and keep the cited answer.",
            [
                Step("ask", "Ask the story file", "The answer cites its source.", opens: "ask", [
                    f("question", "Your question", .longText, "What you want to know.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it serves the story."),
                ]),
            ]),

        "jrn.methods": build(
            "Run a structured method over the story.",
            [
                Step("pick", "Pick the method", "Which structured method.", opens: "matrix", [
                    f("method", "Method", .text, "e.g. 5W1H, hypothesis matrix.", required: true),
                ]),
                Step("run", "Run it", "Inputs and result.", opens: "matrix", [
                    f("runNote", "Result", .longText, "What it surfaced."),
                ]),
                Step("produce", "Produce the method run", "Assemble the result.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this run.", required: true),
                ]),
            ]),

        "jrn.data-desk": build(
            "Build datasets over documents (logs, filings) with cited cells.",
            [
                Step("assemble", "Assemble the documents", "Which documents this dataset draws on.", opens: "sources", [
                    f("scope", "What this covers", .text, "The data in scope.", required: true),
                ]),
                Step("build", "Build the dataset", "Each cell cited.", opens: "dataLab", [
                    f("columns", "Columns & notes", .longText, "What each column is and its source."),
                ]),
                Step("check", "Check the numbers", "Totals and outliers.", opens: "dataLab", [
                    f("check", "Checks", .longText, "Anything to warn a reader about."),
                ]),
                Step("produce", "Produce the dataset", "Assemble the story dataset.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this dataset.", required: true),
                ]),
            ]),

        "jrn.whos-who": build(
            "Unify names and aliases to one subject — reversible, human-reviewed.",
            [
                Step("gather", "Gather the names", "Names/handles that may be one subject.", opens: "knowledge", [
                    f("identifiers", "Candidate names", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across sources", "How each appears.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Exclude coincidental matches.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "A human decides. Reversible.", [
                    f("decision", "Decision", .choice, "Your decision.", required: true, options: ["Confirm same subject", "Reject — different", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "jrn.causal": build(
            "Trace why events unfolded — Five Whys / Fishbone over cited evidence, then a human takeaway.",
            [
                Step("problem", "State what to explain", "The event to explain.", opens: "findings", [
                    f("problem", "Question", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where evidence stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "The factors at play."),
                ]),
                Step("takeaway", "Takeaway (your decision)", "The explanation you'll present — grounded, not overstated.", [
                    f("takeaway", "Takeaway & basis", .longText, "On the evidence.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "jrn.source-vault": build(
            "Keep a custody-tracked vault for source documents with integrity hashes.",
            [
                Step("register", "Register the documents", "Each source with provenance (attach originals).", opens: "audit", [
                    f("items", "Documents", .longText, "What each item is and where it came from.", required: true),
                ]),
                Step("integrity", "Record integrity", "Hash/verify each.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from platform/service", "Physical/device transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("protect", "Note source protection", "Confidential-source handling.", opens: "audit", [
                    f("protect", "Protection", .longText, "How confidential sources are protected."),
                ]),
                Step("seal", "Seal the vault", "Post the sealed vault manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this manifest.", required: true),
                ]),
            ]),

        "jrn.correction-actions": build(
            "Track corrective actions on published errors to closure.",
            [
                Step("link", "Link actions to errors", "What each action fixes.", opens: "findings", [
                    f("links", "Action ↔ error", .longText, "Which published error each addresses.", required: true),
                ]),
                Step("define", "Define the actions", "Action, owner, due.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Each with owner and due date.", required: true),
                ]),
                Step("produce", "Produce the register", "Assemble the register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "jrn.correction-review": build(
            "Verify a published correction actually resolved the error.",
            [
                Step("select", "Select the correction", "Which correction.", opens: "handoff", [
                    f("action", "Correction", .text, "The correction under review.", required: true),
                ]),
                Step("evidence", "Check the outcome", "Whether the error is resolved.", opens: "findings", [
                    f("evidence", "Outcome", .longText, "What changed."),
                ]),
                Step("judge", "Resolved? (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Resolved", "Partially", "Not resolved"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        // MARK: Individual (2026-08-20)

        "ind.personal-records": build(
            "Bring in and organize your documents — point the app at your records, sort them, confirm, then open the collection.",
            [
                Step("gather", "Bring in your records", "Point the app at the folders/files with your documents (attach or add sources).", opens: "sources", [
                    f("what", "What this covers", .text, "The records this is about (e.g. household papers).", required: true),
                ]),
                Step("organize", "Organize by category", "Group them so they're easy to find.", opens: "knowledge", [
                    f("categories", "Categories", .longText, "How you're grouping them."),
                ]),
                Step("confirm", "Confirm it looks right (your decision)", "Check nothing sensitive is exposed and categories are right.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("open", "Open the collection", "Open the numbered records collection.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Name", .text, "A findable name.", required: true),
                ]),
            ]),

        "ind.document-versions": build(
            "Track versions of official documents so you always know which is current.",
            [
                Step("gather", "Gather the documents", "The official documents to track.", opens: "sources", [
                    f("scope", "What this covers", .text, "e.g. passport, licences.", required: true),
                ]),
                Step("build", "List the versions", "Each version with its date.", opens: "dataLab", [
                    f("versions", "Versions", .longText, "Old and new — keep the old ones on file."),
                ]),
                Step("confirm", "Mark the current one (your decision)", "Which version is current.", [
                    f("current", "Current version", .longText, "The current one — never discard the old.", required: true),
                ]),
                Step("produce", "Produce the version history", "Assemble the history.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this history.", required: true),
                ]),
            ]),

        "ind.career-education": build(
            "Summarize your career and education over time.",
            [
                Step("gather", "Gather the records", "Résumés, certificates, references.", opens: "sources", [
                    f("scope", "What this covers", .text, "The span this summarizes.", required: true),
                ]),
                Step("timeline", "Lay out the timeline", "Roles and qualifications by date.", opens: "timeline", [
                    f("events", "Timeline", .longText, "Each entry with dates — cited, never invented."),
                ]),
                Step("confirm", "Confirm the entries (your decision)", "Check each is accurate.", [
                    f("basis", "Confirmation", .longText, "Anything to note — never invent credentials.", required: true),
                ]),
                Step("produce", "Produce the summary", "Assemble the career/education summary.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this summary.", required: true),
                ]),
            ]),

        "ind.family-records": build(
            "Organize family members and relationships.",
            [
                Step("identify", "List the family", "Who this covers.", opens: "dossier", [
                    f("people", "Family members", .longText, "One per line with relationship.", required: true),
                ]),
                Step("compile", "Add the details", "Documents and relationships, each cited.", opens: "dossier", [
                    f("details", "Details", .longText, "Only what your records support."),
                ]),
                Step("confirm", "Confirm relationships (your decision)", "Check the relationships are right.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("produce", "Produce the family record", "Assemble the record.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this record.", required: true),
                ]),
            ]),

        "ind.property": build(
            "Keep a register of property and assets.",
            [
                Step("gather", "Gather the documents", "Deeds, titles, bills.", opens: "sources", [
                    f("scope", "What this covers", .text, "The property/assets.", required: true),
                ]),
                Step("build", "Build the register", "Each item with its documents.", opens: "dataLab", [
                    f("items", "Items", .longText, "What you own and the papers that show it — cited."),
                ]),
                Step("confirm", "Confirm ownership (your decision)", "Check the details.", [
                    f("basis", "Confirmation", .longText, "Anything to note — the app doesn't assert legal title.", required: true),
                ]),
                Step("produce", "Produce the register", "Assemble the property register.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this register.", required: true),
                ]),
            ]),

        "ind.insurance": build(
            "Keep a register of insurance policies, renewals and claims.",
            [
                Step("gather", "Gather the policies", "Policies and correspondence.", opens: "sources", [
                    f("scope", "What this covers", .text, "The policies.", required: true),
                ]),
                Step("build", "Build the register", "Each policy with key dates.", opens: "dataLab", [
                    f("items", "Policies", .longText, "Cover, premium, renewal — cited."),
                ]),
                Step("confirm", "Confirm renewals (your decision)", "Check renewal dates.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("produce", "Produce the register", "Assemble the insurance register.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this register.", required: true),
                ]),
            ]),

        "ind.health-scope": build(
            "Summarize the health records you choose to include — under strict, private scope.",
            [
                Step("scope", "Choose what to include", "Only the records you want in scope.", opens: "sources", [
                    f("scope", "In scope", .longText, "What to include — sensitive data stays private.", required: true),
                ]),
                Step("summarize", "Summarize", "A plain summary of what's there.", opens: "findings", [
                    f("summary", "Summary", .longText, "Facts from your records — the app never diagnoses."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "Confirm what's included.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("produce", "Produce the summary", "Assemble the health summary.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this summary.", required: true),
                ]),
            ]),

        "ind.applications": build(
            "Track applications and open cases.",
            [
                Step("list", "List the applications", "Applications and cases you're tracking.", opens: "findings", [
                    f("apps", "Applications", .longText, "One per line with status.", required: true),
                ]),
                Step("detail", "Add the documents & dates", "Submissions, references, deadlines.", opens: "dataLab", [
                    f("detail", "Details", .longText, "Each with its documents — cited."),
                ]),
                Step("confirm", "Confirm submissions (your decision)", "Check what's submitted.", [
                    f("basis", "Confirmation", .longText, "Anything to note — the app never submits for you.", required: true),
                ]),
                Step("produce", "Produce the tracker", "Assemble the application tracker.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this tracker.", required: true),
                ]),
            ]),

        "ind.reminders": build(
            "Turn dated obligations into confirmed reminders — renewals, expiries, deadlines.",
            [
                Step("gather", "Find the dates", "Documents with dates that matter.", opens: "timeline", [
                    f("dates", "Dated obligations", .longText, "Renewals, expiries, deadlines — with source.", required: true),
                ]),
                Step("confirm", "Confirm each reminder (your decision)", "Confirm each date before it becomes a reminder.", [
                    f("confirmed", "Confirmed reminders", .longText, "Only confirmed dates fire — never an unconfirmed one.", required: true),
                ]),
                Step("produce", "Produce the reminder list", "Assemble the list.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this list.", required: true),
                ]),
            ]),

        "ind.emergency-pack": build(
            "Assemble your in-case-of-emergency binder — what loved ones need, in one place.",
            [
                Step("choose", "Choose the essentials", "The key documents and contacts.", opens: "findings", [
                    f("items", "Essentials", .longText, "What belongs in the binder.", required: true),
                ]),
                Step("assemble", "Assemble the binder", "Put them together clearly.", opens: "handoff", [
                    f("layout", "Layout", .longText, "How it's organized for a stranger to follow."),
                ]),
                Step("confirm", "Confirm the pack (your decision)", "Check it's complete and safe to store.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("produce", "Produce the emergency pack", "Assemble the ICE pack.", opens: "handoff", posts: "ARC", [
                    f("title", "Name", .text, "Name this pack.", required: true),
                ]),
            ]),

        "ind.secure-share": build(
            "Prepare a redacted copy to share — sensitive details masked and validated first.",
            [
                Step("choose", "Choose what to share", "The documents and the recipient.", opens: "findings", [
                    f("items", "To share", .longText, "What you're sharing and with whom.", required: true),
                ]),
                Step("redact", "Redact the sensitive parts", "Mask what shouldn't leave.", opens: "handoff", [
                    f("redactions", "Redactions", .longText, "What's masked."),
                ]),
                Step("validate", "Validate the redaction (your decision)", "Confirm nothing sensitive remains.", [
                    f("validated", "Redaction validated", .choice, "Confirm before sharing.", required: true, options: ["Validated", "Not yet"]),
                    f("note", "Note", .longText, "Anything to record."),
                ]),
                Step("produce", "Produce the shareable copy", "Assemble the redacted copy.", opens: "handoff", posts: "EXP", [
                    f("title", "Name", .text, "Name this copy.", required: true),
                ]),
            ]),

        "ind.personal-chronology": build(
            "See your personal timeline (undated events labelled).",
            [
                Step("events", "Collect the events", "Life events with dates.", opens: "timeline", [
                    f("events", "Events", .longText, "Date (or 'undated'), event, source.", required: true),
                ]),
                Step("confirm", "Confirm the timeline (your decision)", "Check it's right.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("produce", "Produce the chronology", "Assemble the personal chronology.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this chronology.", required: true),
                ]),
            ]),

        "ind.legacy-archive": build(
            "Assemble the legacy binder — your records for the next generation, with a sealed receipt.",
            [
                Step("choose", "Choose what to pass on", "The records that matter for the future.", opens: "findings", [
                    f("items", "Contents", .longText, "What belongs in the legacy binder.", required: true),
                ]),
                Step("assemble", "Assemble & explain", "Organize with notes for whoever inherits it.", opens: "handoff", [
                    f("layout", "Layout & notes", .longText, "How it's organized and any guidance."),
                ]),
                Step("confirm", "Confirm the binder (your decision)", "Check it's complete.", [
                    f("basis", "Confirmation", .longText, "Anything to note.", required: true),
                ]),
                Step("produce", "Produce the legacy binder", "Assemble the binder with its receipt.", opens: "handoff", posts: "ARC", [
                    f("title", "Name", .text, "Name this binder.", required: true),
                ]),
            ]),

        "ind.ask": build(
            "Ask a question over your records — every answer cites its document.",
            [
                Step("ask", "Ask my records", "Ask in plain language.", opens: "ask", [
                    f("question", "Your question", .longText, "What you want to know.", required: true),
                ]),
                Step("record", "Keep the answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "Why you're keeping it."),
                ]),
            ]),

        "ind.methods": build(
            "Work through a guided, structured method over your records.",
            [
                Step("pick", "Pick a method", "Which guided method.", opens: "matrix", [
                    f("method", "Method", .text, "e.g. a 5W1H worksheet or checklist.", required: true),
                ]),
                Step("run", "Work through it", "Fill it in from your records.", opens: "matrix", [
                    f("runNote", "Result", .longText, "What you worked out."),
                ]),
                Step("produce", "Produce the result", "Assemble it.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this.", required: true),
                ]),
            ]),

        "ind.name-resolution": build(
            "Confirm two names are the same person or company — reversible, you decide.",
            [
                Step("gather", "Gather the names", "The names/spellings in question.", opens: "knowledge", [
                    f("identifiers", "Names", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across your records", "How each name appears.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "What matches and what doesn't."),
                ]),
                Step("decide", "Same or not? (your decision)", "You decide. Reversible.", [
                    f("decision", "Decision", .choice, "Your call.", required: true, options: ["Same", "Different", "Not sure"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("record", "Record it", "Save the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Name", .text, "Name this record.", required: true),
                ]),
            ]),

        "ind.doc-reliability": build(
            "Assess how reliable a document or its source is — a judgement, not a fact.",
            [
                Step("list", "List the documents", "The documents to weigh.", opens: "review", [
                    f("sources", "Documents", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Weigh each", "Where it came from and how trustworthy.", opens: "review", [
                    f("factors", "Notes", .longText, "What makes each more or less reliable."),
                ]),
                Step("decide", "Record your view (your decision)", "Your judgement.", [
                    f("basis", "Basis", .longText, "A judgement, not a fact.", required: true),
                ]),
                Step("produce", "Produce the notes", "Assemble the reliability notes.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this.", required: true),
                ]),
            ]),

        "ind.conflicts-gaps": build(
            "See where your records disagree or are missing — absence is not proof.",
            [
                Step("collect", "Gather the records", "The records in question.", opens: "findings", [
                    f("items", "Records", .longText, "What you're comparing.", required: true),
                ]),
                Step("compare", "Spot the disagreements", "Where they conflict.", opens: "matrix", [
                    f("comparison", "Conflicts", .longText, "Both kept."),
                ]),
                Step("gaps", "Note what's missing", "What should be there but isn't.", opens: "review", [
                    f("gaps", "Gaps", .longText, "Absence is not proof."),
                ]),
                Step("produce", "Produce the notes", "Assemble the conflicts & gaps.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this.", required: true),
                ]),
            ]),

        "ind.why": build(
            "Trace why something happened, step by step, over your cited records.",
            [
                Step("problem", "What do you want to explain?", "The thing to understand.", opens: "findings", [
                    f("problem", "Question", .longText, "Be specific.", required: true),
                ]),
                Step("whys", "Ask why, step by step", "Follow the chain as far as your records support.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each step backed by a record."),
                ]),
                Step("decide", "Your conclusion (your decision)", "The most likely explanation, on your records.", [
                    f("conclusion", "Conclusion & basis", .longText, "Not stated as certain beyond the records.", required: true),
                ]),
                Step("produce", "Produce the explanation", "Assemble it.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this.", required: true),
                ]),
            ]),

        "ind.fix-it": build(
            "Track corrective actions — renewals, disputes, fixes — to closure.",
            [
                Step("list", "List what needs fixing", "The issues and their fixes.", opens: "findings", [
                    f("items", "Fixes", .longText, "One per line.", required: true),
                ]),
                Step("define", "Add owners & due dates", "Who and by when.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Each with owner and due date."),
                ]),
                Step("produce", "Produce the fix-it list", "Assemble the list.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this list.", required: true),
                ]),
            ]),

        "ind.fix-review": build(
            "Verify a completed fix actually resolved the problem.",
            [
                Step("select", "Select the fix", "Which fix you're checking.", opens: "handoff", [
                    f("action", "Fix", .text, "The fix under review.", required: true),
                ]),
                Step("evidence", "Check the outcome", "Is the problem resolved?", opens: "findings", [
                    f("evidence", "Outcome", .longText, "What changed."),
                ]),
                Step("judge", "Did it work? (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Your call.", required: true, options: ["Fixed", "Partly", "Not fixed"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Name", .text, "Name this.", required: true),
                ]),
            ]),

        "ind.document-vault": build(
            "Keep a custody-tracked vault for your originals with integrity hashes.",
            [
                Step("register", "Add the originals", "Your key documents (attach them).", opens: "audit", [
                    f("items", "Originals", .longText, "What each is.", required: true),
                ]),
                Step("integrity", "Protect & verify", "Hash/verify them.", opens: "audit", [
                    f("method", "How added", .choice, "How they came in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Scan/import"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("seal", "Seal the vault", "Post the sealed manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Name", .text, "Name this vault.", required: true),
                ]),
            ]),

        "ind.close-matter": build(
            "Close a personal matter — sealed, reopenable with history.",
            [
                Step("recap", "Wrap it up", "What's done and anything left.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the matter."),
                ]),
                Step("decide", "Close it? (your decision)", "You close or keep it open.", [
                    f("decision", "Decision", .choice, "Close only when done.", required: true, options: ["Close", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening keeps the history.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record.", opens: "handoff", posts: "EXP", [
                    f("title", "Name", .text, "Name this record.", required: true),
                ]),
            ]),

        // MARK: Lawyer / Professional Reviewer (2026-08-20)

        "law.matter-intake": build(
            "Open the matter and set its authorized, privilege-sensitive scope, then open the matter file.",
            [
                Step("matter", "Record the matter", "The matter and the issues in dispute.", opens: "sources", [
                    f("matterName", "Matter", .text, "e.g. Acme v. Roe.", required: true),
                    f("issues", "Issues", .longText, "What's in dispute."),
                ]),
                Step("scope", "Scope (privilege-sensitive)", "The boundary, mindful of privilege.", opens: "sources", [
                    f("scope", "Scope statement", .longText, "In and out of scope.", required: true),
                    f("window", "Time window", .dateRange, "The relevant period."),
                ]),
                Step("inscope", "Set the record in scope", "Authorize the document set.", opens: "sources", [
                    f("sources", "Record in scope", .longText, "The authorized record — the evidence boundary."),
                ]),
                Step("confirm", "Confirm scope (your decision)", "A human confirms scope before work.", [
                    f("decision", "Scope confirmed?", .choice, "Confirm only when correct.", required: true, options: ["Confirmed", "Needs revision"]),
                    f("note", "Note", .longText, "Anything to record."),
                ]),
                Step("open", "Open the matter", "Open the numbered matter.", opens: "handoff", posts: "IMP", [
                    f("caseName", "Matter name", .text, "A findable name.", required: true),
                ]),
            ]),

        "law.parties-issues": build(
            "Identify parties and issues linked to canonical objects.",
            [
                Step("parties", "Identify the parties", "Every party to the matter.", opens: "dossier", [
                    f("parties", "Parties", .longText, "One per line with role.", required: true),
                ]),
                Step("issues", "Map the issues", "Link issues to parties and evidence.", opens: "matrix", [
                    f("issues", "Issues", .longText, "Each issue and who it touches — cited."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm parties and issues.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the parties & issues", "Assemble the work product.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "law.fact-chronology": build(
            "Build the case chronology — the spine of the matter (undated labelled, each fact cited).",
            [
                Step("events", "Collect the facts", "Each dated fact with its source.", opens: "timeline", [
                    f("events", "Facts", .longText, "Date (or 'undated'), fact, source.", required: true),
                ]),
                Step("order", "Order & link", "Sequence and connect the facts.", opens: "connections", [
                    f("links", "Links", .longText, "How facts and parties relate."),
                ]),
                Step("confirm", "Confirm inclusion (your decision)", "Confirm the chronology — each fact cited.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the chronology", "Assemble the case chronology.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this chronology.", required: true),
                ]),
            ]),

        "law.fact-evidence": build(
            "Map facts to evidence — both sides preserved, cites reopen.",
            [
                Step("facts", "List the facts", "The facts at issue.", opens: "findings", [
                    f("facts", "Facts", .longText, "One per line.", required: true),
                ]),
                Step("map", "Map to evidence", "Evidence for and against each fact.", opens: "matrix", [
                    f("matrix", "Fact–evidence matrix", .longText, "Both sides preserved; each cite reopens."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the mapping.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the matrix", "Assemble the fact–evidence matrix.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this matrix.", required: true),
                ]),
            ]),

        "law.witness-profiles": build(
            "Profile witnesses; contradictions cite both sides.",
            [
                Step("identify", "Identify the witnesses", "Who they are.", opens: "dossier", [
                    f("witnesses", "Witnesses", .longText, "One per line.", required: true),
                ]),
                Step("compile", "Compile each profile", "What each says, cited.", opens: "dossier", [
                    f("profiles", "Profiles", .longText, "Contradictions cite both sides."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the profiles.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the profiles", "Assemble the witness profiles.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this work product.", required: true),
                ]),
            ]),

        "law.document-coding": build(
            "Code documents by recorded, reversible decisions.",
            [
                Step("set", "Scope the set", "The documents under review.", opens: "sources", [
                    f("scope", "Set", .text, "What's being coded.", required: true),
                ]),
                Step("code", "Code the documents", "Responsive / non-responsive, issues, confidentiality.", opens: "review", [
                    f("coding", "Coding", .longText, "Decisions recorded and reversible."),
                ]),
                Step("qc", "Quality-check the coding (your decision)", "Confirm the coding is consistent.", [
                    f("basis", "QC", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the coding report", "Assemble the report.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this report.", required: true),
                ]),
            ]),

        "law.privilege": build(
            "Build the privilege log — candidates recorded with basis; privilege is NEVER auto-established.",
            [
                Step("identify", "Identify candidates", "Documents that may be privileged.", opens: "review", [
                    f("candidates", "Candidates", .longText, "One per line.", required: true),
                ]),
                Step("basis", "Record the basis", "The ground for each — attorney-client / work product.", opens: "matrix", [
                    f("basis", "Basis per document", .longText, "Annotated — privilege is never auto-established."),
                ]),
                Step("complete", "Complete the log (your decision)", "Confirm every candidate is annotated.", [
                    f("logComplete", "Privilege log complete?", .choice, "Only when every candidate has a basis.", required: true, options: ["Complete", "Incomplete"]),
                    f("note", "Note", .longText, "Anything outstanding."),
                ]),
                Step("produce", "Produce the privilege log", "Assemble the log.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this log.", required: true),
                ]),
            ]),

        "law.obligations": build(
            "Compare obligations/clauses, each cell citing a clause locator.",
            [
                Step("assemble", "Assemble the documents", "The contracts/policies to compare.", opens: "sources", [
                    f("scope", "What this covers", .text, "The documents compared.", required: true),
                ]),
                Step("build", "Build the comparison", "Each obligation, per document.", opens: "dataLab", [
                    f("columns", "Obligations", .longText, "Every cell cites a clause locator."),
                ]),
                Step("confirm", "Confirm (your decision)", "Confirm the comparison.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the comparison", "Assemble the obligations comparison.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this comparison.", required: true),
                ]),
            ]),

        "law.damages": build(
            "Build a damages ledger; amounts cite source cells.",
            [
                Step("assemble", "Assemble the records", "The financial records.", opens: "sources", [
                    f("scope", "What this covers", .text, "The records in scope.", required: true),
                ]),
                Step("build", "Build the ledger", "Each amount, cited.", opens: "dataLab", [
                    f("columns", "Damages ledger", .longText, "Every amount cites its source cell."),
                ]),
                Step("confirm", "Confirm the totals (your decision)", "Confirm the ledger ties out.", [
                    f("basis", "Confirmation", .longText, "What you confirm.", required: true),
                ]),
                Step("produce", "Produce the ledger", "Assemble the damages ledger.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this ledger.", required: true),
                ]),
            ]),

        "law.deadlines": build(
            "Track deadlines — a candidate until a human confirms it.",
            [
                Step("gather", "Find the dates", "Dated obligations in the record.", opens: "timeline", [
                    f("dates", "Candidate deadlines", .longText, "Each with its source.", required: true),
                ]),
                Step("confirm", "Confirm each (your decision)", "Confirm each deadline — a candidate until you do.", [
                    f("confirmed", "Confirmed deadlines", .longText, "Only confirmed dates are relied on.", required: true),
                ]),
                Step("produce", "Produce the deadline list", "Assemble the list.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this list.", required: true),
                ]),
            ]),

        "law.deposition": build(
            "Draft a deposition outline; questions cite the record.",
            [
                Step("focus", "Set the objectives", "What the deposition must establish.", opens: "ask", [
                    f("focus", "Objectives", .longText, "The points to cover.", required: true),
                ]),
                Step("questions", "Draft the outline", "Questions grouped by topic, each citing the record.", opens: "matrix", [
                    f("questions", "Outline", .longText, "Record-anchored questions.", required: true),
                ]),
                Step("produce", "Produce the outline", "Assemble the deposition outline.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this outline.", required: true),
                ]),
            ]),

        "law.exhibit-binder": build(
            "Assemble the exhibit list and trial binder; each exhibit cites its source version.",
            [
                Step("register", "Register the exhibits", "Each exhibit with its source version (attach).", opens: "audit", [
                    f("exhibits", "Exhibits", .longText, "What each exhibit is and its source.", required: true),
                ]),
                Step("integrity", "Record integrity", "Hash/verify each.", opens: "audit", [
                    f("method", "Acquisition method", .choice, "How it was taken in.", required: true, options: ["In-place ingest (watched folder)", "Copy into vault", "Export from system/service", "Physical/scan transfer"]),
                    f("integrity", "Integrity verified", .bool, "Turn on after Verify integrity on Audit."),
                ]),
                Step("order", "Order the binder", "The exhibit sequence.", opens: "audit", [
                    f("order", "Exhibit order", .longText, "The binder order and numbering."),
                ]),
                Step("seal", "Seal the exhibit list", "Post the sealed exhibit manifest.", opens: "handoff", posts: "PRS", [
                    f("title", "Title", .text, "Name this binder.", required: true),
                ]),
            ]),

        "law.production": build(
            "Produce the export set — every document Bates-numbered; report == receipt with custody hashes. The privilege log must be complete before anything leaves.",
            [
                Step("assemble", "Assemble the set", "The responsive documents to produce.", opens: "sources", [
                    f("set", "Production set", .text, "What's being produced.", required: true),
                ]),
                Step("privilege", "Confirm privilege log complete (your decision)", "Nothing produced before every privileged doc is logged.", [
                    f("privComplete", "Privilege log complete?", .choice, "Producing before the log is complete is the gap opposing counsel finds.", required: true, options: ["Complete", "Incomplete"]),
                ]),
                Step("redact", "Apply & validate redactions", "Redact and validate before production.", opens: "handoff", [
                    f("redactions", "Redactions", .longText, "What's redacted and validated."),
                ]),
                Step("number", "Bates-number the set", "Every document numbered.", opens: "handoff", [
                    f("bates", "Bates range", .text, "The numbering applied.", placeholder: "ACME000001–ACME000500"),
                ]),
                Step("produce", "Produce the set", "Export with custody hashes — report == receipt.", opens: "handoff", posts: "PRD", [
                    f("title", "Production name", .text, "Label this production volume.", required: true),
                ]),
            ]),

        "law.redaction": build(
            "Validate text and visual redaction before production.",
            [
                Step("apply", "Apply redactions", "Redact the sensitive/privileged content.", opens: "handoff", [
                    f("redactions", "Redactions", .longText, "What's redacted.", required: true),
                ]),
                Step("text", "Validate text redaction", "No hidden text remains.", opens: "review", [
                    f("textNote", "Text validation", .longText, "Underlying text checked."),
                ]),
                Step("visual", "Validate visual & confirm (your decision)", "Visual layer checked; confirm before production.", [
                    f("validated", "Redaction validated?", .choice, "Confirm only when text + visual pass.", required: true, options: ["Validated", "Not yet"]),
                    f("note", "Note", .longText, "Anything to record."),
                ]),
                Step("produce", "Produce the validation", "Assemble the redaction validation.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this validation.", required: true),
                ]),
            ]),

        "law.ask": build(
            "Ask a question over the matter's record and keep the cited answer.",
            [
                Step("ask", "Ask the case file", "The answer cites the record.", opens: "ask", [
                    f("question", "Your question", .longText, "What you need to know.", required: true),
                ]),
                Step("record", "Keep the cited answer", "Save the answer that matters.", opens: "answers", posts: "RPT", [
                    f("why", "Why it matters", .longText, "How it bears on the matter."),
                ]),
            ]),

        "law.methods": build(
            "Run a structured method over the matter.",
            [
                Step("pick", "Pick the method", "Which structured method.", opens: "matrix", [
                    f("method", "Method", .text, "e.g. 5W1H, hypothesis matrix.", required: true),
                ]),
                Step("run", "Run it", "Inputs and result.", opens: "matrix", [
                    f("runNote", "Result", .longText, "What it surfaced."),
                ]),
                Step("produce", "Produce the method run", "Assemble the result.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this run.", required: true),
                ]),
            ]),

        "law.party-resolution": build(
            "Unify party names and aliases — reversible, human-reviewed.",
            [
                Step("gather", "Gather the names", "Party names/aliases that may be one.", opens: "knowledge", [
                    f("identifiers", "Candidate names", .longText, "One per line.", required: true),
                ]),
                Step("compare", "Compare across the record", "How each appears.", opens: "knowledge", [
                    f("comparison", "Signals", .longText, "Matching and conflicting signals."),
                ]),
                Step("ruleout", "Rule out look-alikes", "Exclude coincidental matches.", opens: "review", [
                    f("ruledOut", "Excluded", .longText, "With reason."),
                ]),
                Step("decide", "Confirm or reject (your decision)", "A human decides. Reversible.", [
                    f("decision", "Decision", .choice, "Your decision.", required: true, options: ["Confirm same party", "Reject — different", "Insufficient evidence"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("record", "Record the resolution", "Post the reversible decision.", opens: "handoff", posts: "RPT", [
                    f("recordName", "Record name", .text, "Name this record.", required: true),
                ]),
            ]),

        "law.source-desk": build(
            "Assess reliability and independence of record sources — a rating is a judgement, not a fact.",
            [
                Step("list", "List the sources", "Each record source to assess.", opens: "review", [
                    f("sources", "Sources", .longText, "One per line.", required: true),
                ]),
                Step("assess", "Assess each", "Reliability and independence.", opens: "review", [
                    f("factors", "Factors", .longText, "What strengthens or weakens each."),
                    f("rating", "Reliability rating", .longText, "High / Medium / Low — a judgement."),
                ]),
                Step("decide", "Own the ratings (your decision)", "These are judgements.", [
                    f("basis", "Basis", .longText, "Confirm the ratings.", required: true),
                ]),
                Step("produce", "Produce the desk report", "Assemble the reliability desk.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this report.", required: true),
                ]),
            ]),

        "law.causation": build(
            "Trace causation step by step — Five Whys / Fishbone over the record, then a human determination.",
            [
                Step("problem", "State what to explain", "The outcome to explain.", opens: "findings", [
                    f("problem", "Problem statement", .longText, "Specific and evidence-based.", required: true),
                ]),
                Step("whys", "Five Whys", "Cause to cause; stop where the record stops.", opens: "connections", [
                    f("whys", "Why chain", .longText, "Each link supported."),
                ]),
                Step("fishbone", "Fishbone — categorize", "Sort candidate causes.", opens: "matrix", [
                    f("categories", "Categories", .longText, "The factors at play."),
                ]),
                Step("determine", "Determination (your decision)", "A human determines causation.", [
                    f("determination", "Determination & basis", .longText, "On the record.", required: true),
                ]),
                Step("produce", "Produce the analysis", "Assemble the causation analysis.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this analysis.", required: true),
                ]),
            ]),

        "law.remediation": build(
            "Track remediation/undertaking actions to closure.",
            [
                Step("link", "Link actions to issues", "What each action addresses.", opens: "findings", [
                    f("links", "Action ↔ issue", .longText, "Which issue each responds to.", required: true),
                ]),
                Step("define", "Define the actions", "Action, owner, due date.", opens: "handoff", [
                    f("actions", "Actions", .longText, "Each with owner and due date.", required: true),
                ]),
                Step("assign", "Agree owners & dates (your decision)", "Confirm each is agreed.", [
                    f("basis", "Confirmation", .longText, "Confirm owners and dates.", required: true),
                ]),
                Step("produce", "Produce the register", "Assemble the remediation register.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this register.", required: true),
                ]),
            ]),

        "law.remediation-review": build(
            "Verify a completed remediation actually resolved the issue.",
            [
                Step("select", "Select the action", "Which remediation.", opens: "handoff", [
                    f("action", "Action", .text, "The action under review.", required: true),
                ]),
                Step("evidence", "Gather evidence", "Evidence of the outcome (attach it).", opens: "findings", [
                    f("evidence", "Evidence", .longText, "What changed."),
                ]),
                Step("judge", "Resolved? (your decision)", "On the evidence.", [
                    f("verdict", "Verdict", .choice, "Evidence-based.", required: true, options: ["Effective", "Partially effective", "Not effective"]),
                    f("basis", "Basis", .longText, "Why.", required: true),
                ]),
                Step("produce", "Produce the review", "Assemble the review.", opens: "handoff", posts: "RPT", [
                    f("title", "Title", .text, "Name this review.", required: true),
                ]),
            ]),

        "law.matter-closure": build(
            "Close the matter (sealed); reopen preserves full history.",
            [
                Step("recap", "Confirm the outcome", "Deliverables, productions, open items.", opens: "handoff", [
                    f("recap", "Recap", .longText, "State of the matter."),
                ]),
                Step("retention", "Retention & confidentiality", "Where the file is kept and access.", opens: "handoff", [
                    f("retention", "Retention & access", .longText, "Storage, retention, access."),
                ]),
                Step("decide", "Closure decision (your decision)", "A human closes or reopens.", [
                    f("decision", "Decision", .choice, "Close only when complete.", required: true, options: ["Close the matter", "Keep open"]),
                    f("reason", "Reason", .longText, "Why — reopening preserves history.", required: true),
                ]),
                Step("produce", "Produce the closure record", "Post the closure record and receipt.", opens: "handoff", posts: "EXP", [
                    f("title", "Title", .text, "Name this record.", required: true),
                ]),
            ]),
    ]
}
