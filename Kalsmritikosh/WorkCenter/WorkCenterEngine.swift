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
        catalog[id]
    }

    // Device-light: workflow content lives as JSON parsed once at runtime, so the
    // Swift type-checker never walks a giant literal. Edit a job by editing its
    // entry in catalogJSON below (steps are gated + numbered automatically).
    private struct JField: Codable {
        let key: String; let label: String; let kind: String; let help: String
        var required: Bool? = nil; var placeholder: String? = nil; var options: [String]? = nil
    }
    private struct JStep: Codable {
        let key: String; let title: String; let hint: String
        var opens: String? = nil; var posts: String? = nil; var fields: [JField]? = nil
    }
    private struct JJob: Codable { let purpose: String; let steps: [JStep] }

    private static let catalog: [String: (purpose: String, ops: [WCOperation])] = {
        guard let data = catalogJSON.data(using: .utf8),
              let jobs = try? JSONDecoder().decode([String: JJob].self, from: data) else { return [:] }
        var out: [String: (purpose: String, ops: [WCOperation])] = [:]
        for (id, job) in jobs {
            var ops: [WCOperation] = []
            for (i, s) in job.steps.enumerated() {
                let seq = i + 1
                let gates: [WCGate] = seq <= 1 ? [] : [WCGate(rule: .operationConfirmed(seq: seq - 1), reason: "Complete the previous step first.")]
                let fields = (s.fields ?? []).map { jf in
                    WCField(key: jf.key, label: jf.label, kind: WCField.Kind(rawValue: jf.kind) ?? .text, help: jf.help, placeholder: jf.placeholder ?? "", required: jf.required ?? false, options: jf.options ?? [])
                }
                ops.append(WCOperation(seq: seq, key: s.key, title: s.title, hint: s.hint, postsDocType: s.posts, launchesSurface: s.opens, fields: fields, gates: gates))
            }
            out[id] = (job.purpose, ops)
        }
        return out
    }()

    private static let catalogJSON = ##"""
{
  "cc.angle" : {
    "purpose" : "Shape the hook and outline from what the sources actually support.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The hook, grounded in the sources.",
            "key" : "angle",
            "kind" : "longText",
            "label" : "Angle",
            "required" : true
          }
        ],
        "hint" : "The hook — what's new/interesting and supported.",
        "key" : "angle",
        "opens" : "findings",
        "title" : "Find the angle"
      },
      {
        "fields" : [
          {
            "help" : "The structure of the piece.",
            "key" : "outline",
            "kind" : "longText",
            "label" : "Outline"
          }
        ],
        "hint" : "Section outline, each point evidence-anchored.",
        "key" : "outline",
        "opens" : "matrix",
        "title" : "Outline (5W1H)"
      },
      {
        "fields" : [
          {
            "help" : "Gaps to fill before writing.",
            "key" : "check",
            "kind" : "longText",
            "label" : "Unsupported claims"
          }
        ],
        "hint" : "Anything the outline claims the sources don't yet support.",
        "key" : "check",
        "opens" : "review",
        "title" : "Check against the sources"
      },
      {
        "fields" : [
          {
            "help" : "Name this outline.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the angle & outline.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the outline"
      }
    ]
  },
  "cc.ask" : {
    "purpose" : "Ask a question across the project's sources and keep the cited answer.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you want to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "The answer cites its source.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask your research"
      },
      {
        "fields" : [
          {
            "help" : "How it serves the piece.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "cc.corrections" : {
    "purpose" : "Track corrections, rights clearances and follow-ups through to done.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which claim or clip each addresses.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Item ↔ issue",
            "required" : true
          }
        ],
        "hint" : "What each correction/clearance addresses.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link items to the issue"
      },
      {
        "fields" : [
          {
            "help" : "Each with owner and due date.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Items",
            "required" : true
          }
        ],
        "hint" : "Correction/clearance/follow-up, owner, due.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the items"
      },
      {
        "fields" : [
          {
            "help" : "Name this tracker.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the corrections tracker.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the tracker"
      }
    ]
  },
  "cc.explainer" : {
    "purpose" : "Explain how something came about — Five Whys / Fishbone over cited evidence, then a human takeaway.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Question",
            "required" : true
          }
        ],
        "hint" : "The thing to explain.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "What to explain"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "The factors at play.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "How it came about, on the evidence.",
            "key" : "takeaway",
            "kind" : "longText",
            "label" : "Takeaway & basis",
            "required" : true
          }
        ],
        "hint" : "The explanation you'll present — grounded, not overstated.",
        "key" : "takeaway",
        "title" : "Write the takeaway (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this explainer.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the explainer.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the explainer"
      }
    ]
  },
  "cc.fact-check" : {
    "purpose" : "Check each claim against evidence — conflicting accounts preserved, never averaged.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "claims",
            "kind" : "longText",
            "label" : "Claims",
            "required" : true
          }
        ],
        "hint" : "Each claim the piece makes.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "List the claims"
      },
      {
        "fields" : [
          {
            "help" : "Supported / unsupported / disputed — with the source.",
            "key" : "verify",
            "kind" : "longText",
            "label" : "Verification"
          }
        ],
        "hint" : "Evidence and status per claim.",
        "key" : "verify",
        "opens" : "matrix",
        "title" : "Verify each claim"
      },
      {
        "fields" : [
          {
            "help" : "Never averaged.",
            "key" : "conflicts",
            "kind" : "longText",
            "label" : "Conflicts"
          }
        ],
        "hint" : "Conflicting accounts, kept side by side.",
        "key" : "conflicts",
        "opens" : "review",
        "title" : "Preserve conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this board.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the fact-check board.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the fact-check"
      }
    ]
  },
  "cc.guest-workup" : {
    "purpose" : "Background a guest or subject before you feature them, citing exact evidence.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Name and role.",
            "key" : "subject",
            "kind" : "text",
            "label" : "Guest / subject",
            "required" : true
          }
        ],
        "hint" : "Who you're backgrounding.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the guest/subject"
      },
      {
        "fields" : [
          {
            "help" : "Only what the evidence supports.",
            "key" : "profile",
            "kind" : "longText",
            "label" : "Background"
          }
        ],
        "hint" : "Bio, prior statements, relationships — each cited.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Compile the background"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm and how.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation & basis",
            "required" : true
          }
        ],
        "hint" : "Confirm the key facts before you feature them.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this workup.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the workup.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the background"
      }
    ]
  },
  "cc.identity" : {
    "purpose" : "Confirm names, handles and entities are the same party: gather, compare, rule out, then decide — reversible, human-gated.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate identifiers",
            "required" : true
          }
        ],
        "hint" : "Names, handles, accounts that may be one party.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the handles"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each appears across the research.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across sources"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude coincidental matches.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Reversible later.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same party",
              "Reject — different parties",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind it.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "You decide. Never automatic.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the decision"
      }
    ]
  },
  "cc.performance" : {
    "purpose" : "Verify a correction or clearance actually resolved the issue it was for.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The item under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Item",
            "required" : true
          }
        ],
        "hint" : "Which correction/clearance you're reviewing.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the item"
      },
      {
        "fields" : [
          {
            "help" : "What changed since.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "Evidence the issue is resolved.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Gather evidence"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Resolved",
              "Partially",
              "Not resolved"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Resolved? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "cc.project-intake" : {
    "purpose" : "Open a content project and set which sources it may draw on.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The piece's working title.",
            "key" : "title",
            "kind" : "text",
            "label" : "Working title",
            "required" : true
          },
          {
            "help" : "What it's about and for whom.",
            "key" : "premise",
            "kind" : "longText",
            "label" : "Premise",
            "required" : true
          }
        ],
        "hint" : "What this piece is about.",
        "key" : "frame",
        "opens" : "sources",
        "title" : "Frame the project"
      },
      {
        "fields" : [
          {
            "help" : "The authorized source set.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources in scope"
          }
        ],
        "hint" : "Which research/sources it may use.",
        "key" : "sources",
        "opens" : "sources",
        "title" : "Set the sources in scope"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when correct.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Scope confirmed?",
            "options" : [
              "Confirmed",
              "Needs revision"
            ],
            "required" : true
          }
        ],
        "hint" : "Confirm what the piece can draw on.",
        "key" : "confirm",
        "title" : "Confirm scope (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Project name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered project.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the project"
      }
    ]
  },
  "cc.publish-package" : {
    "purpose" : "Assemble the cited, rights-cleared package: assemble the piece, verify every claim is cited, confirm rights cleared, choose the export format, then produce.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Draft with citations.",
            "key" : "assemble",
            "kind" : "longText",
            "label" : "The piece",
            "required" : true
          }
        ],
        "hint" : "The near-final piece with its citations.",
        "key" : "assemble",
        "opens" : "findings",
        "title" : "Assemble the piece"
      },
      {
        "fields" : [
          {
            "help" : "Any claim not yet cited.",
            "key" : "verify",
            "kind" : "longText",
            "label" : "Citation check"
          }
        ],
        "hint" : "Each claim maps to a vetted source.",
        "key" : "verify",
        "opens" : "matrix",
        "title" : "Verify every claim is cited"
      },
      {
        "fields" : [
          {
            "help" : "Clearance status.",
            "key" : "rights",
            "kind" : "choice",
            "label" : "Rights",
            "options" : [
              "All cleared",
              "Outstanding items"
            ],
            "required" : true
          },
          {
            "help" : "Any outstanding clearances.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "Everything used is cleared.",
        "key" : "rights",
        "title" : "Confirm rights cleared (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "The deliverable format.",
            "key" : "format",
            "kind" : "choice",
            "label" : "Export format",
            "options" : [
              "Word (.docx)",
              "PDF",
              "Both"
            ]
          }
        ],
        "hint" : "How to export the package.",
        "key" : "format",
        "opens" : "handoff",
        "title" : "Choose export format"
      },
      {
        "fields" : [
          {
            "help" : "Name this package.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the cited package and export.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "PUB",
        "title" : "Produce the package"
      }
    ]
  },
  "cc.research-table" : {
    "purpose" : "Build a data-backed table for the piece — every cell drills to its source.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The data this table spans.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "What this table is built from (attach any not ingested).",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the sources"
      },
      {
        "fields" : [
          {
            "help" : "What each column is and its source.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Columns & notes"
          }
        ],
        "hint" : "Each row/column cited.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the table"
      },
      {
        "fields" : [
          {
            "help" : "Anything a reader should be warned about.",
            "key" : "check",
            "kind" : "longText",
            "label" : "Checks"
          }
        ],
        "hint" : "Sanity-check totals and outliers.",
        "key" : "check",
        "opens" : "dataLab",
        "title" : "Check the numbers"
      },
      {
        "fields" : [
          {
            "help" : "Name this table.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the research table.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the table"
      }
    ]
  },
  "cc.rights-locker" : {
    "purpose" : "Keep sources and clips with integrity hashes and their rights/clearance status.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What each item is and where it came from.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Items",
            "required" : true
          }
        ],
        "hint" : "Each item with provenance (attach originals).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the sources & clips"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from platform/service",
              "Physical/device transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "Hash/verify each item.",
        "key" : "integrity",
        "opens" : "audit",
        "title" : "Record integrity"
      },
      {
        "fields" : [
          {
            "help" : "Owned / licensed / fair-use / pending — per item.",
            "key" : "rights",
            "kind" : "longText",
            "label" : "Rights status"
          }
        ],
        "hint" : "Clearance status per item.",
        "key" : "rights",
        "opens" : "audit",
        "title" : "Record rights/clearance"
      },
      {
        "fields" : [
          {
            "help" : "Name this manifest.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed rights/custody manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the locker"
      }
    ]
  },
  "cc.script-prep" : {
    "purpose" : "Draft interview questions and talking points over the cited record.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The points to cover.",
            "key" : "focus",
            "kind" : "longText",
            "label" : "Focus",
            "required" : true
          }
        ],
        "hint" : "What the script/interview needs to establish.",
        "key" : "focus",
        "opens" : "ask",
        "title" : "What to cover"
      },
      {
        "fields" : [
          {
            "help" : "Grouped by topic.",
            "key" : "questions",
            "kind" : "longText",
            "label" : "Questions / points",
            "required" : true
          }
        ],
        "hint" : "Open, non-leading, evidence-anchored.",
        "key" : "questions",
        "opens" : "matrix",
        "title" : "Draft questions & talking points"
      },
      {
        "fields" : [
          {
            "help" : "Practical arrangements.",
            "key" : "logistics",
            "kind" : "longText",
            "label" : "Logistics"
          }
        ],
        "hint" : "Guest, format, timing.",
        "key" : "logistics",
        "opens" : "handoff",
        "title" : "Plan the shoot/interview"
      },
      {
        "fields" : [
          {
            "help" : "Name this prep.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the prep.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "INT",
        "title" : "Produce the script/prep"
      }
    ]
  },
  "cc.source-vetting" : {
    "purpose" : "Assess how reliable and independent each source is before you rely on it — a rating is a judgement, not a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each source to vet.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "What strengthens or weakens each.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Factors"
          },
          {
            "help" : "High / Medium / Low — a judgement.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Reliability rating"
          }
        ],
        "hint" : "Independence, track record, corroboration.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are your judgements.",
        "key" : "decide",
        "title" : "Own the ratings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this vetting.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the source vetting.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the vetting"
      }
    ]
  },
  "cc.timeline" : {
    "purpose" : "Build the story's timeline and how the people and orgs connect.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date, event, source — one per line.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Dated events, each cited.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect the events"
      },
      {
        "fields" : [
          {
            "help" : "Each link and its evidence.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Connections"
          }
        ],
        "hint" : "How people and orgs relate.",
        "key" : "links",
        "opens" : "connections",
        "title" : "Map the connections"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the timeline & connections.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the timeline"
      }
    ]
  },
  "cc.wrap" : {
    "purpose" : "Archive or wrap the project by an explicit human decision — sources and package retained.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the project.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Published package, corrections, and any open items.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm the package"
      },
      {
        "fields" : [
          {
            "help" : "Storage, retention, clearances.",
            "key" : "retention",
            "kind" : "longText",
            "label" : "Retention & rights"
          }
        ],
        "hint" : "Where sources/clips are kept and their rights status.",
        "key" : "retention",
        "opens" : "handoff",
        "title" : "Retention & rights"
      },
      {
        "fields" : [
          {
            "help" : "Wrap only when done.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Archive / wrap",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves this wrap.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "You wrap or keep the project open.",
        "key" : "decide",
        "title" : "Wrap decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the wrap record and receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the wrap record"
      }
    ]
  },
  "fa.analysis" : {
    "purpose" : "Frame hypotheses and the evidence plan for the engagement (5W1H).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each testable, one per line.",
            "key" : "hypotheses",
            "kind" : "longText",
            "label" : "Hypotheses",
            "required" : true
          }
        ],
        "hint" : "The explanations to test.",
        "key" : "hypotheses",
        "opens" : "findings",
        "title" : "State the hypotheses"
      },
      {
        "fields" : [
          {
            "help" : "Who/what/when/where/why/how.",
            "key" : "fiveW",
            "kind" : "longText",
            "label" : "5W1H"
          }
        ],
        "hint" : "Over the engagement question.",
        "key" : "fiveW",
        "opens" : "matrix",
        "title" : "5W1H"
      },
      {
        "fields" : [
          {
            "help" : "Requests and tests per hypothesis.",
            "key" : "plan",
            "kind" : "longText",
            "label" : "Evidence plan"
          }
        ],
        "hint" : "What each hypothesis needs.",
        "key" : "plan",
        "opens" : "review",
        "title" : "Plan the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Name this worksheet.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis worksheet.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the worksheet"
      }
    ]
  },
  "fa.ask" : {
    "purpose" : "Ask a question over the engagement's records and keep the cited answer on the record.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you need from the records.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "The answer cites the engagement's evidence.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the records"
      },
      {
        "fields" : [
          {
            "help" : "How it bears on the mandate.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "fa.closure" : {
    "purpose" : "Close the engagement by an explicit human decision — unresolved items retained, reopening preserves the prior closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the engagement.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Report, schedules, and any items left open.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm deliverables"
      },
      {
        "fields" : [
          {
            "help" : "Storage, retention, access.",
            "key" : "retention",
            "kind" : "longText",
            "label" : "Retention & access"
          }
        ],
        "hint" : "Where the workpapers are kept and who may access them.",
        "key" : "retention",
        "opens" : "handoff",
        "title" : "Retention & confidentiality"
      },
      {
        "fields" : [
          {
            "help" : "Close only when complete.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the engagement",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves this closure.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "A human closes or keeps the engagement open.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "fa.discrepancies" : {
    "purpose" : "Surface where the records disagree or are absent — absence is not proof.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're comparing.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Records",
            "required" : true
          }
        ],
        "hint" : "The records in question.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the records"
      },
      {
        "fields" : [
          {
            "help" : "Item · What record A says (cited) · What record B says (cited) · Difference / amount · Possible explanation · Follow-up needed.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Discrepancy columns",
            "required" : true
          }
        ],
        "hint" : "One row per discrepancy.",
        "key" : "compare",
        "opens" : "matrix",
        "title" : "Compare"
      },
      {
        "fields" : [
          {
            "help" : "Absence noted, not concluded from.",
            "key" : "missing",
            "kind" : "longText",
            "label" : "Missing"
          }
        ],
        "hint" : "What should exist but doesn't.",
        "key" : "missing",
        "opens" : "review",
        "title" : "Note missing records"
      },
      {
        "fields" : [
          {
            "help" : "Name this schedule.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the discrepancy schedule.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the schedule"
      }
    ]
  },
  "fa.doc-reliability" : {
    "purpose" : "Assess the origin and reliability of ledgers, invoices and statements — a rating is a judgement, not a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Records",
            "required" : true
          }
        ],
        "hint" : "Each record to assess.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the records"
      },
      {
        "fields" : [
          {
            "help" : "What strengthens or weakens each.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Factors"
          },
          {
            "help" : "High / Medium / Low — a judgement.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Reliability rating"
          }
        ],
        "hint" : "Origin, custody, corroboration.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are your judgements.",
        "key" : "decide",
        "title" : "Own the ratings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this assessment.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the assessment.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the assessment"
      }
    ]
  },
  "fa.engagement" : {
    "purpose" : "Open a forensic engagement: record the mandate, fix scope and standards, set records in scope, then open the engagement.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Your engagement/matter reference.",
            "key" : "ref",
            "kind" : "text",
            "label" : "Engagement number",
            "required" : true
          },
          {
            "help" : "Who retained you (counsel, company, court).",
            "key" : "client",
            "kind" : "text",
            "label" : "Retaining party"
          },
          {
            "help" : "The question to answer — trace funds, quantify loss, opine.",
            "key" : "mandate",
            "kind" : "longText",
            "label" : "Mandate",
            "required" : true
          }
        ],
        "hint" : "What you're engaged to do.",
        "key" : "record",
        "opens" : "sources",
        "title" : "Record the engagement"
      },
      {
        "fields" : [
          {
            "help" : "In and out of scope.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "Scope statement",
            "required" : true
          },
          {
            "help" : "The professional standards this work follows.",
            "key" : "standards",
            "kind" : "choice",
            "label" : "Standards",
            "options" : [
              "AICPA / consulting standards",
              "Court-directed",
              "Internal policy",
              "Other"
            ]
          }
        ],
        "hint" : "The boundary and the standards you'll work to.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Scope & standards"
      },
      {
        "fields" : [
          {
            "help" : "The authorized records — the evidence boundary.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Records in scope"
          }
        ],
        "hint" : "Authorize ledgers, bank statements, invoices.",
        "key" : "inscope",
        "opens" : "sources",
        "title" : "Set records in scope"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when correct.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Scope confirmed?",
            "options" : [
              "Confirmed",
              "Needs revision"
            ],
            "required" : true
          },
          {
            "help" : "Anything to record.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "A human confirms scope before work.",
        "key" : "confirm",
        "title" : "Confirm scope (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Engagement name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered engagement.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the engagement"
      }
    ]
  },
  "fa.entity-resolution" : {
    "purpose" : "Resolve shell names and aliases to one entity: gather identifiers, compare, rule out look-alikes, then confirm or reject — reversible, human-gated.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate identifiers",
            "required" : true
          }
        ],
        "hint" : "Names, aliases, registrations that may be one entity.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather identifiers"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each appears across the records.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across evidence"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude coincidental matches.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Reversible later.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same entity",
              "Reject — different entities",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind it.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human decides. Never automatic.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "fa.expert-report" : {
    "purpose" : "Assemble the expert report: restate the assignment, summarize methodology, marshal exhibits, state opinions, note assumptions and limitations, then produce — opine only within your expertise.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Precisely what you were asked.",
            "key" : "assignment",
            "kind" : "longText",
            "label" : "Assignment",
            "required" : true
          }
        ],
        "hint" : "The question and scope you were engaged to opine on.",
        "key" : "assignment",
        "opens" : "findings",
        "title" : "Restate the assignment"
      },
      {
        "fields" : [
          {
            "help" : "Approach and standards.",
            "key" : "methodology",
            "kind" : "longText",
            "label" : "Methodology"
          }
        ],
        "hint" : "The methods you applied and why.",
        "key" : "methodology",
        "opens" : "matrix",
        "title" : "Summarize methodology"
      },
      {
        "fields" : [
          {
            "help" : "Exhibit no. · Title · What it shows · Source (cited) · Which opinion it supports.",
            "key" : "exhibits",
            "kind" : "longText",
            "label" : "Exhibit schedule columns",
            "required" : true
          }
        ],
        "hint" : "One row per exhibit the opinion rests on (attach).",
        "key" : "exhibits",
        "opens" : "findings",
        "title" : "Marshal the exhibits"
      },
      {
        "fields" : [
          {
            "help" : "Within your expertise only — each supported.",
            "key" : "opinions",
            "kind" : "longText",
            "label" : "Opinions",
            "required" : true
          }
        ],
        "hint" : "Your opinions, each tied to exhibits.",
        "key" : "opinions",
        "title" : "State opinions (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Data limitations and matters outside scope.",
            "key" : "limitations",
            "kind" : "longText",
            "label" : "Assumptions & limits"
          }
        ],
        "hint" : "What you relied on and what you didn't reach.",
        "key" : "limits",
        "opens" : "review",
        "title" : "Assumptions & limitations"
      },
      {
        "fields" : [
          {
            "help" : "Name this report.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the report with its sealed receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the expert report"
      }
    ]
  },
  "fa.funds-tracing" : {
    "purpose" : "Follow the money: identify accounts and parties, trace the transactions, map the flow, flag gaps and commingling, then produce the flow.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "accounts",
            "kind" : "longText",
            "label" : "Accounts & parties",
            "required" : true
          }
        ],
        "hint" : "The accounts and entities in the flow.",
        "key" : "accounts",
        "opens" : "connections",
        "title" : "Identify accounts & parties"
      },
      {
        "fields" : [
          {
            "help" : "Date · From (account / party) · To (account / party) · Amount · Currency · Instrument (wire / cheque / cash / transfer) · Source document (cited) · Running balance · Characterization.",
            "key" : "transactions",
            "kind" : "longText",
            "label" : "Transaction columns",
            "required" : true
          }
        ],
        "hint" : "One row per movement, as in a funds-flow spreadsheet.",
        "key" : "trace",
        "opens" : "dataLab",
        "title" : "Trace the transactions"
      },
      {
        "fields" : [
          {
            "help" : "The path of the funds.",
            "key" : "flow",
            "kind" : "longText",
            "label" : "Flow"
          }
        ],
        "hint" : "How money moved between parties.",
        "key" : "map",
        "opens" : "connections",
        "title" : "Map the flow & links"
      },
      {
        "fields" : [
          {
            "help" : "Absence is not proof.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Gaps"
          }
        ],
        "hint" : "Missing statements, commingled funds, unexplained transfers.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Flag gaps & commingling"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the funds-flow work product.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the flow"
      }
    ]
  },
  "fa.methods" : {
    "purpose" : "Run a structured method over the cited record — a method flags, it doesn't conclude.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. Benford's law, ratio/variance analysis.",
            "key" : "method",
            "kind" : "text",
            "label" : "Method",
            "required" : true
          }
        ],
        "hint" : "Which structured method.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick the method"
      },
      {
        "fields" : [
          {
            "help" : "What the method flagged — an indicator, not a conclusion.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "Inputs and what it surfaced.",
        "key" : "run",
        "opens" : "dataLab",
        "title" : "Run it"
      },
      {
        "fields" : [
          {
            "help" : "Name this run.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the result.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the method run"
      }
    ]
  },
  "fa.payee-workup" : {
    "purpose" : "Work up a payee, vendor or counterparty from cited in-scope evidence, and confirm the entity.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Payee, vendor, counterparty.",
            "key" : "subject",
            "kind" : "text",
            "label" : "Entity",
            "required" : true
          }
        ],
        "hint" : "Who/what you're working up.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the entity"
      },
      {
        "fields" : [
          {
            "help" : "Only what the evidence supports.",
            "key" : "profile",
            "kind" : "longText",
            "label" : "Workup"
          }
        ],
        "hint" : "Registration, ownership, relationships — each cited.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Compile the workup"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm and how.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation & basis",
            "required" : true
          }
        ],
        "hint" : "Confirm the entity and associations.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this workup.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the workup.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the workup"
      }
    ]
  },
  "fa.recovery" : {
    "purpose" : "Track recovery and remediation actions to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which finding each action responds to.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Action ↔ finding",
            "required" : true
          }
        ],
        "hint" : "What each action addresses.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link actions to findings"
      },
      {
        "fields" : [
          {
            "help" : "Recovery/remediation — with owner and due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions",
            "required" : true
          }
        ],
        "hint" : "Action, owner, due date.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the actions"
      },
      {
        "fields" : [
          {
            "help" : "Confirm owners and dates.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each is agreed.",
        "key" : "assign",
        "title" : "Agree owners & dates (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the actions register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "fa.recovery-review" : {
    "purpose" : "Verify a completed action actually recovered or remediated — never declare success without evidence.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The action under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Action",
            "required" : true
          }
        ],
        "hint" : "Which completed action.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the action"
      },
      {
        "fields" : [
          {
            "help" : "What happened since.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "Evidence of the outcome (attach it).",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Gather evidence"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Effective",
              "Partially effective",
              "Not effective"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Judge effectiveness (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "fa.root-cause" : {
    "purpose" : "Trace how the loss or misstatement occurred: Five Whys, Fishbone, then a human determination.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "The loss/misstatement to explain.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State the problem"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "Controls, process, people, systems.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "The root cause(s), on the evidence.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "A human determines the root cause.",
        "key" : "determine",
        "title" : "Determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "fa.tracing-schedule" : {
    "purpose" : "Build tracing schedules where every cell cites its source, and reconcile to the ledgers.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The records indexed.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Which statements/ledgers this schedule spans (attach any not ingested).",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the records"
      },
      {
        "fields" : [
          {
            "help" : "The columns a forensic tracing schedule uses: Date · From (payer / account) · To (payee / account) · Amount · Currency · Running balance · Transaction type · Source-document reference · Characterization (legitimate / commingled / suspect) · Notes. Every cell cites its source.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Schedule columns",
            "required" : true
          }
        ],
        "hint" : "Build it in DataLab (the app's spreadsheet) — one row per transaction, exactly as you would in Excel.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the tracing schedule"
      },
      {
        "fields" : [
          {
            "help" : "Ties and variances.",
            "key" : "reconcile",
            "kind" : "longText",
            "label" : "Reconciliation"
          }
        ],
        "hint" : "Tie to bank/ledger totals.",
        "key" : "reconcile",
        "opens" : "dataLab",
        "title" : "Reconcile & note variances"
      },
      {
        "fields" : [
          {
            "help" : "Name this schedule.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the tracing schedule.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the schedule"
      }
    ]
  },
  "fa.workpapers" : {
    "purpose" : "Keep custody-tracked workpapers: register originals, record acquisition and integrity, index, then seal.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What each item is and where it came from.",
            "key" : "originals",
            "kind" : "longText",
            "label" : "Originals",
            "required" : true
          }
        ],
        "hint" : "Each source document, with provenance (attach).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the originals"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from system/service",
              "Physical/device transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "How each entered custody unaltered.",
        "key" : "acquire",
        "opens" : "audit",
        "title" : "Acquisition & integrity"
      },
      {
        "fields" : [
          {
            "help" : "WP ref · Title · Purpose · Preparer · Reviewer · Report section supported · Source documents (cited).",
            "key" : "index",
            "kind" : "longText",
            "label" : "Workpaper index columns",
            "required" : true
          }
        ],
        "hint" : "One row per workpaper, cross-referenced to the report.",
        "key" : "index",
        "opens" : "audit",
        "title" : "Index the workpapers"
      },
      {
        "fields" : [
          {
            "help" : "Name this set.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the workpaper set"
      }
    ]
  },
  "gen.ancestor-profile" : {
    "purpose" : "Compile everything known about one ancestor, each fact cited.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Name and rough dates.",
            "key" : "subject",
            "kind" : "text",
            "label" : "Ancestor",
            "required" : true
          }
        ],
        "hint" : "Who this profile is about.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the ancestor"
      },
      {
        "fields" : [
          {
            "help" : "Only what the evidence supports.",
            "key" : "profile",
            "kind" : "longText",
            "label" : "Profile"
          }
        ],
        "hint" : "Life events, relationships, places — each cited.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Compile the profile"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm and how.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation & basis",
            "required" : true
          }
        ],
        "hint" : "Confirm each fact is evidenced.",
        "key" : "confirm",
        "title" : "Confirm the facts (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this profile.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the ancestor profile.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the profile"
      }
    ]
  },
  "gen.ask" : {
    "purpose" : "Ask a question over your family records and keep the cited answer.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you want to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "The answer cites its document.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the records"
      },
      {
        "fields" : [
          {
            "help" : "How it bears on the research question.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "gen.close-question" : {
    "purpose" : "Close or reopen the research question by explicit decision — the conclusion and its evidence retained.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the question.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Conclusion, evidence, and any open leads.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm the proof"
      },
      {
        "fields" : [
          {
            "help" : "Close only when the proof holds.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the question",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves this closure.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "You close or keep the question open.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "gen.conflicts" : {
    "purpose" : "Resolve records that disagree — both kept on file (GPS element 4).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What conflicts.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Records",
            "required" : true
          }
        ],
        "hint" : "The records that disagree.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the conflicting records"
      },
      {
        "fields" : [
          {
            "help" : "The conflict, side by side.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Comparison"
          }
        ],
        "hint" : "How they disagree — both preserved.",
        "key" : "compare",
        "opens" : "matrix",
        "title" : "Compare them"
      },
      {
        "fields" : [
          {
            "help" : "Which you favor and why.",
            "key" : "resolution",
            "kind" : "longText",
            "label" : "Resolution & reasoning",
            "required" : true
          }
        ],
        "hint" : "Your reasoned resolution — both records stay on file.",
        "key" : "resolve",
        "title" : "Resolve (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the conflict resolution.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the resolution"
      }
    ]
  },
  "gen.evidence-notes" : {
    "purpose" : "Correlate evidence across records with 5W1H worksheets.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're correlating.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Evidence",
            "required" : true
          }
        ],
        "hint" : "The records bearing on the question.",
        "key" : "gather",
        "opens" : "findings",
        "title" : "Gather the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Who/what/when/where/why/how.",
            "key" : "fiveW",
            "kind" : "longText",
            "label" : "5W1H"
          }
        ],
        "hint" : "Across the records.",
        "key" : "fiveW",
        "opens" : "matrix",
        "title" : "5W1H"
      },
      {
        "fields" : [
          {
            "help" : "The picture the evidence supports.",
            "key" : "correlate",
            "kind" : "longText",
            "label" : "Correlation"
          }
        ],
        "hint" : "Where independent sources agree.",
        "key" : "correlate",
        "opens" : "review",
        "title" : "Correlate"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the correlation notes.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the notes"
      }
    ]
  },
  "gen.family-lines" : {
    "purpose" : "Build family relationships and life timelines, correlate the evidence, every event cited.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date, event, source — one per line.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Births, marriages, deaths, moves — cited.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect dated events"
      },
      {
        "fields" : [
          {
            "help" : "Each link and its evidence.",
            "key" : "relations",
            "kind" : "longText",
            "label" : "Relationships"
          }
        ],
        "hint" : "Parent/child/spouse links, each on evidence.",
        "key" : "links",
        "opens" : "connections",
        "title" : "Establish relationships"
      },
      {
        "fields" : [
          {
            "help" : "What disagrees.",
            "key" : "conflicts",
            "kind" : "longText",
            "label" : "Conflicts"
          }
        ],
        "hint" : "Dates or relationships that disagree — both kept.",
        "key" : "conflicts",
        "opens" : "review",
        "title" : "Note conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Where sources agree.",
            "key" : "correlate",
            "kind" : "longText",
            "label" : "Correlation"
          }
        ],
        "hint" : "How independent sources fit together.",
        "key" : "correlate",
        "opens" : "matrix",
        "title" : "Correlate the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the lines & timeline.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the family lines"
      }
    ]
  },
  "gen.methods" : {
    "purpose" : "Work a structured checklist toward reasonably exhaustive research.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. record-type coverage, locality guide.",
            "key" : "method",
            "kind" : "text",
            "label" : "Checklist",
            "required" : true
          }
        ],
        "hint" : "Which method/checklist.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick the checklist"
      },
      {
        "fields" : [
          {
            "help" : "What's covered and what remains.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Coverage"
          }
        ],
        "hint" : "What you covered and found.",
        "key" : "run",
        "opens" : "review",
        "title" : "Work through it"
      },
      {
        "fields" : [
          {
            "help" : "Name this checklist.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the result.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the checklist"
      }
    ]
  },
  "gen.migration" : {
    "purpose" : "Trace why an ancestor moved or changed names — Five Whys / Fishbone over cited records, then a human determination.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "The move or change to explain.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State what to explain"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported (economic, legal, family).",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where the records stop.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Trace the causes"
      },
      {
        "fields" : [
          {
            "help" : "What supports or rules out each.",
            "key" : "weighing",
            "kind" : "longText",
            "label" : "For / against"
          }
        ],
        "hint" : "Evidence for and against each explanation.",
        "key" : "weigh",
        "opens" : "review",
        "title" : "Weigh the candidates"
      },
      {
        "fields" : [
          {
            "help" : "The most likely cause(s), on the evidence.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "Your reasoned explanation — never presented as certain beyond the evidence.",
        "key" : "determine",
        "title" : "Determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "gen.originals" : {
    "purpose" : "Keep custody-tracked originals and write full citations so every citation reopens its exact source.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What each item is and where it came from.",
            "key" : "originals",
            "kind" : "longText",
            "label" : "Originals",
            "required" : true
          }
        ],
        "hint" : "Each source with provenance (attach the images/records).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the originals"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from archive/service",
              "Physical/scan transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "Hash/verify the originals.",
        "key" : "integrity",
        "opens" : "audit",
        "title" : "Record integrity"
      },
      {
        "fields" : [
          {
            "help" : "So each reopens its exact source.",
            "key" : "citations",
            "kind" : "longText",
            "label" : "Citations"
          }
        ],
        "hint" : "A complete citation per source.",
        "key" : "cite",
        "opens" : "audit",
        "title" : "Write full citations"
      },
      {
        "fields" : [
          {
            "help" : "Name this manifest.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed citation/originals manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the source list"
      }
    ]
  },
  "gen.proof-argument" : {
    "purpose" : "Write the Genealogical Proof Standard argument: state the question and conclusion, summarize the evidence, show reasonably exhaustive research, resolve conflicts, write the reasoned conclusion, then produce.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Both stated up front.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Question & conclusion",
            "required" : true
          }
        ],
        "hint" : "The question and the conclusion you'll argue.",
        "key" : "question",
        "opens" : "findings",
        "title" : "Question & conclusion"
      },
      {
        "fields" : [
          {
            "help" : "What supports the conclusion.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "The relevant evidence, cited.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Summarize the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Why the research is reasonably exhaustive.",
            "key" : "exhaustive",
            "kind" : "longText",
            "label" : "Coverage"
          }
        ],
        "hint" : "Show the search was thorough.",
        "key" : "exhaustive",
        "opens" : "review",
        "title" : "Reasonably exhaustive research"
      },
      {
        "fields" : [
          {
            "help" : "Both sides, and your resolution.",
            "key" : "conflicts",
            "kind" : "longText",
            "label" : "Conflict resolution"
          }
        ],
        "hint" : "Conflicting evidence and how resolved.",
        "key" : "resolve",
        "opens" : "matrix",
        "title" : "Resolve conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Your reasoned proof.",
            "key" : "conclusion",
            "kind" : "longText",
            "label" : "Conclusion",
            "required" : true
          }
        ],
        "hint" : "The soundly-reasoned, written conclusion.",
        "key" : "conclusion",
        "title" : "Write the conclusion (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this proof argument.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the argument with its sealed receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the proof argument"
      }
    ]
  },
  "gen.research-log" : {
    "purpose" : "Keep the classic research log — every search, where, and what it yielded (including negative results).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date searched · Repository / website · Source (title, call number / URL) · Search terms & scope · Result (found / NIL) · Citation of anything found · Next step. Record NIL results too — they prove the search was reasonably exhaustive.",
            "key" : "searches",
            "kind" : "longText",
            "label" : "Research-log columns",
            "required" : true
          }
        ],
        "hint" : "The classic research-log columns, one row per search (as you would on paper or in Excel).",
        "key" : "searches",
        "opens" : "dataLab",
        "title" : "Record each search"
      },
      {
        "fields" : [
          {
            "help" : "Include negative results — they matter.",
            "key" : "results",
            "kind" : "longText",
            "label" : "Results"
          }
        ],
        "hint" : "What each search yielded.",
        "key" : "results",
        "opens" : "dataLab",
        "title" : "Record results"
      },
      {
        "fields" : [
          {
            "help" : "What to search next.",
            "key" : "next",
            "kind" : "longText",
            "label" : "Next"
          }
        ],
        "hint" : "Leads and gaps to pursue.",
        "key" : "next",
        "opens" : "review",
        "title" : "Note next searches"
      },
      {
        "fields" : [
          {
            "help" : "Name this log entry.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the research log entry.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "LOG",
        "title" : "Produce the log entry"
      }
    ]
  },
  "gen.research-plan" : {
    "purpose" : "Fix the research question and record scope before searching — the start of the Genealogical Proof Standard.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and answerable.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Research question",
            "required" : true
          }
        ],
        "hint" : "The specific question — a person, event, or relationship.",
        "key" : "question",
        "opens" : "sources",
        "title" : "State the research question"
      },
      {
        "fields" : [
          {
            "help" : "With sources.",
            "key" : "known",
            "kind" : "longText",
            "label" : "Known facts"
          },
          {
            "help" : "The period this covers.",
            "key" : "window",
            "kind" : "dateRange",
            "label" : "Time & place"
          }
        ],
        "hint" : "What you already know and its sources; the time/place scope.",
        "key" : "known",
        "opens" : "sources",
        "title" : "Known facts & scope"
      },
      {
        "fields" : [
          {
            "help" : "Where to look and for what.",
            "key" : "plan",
            "kind" : "longText",
            "label" : "Search plan"
          }
        ],
        "hint" : "Record types and repositories — reasonably exhaustive.",
        "key" : "plan",
        "opens" : "sources",
        "title" : "Plan the search"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Question name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered question to work.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the research question"
      }
    ]
  },
  "gen.same-person" : {
    "purpose" : "Decide whether name variants are one person: gather them, compare across records, rule out look-alikes, then decide — reversible, you decide.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Name variants",
            "required" : true
          }
        ],
        "hint" : "Every spelling/variant that may be one person.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the variants"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals (dates, places, kin).",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each appears across the records.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across records"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Same-name different-person is common — exclude them.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Reversible later.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same person",
              "Reject — different people",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind it.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "You decide identity. Never automatic.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "gen.source-analysis" : {
    "purpose" : "Classify each source — original or derivative, primary or secondary information, direct or indirect evidence (a classification is a judgement).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each source to analyze.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "For each source, on the GPS axes.",
            "key" : "classify",
            "kind" : "longText",
            "label" : "Classification"
          }
        ],
        "hint" : "Original/derivative; primary/secondary; direct/indirect.",
        "key" : "classify",
        "opens" : "review",
        "title" : "Classify each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the classifications.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are your judgements.",
        "key" : "decide",
        "title" : "Own the classification (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the source analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "gen.to-do" : {
    "purpose" : "Track follow-up searches and record orders to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which gap each addresses.",
            "key" : "links",
            "kind" : "longText",
            "label" : "To-do ↔ question",
            "required" : true
          }
        ],
        "hint" : "What each search will answer.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link to-dos to the question"
      },
      {
        "fields" : [
          {
            "help" : "Each with repository and priority.",
            "key" : "todos",
            "kind" : "longText",
            "label" : "To-dos",
            "required" : true
          }
        ],
        "hint" : "Search/record order, where, priority.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the to-dos"
      },
      {
        "fields" : [
          {
            "help" : "Name this list.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the research to-dos.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the to-do list"
      }
    ]
  },
  "gen.to-do-review" : {
    "purpose" : "Verify a completed search actually answered the question — never assume it did.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The completed search.",
            "key" : "action",
            "kind" : "text",
            "label" : "Search",
            "required" : true
          }
        ],
        "hint" : "Which to-do you're reviewing.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the completed search"
      },
      {
        "fields" : [
          {
            "help" : "What the search produced.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "The result and whether it answered the question.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "What it yielded"
      },
      {
        "fields" : [
          {
            "help" : "Did it answer the question?",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Answered",
              "Partially",
              "Did not answer"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the result.",
        "key" : "judge",
        "title" : "Did it answer? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "hr.action-review" : {
    "purpose" : "Verify a completed action actually fixed the issue — never declare it effective without evidence.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which corrective/preventive action.",
            "key" : "action",
            "kind" : "text",
            "label" : "Action under review",
            "required" : true
          }
        ],
        "hint" : "Pick the completed action you're reviewing.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the action"
      },
      {
        "fields" : [
          {
            "help" : "What has (or hasn't) happened since the action.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Post-action evidence"
          }
        ],
        "hint" : "Collect evidence of whether the issue recurred (attach it).",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Gather post-action evidence"
      },
      {
        "fields" : [
          {
            "help" : "Your evidence-based verdict.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Effective",
              "Partially effective",
              "Not effective"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind the verdict.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "Decide, on the evidence, whether the action worked.",
        "key" : "judge",
        "title" : "Judge effectiveness (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the effectiveness review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "hr.allegations" : {
    "purpose" : "Frame each allegation with 5W1H, link the evidence, and record its status — an allegation is unproven until found.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One allegation per line — each specific enough to test.",
            "key" : "allegations",
            "kind" : "longText",
            "label" : "Allegations",
            "required" : true
          }
        ],
        "hint" : "Break the complaint into distinct, testable allegations.",
        "key" : "list",
        "opens" : "findings",
        "title" : "List the allegations"
      },
      {
        "fields" : [
          {
            "help" : "Who did what, to whom, when and where, and how you know.",
            "key" : "fiveW",
            "kind" : "longText",
            "label" : "5W1H per allegation",
            "required" : true
          }
        ],
        "hint" : "For each allegation: who, what, when, where, why, how.",
        "key" : "frame",
        "opens" : "matrix",
        "title" : "Frame each with 5W1H"
      },
      {
        "fields" : [
          {
            "help" : "Which documents support or rebut each allegation.",
            "key" : "evidenceNote",
            "kind" : "longText",
            "label" : "Evidence per allegation"
          }
        ],
        "hint" : "Attach or cite the documents that speak to each allegation.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Link the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Substantiated / not substantiated / unfounded / inconclusive — with basis for each.",
            "key" : "status",
            "kind" : "longText",
            "label" : "Status per allegation",
            "required" : true
          }
        ],
        "hint" : "Record a status per allegation with its basis — never state a finding you can't support.",
        "key" : "status",
        "posts" : "ALG",
        "title" : "Record status (your decision)"
      }
    ]
  },
  "hr.ask" : {
    "purpose" : "Ask a question over the case's authorized documents and keep the cited answer on the record.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you need to know from the case file.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "Ask in plain language — the answer is grounded in the case's authorized evidence and cites it.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the record"
      },
      {
        "fields" : [
          {
            "help" : "How this answer bears on the allegations.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters so it's quotable later.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "hr.closure" : {
    "purpose" : "Close the case by an explicit human decision — unresolved items retained, and reopening preserves the prior closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of findings, actions, and any items left open.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Closure recap"
          }
        ],
        "hint" : "Check findings are approved and actions tracked to closure.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm findings & actions"
      },
      {
        "fields" : [
          {
            "help" : "Storage, retention period, and access restrictions.",
            "key" : "retention",
            "kind" : "longText",
            "label" : "Retention & access"
          }
        ],
        "hint" : "Record where the file is kept and who may access it.",
        "key" : "retention",
        "opens" : "handoff",
        "title" : "Retention & confidentiality"
      },
      {
        "fields" : [
          {
            "help" : "Close only when it's genuinely complete.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the case",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening later preserves this closure.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "A human closes or keeps the case open. The app never closes on its own.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this closure record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and sealed receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "hr.complaint-intake" : {
    "purpose" : "Open a workplace/compliance case the way an investigator actually does it — receive and log the complaint, triage immediate risk, clear conflicts, fix authority and scope, issue the preservation hold, plan the investigation, get sign-off, then open the case file. Intake never decides the merits.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Your case/complaint number.",
            "key" : "ref",
            "kind" : "text",
            "label" : "Complaint reference",
            "placeholder" : "HR-2026-0001",
            "required" : true
          },
          {
            "help" : "When it came in — anchors every deadline.",
            "key" : "receivedOn",
            "kind" : "date",
            "label" : "Date received"
          },
          {
            "help" : "Who raised it (or 'anonymous').",
            "key" : "complainant",
            "kind" : "text",
            "label" : "Complainant"
          },
          {
            "help" : "How it arrived.",
            "key" : "channel",
            "kind" : "choice",
            "label" : "Channel",
            "options" : [
              "Hotline",
              "Email",
              "Manager referral",
              "HR walk-in",
              "Regulator",
              "Other"
            ]
          },
          {
            "help" : "The complaint in the complainant's own words — not your summary.",
            "key" : "verbatim",
            "kind" : "longText",
            "label" : "Allegation (verbatim)",
            "required" : true
          }
        ],
        "hint" : "Log it exactly as received — verbatim, before any assessment.",
        "key" : "receive",
        "opens" : "sources",
        "title" : "Receive & log the complaint"
      },
      {
        "fields" : [
          {
            "help" : "How urgent/serious on its face.",
            "key" : "risk",
            "kind" : "choice",
            "label" : "Risk level",
            "options" : [
              "Low",
              "Medium",
              "High",
              "Critical — immediate action"
            ],
            "required" : true
          },
          {
            "help" : "e.g. separation of parties, suspension (neutral), access revocation, safety steps — and the basis.",
            "key" : "interim",
            "kind" : "longText",
            "label" : "Interim measures"
          },
          {
            "help" : "Does law/policy require external reporting (regulator, police, safeguarding)?",
            "key" : "mandatory",
            "kind" : "choice",
            "label" : "Mandatory report needed?",
            "options" : [
              "No",
              "Yes — noted below",
              "Unsure — escalate"
            ]
          }
        ],
        "hint" : "Before anything else, decide if urgent safeguards are needed.",
        "key" : "triage",
        "opens" : "review",
        "title" : "Triage risk & interim measures"
      },
      {
        "fields" : [
          {
            "help" : "Who will run the investigation.",
            "key" : "investigator",
            "kind" : "text",
            "label" : "Assigned investigator",
            "required" : true
          },
          {
            "help" : "Any relationship to the parties?",
            "key" : "conflicts",
            "kind" : "choice",
            "label" : "Conflicts of interest",
            "options" : [
              "None",
              "Managed — noted",
              "Yes — reassign"
            ],
            "required" : true
          },
          {
            "help" : "How any conflict is managed.",
            "key" : "conflictNote",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "Confirm the investigator is impartial and qualified.",
        "key" : "conflicts",
        "opens" : "handoff",
        "title" : "Clear conflicts & independence"
      },
      {
        "fields" : [
          {
            "help" : "Under whose mandate.",
            "key" : "authority",
            "kind" : "choice",
            "label" : "Authority",
            "options" : [
              "Company policy",
              "Regulatory requirement",
              "Management directive",
              "Legal/counsel instruction",
              "Other"
            ],
            "required" : true
          },
          {
            "help" : "The specific policies, code sections, or laws in play.",
            "key" : "policies",
            "kind" : "longText",
            "label" : "Applicable policies / law"
          },
          {
            "help" : "Is this conducted at counsel's direction (privileged)?",
            "key" : "privilege",
            "kind" : "choice",
            "label" : "Legal privilege?",
            "options" : [
              "No",
              "Yes — at counsel's direction"
            ]
          }
        ],
        "hint" : "The mandate and the rules this runs under.",
        "key" : "authority",
        "opens" : "sources",
        "title" : "Determine authority & policy"
      },
      {
        "fields" : [
          {
            "help" : "One discrete allegation per line — each specific enough to prove or disprove.",
            "key" : "allegations",
            "kind" : "longText",
            "label" : "Allegations",
            "required" : true
          }
        ],
        "hint" : "Split the complaint into distinct, testable allegations.",
        "key" : "allegations",
        "opens" : "findings",
        "title" : "Break down the allegations"
      },
      {
        "fields" : [
          {
            "help" : "What is in and out of scope.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "Scope statement",
            "required" : true
          },
          {
            "help" : "The period under investigation.",
            "key" : "window",
            "kind" : "dateRange",
            "label" : "Time window"
          }
        ],
        "hint" : "The boundary the investigation must stay within.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Define scope & window"
      },
      {
        "fields" : [
          {
            "help" : "Mailboxes, drives, chat, devices, CCTV, physical files to preserve.",
            "key" : "holdScope",
            "kind" : "longText",
            "label" : "Hold scope",
            "required" : true
          },
          {
            "help" : "Turn on once custodians/IT are notified in writing.",
            "key" : "holdIssued",
            "kind" : "bool",
            "label" : "Hold issued"
          },
          {
            "help" : "When the hold was issued.",
            "key" : "holdDate",
            "kind" : "date",
            "label" : "Hold date"
          }
        ],
        "hint" : "Stop relevant evidence being deleted — before collection.",
        "key" : "hold",
        "opens" : "audit",
        "title" : "Issue the preservation / legal hold"
      },
      {
        "fields" : [
          {
            "help" : "People/systems holding relevant material.",
            "key" : "custodians",
            "kind" : "longText",
            "label" : "Custodians",
            "required" : true
          },
          {
            "help" : "The authorized document sets — the hard evidence boundary.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources in scope"
          }
        ],
        "hint" : "Who holds the evidence, and which sets are authorized.",
        "key" : "custodians",
        "opens" : "sources",
        "title" : "Identify sources & custodians"
      },
      {
        "fields" : [
          {
            "help" : "Who is informed, and why.",
            "key" : "needToKnow",
            "kind" : "longText",
            "label" : "Need-to-know list"
          },
          {
            "help" : "Lawful basis, minimisation, retention, special-category data handling.",
            "key" : "dataProtection",
            "kind" : "longText",
            "label" : "Data-protection note"
          },
          {
            "help" : "Complainant/witnesses reminded that retaliation is prohibited.",
            "key" : "antiRetaliation",
            "kind" : "bool",
            "label" : "Anti-retaliation reminder"
          }
        ],
        "hint" : "Who may know, and how personal data is handled.",
        "key" : "confidentiality",
        "opens" : "handoff",
        "title" : "Confidentiality & data-protection plan"
      },
      {
        "fields" : [
          {
            "help" : "Interview order (usually complainant → witnesses → respondent), documents to collect, methods, and target dates.",
            "key" : "plan",
            "kind" : "longText",
            "label" : "Investigation plan",
            "required" : true
          }
        ],
        "hint" : "The route: who to interview, what to collect, in what order.",
        "key" : "plan",
        "opens" : "handoff",
        "title" : "Draft the investigation plan"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when scope, authority, hold and plan are right.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Approve to proceed?",
            "options" : [
              "Approved",
              "Needs revision"
            ],
            "required" : true
          },
          {
            "help" : "Who signed off.",
            "key" : "approver",
            "kind" : "text",
            "label" : "Approved by"
          }
        ],
        "hint" : "A human signs off before any evidence is worked. The app never decides the merits.",
        "key" : "signoff",
        "title" : "Confirm scope & plan (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name for this case.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Case name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered case the rest of the jobs run against.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the case file"
      }
    ]
  },
  "hr.corrective-actions" : {
    "purpose" : "Turn findings and root causes into tracked corrective and preventive actions with owners and due dates.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which finding/root cause each action responds to.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Action ↔ cause",
            "required" : true
          }
        ],
        "hint" : "Tie each planned action to the finding or root cause it addresses.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link actions to causes"
      },
      {
        "fields" : [
          {
            "help" : "Each action: description, corrective vs preventive, owner, due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions",
            "required" : true
          }
        ],
        "hint" : "Specify each action, its type, owner and due date.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the actions"
      },
      {
        "fields" : [
          {
            "help" : "Confirm owners and dates, or note what's still open.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each owner and due date is agreed.",
        "key" : "assign",
        "title" : "Agree owners & dates (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the corrective-actions register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the CAPA register"
      }
    ]
  },
  "hr.credibility" : {
    "purpose" : "Assess the reliability and independence of each account — a rating is a judgement, never a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each account/source, one per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Accounts",
            "required" : true
          }
        ],
        "hint" : "List each account/source you'll assess.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the accounts"
      },
      {
        "fields" : [
          {
            "help" : "For each account: what strengthens or weakens its reliability.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Assessment factors"
          },
          {
            "help" : "High / Medium / Low per account — a judgement, not proof.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Reliability rating"
          }
        ],
        "hint" : "Weigh consistency, corroboration, bias and opportunity to observe.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each account"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings and note these are judgements, not findings.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "Own the ratings as your assessment.",
        "key" : "decide",
        "title" : "Record your judgement (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this assessment.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the credibility assessment.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the assessment"
      }
    ]
  },
  "hr.evidence-custody" : {
    "purpose" : "Keep a defensible chain of custody: register each exhibit, record acquisition and integrity, log transfers, then seal the manifest.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each exhibit: what it is and its source.",
            "key" : "exhibits",
            "kind" : "longText",
            "label" : "Exhibits",
            "required" : true
          }
        ],
        "hint" : "List each item collected, with where it came from (attach the originals).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the exhibits"
      },
      {
        "fields" : [
          {
            "help" : "How the material was taken into custody.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from system/service",
              "Physical/device transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after running Verify integrity on the Audit screen.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "Record how each item entered custody without being altered.",
        "key" : "acquire",
        "opens" : "audit",
        "title" : "Acquisition & integrity"
      },
      {
        "fields" : [
          {
            "help" : "Each hand-off: from, to, when, why.",
            "key" : "transfers",
            "kind" : "longText",
            "label" : "Custody transfers"
          }
        ],
        "hint" : "Who held what, and when.",
        "key" : "transfers",
        "opens" : "audit",
        "title" : "Log custody transfers"
      },
      {
        "fields" : [
          {
            "help" : "Name this manifest.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed custody manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the custody manifest"
      }
    ]
  },
  "hr.evidence-register" : {
    "purpose" : "Register the documentary evidence (emails, records, policies) with cited cells, and check it for gaps.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The document set this register indexes.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Gather the documents this register covers (attach any not yet ingested).",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the documents"
      },
      {
        "fields" : [
          {
            "help" : "Date, author, type, relevance — every cell traceable to its source.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Register columns & notes"
          }
        ],
        "hint" : "Index each document with the columns that matter.",
        "key" : "register",
        "opens" : "dataLab",
        "title" : "Build the register"
      },
      {
        "fields" : [
          {
            "help" : "Anything missing or unverified a reviewer should know.",
            "key" : "quality",
            "kind" : "longText",
            "label" : "Quality issues"
          }
        ],
        "hint" : "Flag missing, undated or unauthenticated items.",
        "key" : "quality",
        "opens" : "dataLab",
        "title" : "Check quality & gaps"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the evidence register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "hr.findings-memo" : {
    "purpose" : "Reach findings on the balance of probabilities: recap scope, marshal the evidence per allegation, apply the standard, record findings with basis, note limitations, then produce the memo — never assert an unproven finding.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The allegations being decided and the scope they're decided within.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Scope & allegations",
            "required" : true
          }
        ],
        "hint" : "Anchor the memo in the case's scope and allegations.",
        "key" : "recap",
        "opens" : "findings",
        "title" : "Restate scope & allegations"
      },
      {
        "fields" : [
          {
            "help" : "The cited evidence bearing on each allegation.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence per allegation"
          }
        ],
        "hint" : "For each allegation, line up the evidence for and against (attach key exhibits).",
        "key" : "marshal",
        "opens" : "findings",
        "title" : "Marshal the evidence"
      },
      {
        "fields" : [
          {
            "help" : "How the evidence meets or falls short of the standard, per allegation.",
            "key" : "reasoning",
            "kind" : "longText",
            "label" : "Reasoning"
          }
        ],
        "hint" : "Balance of probabilities — is each allegation more likely than not?",
        "key" : "standard",
        "opens" : "matrix",
        "title" : "Apply the standard of proof"
      },
      {
        "fields" : [
          {
            "help" : "Substantiated / not substantiated per allegation — with basis. Do not assert findings the evidence doesn't support.",
            "key" : "findings",
            "kind" : "longText",
            "label" : "Findings",
            "required" : true
          }
        ],
        "hint" : "The human finding for each allegation, with its basis.",
        "key" : "findings",
        "title" : "Record findings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "What remains uncertain or was outside reach.",
            "key" : "limitations",
            "kind" : "longText",
            "label" : "Limitations"
          }
        ],
        "hint" : "Record gaps, refusals and unresolved conflicts — honest closure.",
        "key" : "limits",
        "opens" : "review",
        "title" : "Note limitations"
      },
      {
        "fields" : [
          {
            "help" : "Name this memo.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the findings memo with its sealed receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the findings memo"
      }
    ]
  },
  "hr.incident-timeline" : {
    "purpose" : "Build the incident chronology with relationship links, flagging gaps and conflicts — absence is not proof.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each event: date, what happened, source — one per line.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Gather every dated event, each with its source.",
        "key" : "collect",
        "opens" : "timeline",
        "title" : "Collect dated events"
      },
      {
        "fields" : [
          {
            "help" : "Who was involved in what, and how events relate.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Links"
          }
        ],
        "hint" : "Put events in order and link the parties involved.",
        "key" : "link",
        "opens" : "connections",
        "title" : "Order & link"
      },
      {
        "fields" : [
          {
            "help" : "Where the record is silent or accounts disagree.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Gaps & conflicts"
          }
        ],
        "hint" : "Note missing periods and conflicting dates — keep both sides.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Flag gaps & conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this chronology.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the cited chronology.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the chronology"
      }
    ]
  },
  "hr.interview-prep" : {
    "purpose" : "Prepare an interview grounded in the record: what to establish, non-leading questions tied to evidence, and the logistics and rights.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The points this interview needs to clarify or confirm.",
            "key" : "focus",
            "kind" : "longText",
            "label" : "What to establish",
            "required" : true
          }
        ],
        "hint" : "See what the evidence already shows and what's missing.",
        "key" : "review",
        "opens" : "ask",
        "title" : "Review the record"
      },
      {
        "fields" : [
          {
            "help" : "The question list — grouped by topic, evidence-anchored.",
            "key" : "questions",
            "kind" : "longText",
            "label" : "Questions",
            "required" : true
          }
        ],
        "hint" : "Open, non-leading questions, each tied to specific evidence.",
        "key" : "questions",
        "opens" : "matrix",
        "title" : "Draft the questions"
      },
      {
        "fields" : [
          {
            "help" : "Arrangements and the rights/notice to give the interviewee.",
            "key" : "logistics",
            "kind" : "longText",
            "label" : "Logistics & rights"
          }
        ],
        "hint" : "Who, when, support person, and any notice/rights to state.",
        "key" : "logistics",
        "opens" : "handoff",
        "title" : "Plan logistics & rights"
      },
      {
        "fields" : [
          {
            "help" : "Name this interview plan.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the interview plan.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "INT",
        "title" : "Produce the interview plan"
      }
    ]
  },
  "hr.name-resolution" : {
    "purpose" : "Decide whether names/accounts are the same person: gather identifiers, compare across evidence, rule out look-alikes, then confirm or reject — reversible, never automatic.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "All the identifiers in play — one per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate identifiers",
            "required" : true
          }
        ],
        "hint" : "Collect every name, email, username or account ID that might be the same person.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the identifiers"
      },
      {
        "fields" : [
          {
            "help" : "Where the identifiers co-occur, and where they conflict.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Matching & conflicting signals"
          }
        ],
        "hint" : "See how each identifier appears across the documents.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Candidates you considered and ruled out, with the reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Look-alikes excluded"
          }
        ],
        "hint" : "Consider look-alikes (common names, shared devices) and exclude them.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out coincidental matches"
      },
      {
        "fields" : [
          {
            "help" : "Your identity decision — reversible later.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same person",
              "Reject — different people",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind your decision.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human decides identity. The app never auto-merges.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this resolution record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible identity decision to the case file.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "hr.parties" : {
    "purpose" : "Profile the complainant, respondent(s) and witnesses from cited evidence, and confirm each identity.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Complainant, respondent(s), witnesses — one per line with role.",
            "key" : "parties",
            "kind" : "longText",
            "label" : "Parties",
            "required" : true
          }
        ],
        "hint" : "List everyone the case involves and their role.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the parties"
      },
      {
        "fields" : [
          {
            "help" : "For each party: role, relationships, relevant cited facts.",
            "key" : "profiles",
            "kind" : "longText",
            "label" : "Profiles"
          }
        ],
        "hint" : "Build each profile only from cited evidence.",
        "key" : "profile",
        "opens" : "dossier",
        "title" : "Compile each profile"
      },
      {
        "fields" : [
          {
            "help" : "Confirm each identity, or flag any you cannot — with basis.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation & basis",
            "required" : true
          }
        ],
        "hint" : "Confirm each profile maps to the right real person.",
        "key" : "confirm",
        "title" : "Confirm identities (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the profiles for the case file.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce party profiles"
      }
    ]
  },
  "hr.root-cause" : {
    "purpose" : "Find why it happened: Five Whys down the causal chain, Fishbone across cause categories, weigh the candidates, then record the human root-cause determination — the app never confirms a cause.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The issue to explain — specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "Define the confirmed issue precisely.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State the problem"
      },
      {
        "fields" : [
          {
            "help" : "Why → because → why → because … each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Trace cause to cause; stop where the evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "People / process / policy / systems / environment.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Cause categories"
          }
        ],
        "hint" : "Sort candidate causes by category.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "What supports or rules out each candidate cause.",
            "key" : "weighing",
            "kind" : "longText",
            "label" : "For / against"
          }
        ],
        "hint" : "Evidence for and against each candidate cause.",
        "key" : "weigh",
        "opens" : "review",
        "title" : "Weigh the candidates"
      },
      {
        "fields" : [
          {
            "help" : "The root cause(s) you determine, and why.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "A human determines the root cause(s). The app never confirms one.",
        "key" : "determine",
        "title" : "Root-cause determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the root-cause analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "hr.statements" : {
    "purpose" : "Compare the parties' accounts point by point, preserving conflicts rather than averaging them — due process depends on it.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each account, attributed and cited.",
            "key" : "accounts",
            "kind" : "longText",
            "label" : "Accounts",
            "required" : true
          }
        ],
        "hint" : "Gather each party's statement (attach interview notes/recordings).",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the accounts"
      },
      {
        "fields" : [
          {
            "help" : "Where accounts agree, and where they conflict — keep both sides.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Agreement & conflict"
          }
        ],
        "hint" : "Line up the accounts on each disputed point.",
        "key" : "compare",
        "opens" : "matrix",
        "title" : "Compare point by point"
      },
      {
        "fields" : [
          {
            "help" : "Conflicts still unresolved, and why.",
            "key" : "conflicts",
            "kind" : "longText",
            "label" : "Open conflicts"
          }
        ],
        "hint" : "Note conflicts that remain open — never resolved by averaging.",
        "key" : "conflicts",
        "opens" : "review",
        "title" : "Record unresolved conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this comparison.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the statement comparison.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the comparison"
      }
    ]
  },
  "ind.applications" : {
    "purpose" : "Track applications and open cases.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line with status.",
            "key" : "apps",
            "kind" : "longText",
            "label" : "Applications",
            "required" : true
          }
        ],
        "hint" : "Applications and cases you're tracking.",
        "key" : "list",
        "opens" : "findings",
        "title" : "List the applications"
      },
      {
        "fields" : [
          {
            "help" : "Each with its documents — cited.",
            "key" : "detail",
            "kind" : "longText",
            "label" : "Details"
          }
        ],
        "hint" : "Submissions, references, deadlines.",
        "key" : "detail",
        "opens" : "dataLab",
        "title" : "Add the documents & dates"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note — the app never submits for you.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check what's submitted.",
        "key" : "confirm",
        "title" : "Confirm submissions (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this tracker.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the application tracker.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the tracker"
      }
    ]
  },
  "ind.ask" : {
    "purpose" : "Ask a question over your records — every answer cites its document.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you want to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "Ask in plain language.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask my records"
      },
      {
        "fields" : [
          {
            "help" : "Why you're keeping it.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the answer"
      }
    ]
  },
  "ind.career-education" : {
    "purpose" : "Summarize your career and education over time.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The span this summarizes.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Résumés, certificates, references.",
        "key" : "gather",
        "opens" : "sources",
        "title" : "Gather the records"
      },
      {
        "fields" : [
          {
            "help" : "Each entry with dates — cited, never invented.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Timeline"
          }
        ],
        "hint" : "Roles and qualifications by date.",
        "key" : "timeline",
        "opens" : "timeline",
        "title" : "Lay out the timeline"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note — never invent credentials.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check each is accurate.",
        "key" : "confirm",
        "title" : "Confirm the entries (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this summary.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the career/education summary.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the summary"
      }
    ]
  },
  "ind.close-matter" : {
    "purpose" : "Close a personal matter — sealed, reopenable with history.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the matter.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "What's done and anything left.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Wrap it up"
      },
      {
        "fields" : [
          {
            "help" : "Close only when done.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening keeps the history.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "You close or keep it open.",
        "key" : "decide",
        "title" : "Close it? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Post the closure record.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "ind.conflicts-gaps" : {
    "purpose" : "See where your records disagree or are missing — absence is not proof.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're comparing.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Records",
            "required" : true
          }
        ],
        "hint" : "The records in question.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Gather the records"
      },
      {
        "fields" : [
          {
            "help" : "Both kept.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Conflicts"
          }
        ],
        "hint" : "Where they conflict.",
        "key" : "compare",
        "opens" : "matrix",
        "title" : "Spot the disagreements"
      },
      {
        "fields" : [
          {
            "help" : "Absence is not proof.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Gaps"
          }
        ],
        "hint" : "What should be there but isn't.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Note what's missing"
      },
      {
        "fields" : [
          {
            "help" : "Name this.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the conflicts & gaps.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the notes"
      }
    ]
  },
  "ind.doc-reliability" : {
    "purpose" : "Assess how reliable a document or its source is — a judgement, not a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Documents",
            "required" : true
          }
        ],
        "hint" : "The documents to weigh.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the documents"
      },
      {
        "fields" : [
          {
            "help" : "What makes each more or less reliable.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Notes"
          }
        ],
        "hint" : "Where it came from and how trustworthy.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Weigh each"
      },
      {
        "fields" : [
          {
            "help" : "A judgement, not a fact.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "Your judgement.",
        "key" : "decide",
        "title" : "Record your view (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the reliability notes.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the notes"
      }
    ]
  },
  "ind.document-vault" : {
    "purpose" : "Keep a custody-tracked vault for your originals with integrity hashes.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What each is.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Originals",
            "required" : true
          }
        ],
        "hint" : "Your key documents (attach them).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Add the originals"
      },
      {
        "fields" : [
          {
            "help" : "How they came in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "How added",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Scan/import"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "Hash/verify them.",
        "key" : "integrity",
        "opens" : "audit",
        "title" : "Protect & verify"
      },
      {
        "fields" : [
          {
            "help" : "Name this vault.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Post the sealed manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the vault"
      }
    ]
  },
  "ind.document-versions" : {
    "purpose" : "Track versions of official documents so you always know which is current.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. passport, licences.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "The official documents to track.",
        "key" : "gather",
        "opens" : "sources",
        "title" : "Gather the documents"
      },
      {
        "fields" : [
          {
            "help" : "Old and new — keep the old ones on file.",
            "key" : "versions",
            "kind" : "longText",
            "label" : "Versions"
          }
        ],
        "hint" : "Each version with its date.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "List the versions"
      },
      {
        "fields" : [
          {
            "help" : "The current one — never discard the old.",
            "key" : "current",
            "kind" : "longText",
            "label" : "Current version",
            "required" : true
          }
        ],
        "hint" : "Which version is current.",
        "key" : "confirm",
        "title" : "Mark the current one (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this history.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the history.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the version history"
      }
    ]
  },
  "ind.emergency-pack" : {
    "purpose" : "Assemble your in-case-of-emergency binder — what loved ones need, in one place.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What belongs in the binder.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Essentials",
            "required" : true
          }
        ],
        "hint" : "The key documents and contacts.",
        "key" : "choose",
        "opens" : "findings",
        "title" : "Choose the essentials"
      },
      {
        "fields" : [
          {
            "help" : "How it's organized for a stranger to follow.",
            "key" : "layout",
            "kind" : "longText",
            "label" : "Layout"
          }
        ],
        "hint" : "Put them together clearly.",
        "key" : "assemble",
        "opens" : "handoff",
        "title" : "Assemble the binder"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check it's complete and safe to store.",
        "key" : "confirm",
        "title" : "Confirm the pack (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this pack.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the ICE pack.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "ARC",
        "title" : "Produce the emergency pack"
      }
    ]
  },
  "ind.family-records" : {
    "purpose" : "Organize family members and relationships.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line with relationship.",
            "key" : "people",
            "kind" : "longText",
            "label" : "Family members",
            "required" : true
          }
        ],
        "hint" : "Who this covers.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "List the family"
      },
      {
        "fields" : [
          {
            "help" : "Only what your records support.",
            "key" : "details",
            "kind" : "longText",
            "label" : "Details"
          }
        ],
        "hint" : "Documents and relationships, each cited.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Add the details"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check the relationships are right.",
        "key" : "confirm",
        "title" : "Confirm relationships (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the record.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the family record"
      }
    ]
  },
  "ind.fix-it" : {
    "purpose" : "Track corrective actions — renewals, disputes, fixes — to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Fixes",
            "required" : true
          }
        ],
        "hint" : "The issues and their fixes.",
        "key" : "list",
        "opens" : "findings",
        "title" : "List what needs fixing"
      },
      {
        "fields" : [
          {
            "help" : "Each with owner and due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions"
          }
        ],
        "hint" : "Who and by when.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Add owners & due dates"
      },
      {
        "fields" : [
          {
            "help" : "Name this list.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the list.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the fix-it list"
      }
    ]
  },
  "ind.fix-review" : {
    "purpose" : "Verify a completed fix actually resolved the problem.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The fix under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Fix",
            "required" : true
          }
        ],
        "hint" : "Which fix you're checking.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the fix"
      },
      {
        "fields" : [
          {
            "help" : "What changed.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Outcome"
          }
        ],
        "hint" : "Is the problem resolved?",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Check the outcome"
      },
      {
        "fields" : [
          {
            "help" : "Your call.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Fixed",
              "Partly",
              "Not fixed"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Did it work? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "ind.health-scope" : {
    "purpose" : "Summarize the health records you choose to include — under strict, private scope.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What to include — sensitive data stays private.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "In scope",
            "required" : true
          }
        ],
        "hint" : "Only the records you want in scope.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Choose what to include"
      },
      {
        "fields" : [
          {
            "help" : "Facts from your records — the app never diagnoses.",
            "key" : "summary",
            "kind" : "longText",
            "label" : "Summary"
          }
        ],
        "hint" : "A plain summary of what's there.",
        "key" : "summarize",
        "opens" : "findings",
        "title" : "Summarize"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm what's included.",
        "key" : "confirm",
        "title" : "Confirm scope (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this summary.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the health summary.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the summary"
      }
    ]
  },
  "ind.insurance" : {
    "purpose" : "Keep a register of insurance policies, renewals and claims.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The policies.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Policies and correspondence.",
        "key" : "gather",
        "opens" : "sources",
        "title" : "Gather the policies"
      },
      {
        "fields" : [
          {
            "help" : "Cover, premium, renewal — cited.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Policies"
          }
        ],
        "hint" : "Each policy with key dates.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the register"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check renewal dates.",
        "key" : "confirm",
        "title" : "Confirm renewals (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the insurance register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "ind.legacy-archive" : {
    "purpose" : "Assemble the legacy binder — your records for the next generation, with a sealed receipt.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What belongs in the legacy binder.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Contents",
            "required" : true
          }
        ],
        "hint" : "The records that matter for the future.",
        "key" : "choose",
        "opens" : "findings",
        "title" : "Choose what to pass on"
      },
      {
        "fields" : [
          {
            "help" : "How it's organized and any guidance.",
            "key" : "layout",
            "kind" : "longText",
            "label" : "Layout & notes"
          }
        ],
        "hint" : "Organize with notes for whoever inherits it.",
        "key" : "assemble",
        "opens" : "handoff",
        "title" : "Assemble & explain"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check it's complete.",
        "key" : "confirm",
        "title" : "Confirm the binder (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this binder.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the binder with its receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "ARC",
        "title" : "Produce the legacy binder"
      }
    ]
  },
  "ind.methods" : {
    "purpose" : "Work through a guided, structured method over your records.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. a 5W1H worksheet or checklist.",
            "key" : "method",
            "kind" : "text",
            "label" : "Method",
            "required" : true
          }
        ],
        "hint" : "Which guided method.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick a method"
      },
      {
        "fields" : [
          {
            "help" : "What you worked out.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "Fill it in from your records.",
        "key" : "run",
        "opens" : "matrix",
        "title" : "Work through it"
      },
      {
        "fields" : [
          {
            "help" : "Name this.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble it.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the result"
      }
    ]
  },
  "ind.name-resolution" : {
    "purpose" : "Confirm two names are the same person or company — reversible, you decide.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Names",
            "required" : true
          }
        ],
        "hint" : "The names/spellings in question.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the names"
      },
      {
        "fields" : [
          {
            "help" : "What matches and what doesn't.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each name appears.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across your records"
      },
      {
        "fields" : [
          {
            "help" : "Your call.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Same",
              "Different",
              "Not sure"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "You decide. Reversible.",
        "key" : "decide",
        "title" : "Same or not? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Save the reversible decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record it"
      }
    ]
  },
  "ind.personal-chronology" : {
    "purpose" : "See your personal timeline (undated events labelled).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date (or 'undated'), event, source.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Life events with dates.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect the events"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check it's right.",
        "key" : "confirm",
        "title" : "Confirm the timeline (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this chronology.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the personal chronology.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the chronology"
      }
    ]
  },
  "ind.personal-records" : {
    "purpose" : "Bring in and organize your documents — point the app at your records, sort them, confirm, then open the collection.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The records this is about (e.g. household papers).",
            "key" : "what",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Point the app at the folders/files with your documents (attach or add sources).",
        "key" : "gather",
        "opens" : "sources",
        "title" : "Bring in your records"
      },
      {
        "fields" : [
          {
            "help" : "How you're grouping them.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Group them so they're easy to find.",
        "key" : "organize",
        "opens" : "knowledge",
        "title" : "Organize by category"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check nothing sensitive is exposed and categories are right.",
        "key" : "confirm",
        "title" : "Confirm it looks right (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered records collection.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the collection"
      }
    ]
  },
  "ind.property" : {
    "purpose" : "Keep a register of property and assets.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The property/assets.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Deeds, titles, bills.",
        "key" : "gather",
        "opens" : "sources",
        "title" : "Gather the documents"
      },
      {
        "fields" : [
          {
            "help" : "What you own and the papers that show it — cited.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Items"
          }
        ],
        "hint" : "Each item with its documents.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the register"
      },
      {
        "fields" : [
          {
            "help" : "Anything to note — the app doesn't assert legal title.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Check the details.",
        "key" : "confirm",
        "title" : "Confirm ownership (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the property register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "ind.reminders" : {
    "purpose" : "Turn dated obligations into confirmed reminders — renewals, expiries, deadlines.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Renewals, expiries, deadlines — with source.",
            "key" : "dates",
            "kind" : "longText",
            "label" : "Dated obligations",
            "required" : true
          }
        ],
        "hint" : "Documents with dates that matter.",
        "key" : "gather",
        "opens" : "timeline",
        "title" : "Find the dates"
      },
      {
        "fields" : [
          {
            "help" : "Only confirmed dates fire — never an unconfirmed one.",
            "key" : "confirmed",
            "kind" : "longText",
            "label" : "Confirmed reminders",
            "required" : true
          }
        ],
        "hint" : "Confirm each date before it becomes a reminder.",
        "key" : "confirm",
        "title" : "Confirm each reminder (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this list.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the list.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the reminder list"
      }
    ]
  },
  "ind.secure-share" : {
    "purpose" : "Prepare a redacted copy to share — sensitive details masked and validated first.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're sharing and with whom.",
            "key" : "items",
            "kind" : "longText",
            "label" : "To share",
            "required" : true
          }
        ],
        "hint" : "The documents and the recipient.",
        "key" : "choose",
        "opens" : "findings",
        "title" : "Choose what to share"
      },
      {
        "fields" : [
          {
            "help" : "What's masked.",
            "key" : "redactions",
            "kind" : "longText",
            "label" : "Redactions"
          }
        ],
        "hint" : "Mask what shouldn't leave.",
        "key" : "redact",
        "opens" : "handoff",
        "title" : "Redact the sensitive parts"
      },
      {
        "fields" : [
          {
            "help" : "Confirm before sharing.",
            "key" : "validated",
            "kind" : "choice",
            "label" : "Redaction validated",
            "options" : [
              "Validated",
              "Not yet"
            ],
            "required" : true
          },
          {
            "help" : "Anything to record.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "Confirm nothing sensitive remains.",
        "key" : "validate",
        "title" : "Validate the redaction (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this copy.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble the redacted copy.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the shareable copy"
      }
    ]
  },
  "ind.why" : {
    "purpose" : "Trace why something happened, step by step, over your cited records.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Be specific.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Question",
            "required" : true
          }
        ],
        "hint" : "The thing to understand.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "What do you want to explain?"
      },
      {
        "fields" : [
          {
            "help" : "Each step backed by a record.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Follow the chain as far as your records support.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Ask why, step by step"
      },
      {
        "fields" : [
          {
            "help" : "Not stated as certain beyond the records.",
            "key" : "conclusion",
            "kind" : "longText",
            "label" : "Conclusion & basis",
            "required" : true
          }
        ],
        "hint" : "The most likely explanation, on your records.",
        "key" : "decide",
        "title" : "Your conclusion (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this.",
            "key" : "title",
            "kind" : "text",
            "label" : "Name",
            "required" : true
          }
        ],
        "hint" : "Assemble it.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the explanation"
      }
    ]
  },
  "inv.analysis" : {
    "purpose" : "Work the analytical spine (Analysis of Competing Hypotheses): brainstorm leads, form hypotheses, answer 5W1H, plan and gather evidence, score each hypothesis for and against, identify the most consistent, then produce — never auto-won.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line — nothing filtered yet.",
            "key" : "ideas",
            "kind" : "longText",
            "label" : "Leads",
            "required" : true
          }
        ],
        "hint" : "Every idea and lead, before judging.",
        "key" : "brainstorm",
        "opens" : "findings",
        "title" : "Brainstorm leads"
      },
      {
        "fields" : [
          {
            "help" : "Each a distinct, testable explanation.",
            "key" : "hypotheses",
            "kind" : "longText",
            "label" : "Hypotheses",
            "required" : true
          }
        ],
        "hint" : "Turn leads into a set of explanations to test.",
        "key" : "hypotheses",
        "opens" : "findings",
        "title" : "Form the hypotheses"
      },
      {
        "fields" : [
          {
            "help" : "Who/what/when/where/why/how — cited or unknown.",
            "key" : "fiveW",
            "kind" : "longText",
            "label" : "5W1H"
          }
        ],
        "hint" : "Answer each from evidence, or mark unknown.",
        "key" : "fiveW",
        "opens" : "matrix",
        "title" : "5W1H worksheet"
      },
      {
        "fields" : [
          {
            "help" : "Requests per hypothesis — never assert evidence exists.",
            "key" : "plan",
            "kind" : "longText",
            "label" : "Evidence plan"
          }
        ],
        "hint" : "What evidence each hypothesis needs.",
        "key" : "plan",
        "opens" : "review",
        "title" : "Evidence collection plan"
      },
      {
        "fields" : [
          {
            "help" : "Each item and which hypothesis it supports/undercuts (cited).",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence log"
          }
        ],
        "hint" : "Collect evidence and mark what it bears on.",
        "key" : "gather",
        "opens" : "findings",
        "title" : "Gather & mark evidence"
      },
      {
        "fields" : [
          {
            "help" : "Focus on what DISPROVES — the least-contradicted hypothesis leads.",
            "key" : "matrixNote",
            "kind" : "longText",
            "label" : "Matrix",
            "required" : true
          }
        ],
        "hint" : "Rate each item consistent / inconsistent / N-A per hypothesis.",
        "key" : "matrix",
        "opens" : "matrix",
        "title" : "Score the hypothesis matrix"
      },
      {
        "fields" : [
          {
            "help" : "The most-consistent explanation and the key diagnostics.",
            "key" : "leading",
            "kind" : "longText",
            "label" : "Leading hypothesis & basis",
            "required" : true
          }
        ],
        "hint" : "Which hypothesis the evidence least contradicts — never auto-won.",
        "key" : "assess",
        "title" : "Identify the most consistent (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this worksheet.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis worksheet.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the worksheet"
      }
    ]
  },
  "inv.ask" : {
    "purpose" : "Ask a question over the case's authorized evidence and keep the cited answer — instead of digging through files by hand, the app reads every in-scope document and answers with citations.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The specific thing you need to know.",
            "key" : "need",
            "kind" : "longText",
            "label" : "What you're trying to establish"
          }
        ],
        "hint" : "A moment to frame the question sharpens the answer.",
        "key" : "frame",
        "opens" : "ask",
        "title" : "Decide what you need"
      },
      {
        "fields" : [
          {
            "help" : "What you need to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "Type it in plain language — the app searches every authorized document for you and answers with citations, so there's no manual file-hunting.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask (case-scoped)"
      },
      {
        "fields" : [
          {
            "help" : "How it bears on the case.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "The answer lands in the case file already cited — no copy-paste, no lost source.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "inv.capa-register" : {
    "purpose" : "Record corrective/preventive actions linked to causes, tracked to a human close — the app keeps each action tied to the finding that prompted it.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which finding/cause each action responds to.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Action ↔ cause",
            "required" : true
          }
        ],
        "hint" : "What each action addresses.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link actions to causes"
      },
      {
        "fields" : [
          {
            "help" : "Corrective/preventive — with owner and due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions",
            "required" : true
          }
        ],
        "hint" : "Action, owner, due date, type.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the actions"
      },
      {
        "fields" : [
          {
            "help" : "Confirm owners and dates.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each is agreed.",
        "key" : "assign",
        "title" : "Agree owners & dates (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Open / in progress / done per action.",
            "key" : "status",
            "kind" : "longText",
            "label" : "Status"
          }
        ],
        "hint" : "Keep each action's status current.",
        "key" : "track",
        "opens" : "handoff",
        "title" : "Track to status"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the CAPA register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "inv.case-intake" : {
    "purpose" : "Open a case the way an investigator actually does: record the mandate and authority, assess urgency, clear conflicts, frame the questions, fix scope, issue the preservation hold, identify custodians, plan the investigation, get sign-off, then open the case. Intake never decides the merits.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Your case reference.",
            "key" : "caseNo",
            "kind" : "text",
            "label" : "Case number",
            "required" : true
          },
          {
            "help" : "Who authorized/tasked the case.",
            "key" : "requestor",
            "kind" : "text",
            "label" : "Requestor"
          },
          {
            "help" : "The authority behind the case and the objective.",
            "key" : "mandate",
            "kind" : "longText",
            "label" : "Mandate",
            "required" : true
          }
        ],
        "hint" : "Who tasked this and what it must resolve.",
        "key" : "mandate",
        "opens" : "sources",
        "title" : "Record the mandate & authority"
      },
      {
        "fields" : [
          {
            "help" : "How time-critical.",
            "key" : "urgency",
            "kind" : "choice",
            "label" : "Urgency",
            "options" : [
              "Routine",
              "Elevated",
              "Urgent",
              "Critical — act now"
            ],
            "required" : true
          },
          {
            "help" : "Preservation triggers, safety, notifications, legal risk.",
            "key" : "immediate",
            "kind" : "longText",
            "label" : "Immediate actions"
          }
        ],
        "hint" : "Any time-critical safeguards before work begins.",
        "key" : "urgency",
        "opens" : "review",
        "title" : "Assess urgency & immediate actions"
      },
      {
        "fields" : [
          {
            "help" : "Who runs the case.",
            "key" : "investigator",
            "kind" : "text",
            "label" : "Assigned investigator",
            "required" : true
          },
          {
            "help" : "Any relationship to subjects?",
            "key" : "conflicts",
            "kind" : "choice",
            "label" : "Conflicts of interest",
            "options" : [
              "None",
              "Managed — noted",
              "Yes — reassign"
            ],
            "required" : true
          }
        ],
        "hint" : "Confirm the investigator is impartial and cleared.",
        "key" : "conflicts",
        "opens" : "handoff",
        "title" : "Clear conflicts & clearance"
      },
      {
        "fields" : [
          {
            "help" : "One per line — each answerable from evidence.",
            "key" : "questions",
            "kind" : "longText",
            "label" : "Investigative questions",
            "required" : true
          }
        ],
        "hint" : "What the case must answer, as discrete questions.",
        "key" : "questions",
        "opens" : "findings",
        "title" : "Frame the questions"
      },
      {
        "fields" : [
          {
            "help" : "In and out of scope.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "Scope statement",
            "required" : true
          },
          {
            "help" : "The period under investigation.",
            "key" : "window",
            "kind" : "dateRange",
            "label" : "Time window"
          }
        ],
        "hint" : "The boundary and the period.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Define scope & window"
      },
      {
        "fields" : [
          {
            "help" : "Accounts, drives, devices, records to preserve.",
            "key" : "holdScope",
            "kind" : "longText",
            "label" : "Hold scope",
            "required" : true
          },
          {
            "help" : "Turn on once custodians/IT are notified.",
            "key" : "holdIssued",
            "kind" : "bool",
            "label" : "Hold issued"
          }
        ],
        "hint" : "Stop relevant evidence being lost before collection.",
        "key" : "hold",
        "opens" : "audit",
        "title" : "Issue the preservation hold"
      },
      {
        "fields" : [
          {
            "help" : "People/systems holding relevant material.",
            "key" : "custodians",
            "kind" : "longText",
            "label" : "Custodians"
          },
          {
            "help" : "The authorized source set — the hard evidence boundary.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources in scope",
            "required" : true
          }
        ],
        "hint" : "Who holds the evidence, and which sets are authorized.",
        "key" : "custodians",
        "opens" : "sources",
        "title" : "Identify sources & custodians"
      },
      {
        "fields" : [
          {
            "help" : "What to collect/analyze, in what order, by when.",
            "key" : "plan",
            "kind" : "longText",
            "label" : "Investigation plan",
            "required" : true
          }
        ],
        "hint" : "Methods, sequence, and target dates.",
        "key" : "plan",
        "opens" : "handoff",
        "title" : "Draft the investigation plan"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when scope, hold and plan are right.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Approve to proceed?",
            "options" : [
              "Approved",
              "Needs revision"
            ],
            "required" : true
          },
          {
            "help" : "Who signed off.",
            "key" : "approver",
            "kind" : "text",
            "label" : "Approved by"
          }
        ],
        "hint" : "A human signs off before evidence is worked.",
        "key" : "confirm",
        "title" : "Confirm scope & plan (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Case name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered case.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the case"
      }
    ]
  },
  "inv.causal-analysis" : {
    "purpose" : "Trace how something came about: Five Whys down the chain, Fishbone across categories, weigh the candidates, test against evidence, then a human determination — the app never confirms a cause.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "The issue to explain, precisely.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State the problem"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where the evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "People / process / systems / environment.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes by category.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "What supports or rules out each.",
            "key" : "weighing",
            "kind" : "longText",
            "label" : "For / against"
          }
        ],
        "hint" : "Evidence for and against each candidate cause.",
        "key" : "weigh",
        "opens" : "review",
        "title" : "Weigh the candidates"
      },
      {
        "fields" : [
          {
            "help" : "Facts the cause explains — and any it doesn't.",
            "key" : "test",
            "kind" : "longText",
            "label" : "Consistency check"
          }
        ],
        "hint" : "Check the leading cause explains all the facts.",
        "key" : "test",
        "opens" : "matrix",
        "title" : "Test against the evidence"
      },
      {
        "fields" : [
          {
            "help" : "The cause(s), on the evidence.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "A human determines the cause.",
        "key" : "determine",
        "title" : "Determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "inv.closure" : {
    "purpose" : "Close or reopen the case by an explicit human decision — unresolved items retained, reopening preserves the prior closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the case.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Report approved, actions tracked, open items retained.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm the outcome"
      },
      {
        "fields" : [
          {
            "help" : "Storage, retention, access.",
            "key" : "retention",
            "kind" : "longText",
            "label" : "Retention & access"
          }
        ],
        "hint" : "Where the file is kept and who may access it.",
        "key" : "retention",
        "opens" : "handoff",
        "title" : "Retention & confidentiality"
      },
      {
        "fields" : [
          {
            "help" : "Who is informed — within confidentiality limits.",
            "key" : "notify",
            "kind" : "longText",
            "label" : "Notifications"
          }
        ],
        "hint" : "Who is told of the outcome, and how.",
        "key" : "notify",
        "opens" : "handoff",
        "title" : "Notify the parties (as appropriate)"
      },
      {
        "fields" : [
          {
            "help" : "Close only when complete.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the case",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves this closure.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "A human closes or reopens.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and receipt — sealed and tamper-evident, unlike a Word doc.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "inv.contradiction-gap" : {
    "purpose" : "Review in-scope contradictions and gaps — both sides preserved, absence never treated as proof. The app already flags where accounts conflict, so you review rather than hunt.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're testing.",
            "key" : "claims",
            "kind" : "longText",
            "label" : "Claims",
            "required" : true
          }
        ],
        "hint" : "The claims under review — the app assembles them from the evidence.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the claims"
      },
      {
        "fields" : [
          {
            "help" : "Both sides preserved, never averaged.",
            "key" : "contradictions",
            "kind" : "longText",
            "label" : "Contradictions"
          }
        ],
        "hint" : "Where claims conflict — surfaced automatically.",
        "key" : "contradictions",
        "opens" : "matrix",
        "title" : "Review contradictions"
      },
      {
        "fields" : [
          {
            "help" : "Which is better supported, and why — or 'unresolved'.",
            "key" : "assessment",
            "kind" : "longText",
            "label" : "Assessment"
          }
        ],
        "hint" : "Weigh the conflicting accounts on the evidence.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess which account holds"
      },
      {
        "fields" : [
          {
            "help" : "Absence is not proof.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Gaps"
          }
        ],
        "hint" : "Missing evidence needed to resolve.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "List the gaps"
      },
      {
        "fields" : [
          {
            "help" : "Requests/interviews to resolve each gap.",
            "key" : "plan",
            "kind" : "longText",
            "label" : "Follow-up plan"
          }
        ],
        "hint" : "What to collect or ask next.",
        "key" : "close",
        "opens" : "handoff",
        "title" : "Plan to close the gaps"
      },
      {
        "fields" : [
          {
            "help" : "Name this report.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the contradiction & gap report.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the desk report"
      }
    ]
  },
  "inv.data-lab" : {
    "purpose" : "Build an authorized-only dataset in DataLab (the app's spreadsheet). Unlike Excel, every cell keeps a live link to its source document — no manual copy-paste, no lost provenance.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you want the table to show.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Dataset question",
            "required" : true
          }
        ],
        "hint" : "What the dataset needs to answer.",
        "key" : "question",
        "opens" : "dataLab",
        "title" : "Define the question"
      },
      {
        "fields" : [
          {
            "help" : "The data in scope.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Which authorized records feed it.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the data"
      },
      {
        "fields" : [
          {
            "help" : "Each column and what it holds.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Columns"
          }
        ],
        "hint" : "Set the header before filling — like laying out a spreadsheet.",
        "key" : "columns",
        "opens" : "dataLab",
        "title" : "Define the columns"
      },
      {
        "fields" : [
          {
            "help" : "How rows were derived; anything estimated is flagged.",
            "key" : "fillNote",
            "kind" : "longText",
            "label" : "Population notes"
          }
        ],
        "hint" : "Pull values from your documents — the app cites each cell automatically, so you skip the data-entry and keep the source.",
        "key" : "fill",
        "opens" : "dataLab",
        "title" : "Fill from evidence"
      },
      {
        "fields" : [
          {
            "help" : "Anything a reader should be warned about.",
            "key" : "quality",
            "kind" : "longText",
            "label" : "Quality issues"
          }
        ],
        "hint" : "Missing/stale/unsupported values.",
        "key" : "quality",
        "opens" : "dataLab",
        "title" : "Check quality"
      },
      {
        "fields" : [
          {
            "help" : "Name this dataset.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the dataset.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the dataset"
      }
    ]
  },
  "inv.effectiveness-review" : {
    "purpose" : "Review whether a CAPA action worked — never declare it effective without evidence. The app surfaces anything new that's arrived since the action.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The action under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Action",
            "required" : true
          }
        ],
        "hint" : "Which completed action.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the action"
      },
      {
        "fields" : [
          {
            "help" : "What happened since.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "Evidence of the outcome (attach it).",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Gather post-action evidence"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Effective",
              "Partially effective",
              "Not effective"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Judge effectiveness (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "inv.evidence-custody" : {
    "purpose" : "Maintain a defensible evidence locker: identify and seize, register each exhibit, record the acquisition method, hash and verify integrity, label and store, log every transfer, then seal the manifest.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each item and the point of seizure (attach originals).",
            "key" : "items",
            "kind" : "longText",
            "label" : "Items",
            "required" : true
          }
        ],
        "hint" : "What is taken into evidence, and from where.",
        "key" : "identify",
        "opens" : "audit",
        "title" : "Identify & seize"
      },
      {
        "fields" : [
          {
            "help" : "Exhibit no. · description · source · collector · date/time.",
            "key" : "exhibits",
            "kind" : "longText",
            "label" : "Exhibit register"
          }
        ],
        "hint" : "Give each an exhibit number and description.",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the exhibits"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from system/service",
              "Physical/device transfer"
            ],
            "required" : true
          }
        ],
        "hint" : "How each entered custody without alteration.",
        "key" : "acquire",
        "opens" : "audit",
        "title" : "Record acquisition method"
      },
      {
        "fields" : [
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          },
          {
            "help" : "Algorithm and where the value is recorded.",
            "key" : "hashNote",
            "kind" : "longText",
            "label" : "Hash / seal note"
          }
        ],
        "hint" : "Fix the tamper-evident seal.",
        "key" : "hash",
        "opens" : "audit",
        "title" : "Hash & verify integrity"
      },
      {
        "fields" : [
          {
            "help" : "Location, container, access controls.",
            "key" : "storage",
            "kind" : "longText",
            "label" : "Storage & labelling"
          }
        ],
        "hint" : "Where the originals live and how access is controlled.",
        "key" : "store",
        "opens" : "audit",
        "title" : "Label & store"
      },
      {
        "fields" : [
          {
            "help" : "Each hand-off: from, to, date/time, purpose.",
            "key" : "transfers",
            "kind" : "longText",
            "label" : "Custody transfers"
          }
        ],
        "hint" : "Unbroken chain — who held what, when, why.",
        "key" : "transfers",
        "opens" : "audit",
        "title" : "Log every transfer"
      },
      {
        "fields" : [
          {
            "help" : "Name this manifest.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed custody manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the manifest"
      }
    ]
  },
  "inv.findings" : {
    "purpose" : "Assemble the case report the way it's really written: restate the mandate and questions, summarize methodology, marshal the evidence per question, assess weight and reliability, apply the standard of proof, record findings, weigh alternative explanations, note limitations, add recommendations, then produce — never assert unproven findings.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The objective, the questions, and the scope.",
            "key" : "mandate",
            "kind" : "longText",
            "label" : "Mandate & questions",
            "required" : true
          }
        ],
        "hint" : "Anchor the report to what it set out to answer.",
        "key" : "mandate",
        "opens" : "findings",
        "title" : "Restate mandate & questions"
      },
      {
        "fields" : [
          {
            "help" : "Sources reviewed, methods used, period covered.",
            "key" : "method",
            "kind" : "longText",
            "label" : "Methodology"
          }
        ],
        "hint" : "What you did and how — so the work is defensible.",
        "key" : "method",
        "opens" : "matrix",
        "title" : "Summarize methodology"
      },
      {
        "fields" : [
          {
            "help" : "For and against each point.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence per question"
          }
        ],
        "hint" : "The cited evidence for each question (attach exhibits).",
        "key" : "marshal",
        "opens" : "findings",
        "title" : "Marshal the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Corroboration, source reliability, gaps.",
            "key" : "weight",
            "kind" : "longText",
            "label" : "Weight & reliability"
          }
        ],
        "hint" : "How strong and how reliable each piece is.",
        "key" : "weigh",
        "opens" : "review",
        "title" : "Assess weight & reliability"
      },
      {
        "fields" : [
          {
            "help" : "e.g. balance of probabilities / reasonable grounds — and whether each question meets it.",
            "key" : "standard",
            "kind" : "longText",
            "label" : "Standard applied"
          }
        ],
        "hint" : "The threshold this case is judged against.",
        "key" : "standard",
        "opens" : "matrix",
        "title" : "Apply the standard of proof"
      },
      {
        "fields" : [
          {
            "help" : "Per question — do not assert findings the evidence doesn't support.",
            "key" : "findings",
            "kind" : "longText",
            "label" : "Findings",
            "required" : true
          }
        ],
        "hint" : "The human findings, each supported.",
        "key" : "findings",
        "title" : "Record findings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Competing explanations and why the evidence favors the finding.",
            "key" : "alternatives",
            "kind" : "longText",
            "label" : "Alternatives considered"
          }
        ],
        "hint" : "Show you considered other readings.",
        "key" : "alternatives",
        "opens" : "review",
        "title" : "Weigh alternative explanations"
      },
      {
        "fields" : [
          {
            "help" : "What remains uncertain or outside reach.",
            "key" : "limitations",
            "kind" : "longText",
            "label" : "Limitations"
          }
        ],
        "hint" : "Gaps and unresolved items — honest closure.",
        "key" : "limits",
        "opens" : "review",
        "title" : "Note limitations"
      },
      {
        "fields" : [
          {
            "help" : "What should happen next (kept separate from the findings).",
            "key" : "recommendations",
            "kind" : "longText",
            "label" : "Recommendations"
          }
        ],
        "hint" : "Actions or referrals that follow from the findings.",
        "key" : "recommend",
        "opens" : "handoff",
        "title" : "Add recommendations"
      },
      {
        "fields" : [
          {
            "help" : "Name this report.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the report with its sealed receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the case report"
      }
    ]
  },
  "inv.identity-resolution" : {
    "purpose" : "Resolve identity via the shared reversible merge. The app proposes matches by comparing attributes across every document; you make the call — never automatic.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate identifiers",
            "required" : true
          }
        ],
        "hint" : "Names, aliases, accounts that may be one entity.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather identifiers"
      },
      {
        "fields" : [
          {
            "help" : "Variants folded together (e.g. 'Bob'/'Robert').",
            "key" : "normalized",
            "kind" : "longText",
            "label" : "Notes"
          }
        ],
        "hint" : "Standardize spellings/formats so real matches surface — the app does this pass for you.",
        "key" : "normalize",
        "opens" : "knowledge",
        "title" : "Normalize the identifiers"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals the app surfaced.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each appears across the case — dates, places, contacts.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare attributes"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude coincidental same-name matches.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Your identity decision.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same entity",
              "Reject — different",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind it.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human decides. Reversible later.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible decision — the merge updates everywhere at once, unlike hand-editing each file.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "inv.linkage" : {
    "purpose" : "Build the timeline, link chart, and transaction/asset flow. The app auto-assembles dated events and co-occurrence links from your evidence — you analyze instead of drawing charts by hand.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date, event, source — one per line.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Each event with its source — auto-pulled from the documents.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect dated events"
      },
      {
        "fields" : [
          {
            "help" : "The nodes for the link chart.",
            "key" : "entities",
            "kind" : "longText",
            "label" : "Entities"
          }
        ],
        "hint" : "People, orgs, objects, locations in play.",
        "key" : "entities",
        "opens" : "connections",
        "title" : "Gather the entities"
      },
      {
        "fields" : [
          {
            "help" : "How entities connect, on evidence.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Links"
          }
        ],
        "hint" : "Connect the entities — the app proposes edges from co-occurrence.",
        "key" : "links",
        "opens" : "connections",
        "title" : "Build the link chart"
      },
      {
        "fields" : [
          {
            "help" : "Dated, cited movements.",
            "key" : "flow",
            "kind" : "longText",
            "label" : "Flow"
          }
        ],
        "hint" : "Trace movements of money or assets.",
        "key" : "flow",
        "opens" : "dataLab",
        "title" : "Transaction / asset flow"
      },
      {
        "fields" : [
          {
            "help" : "Central entities, clusters, and what they suggest.",
            "key" : "key",
            "kind" : "longText",
            "label" : "Key nodes"
          }
        ],
        "hint" : "Who/what sits at the center.",
        "key" : "key",
        "opens" : "matrix",
        "title" : "Identify key nodes & patterns"
      },
      {
        "fields" : [
          {
            "help" : "Kept, not averaged.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Gaps & conflicts"
          }
        ],
        "hint" : "Missing links or conflicting dates.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Flag gaps & conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the linkage work product.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the linkage"
      }
    ]
  },
  "inv.methods" : {
    "purpose" : "Run a professional method over case-authorized evidence — a method structures the analysis, it doesn't conclude. The app pulls the inputs from your ingested evidence, so you skip the manual data-gathering.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The method to run.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Method",
            "options" : [
              "5W1H",
              "Hypothesis matrix (ACH)",
              "Link analysis",
              "Timeline",
              "Five Whys",
              "Fishbone"
            ],
            "required" : true
          }
        ],
        "hint" : "Which structured method fits the question.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick the method"
      },
      {
        "fields" : [
          {
            "help" : "The claims/entities/events this method works on.",
            "key" : "inputs",
            "kind" : "longText",
            "label" : "Inputs"
          }
        ],
        "hint" : "Point the method at the evidence — the app already has it indexed, so you select rather than re-type.",
        "key" : "inputs",
        "opens" : "matrix",
        "title" : "Set the inputs"
      },
      {
        "fields" : [
          {
            "help" : "What the method structured or surfaced.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "Work through the method.",
        "key" : "run",
        "opens" : "matrix",
        "title" : "Run & read the result"
      },
      {
        "fields" : [
          {
            "help" : "What you take from it — the method never concludes for you.",
            "key" : "reading",
            "kind" : "longText",
            "label" : "Your reading",
            "required" : true
          }
        ],
        "hint" : "The method organizes; you draw the conclusion.",
        "key" : "confirm",
        "title" : "Confirm the reading (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this run.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the result.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the method run"
      }
    ]
  },
  "inv.source-reliability" : {
    "purpose" : "Rate case sources on the Admiralty scale — source reliability (A–F) and information credibility (1–6). Ratings are judgements, never facts; the app keeps each rating tied to the source it came from.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each source/custodian — the app already lists who provided what.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "A (reliable) … F (cannot judge), with reason.",
            "key" : "reliability",
            "kind" : "longText",
            "label" : "Reliability per source"
          }
        ],
        "hint" : "How dependable the source itself is.",
        "key" : "reliability",
        "opens" : "review",
        "title" : "Rate reliability (A–F)"
      },
      {
        "fields" : [
          {
            "help" : "1 (confirmed) … 6 (cannot judge), with reason.",
            "key" : "credibility",
            "kind" : "longText",
            "label" : "Credibility per item"
          }
        ],
        "hint" : "How well the information itself holds up.",
        "key" : "credibility",
        "opens" : "review",
        "title" : "Rate credibility (1–6)"
      },
      {
        "fields" : [
          {
            "help" : "Independent support/conflict.",
            "key" : "corroboration",
            "kind" : "longText",
            "label" : "Corroboration"
          }
        ],
        "hint" : "What independently confirms or contradicts each — the app flags overlaps for you.",
        "key" : "corroborate",
        "opens" : "matrix",
        "title" : "Check corroboration"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings; they are judgements, not facts.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "Own the ratings as judgements.",
        "key" : "decide",
        "title" : "Record the ratings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this schedule.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the reliability schedule.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the schedule"
      }
    ]
  },
  "inv.subject-dossier" : {
    "purpose" : "Work up a subject from cited in-scope evidence. Instead of trawling every file, the app surfaces everywhere the subject appears — you review and confirm.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Name and role.",
            "key" : "subject",
            "kind" : "text",
            "label" : "Subject",
            "required" : true
          }
        ],
        "hint" : "Who you're working up.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the subject"
      },
      {
        "fields" : [
          {
            "help" : "Which names/accounts you've confirmed are this subject.",
            "key" : "identityNote",
            "kind" : "longText",
            "label" : "Identity basis"
          }
        ],
        "hint" : "Make sure mentions are the same person before you build — the app clusters aliases for you to approve.",
        "key" : "resolve",
        "opens" : "knowledge",
        "title" : "Confirm identity"
      },
      {
        "fields" : [
          {
            "help" : "Only what the evidence supports.",
            "key" : "bio",
            "kind" : "longText",
            "label" : "Background"
          }
        ],
        "hint" : "Biographical facts, each cited.",
        "key" : "bio",
        "opens" : "dossier",
        "title" : "Gather the background"
      },
      {
        "fields" : [
          {
            "help" : "Key associates and the evidence for each.",
            "key" : "relationships",
            "kind" : "longText",
            "label" : "Relationships"
          }
        ],
        "hint" : "Who the subject connects to — the app has already linked co-occurrences.",
        "key" : "relationships",
        "opens" : "connections",
        "title" : "Map relationships & associations"
      },
      {
        "fields" : [
          {
            "help" : "Key dated events for this subject.",
            "key" : "timeline",
            "kind" : "longText",
            "label" : "Timeline notes"
          }
        ],
        "hint" : "The subject's relevant events in order — auto-assembled from dated mentions.",
        "key" : "timeline",
        "opens" : "timeline",
        "title" : "Build the subject timeline"
      },
      {
        "fields" : [
          {
            "help" : "Questions the dossier can't yet answer — absence is not proof.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Open items"
          }
        ],
        "hint" : "What's still unknown.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Note open items & gaps"
      },
      {
        "fields" : [
          {
            "help" : "Name this dossier.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the subject workup.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the dossier"
      }
    ]
  },
  "jrn.ask" : {
    "purpose" : "Ask a question over the story's sources and keep the cited answer.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you want to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "The answer cites its source.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the story file"
      },
      {
        "fields" : [
          {
            "help" : "How it serves the story.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "jrn.causal" : {
    "purpose" : "Trace why events unfolded — Five Whys / Fishbone over cited evidence, then a human takeaway.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Question",
            "required" : true
          }
        ],
        "hint" : "The event to explain.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State what to explain"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "The factors at play.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "On the evidence.",
            "key" : "takeaway",
            "kind" : "longText",
            "label" : "Takeaway & basis",
            "required" : true
          }
        ],
        "hint" : "The explanation you'll present — grounded, not overstated.",
        "key" : "takeaway",
        "title" : "Takeaway (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "jrn.chronology" : {
    "purpose" : "Build the story's tick-tock — the reconstructed timeline (undated labelled, cited).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date (or 'undated'), event, source.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Each event with its source.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect dated events"
      },
      {
        "fields" : [
          {
            "help" : "How events and people relate.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Links"
          }
        ],
        "hint" : "Sequence and connect the events.",
        "key" : "order",
        "opens" : "connections",
        "title" : "Order & link"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the tick-tock — never invent dates.",
        "key" : "confirm",
        "title" : "Confirm inclusion (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this timeline.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the timeline.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the tick-tock"
      }
    ]
  },
  "jrn.claim-board" : {
    "purpose" : "Track every claim and its verification status — checked, unchecked, disputed.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "claims",
            "kind" : "longText",
            "label" : "Claims",
            "required" : true
          }
        ],
        "hint" : "Every claim the story rests on.",
        "key" : "list",
        "opens" : "findings",
        "title" : "List the claims"
      },
      {
        "fields" : [
          {
            "help" : "Never publish an unverified claim.",
            "key" : "status",
            "kind" : "longText",
            "label" : "Status per claim"
          }
        ],
        "hint" : "Checked / unchecked / disputed, with the source.",
        "key" : "status",
        "opens" : "matrix",
        "title" : "Set each status"
      },
      {
        "fields" : [
          {
            "help" : "What supports each.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "The evidence behind each checked claim.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Cite the support"
      },
      {
        "fields" : [
          {
            "help" : "Name this board.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the fact-check board.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the board"
      }
    ]
  },
  "jrn.correction-actions" : {
    "purpose" : "Track corrective actions on published errors to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which published error each addresses.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Action ↔ error",
            "required" : true
          }
        ],
        "hint" : "What each action fixes.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link actions to errors"
      },
      {
        "fields" : [
          {
            "help" : "Each with owner and due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions",
            "required" : true
          }
        ],
        "hint" : "Action, owner, due.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the actions"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "jrn.correction-history" : {
    "purpose" : "Track post-publication corrections — the record is never rewritten silently.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line, with new evidence.",
            "key" : "corrections",
            "kind" : "longText",
            "label" : "Corrections",
            "required" : true
          }
        ],
        "hint" : "Each correction and what prompted it.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "List the corrections"
      },
      {
        "fields" : [
          {
            "help" : "Transparent — never rewrite the record silently.",
            "key" : "history",
            "kind" : "longText",
            "label" : "Correction history"
          }
        ],
        "hint" : "What changed and when.",
        "key" : "record",
        "opens" : "review",
        "title" : "Record each transparently"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the correction history.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this log.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the log.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the correction log"
      }
    ]
  },
  "jrn.correction-review" : {
    "purpose" : "Verify a published correction actually resolved the error.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The correction under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Correction",
            "required" : true
          }
        ],
        "hint" : "Which correction.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the correction"
      },
      {
        "fields" : [
          {
            "help" : "What changed.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Outcome"
          }
        ],
        "hint" : "Whether the error is resolved.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Check the outcome"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Resolved",
              "Partially",
              "Not resolved"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Resolved? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "jrn.data-desk" : {
    "purpose" : "Build datasets over documents (logs, filings) with cited cells.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The data in scope.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Which documents this dataset draws on.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the documents"
      },
      {
        "fields" : [
          {
            "help" : "What each column is and its source.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Columns & notes"
          }
        ],
        "hint" : "Each cell cited.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the dataset"
      },
      {
        "fields" : [
          {
            "help" : "Anything to warn a reader about.",
            "key" : "check",
            "kind" : "longText",
            "label" : "Checks"
          }
        ],
        "hint" : "Totals and outliers.",
        "key" : "check",
        "opens" : "dataLab",
        "title" : "Check the numbers"
      },
      {
        "fields" : [
          {
            "help" : "Name this dataset.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the story dataset.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the dataset"
      }
    ]
  },
  "jrn.fact-verification" : {
    "purpose" : "Verify claims against evidence — conflicting accounts preserved, never averaged.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "claims",
            "kind" : "longText",
            "label" : "Claims",
            "required" : true
          }
        ],
        "hint" : "Claims to verify.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "List the claims"
      },
      {
        "fields" : [
          {
            "help" : "Verified / not / disputed — with source; never mark verified without evidence.",
            "key" : "verify",
            "kind" : "longText",
            "label" : "Verification"
          }
        ],
        "hint" : "Against the evidence.",
        "key" : "verify",
        "opens" : "matrix",
        "title" : "Verify each"
      },
      {
        "fields" : [
          {
            "help" : "Never averaged.",
            "key" : "conflicts",
            "kind" : "longText",
            "label" : "Conflicts"
          }
        ],
        "hint" : "Conflicting accounts kept.",
        "key" : "conflicts",
        "opens" : "review",
        "title" : "Preserve conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this log.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the log.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the verification log"
      }
    ]
  },
  "jrn.interview-plan" : {
    "purpose" : "Identify reporting gaps and plan the interviews to fill them.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What's unanswered.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Reporting gaps",
            "required" : true
          }
        ],
        "hint" : "What the reporting still needs.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Identify the gaps"
      },
      {
        "fields" : [
          {
            "help" : "Open and evidence-anchored — never assert the answers.",
            "key" : "questions",
            "kind" : "longText",
            "label" : "Questions"
          }
        ],
        "hint" : "Questions tied to each gap.",
        "key" : "questions",
        "opens" : "matrix",
        "title" : "Draft the questions"
      },
      {
        "fields" : [
          {
            "help" : "Name this plan.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the plan.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "INT",
        "title" : "Produce the interview plan"
      }
    ]
  },
  "jrn.methods" : {
    "purpose" : "Run a structured method over the story.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. 5W1H, hypothesis matrix.",
            "key" : "method",
            "kind" : "text",
            "label" : "Method",
            "required" : true
          }
        ],
        "hint" : "Which structured method.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick the method"
      },
      {
        "fields" : [
          {
            "help" : "What it surfaced.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "Inputs and result.",
        "key" : "run",
        "opens" : "matrix",
        "title" : "Run it"
      },
      {
        "fields" : [
          {
            "help" : "Name this run.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the result.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the method run"
      }
    ]
  },
  "jrn.publication" : {
    "purpose" : "Record the human publication decision — never automated.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What's checked, what's outstanding.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Verification status and any legal review.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Recap verification & legal"
      },
      {
        "fields" : [
          {
            "help" : "Never automated.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Publish",
              "Hold",
              "Do not publish"
            ],
            "required" : true
          },
          {
            "help" : "The basis for the decision.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Rationale",
            "required" : true
          }
        ],
        "hint" : "A human makes the go/no-go call.",
        "key" : "decide",
        "title" : "Publication decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the publication decision.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the decision record"
      }
    ]
  },
  "jrn.publication-package" : {
    "purpose" : "Assemble the verified publication package: verify every claim is cited, confirm right of reply, then produce the package.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Draft with its citations.",
            "key" : "assemble",
            "kind" : "longText",
            "label" : "The package",
            "required" : true
          }
        ],
        "hint" : "The near-final story with citations.",
        "key" : "assemble",
        "opens" : "findings",
        "title" : "Assemble the package"
      },
      {
        "fields" : [
          {
            "help" : "Any unverified claim.",
            "key" : "verify",
            "kind" : "longText",
            "label" : "Citation check"
          }
        ],
        "hint" : "Each claim maps to verified evidence.",
        "key" : "verify",
        "opens" : "matrix",
        "title" : "Verify every claim is cited"
      },
      {
        "fields" : [
          {
            "help" : "Status.",
            "key" : "reply",
            "kind" : "choice",
            "label" : "Right of reply",
            "options" : [
              "All offered a reply",
              "Outstanding"
            ],
            "required" : true
          },
          {
            "help" : "Any outstanding outreach.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "Everyone named adversely was offered a reply.",
        "key" : "reply",
        "title" : "Confirm right of reply (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this package.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the cited package with its receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "PUB",
        "title" : "Produce the package"
      }
    ]
  },
  "jrn.quote-book" : {
    "purpose" : "Collect quotes cited to their exact source — a quote is never altered.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Verbatim, with source locator.",
            "key" : "quotes",
            "kind" : "longText",
            "label" : "Quotes",
            "required" : true
          }
        ],
        "hint" : "Each quote with its speaker and context.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the quotes"
      },
      {
        "fields" : [
          {
            "help" : "Confirm wording and context — never alter a quote.",
            "key" : "verifyNote",
            "kind" : "longText",
            "label" : "Verification"
          }
        ],
        "hint" : "Each quote reopens its exact source.",
        "key" : "verify",
        "opens" : "review",
        "title" : "Verify each locator"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm quote and context.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this quote book.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the quote book.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the quote book"
      }
    ]
  },
  "jrn.reporting-gap" : {
    "purpose" : "Track what's still unanswered — absence is not proof of wrongdoing.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Open questions",
            "required" : true
          }
        ],
        "hint" : "What the reporting hasn't answered.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the open questions"
      },
      {
        "fields" : [
          {
            "help" : "Order and why — absence never implies wrongdoing.",
            "key" : "priority",
            "kind" : "longText",
            "label" : "Priorities"
          }
        ],
        "hint" : "What matters most to resolve.",
        "key" : "prioritize",
        "opens" : "matrix",
        "title" : "Prioritize"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the open-questions register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "jrn.right-of-reply" : {
    "purpose" : "Log subjects named adversely and their responses — publishing without offering a reply is the gap that sinks the story.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "subjects",
            "kind" : "longText",
            "label" : "Subjects",
            "required" : true
          }
        ],
        "hint" : "Everyone named adversely.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the subjects"
      },
      {
        "fields" : [
          {
            "help" : "Channel, date, and deadline given.",
            "key" : "contact",
            "kind" : "longText",
            "label" : "Outreach"
          }
        ],
        "hint" : "How and when each was offered a chance to respond.",
        "key" : "contact",
        "opens" : "review",
        "title" : "Record the outreach"
      },
      {
        "fields" : [
          {
            "help" : "On the record — never omit a reply.",
            "key" : "responses",
            "kind" : "longText",
            "label" : "Responses",
            "required" : true
          }
        ],
        "hint" : "Each reply, or non-response after a fair deadline.",
        "key" : "responses",
        "title" : "Record responses (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this log.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the right-of-reply log.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the reply log"
      }
    ]
  },
  "jrn.source-map" : {
    "purpose" : "Map sources, people, and relationships.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "nodes",
            "kind" : "longText",
            "label" : "Sources & people",
            "required" : true
          }
        ],
        "hint" : "Who and what the story involves.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "List the sources & people"
      },
      {
        "fields" : [
          {
            "help" : "Each link, on evidence — protect confidential sources.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Relationships"
          }
        ],
        "hint" : "How they connect and what each supports.",
        "key" : "map",
        "opens" : "connections",
        "title" : "Map the relationships"
      },
      {
        "fields" : [
          {
            "help" : "Name this map.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the map.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the source map"
      }
    ]
  },
  "jrn.source-reliability" : {
    "purpose" : "Assess source reliability and independence — a rating is a judgement, not a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each source to rate.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "What strengthens or weakens each.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Factors"
          },
          {
            "help" : "High / Medium / Low — a judgement.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Reliability rating"
          }
        ],
        "hint" : "Track record, independence, motive.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are judgements.",
        "key" : "decide",
        "title" : "Own the ratings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this schedule.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the reliability schedule.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the schedule"
      }
    ]
  },
  "jrn.source-vault" : {
    "purpose" : "Keep a custody-tracked vault for source documents with integrity hashes.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What each item is and where it came from.",
            "key" : "items",
            "kind" : "longText",
            "label" : "Documents",
            "required" : true
          }
        ],
        "hint" : "Each source with provenance (attach originals).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the documents"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from platform/service",
              "Physical/device transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "Hash/verify each.",
        "key" : "integrity",
        "opens" : "audit",
        "title" : "Record integrity"
      },
      {
        "fields" : [
          {
            "help" : "How confidential sources are protected.",
            "key" : "protect",
            "kind" : "longText",
            "label" : "Protection"
          }
        ],
        "hint" : "Confidential-source handling.",
        "key" : "protect",
        "opens" : "audit",
        "title" : "Note source protection"
      },
      {
        "fields" : [
          {
            "help" : "Name this manifest.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed vault manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the vault"
      }
    ]
  },
  "jrn.story-intake" : {
    "purpose" : "Define the story question, scope, and authorized sources, then open the story file.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're investigating.",
            "key" : "premise",
            "kind" : "longText",
            "label" : "Story premise",
            "required" : true
          }
        ],
        "hint" : "The story question and why it matters.",
        "key" : "premise",
        "opens" : "sources",
        "title" : "Frame the story"
      },
      {
        "fields" : [
          {
            "help" : "The boundary.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "Scope",
            "required" : true
          },
          {
            "help" : "Leaks, filings, records authorized.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources in scope"
          }
        ],
        "hint" : "What's in scope and which sources it draws on.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Scope & sources"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when framed.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Confirmed?",
            "options" : [
              "Confirmed",
              "Needs revision"
            ],
            "required" : true
          }
        ],
        "hint" : "A human confirms the framing — intake never decides the story's truth.",
        "key" : "confirm",
        "title" : "Confirm the premise (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Story name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered story.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the story file"
      }
    ]
  },
  "jrn.transcript" : {
    "purpose" : "Correct transcripts with locators — unheard words are never asserted.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're correcting.",
            "key" : "source",
            "kind" : "text",
            "label" : "Source",
            "required" : true
          }
        ],
        "hint" : "The recording/transcript.",
        "key" : "source",
        "opens" : "sources",
        "title" : "Choose the source"
      },
      {
        "fields" : [
          {
            "help" : "Mark uncertain passages — never invent speech.",
            "key" : "transcript",
            "kind" : "longText",
            "label" : "Corrected transcript"
          }
        ],
        "hint" : "Fix the transcript against the audio.",
        "key" : "correct",
        "opens" : "findings",
        "title" : "Correct with locators"
      },
      {
        "fields" : [
          {
            "help" : "What you corrected.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the corrected transcript.",
        "key" : "confirm",
        "title" : "Confirm corrections (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this transcript.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the corrected transcript.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the transcript"
      }
    ]
  },
  "jrn.whos-who" : {
    "purpose" : "Unify names and aliases to one subject — reversible, human-reviewed.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate names",
            "required" : true
          }
        ],
        "hint" : "Names/handles that may be one subject.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the names"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each appears.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across sources"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude coincidental matches.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Your decision.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same subject",
              "Reject — different",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human decides. Reversible.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "law.ask" : {
    "purpose" : "Ask a question over the matter's record and keep the cited answer.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you need to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "The answer cites the record.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the case file"
      },
      {
        "fields" : [
          {
            "help" : "How it bears on the matter.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "law.causation" : {
    "purpose" : "Trace causation step by step — Five Whys / Fishbone over the record, then a human determination.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "The outcome to explain.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State what to explain"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where the record stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "The factors at play.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "On the record.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "A human determines causation.",
        "key" : "determine",
        "title" : "Determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the causation analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "law.damages" : {
    "purpose" : "Build a damages ledger; amounts cite source cells.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The records in scope.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "The financial records.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the records"
      },
      {
        "fields" : [
          {
            "help" : "Category (special / general / consequential) · Description · Amount · Date incurred · Source document (cited) · Calculation / basis · Mitigation · Running total. Every amount cites its source cell.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Damages ledger columns",
            "required" : true
          }
        ],
        "hint" : "One row per damages item, as in a damages spreadsheet.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the ledger"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the ledger ties out.",
        "key" : "confirm",
        "title" : "Confirm the totals (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this ledger.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the damages ledger.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the ledger"
      }
    ]
  },
  "law.deadlines" : {
    "purpose" : "Track deadlines — a candidate until a human confirms it.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Deadline / event · Trigger (rule / order / contract) · Due date · Computed how · Owner · Source (cited) · Status.",
            "key" : "dates",
            "kind" : "longText",
            "label" : "Deadline columns",
            "required" : true
          }
        ],
        "hint" : "One row per deadline — a candidate until you confirm it.",
        "key" : "gather",
        "opens" : "timeline",
        "title" : "Find the dates"
      },
      {
        "fields" : [
          {
            "help" : "Only confirmed dates are relied on.",
            "key" : "confirmed",
            "kind" : "longText",
            "label" : "Confirmed deadlines",
            "required" : true
          }
        ],
        "hint" : "Confirm each deadline — a candidate until you do.",
        "key" : "confirm",
        "title" : "Confirm each (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this list.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the list.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the deadline list"
      }
    ]
  },
  "law.deposition" : {
    "purpose" : "Draft a deposition outline; questions cite the record.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The points to cover.",
            "key" : "focus",
            "kind" : "longText",
            "label" : "Objectives",
            "required" : true
          }
        ],
        "hint" : "What the deposition must establish.",
        "key" : "focus",
        "opens" : "ask",
        "title" : "Set the objectives"
      },
      {
        "fields" : [
          {
            "help" : "Per topic: Objective · Foundation questions · Key questions · Exhibits to introduce (cited) · Anticipated answers & follow-ups. Every question anchored to the record.",
            "key" : "questions",
            "kind" : "longText",
            "label" : "Outline sections",
            "required" : true
          }
        ],
        "hint" : "By topic — the standard deposition-outline sections.",
        "key" : "questions",
        "opens" : "matrix",
        "title" : "Draft the outline"
      },
      {
        "fields" : [
          {
            "help" : "Name this outline.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the deposition outline.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the outline"
      }
    ]
  },
  "law.document-coding" : {
    "purpose" : "Code documents by recorded, reversible decisions.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What's being coded.",
            "key" : "scope",
            "kind" : "text",
            "label" : "Set",
            "required" : true
          }
        ],
        "hint" : "The documents under review.",
        "key" : "set",
        "opens" : "sources",
        "title" : "Scope the set"
      },
      {
        "fields" : [
          {
            "help" : "Bates / Doc ID · Responsive (Y/N) · Issue tags · Confidentiality (None / Confidential / AEO) · Privilege candidate? · Reviewer · Notes. Reversible.",
            "key" : "coding",
            "kind" : "longText",
            "label" : "Coding fields",
            "required" : true
          }
        ],
        "hint" : "One coding row per document.",
        "key" : "code",
        "opens" : "review",
        "title" : "Code the documents"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "QC",
            "required" : true
          }
        ],
        "hint" : "Confirm the coding is consistent.",
        "key" : "qc",
        "title" : "Quality-check the coding (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this report.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the report.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the coding report"
      }
    ]
  },
  "law.exhibit-binder" : {
    "purpose" : "Assemble the exhibit list and trial binder; each exhibit cites its source version.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Exhibit no. · Description · Date · Source document / Bates · Sponsoring witness · Purpose / issue · Objections anticipated · Admitted? Each cites its source version.",
            "key" : "exhibits",
            "kind" : "longText",
            "label" : "Exhibit list columns",
            "required" : true
          }
        ],
        "hint" : "One row per exhibit, as in an exhibit list (attach the source versions).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the exhibits"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from system/service",
              "Physical/scan transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "Hash/verify each.",
        "key" : "integrity",
        "opens" : "audit",
        "title" : "Record integrity"
      },
      {
        "fields" : [
          {
            "help" : "The binder order and numbering.",
            "key" : "order",
            "kind" : "longText",
            "label" : "Exhibit order"
          }
        ],
        "hint" : "The exhibit sequence.",
        "key" : "order",
        "opens" : "audit",
        "title" : "Order the binder"
      },
      {
        "fields" : [
          {
            "help" : "Name this binder.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed exhibit manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the exhibit list"
      }
    ]
  },
  "law.fact-chronology" : {
    "purpose" : "Build the case chronology — the spine of the matter (undated labelled, each fact cited).",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date (or 'undated / circa') · Fact / event · Actor(s) · Source document (cited) · Disputed? (Y/N) · Significance.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Chronology columns",
            "required" : true
          }
        ],
        "hint" : "One row per fact — the spine of the matter.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect the facts"
      },
      {
        "fields" : [
          {
            "help" : "How facts and parties relate.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Links"
          }
        ],
        "hint" : "Sequence and connect the facts.",
        "key" : "order",
        "opens" : "connections",
        "title" : "Order & link"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the chronology — each fact cited.",
        "key" : "confirm",
        "title" : "Confirm inclusion (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this chronology.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the case chronology.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the chronology"
      }
    ]
  },
  "law.fact-evidence" : {
    "purpose" : "Map facts to evidence — both sides preserved, cites reopen.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "facts",
            "kind" : "longText",
            "label" : "Facts",
            "required" : true
          }
        ],
        "hint" : "The facts at issue.",
        "key" : "facts",
        "opens" : "findings",
        "title" : "List the facts"
      },
      {
        "fields" : [
          {
            "help" : "Fact · Element it proves · Evidence FOR (cited) · Evidence AGAINST (cited) · Weight · Open dispute? Each cite reopens.",
            "key" : "matrix",
            "kind" : "longText",
            "label" : "Fact–evidence matrix columns",
            "required" : true
          }
        ],
        "hint" : "One row per fact, both sides preserved.",
        "key" : "map",
        "opens" : "matrix",
        "title" : "Map to evidence"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the mapping.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this matrix.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the fact–evidence matrix.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the matrix"
      }
    ]
  },
  "law.matter-closure" : {
    "purpose" : "Close the matter (sealed); reopen preserves full history.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the matter.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Deliverables, productions, open items.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm the outcome"
      },
      {
        "fields" : [
          {
            "help" : "Storage, retention, access.",
            "key" : "retention",
            "kind" : "longText",
            "label" : "Retention & access"
          }
        ],
        "hint" : "Where the file is kept and access.",
        "key" : "retention",
        "opens" : "handoff",
        "title" : "Retention & confidentiality"
      },
      {
        "fields" : [
          {
            "help" : "Close only when complete.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the matter",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves history.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "A human closes or reopens.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "law.matter-intake" : {
    "purpose" : "Open the matter and set its authorized, privilege-sensitive scope, then open the matter file.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. Acme v. Roe.",
            "key" : "matterName",
            "kind" : "text",
            "label" : "Matter",
            "required" : true
          },
          {
            "help" : "What's in dispute.",
            "key" : "issues",
            "kind" : "longText",
            "label" : "Issues"
          }
        ],
        "hint" : "The matter and the issues in dispute.",
        "key" : "matter",
        "opens" : "sources",
        "title" : "Record the matter"
      },
      {
        "fields" : [
          {
            "help" : "In and out of scope.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "Scope statement",
            "required" : true
          },
          {
            "help" : "The relevant period.",
            "key" : "window",
            "kind" : "dateRange",
            "label" : "Time window"
          }
        ],
        "hint" : "The boundary, mindful of privilege.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Scope (privilege-sensitive)"
      },
      {
        "fields" : [
          {
            "help" : "The authorized record — the evidence boundary.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Record in scope"
          }
        ],
        "hint" : "Authorize the document set.",
        "key" : "inscope",
        "opens" : "sources",
        "title" : "Set the record in scope"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when correct.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Scope confirmed?",
            "options" : [
              "Confirmed",
              "Needs revision"
            ],
            "required" : true
          },
          {
            "help" : "Anything to record.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "A human confirms scope before work.",
        "key" : "confirm",
        "title" : "Confirm scope (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Matter name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered matter.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the matter"
      }
    ]
  },
  "law.methods" : {
    "purpose" : "Run a structured method over the matter.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. 5W1H, hypothesis matrix.",
            "key" : "method",
            "kind" : "text",
            "label" : "Method",
            "required" : true
          }
        ],
        "hint" : "Which structured method.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick the method"
      },
      {
        "fields" : [
          {
            "help" : "What it surfaced.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "Inputs and result.",
        "key" : "run",
        "opens" : "matrix",
        "title" : "Run it"
      },
      {
        "fields" : [
          {
            "help" : "Name this run.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the result.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the method run"
      }
    ]
  },
  "law.obligations" : {
    "purpose" : "Compare obligations/clauses, each cell citing a clause locator.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The documents compared.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "The contracts/policies to compare.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the documents"
      },
      {
        "fields" : [
          {
            "help" : "Obligation / clause · Document & clause locator · Party bound · Trigger / condition · Deadline · Remedy on breach · Notes. Every cell cites its clause.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Obligations comparison columns",
            "required" : true
          }
        ],
        "hint" : "One row per obligation, as in a clause-comparison sheet.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the comparison"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the comparison.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this comparison.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the obligations comparison.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the comparison"
      }
    ]
  },
  "law.parties-issues" : {
    "purpose" : "Identify parties and issues linked to canonical objects.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line with role.",
            "key" : "parties",
            "kind" : "longText",
            "label" : "Parties",
            "required" : true
          }
        ],
        "hint" : "Every party to the matter.",
        "key" : "parties",
        "opens" : "dossier",
        "title" : "Identify the parties"
      },
      {
        "fields" : [
          {
            "help" : "Issue / legal element · Party it touches · Burden of proof · Supporting evidence (cited) · Opposing evidence (cited) · Status. Each cell reopens its source.",
            "key" : "issues",
            "kind" : "longText",
            "label" : "Issues matrix columns",
            "required" : true
          }
        ],
        "hint" : "One row per issue, as you would in an issues matrix.",
        "key" : "issues",
        "opens" : "matrix",
        "title" : "Map the issues"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm parties and issues.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the work product.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the parties & issues"
      }
    ]
  },
  "law.party-resolution" : {
    "purpose" : "Unify party names and aliases — reversible, human-reviewed.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate names",
            "required" : true
          }
        ],
        "hint" : "Party names/aliases that may be one.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the names"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each appears.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across the record"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude coincidental matches.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Your decision.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same party",
              "Reject — different",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human decides. Reversible.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "law.privilege" : {
    "purpose" : "Build the privilege log — candidates recorded with basis; privilege is NEVER auto-established.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "candidates",
            "kind" : "longText",
            "label" : "Candidates",
            "required" : true
          }
        ],
        "hint" : "Documents that may be privileged.",
        "key" : "identify",
        "opens" : "review",
        "title" : "Identify candidates"
      },
      {
        "fields" : [
          {
            "help" : "Bates / Doc ID · Date · Author (From) · Recipients (To / Cc / Bcc) · Document type · Privilege asserted (Attorney-Client / Work Product / Both) · Description (enough to justify the claim without waiving it) · Withheld vs Redacted. Privilege is never auto-established.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Privilege log columns",
            "required" : true
          }
        ],
        "hint" : "The standard privilege-log columns, one row per withheld or redacted document (as you would in Excel).",
        "key" : "basis",
        "opens" : "matrix",
        "title" : "Build the privilege log"
      },
      {
        "fields" : [
          {
            "help" : "Only when every candidate has a basis.",
            "key" : "logComplete",
            "kind" : "choice",
            "label" : "Privilege log complete?",
            "options" : [
              "Complete",
              "Incomplete"
            ],
            "required" : true
          },
          {
            "help" : "Anything outstanding.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "Confirm every candidate is annotated.",
        "key" : "complete",
        "title" : "Complete the log (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this log.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the log.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the privilege log"
      }
    ]
  },
  "law.production" : {
    "purpose" : "Produce the export set — every document Bates-numbered; report == receipt with custody hashes. The privilege log must be complete before anything leaves.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What's being produced.",
            "key" : "set",
            "kind" : "text",
            "label" : "Production set",
            "required" : true
          }
        ],
        "hint" : "The responsive documents to produce.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the set"
      },
      {
        "fields" : [
          {
            "help" : "Producing before the log is complete is the gap opposing counsel finds.",
            "key" : "privComplete",
            "kind" : "choice",
            "label" : "Privilege log complete?",
            "options" : [
              "Complete",
              "Incomplete"
            ],
            "required" : true
          }
        ],
        "hint" : "Nothing produced before every privileged doc is logged.",
        "key" : "privilege",
        "title" : "Confirm privilege log complete (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "What's redacted and validated.",
            "key" : "redactions",
            "kind" : "longText",
            "label" : "Redactions"
          }
        ],
        "hint" : "Redact and validate before production.",
        "key" : "redact",
        "opens" : "handoff",
        "title" : "Apply & validate redactions"
      },
      {
        "fields" : [
          {
            "help" : "The numbering applied.",
            "key" : "bates",
            "kind" : "text",
            "label" : "Bates range",
            "placeholder" : "ACME000001–ACME000500"
          }
        ],
        "hint" : "Every document numbered.",
        "key" : "number",
        "opens" : "handoff",
        "title" : "Bates-number the set"
      },
      {
        "fields" : [
          {
            "help" : "Label this production volume.",
            "key" : "title",
            "kind" : "text",
            "label" : "Production name",
            "required" : true
          }
        ],
        "hint" : "Export with custody hashes — report == receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "PRD",
        "title" : "Produce the set"
      }
    ]
  },
  "law.redaction" : {
    "purpose" : "Validate text and visual redaction before production.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What's redacted.",
            "key" : "redactions",
            "kind" : "longText",
            "label" : "Redactions",
            "required" : true
          }
        ],
        "hint" : "Redact the sensitive/privileged content.",
        "key" : "apply",
        "opens" : "handoff",
        "title" : "Apply redactions"
      },
      {
        "fields" : [
          {
            "help" : "Underlying text checked.",
            "key" : "textNote",
            "kind" : "longText",
            "label" : "Text validation"
          }
        ],
        "hint" : "No hidden text remains.",
        "key" : "text",
        "opens" : "review",
        "title" : "Validate text redaction"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when text + visual pass.",
            "key" : "validated",
            "kind" : "choice",
            "label" : "Redaction validated?",
            "options" : [
              "Validated",
              "Not yet"
            ],
            "required" : true
          },
          {
            "help" : "Anything to record.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "Visual layer checked; confirm before production.",
        "key" : "visual",
        "title" : "Validate visual & confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this validation.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the redaction validation.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the validation"
      }
    ]
  },
  "law.remediation" : {
    "purpose" : "Track remediation/undertaking actions to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which issue each responds to.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Action ↔ issue",
            "required" : true
          }
        ],
        "hint" : "What each action addresses.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link actions to issues"
      },
      {
        "fields" : [
          {
            "help" : "Each with owner and due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions",
            "required" : true
          }
        ],
        "hint" : "Action, owner, due date.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the actions"
      },
      {
        "fields" : [
          {
            "help" : "Confirm owners and dates.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each is agreed.",
        "key" : "assign",
        "title" : "Agree owners & dates (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the remediation register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "law.remediation-review" : {
    "purpose" : "Verify a completed remediation actually resolved the issue.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The action under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Action",
            "required" : true
          }
        ],
        "hint" : "Which remediation.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the action"
      },
      {
        "fields" : [
          {
            "help" : "What changed.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "Evidence of the outcome (attach it).",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Gather evidence"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Effective",
              "Partially effective",
              "Not effective"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Resolved? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "law.source-desk" : {
    "purpose" : "Assess reliability and independence of record sources — a rating is a judgement, not a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each record source to assess.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "What strengthens or weakens each.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Factors"
          },
          {
            "help" : "High / Medium / Low — a judgement.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Reliability rating"
          }
        ],
        "hint" : "Reliability and independence.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are judgements.",
        "key" : "decide",
        "title" : "Own the ratings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this report.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the reliability desk.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the desk report"
      }
    ]
  },
  "law.witness-profiles" : {
    "purpose" : "Profile witnesses; contradictions cite both sides.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "witnesses",
            "kind" : "longText",
            "label" : "Witnesses",
            "required" : true
          }
        ],
        "hint" : "Who they are.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the witnesses"
      },
      {
        "fields" : [
          {
            "help" : "Name & role · Relationship to parties · What they can speak to · Prior statements (cited) · Credibility notes · Contradictions (both sides cited).",
            "key" : "profiles",
            "kind" : "longText",
            "label" : "Per-witness fields",
            "required" : true
          }
        ],
        "hint" : "One profile per witness.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Compile each profile"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the profiles.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the witness profiles.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the profiles"
      }
    ]
  },
  "res.alternative" : {
    "purpose" : "Explore evidence-bounded counterfactuals — a scenario, never presented as fact, and never mutating the ledger.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The counterfactual to explore.",
            "key" : "scenario",
            "kind" : "longText",
            "label" : "Scenario",
            "required" : true
          }
        ],
        "hint" : "The what-if and its evidence bounds.",
        "key" : "scope",
        "opens" : "findings",
        "title" : "Bound the counterfactual"
      },
      {
        "fields" : [
          {
            "help" : "What the evidence permits — and doesn't.",
            "key" : "trace",
            "kind" : "longText",
            "label" : "Scenario trace"
          }
        ],
        "hint" : "Trace it over cited events.",
        "key" : "build",
        "opens" : "dataLab",
        "title" : "Build the scenario"
      },
      {
        "fields" : [
          {
            "help" : "Presented as scenario, not fact.",
            "key" : "bounds",
            "kind" : "longText",
            "label" : "Bounds & caveats",
            "required" : true
          }
        ],
        "hint" : "Where the scenario leaves the evidence.",
        "key" : "bounds",
        "title" : "State the bounds (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this note.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the alternative-history note.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the note"
      }
    ]
  },
  "res.ask" : {
    "purpose" : "Ask a question over the authorized corpus and keep the cited answer.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you want to know.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "The answer cites its source.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the corpus"
      },
      {
        "fields" : [
          {
            "help" : "How it serves the research.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "res.authority-control" : {
    "purpose" : "Unify names/terms to canonical authorities — reversible and human-reviewed, never auto-unified.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Variants",
            "required" : true
          }
        ],
        "hint" : "Names/terms that may be one authority.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather the variants"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting usages.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Usages"
          }
        ],
        "hint" : "How each variant is used across the corpus.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare usages"
      },
      {
        "fields" : [
          {
            "help" : "With reason.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude distinct entities that share a name.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out false unifications"
      },
      {
        "fields" : [
          {
            "help" : "Your decision.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Unify",
              "Keep separate",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human confirms. Reversible.",
        "key" : "decide",
        "title" : "Confirm the authority (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible authority decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the authority"
      }
    ]
  },
  "res.bibliography" : {
    "purpose" : "Verify every citation reopens its exact source, and seal the bibliography.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each citation to verify.",
            "key" : "citations",
            "kind" : "longText",
            "label" : "Citations",
            "required" : true
          }
        ],
        "hint" : "The citations to audit.",
        "key" : "gather",
        "opens" : "audit",
        "title" : "Gather the citations"
      },
      {
        "fields" : [
          {
            "help" : "Which resolve and which are broken — never assert an unresolved cite.",
            "key" : "verifyNote",
            "kind" : "longText",
            "label" : "Verification"
          }
        ],
        "hint" : "Open each citation to its exact source.",
        "key" : "verify",
        "opens" : "audit",
        "title" : "Verify each resolves"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the audit.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this bibliography.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed bibliography/audit.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the bibliography"
      }
    ]
  },
  "res.causal" : {
    "purpose" : "Trace why an event unfolded — Five Whys / Fishbone over cited evidence, then a human determination.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "The event to explain.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State what to explain"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "The factors at play.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "On the evidence.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "A human determines the cause.",
        "key" : "determine",
        "title" : "Determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "res.chronology" : {
    "purpose" : "Build a periodised timeline — undated events labelled, each cited.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date (or 'undated'), event, source.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "Each event with its source.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect dated events"
      },
      {
        "fields" : [
          {
            "help" : "The periodisation and its rationale.",
            "key" : "periods",
            "kind" : "longText",
            "label" : "Periods"
          }
        ],
        "hint" : "Group events into periods.",
        "key" : "period",
        "opens" : "matrix",
        "title" : "Periodise"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm periods and inclusions — never invent dates.",
        "key" : "confirm",
        "title" : "Confirm inclusion (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this chronology.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the chronology.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the chronology"
      }
    ]
  },
  "res.corpus-catalogue" : {
    "purpose" : "Catalogue every authorized source with provenance.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The corpus spanned.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "The sources to catalogue.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the sources"
      },
      {
        "fields" : [
          {
            "help" : "Provenance per source.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Catalogue columns"
          }
        ],
        "hint" : "Each source: origin, date, custody.",
        "key" : "catalogue",
        "opens" : "dataLab",
        "title" : "Catalogue with provenance"
      },
      {
        "fields" : [
          {
            "help" : "What you include and why — never assert authenticity you can't support.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each source belongs in the corpus.",
        "key" : "confirm",
        "title" : "Confirm inclusion (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this catalogue.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the corpus catalogue.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the catalogue"
      }
    ]
  },
  "res.edition" : {
    "purpose" : "Assemble an annotated edition: fix the protocol link, marshal sources, annotate, then produce the edition — source text never silently altered.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The question and scope.",
            "key" : "protocol",
            "kind" : "longText",
            "label" : "Protocol link",
            "required" : true
          }
        ],
        "hint" : "The research question this edition answers.",
        "key" : "protocol",
        "opens" : "findings",
        "title" : "Anchor to the protocol"
      },
      {
        "fields" : [
          {
            "help" : "What the edition is built from.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Selected sources"
          }
        ],
        "hint" : "The selected sources for the edition.",
        "key" : "sources",
        "opens" : "findings",
        "title" : "Marshal the sources"
      },
      {
        "fields" : [
          {
            "help" : "Source text preserved; annotations clearly yours.",
            "key" : "notes",
            "kind" : "longText",
            "label" : "Annotations"
          }
        ],
        "hint" : "Your notes and apparatus.",
        "key" : "annotate",
        "opens" : "matrix",
        "title" : "Annotate"
      },
      {
        "fields" : [
          {
            "help" : "What you approve — source text never silently altered.",
            "key" : "approval",
            "kind" : "longText",
            "label" : "Approval & basis",
            "required" : true
          }
        ],
        "hint" : "A human approves the edition.",
        "key" : "approve",
        "title" : "Approve the edition (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this edition.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the annotated edition with its receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EDN",
        "title" : "Produce the edition"
      }
    ]
  },
  "res.errata" : {
    "purpose" : "Track corrections to the edition as corrective actions to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The passage each corrects.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Erratum ↔ edition",
            "required" : true
          }
        ],
        "hint" : "What each correction fixes.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link errata to the edition"
      },
      {
        "fields" : [
          {
            "help" : "Each with owner and target.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Corrections"
          }
        ],
        "hint" : "Correction, owner, status.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the corrections"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the errata register"
      }
    ]
  },
  "res.errata-review" : {
    "purpose" : "Verify a published correction actually resolved the issue.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The correction under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Correction",
            "required" : true
          }
        ],
        "hint" : "Which erratum.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the correction"
      },
      {
        "fields" : [
          {
            "help" : "What changed.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Outcome"
          }
        ],
        "hint" : "Whether it resolved the issue.",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Check the outcome"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Resolved",
              "Partially",
              "Not resolved"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Resolved? (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "res.extraction" : {
    "purpose" : "Extract coded findings, each citing an evidence block.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The codes and their definitions.",
            "key" : "codebook",
            "kind" : "longText",
            "label" : "Codebook",
            "required" : true
          }
        ],
        "hint" : "The codes you'll extract against.",
        "key" : "codebook",
        "opens" : "review",
        "title" : "Confirm the codebook"
      },
      {
        "fields" : [
          {
            "help" : "Each finding cites its evidence block — never fabricated.",
            "key" : "findings",
            "kind" : "longText",
            "label" : "Coded findings"
          }
        ],
        "hint" : "Code passages into structured findings.",
        "key" : "extract",
        "opens" : "findings",
        "title" : "Extract & code"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the coding.",
        "key" : "confirm",
        "title" : "Confirm the codes (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this dataset.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the coded dataset.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the coded dataset"
      }
    ]
  },
  "res.interpretation" : {
    "purpose" : "Compare competing interpretations — both accounts preserved, no winner picked for you.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each interpretation and its proponents.",
            "key" : "interps",
            "kind" : "longText",
            "label" : "Interpretations",
            "required" : true
          }
        ],
        "hint" : "The competing readings.",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the interpretations"
      },
      {
        "fields" : [
          {
            "help" : "Support and tension for each — both preserved.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Comparison"
          }
        ],
        "hint" : "How each fits the evidence.",
        "key" : "compare",
        "opens" : "matrix",
        "title" : "Compare on the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Which you favor and why.",
            "key" : "reading",
            "kind" : "longText",
            "label" : "Your reading & basis",
            "required" : true
          }
        ],
        "hint" : "Your interpretation, argued — never presented as the only one.",
        "key" : "confirm",
        "title" : "Record your reading (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the comparison.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the comparison"
      }
    ]
  },
  "res.matter-closure" : {
    "purpose" : "Close the research matter by an explicit decision — sealed and reopenable with history.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the matter.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Edition, findings, open leads.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm the outputs"
      },
      {
        "fields" : [
          {
            "help" : "Close only when complete.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the matter",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves history.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "You close or keep it open.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "res.metadata" : {
    "purpose" : "Record structured metadata per source — your working finding aid, cited to the source.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The sources described.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Which sources to describe.",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Choose the sources"
      },
      {
        "fields" : [
          {
            "help" : "Each field cited to the source — never invented.",
            "key" : "metadata",
            "kind" : "longText",
            "label" : "Metadata"
          }
        ],
        "hint" : "Structured fields per source.",
        "key" : "describe",
        "opens" : "dataLab",
        "title" : "Record the metadata"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each entry is evidenced.",
        "key" : "confirm",
        "title" : "Confirm the metadata (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this finding aid.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the finding aid.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the finding aid"
      }
    ]
  },
  "res.methods" : {
    "purpose" : "Run a structured method over the matter.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "e.g. 5W1H, hypothesis matrix, root cause.",
            "key" : "method",
            "kind" : "text",
            "label" : "Method",
            "required" : true
          }
        ],
        "hint" : "Which structured method.",
        "key" : "pick",
        "opens" : "matrix",
        "title" : "Pick the method"
      },
      {
        "fields" : [
          {
            "help" : "What it structured or surfaced.",
            "key" : "runNote",
            "kind" : "longText",
            "label" : "Result"
          }
        ],
        "hint" : "Inputs and what it produced.",
        "key" : "run",
        "opens" : "matrix",
        "title" : "Run it"
      },
      {
        "fields" : [
          {
            "help" : "Name this run.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the result.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the method run"
      }
    ]
  },
  "res.prosopography" : {
    "purpose" : "Compile a collective biography of a group, each cell cited.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The members and inclusion basis.",
            "key" : "group",
            "kind" : "longText",
            "label" : "Group",
            "required" : true
          }
        ],
        "hint" : "Who's in the collective biography.",
        "key" : "define",
        "opens" : "dossier",
        "title" : "Define the group"
      },
      {
        "fields" : [
          {
            "help" : "Only what the evidence supports.",
            "key" : "entries",
            "kind" : "longText",
            "label" : "Entries"
          }
        ],
        "hint" : "Each member's fields, cited.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Compile the entries"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm — never assert unknown biography.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each entry is evidenced.",
        "key" : "confirm",
        "title" : "Confirm the entries (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this table.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the table.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the prosopography"
      }
    ]
  },
  "res.protocol" : {
    "purpose" : "Fix the research question, scope, and authorized corpus before evidence is touched — the protocol that prevents drift.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Fixed before screening.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Research question",
            "required" : true
          }
        ],
        "hint" : "The question this review answers.",
        "key" : "question",
        "opens" : "sources",
        "title" : "State the research question"
      },
      {
        "fields" : [
          {
            "help" : "What's in and out.",
            "key" : "criteria",
            "kind" : "longText",
            "label" : "Inclusion criteria"
          },
          {
            "help" : "The period this covers.",
            "key" : "window",
            "kind" : "dateRange",
            "label" : "Records window"
          }
        ],
        "hint" : "What qualifies a source, and the period covered.",
        "key" : "criteria",
        "opens" : "sources",
        "title" : "Inclusion criteria & window"
      },
      {
        "fields" : [
          {
            "help" : "The authorized corpus.",
            "key" : "corpus",
            "kind" : "longText",
            "label" : "Corpus"
          }
        ],
        "hint" : "The sources the review may draw on.",
        "key" : "corpus",
        "opens" : "sources",
        "title" : "Set the authorized corpus"
      },
      {
        "fields" : [
          {
            "help" : "A findable name.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "Protocol name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered research matter.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the protocol"
      }
    ]
  },
  "res.screening" : {
    "purpose" : "Screen sources in or out by recorded, reversible criteria — PRISMA-style.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "By which each source is screened.",
            "key" : "criteria",
            "kind" : "longText",
            "label" : "Criteria",
            "required" : true
          }
        ],
        "hint" : "The recorded inclusion/exclusion criteria.",
        "key" : "criteria",
        "opens" : "review",
        "title" : "Confirm the criteria"
      },
      {
        "fields" : [
          {
            "help" : "Each source in/out, with reason — reversible.",
            "key" : "decisions",
            "kind" : "longText",
            "label" : "Screening decisions"
          }
        ],
        "hint" : "Include/exclude each source.",
        "key" : "screen",
        "opens" : "search",
        "title" : "Screen the corpus"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the screen — never auto-exclude silently.",
        "key" : "confirm",
        "title" : "Confirm screening (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this log.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the screening log.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the screening log"
      }
    ]
  },
  "res.source-criticism" : {
    "purpose" : "Assess origin, bias, and reliability of sources — never declare truth from a single source.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each source to criticize.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "What strengthens or weakens each.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Factors"
          },
          {
            "help" : "Your assessment — a judgement.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Assessment"
          }
        ],
        "hint" : "Origin, purpose, bias, reliability.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the assessment.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are judgements.",
        "key" : "decide",
        "title" : "Own the assessment (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this work product.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the notes.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the source criticism"
      }
    ]
  },
  "res.transcription" : {
    "purpose" : "Transcribe and code source text with locators — unheard words are never asserted.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you're transcribing.",
            "key" : "source",
            "kind" : "text",
            "label" : "Source",
            "required" : true
          }
        ],
        "hint" : "The audio/image/text to transcribe.",
        "key" : "source",
        "opens" : "sources",
        "title" : "Choose the source"
      },
      {
        "fields" : [
          {
            "help" : "Mark anything uncertain — never assert unheard words.",
            "key" : "transcript",
            "kind" : "longText",
            "label" : "Transcript & codes"
          }
        ],
        "hint" : "Transcribe with locators and code passages.",
        "key" : "transcribe",
        "opens" : "findings",
        "title" : "Transcribe & code"
      },
      {
        "fields" : [
          {
            "help" : "What you corrected and confirmed.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm the corrected transcript.",
        "key" : "verify",
        "title" : "Verify corrections (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this transcript.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the corrected transcript.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the transcript"
      }
    ]
  },
  "siu.action-review" : {
    "purpose" : "Verify a completed action actually resolved the exposure — never declare it resolved without evidence.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The action under review.",
            "key" : "action",
            "kind" : "text",
            "label" : "Action",
            "required" : true
          }
        ],
        "hint" : "Which completed action you're reviewing.",
        "key" : "select",
        "opens" : "handoff",
        "title" : "Select the action"
      },
      {
        "fields" : [
          {
            "help" : "What happened since.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "Evidence of the outcome (attach it).",
        "key" : "evidence",
        "opens" : "findings",
        "title" : "Gather evidence"
      },
      {
        "fields" : [
          {
            "help" : "Evidence-based.",
            "key" : "verdict",
            "kind" : "choice",
            "label" : "Verdict",
            "options" : [
              "Effective",
              "Partially effective",
              "Not effective"
            ],
            "required" : true
          },
          {
            "help" : "Why.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "On the evidence.",
        "key" : "judge",
        "title" : "Judge effectiveness (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this review.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the review.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the review"
      }
    ]
  },
  "siu.ask" : {
    "purpose" : "Ask a question over the claim's authorized documents and keep the cited answer on the record.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What you need to know from the claim file.",
            "key" : "question",
            "kind" : "longText",
            "label" : "Your question",
            "required" : true
          }
        ],
        "hint" : "Ask in plain language — the answer cites the claim's evidence.",
        "key" : "ask",
        "opens" : "ask",
        "title" : "Ask the claim file"
      },
      {
        "fields" : [
          {
            "help" : "How this answer bears on the exposure.",
            "key" : "why",
            "kind" : "longText",
            "label" : "Why it matters"
          }
        ],
        "hint" : "Save the answer that matters to the investigation.",
        "key" : "record",
        "opens" : "answers",
        "posts" : "RPT",
        "title" : "Keep the cited answer"
      }
    ]
  },
  "siu.causation" : {
    "purpose" : "Trace how the loss occurred: Five Whys, Fishbone, then a human determination — never state fraud as a conclusion here.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Specific and evidence-based.",
            "key" : "problem",
            "kind" : "longText",
            "label" : "Problem statement",
            "required" : true
          }
        ],
        "hint" : "The loss to explain, precisely.",
        "key" : "problem",
        "opens" : "findings",
        "title" : "State the loss"
      },
      {
        "fields" : [
          {
            "help" : "Each link supported.",
            "key" : "whys",
            "kind" : "longText",
            "label" : "Why chain"
          }
        ],
        "hint" : "Cause to cause; stop where evidence stops.",
        "key" : "whys",
        "opens" : "connections",
        "title" : "Five Whys"
      },
      {
        "fields" : [
          {
            "help" : "e.g. mechanism, timing, opportunity, documentation.",
            "key" : "categories",
            "kind" : "longText",
            "label" : "Categories"
          }
        ],
        "hint" : "Sort candidate causes.",
        "key" : "fishbone",
        "opens" : "matrix",
        "title" : "Fishbone — categorize"
      },
      {
        "fields" : [
          {
            "help" : "How the loss occurred, on the evidence.",
            "key" : "determination",
            "kind" : "longText",
            "label" : "Determination & basis",
            "required" : true
          }
        ],
        "hint" : "A human determines how the loss occurred.",
        "key" : "determine",
        "title" : "Determination (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this analysis.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the causation analysis.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the analysis"
      }
    ]
  },
  "siu.claim-intake" : {
    "purpose" : "Open a claim file for investigation: record the claim, fix the referral basis and scope, set the documents in scope, then open the file. Intake never concludes fraud.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The insurer's claim reference.",
            "key" : "claimNo",
            "kind" : "text",
            "label" : "Claim number",
            "required" : true
          },
          {
            "help" : "When the loss is said to have occurred.",
            "key" : "dateOfLoss",
            "kind" : "date",
            "label" : "Date of loss"
          },
          {
            "help" : "The policy the claim is made under.",
            "key" : "policyNo",
            "kind" : "text",
            "label" : "Policy number"
          },
          {
            "help" : "Loss type, amount claimed, parties — as presented.",
            "key" : "summary",
            "kind" : "longText",
            "label" : "The claim",
            "required" : true
          }
        ],
        "hint" : "Capture the claim as presented at FNOL.",
        "key" : "claim",
        "opens" : "sources",
        "title" : "Record the claim"
      },
      {
        "fields" : [
          {
            "help" : "What put this claim into SIU.",
            "key" : "basis",
            "kind" : "choice",
            "label" : "Referral basis",
            "options" : [
              "Red flags at FNOL",
              "Adjuster referral",
              "SIU trigger/rule",
              "Regulatory",
              "Other"
            ],
            "required" : true
          },
          {
            "help" : "What is in and out of scope for this investigation.",
            "key" : "scope",
            "kind" : "longText",
            "label" : "Scope statement",
            "required" : true
          }
        ],
        "hint" : "Why this claim is under investigation, and what the investigation covers.",
        "key" : "scope",
        "opens" : "sources",
        "title" : "Referral basis & scope"
      },
      {
        "fields" : [
          {
            "help" : "The authorized document set — the evidence boundary.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Documents in scope"
          }
        ],
        "hint" : "Authorize the claim file, policy, prior claims and statements.",
        "key" : "inscope",
        "opens" : "sources",
        "title" : "Set the documents in scope"
      },
      {
        "fields" : [
          {
            "help" : "Confirm only when correct.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Scope confirmed?",
            "options" : [
              "Confirmed",
              "Needs revision"
            ],
            "required" : true
          },
          {
            "help" : "Anything to record about the decision.",
            "key" : "note",
            "kind" : "longText",
            "label" : "Note"
          }
        ],
        "hint" : "A human confirms scope before work begins.",
        "key" : "confirm",
        "title" : "Confirm scope (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "A findable name for this claim file.",
            "key" : "caseName",
            "kind" : "text",
            "label" : "File name",
            "required" : true
          }
        ],
        "hint" : "Open the numbered file the rest of the jobs run against.",
        "key" : "open",
        "opens" : "handoff",
        "posts" : "IMP",
        "title" : "Open the claim file"
      }
    ]
  },
  "siu.claimant-workup" : {
    "purpose" : "Work up the claimant/provider from cited in-scope evidence, and confirm the identity/associations.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Claimant, provider, or associate.",
            "key" : "subject",
            "kind" : "text",
            "label" : "Subject",
            "required" : true
          }
        ],
        "hint" : "Who you're working up and why.",
        "key" : "identify",
        "opens" : "dossier",
        "title" : "Identify the subject"
      },
      {
        "fields" : [
          {
            "help" : "Only what the in-scope evidence supports.",
            "key" : "profile",
            "kind" : "longText",
            "label" : "Workup"
          }
        ],
        "hint" : "Background, prior history, relationships — each cited.",
        "key" : "compile",
        "opens" : "dossier",
        "title" : "Compile the workup"
      },
      {
        "fields" : [
          {
            "help" : "What you confirm and how you know.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation & basis",
            "required" : true
          }
        ],
        "hint" : "Confirm identity and associations, with basis.",
        "key" : "confirm",
        "title" : "Confirm (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this workup.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the workup for the file.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the workup"
      }
    ]
  },
  "siu.closure" : {
    "purpose" : "Close the claim file by an explicit human decision — unresolved items retained, reopening preserves the prior closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "State of the file.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap"
          }
        ],
        "hint" : "Report, actions, and any items left open.",
        "key" : "recap",
        "opens" : "handoff",
        "title" : "Confirm outcome"
      },
      {
        "fields" : [
          {
            "help" : "Storage, retention, access.",
            "key" : "retention",
            "kind" : "longText",
            "label" : "Retention & access"
          }
        ],
        "hint" : "Where the file is kept and who may access it.",
        "key" : "retention",
        "opens" : "handoff",
        "title" : "Retention & confidentiality"
      },
      {
        "fields" : [
          {
            "help" : "Close only when complete.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Close the file",
              "Keep open"
            ],
            "required" : true
          },
          {
            "help" : "Why — reopening preserves this closure.",
            "key" : "reason",
            "kind" : "longText",
            "label" : "Reason",
            "required" : true
          }
        ],
        "hint" : "A human closes or keeps the file open.",
        "key" : "decide",
        "title" : "Closure decision (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the closure record and receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "EXP",
        "title" : "Produce the closure record"
      }
    ]
  },
  "siu.custody" : {
    "purpose" : "Keep a defensible evidence locker: register exhibits, record acquisition and integrity, log transfers, then seal the manifest.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "What each item is and where it came from.",
            "key" : "exhibits",
            "kind" : "longText",
            "label" : "Exhibits",
            "required" : true
          }
        ],
        "hint" : "Each item collected, with source (attach originals).",
        "key" : "register",
        "opens" : "audit",
        "title" : "Register the exhibits"
      },
      {
        "fields" : [
          {
            "help" : "How it was taken in.",
            "key" : "method",
            "kind" : "choice",
            "label" : "Acquisition method",
            "options" : [
              "In-place ingest (watched folder)",
              "Copy into vault",
              "Export from system/service",
              "Physical/device transfer"
            ],
            "required" : true
          },
          {
            "help" : "Turn on after Verify integrity on Audit.",
            "key" : "integrity",
            "kind" : "bool",
            "label" : "Integrity verified"
          }
        ],
        "hint" : "How each item entered custody unaltered.",
        "key" : "acquire",
        "opens" : "audit",
        "title" : "Acquisition & integrity"
      },
      {
        "fields" : [
          {
            "help" : "Each hand-off.",
            "key" : "transfers",
            "kind" : "longText",
            "label" : "Transfers"
          }
        ],
        "hint" : "Who held what, when.",
        "key" : "transfers",
        "opens" : "audit",
        "title" : "Log custody transfers"
      },
      {
        "fields" : [
          {
            "help" : "Name this manifest.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Post the sealed custody manifest.",
        "key" : "seal",
        "opens" : "handoff",
        "posts" : "PRS",
        "title" : "Seal the manifest"
      }
    ]
  },
  "siu.euo-prep" : {
    "purpose" : "Prepare an examination under oath grounded in the record: what to establish, sworn-exam questions, and logistics.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The points to cover.",
            "key" : "focus",
            "kind" : "longText",
            "label" : "What to establish",
            "required" : true
          }
        ],
        "hint" : "What the EUO must establish or resolve.",
        "key" : "review",
        "opens" : "ask",
        "title" : "Review the record"
      },
      {
        "fields" : [
          {
            "help" : "Grouped by topic.",
            "key" : "questions",
            "kind" : "longText",
            "label" : "Questions",
            "required" : true
          }
        ],
        "hint" : "Evidence-anchored questions for the examination.",
        "key" : "questions",
        "opens" : "matrix",
        "title" : "Draft the questions"
      },
      {
        "fields" : [
          {
            "help" : "Arrangements and any rights/notice.",
            "key" : "logistics",
            "kind" : "longText",
            "label" : "Logistics"
          }
        ],
        "hint" : "Notice, counsel, oath, scheduling.",
        "key" : "logistics",
        "opens" : "handoff",
        "title" : "Plan logistics"
      },
      {
        "fields" : [
          {
            "help" : "Name this plan.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the examination plan.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "INT",
        "title" : "Produce the EUO plan"
      }
    ]
  },
  "siu.identity" : {
    "purpose" : "Decide whether names/aliases/entities are the same party: gather identifiers, compare, rule out look-alikes, then confirm or reject — reversible, human-gated.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "identifiers",
            "kind" : "longText",
            "label" : "Candidate identifiers",
            "required" : true
          }
        ],
        "hint" : "Names, aliases, entities, accounts that may be one party.",
        "key" : "gather",
        "opens" : "knowledge",
        "title" : "Gather identifiers"
      },
      {
        "fields" : [
          {
            "help" : "Matching and conflicting signals.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Signals"
          }
        ],
        "hint" : "How each identifier appears across the file.",
        "key" : "compare",
        "opens" : "knowledge",
        "title" : "Compare across evidence"
      },
      {
        "fields" : [
          {
            "help" : "Candidates ruled out and why.",
            "key" : "ruledOut",
            "kind" : "longText",
            "label" : "Excluded"
          }
        ],
        "hint" : "Exclude coincidental matches, with reason.",
        "key" : "ruleout",
        "opens" : "review",
        "title" : "Rule out look-alikes"
      },
      {
        "fields" : [
          {
            "help" : "Reversible later.",
            "key" : "decision",
            "kind" : "choice",
            "label" : "Decision",
            "options" : [
              "Confirm same party",
              "Reject — different parties",
              "Insufficient evidence"
            ],
            "required" : true
          },
          {
            "help" : "The evidence behind it.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "A human decides identity. Never automatic.",
        "key" : "decide",
        "title" : "Confirm or reject (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this record.",
            "key" : "recordName",
            "kind" : "text",
            "label" : "Record name",
            "required" : true
          }
        ],
        "hint" : "Post the reversible identity decision.",
        "key" : "record",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Record the resolution"
      }
    ]
  },
  "siu.loss-chronology" : {
    "purpose" : "Build the loss chronology with relationship links and payment flow, flagging gaps and conflicts.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Date, event, source — one per line.",
            "key" : "events",
            "kind" : "longText",
            "label" : "Events",
            "required" : true
          }
        ],
        "hint" : "From FNOL to now, each event cited.",
        "key" : "events",
        "opens" : "timeline",
        "title" : "Collect dated events"
      },
      {
        "fields" : [
          {
            "help" : "Relationships across the file.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Links"
          }
        ],
        "hint" : "How claimants, providers and prior claims connect.",
        "key" : "links",
        "opens" : "connections",
        "title" : "Order & link parties"
      },
      {
        "fields" : [
          {
            "help" : "Where money moved and when.",
            "key" : "payments",
            "kind" : "longText",
            "label" : "Payment flow"
          }
        ],
        "hint" : "Payments and settlements, dated and cited.",
        "key" : "payments",
        "opens" : "dataLab",
        "title" : "Trace the payment flow"
      },
      {
        "fields" : [
          {
            "help" : "Kept, not averaged.",
            "key" : "gaps",
            "kind" : "longText",
            "label" : "Gaps & conflicts"
          }
        ],
        "hint" : "Missing periods and conflicting dates.",
        "key" : "gaps",
        "opens" : "review",
        "title" : "Flag gaps & conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this chronology.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the cited chronology.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the chronology"
      }
    ]
  },
  "siu.prior-claims" : {
    "purpose" : "Register prior and related claims with cited cells, and note any pattern.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The claims this register spans.",
            "key" : "scope",
            "kind" : "text",
            "label" : "What this covers",
            "required" : true
          }
        ],
        "hint" : "Which prior/related claims to index (attach any not ingested).",
        "key" : "assemble",
        "opens" : "sources",
        "title" : "Assemble the claims"
      },
      {
        "fields" : [
          {
            "help" : "Date, insurer, loss type, amount, outcome — cited.",
            "key" : "columns",
            "kind" : "longText",
            "label" : "Columns & notes"
          }
        ],
        "hint" : "Index each claim.",
        "key" : "register",
        "opens" : "dataLab",
        "title" : "Build the register"
      },
      {
        "fields" : [
          {
            "help" : "What the register reveals — an observation, not a conclusion.",
            "key" : "pattern",
            "kind" : "longText",
            "label" : "Pattern"
          }
        ],
        "hint" : "Repetition or links worth flagging.",
        "key" : "pattern",
        "opens" : "dataLab",
        "title" : "Note the pattern"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the prior-claims register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the register"
      }
    ]
  },
  "siu.recovery-actions" : {
    "purpose" : "Track recovery, referral and follow-up actions to closure.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Which finding/exposure each action responds to.",
            "key" : "links",
            "kind" : "longText",
            "label" : "Action ↔ exposure",
            "required" : true
          }
        ],
        "hint" : "What each action addresses.",
        "key" : "link",
        "opens" : "findings",
        "title" : "Link actions to the exposure"
      },
      {
        "fields" : [
          {
            "help" : "Recovery/referral/follow-up — with owner and due date.",
            "key" : "actions",
            "kind" : "longText",
            "label" : "Actions",
            "required" : true
          }
        ],
        "hint" : "Action, owner, due date, type.",
        "key" : "define",
        "opens" : "handoff",
        "title" : "Define the actions"
      },
      {
        "fields" : [
          {
            "help" : "Confirm owners and dates.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Confirmation",
            "required" : true
          }
        ],
        "hint" : "Confirm each is agreed.",
        "key" : "assign",
        "title" : "Agree owners & dates (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this register.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the register.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the actions register"
      }
    ]
  },
  "siu.red-flags" : {
    "purpose" : "Record fraud indicators with 5W1H and cite what supports each — red flags are indicators, never proof.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One indicator per line.",
            "key" : "indicators",
            "kind" : "longText",
            "label" : "Indicators",
            "required" : true
          }
        ],
        "hint" : "Every red flag observed in the file.",
        "key" : "list",
        "opens" : "findings",
        "title" : "List the indicators"
      },
      {
        "fields" : [
          {
            "help" : "The specifics behind each red flag.",
            "key" : "fiveW",
            "kind" : "longText",
            "label" : "5W1H per indicator"
          }
        ],
        "hint" : "Who/what/when/where/how for each indicator.",
        "key" : "frame",
        "opens" : "matrix",
        "title" : "Frame each (5W1H)"
      },
      {
        "fields" : [
          {
            "help" : "The document behind each indicator.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence per indicator"
          }
        ],
        "hint" : "Tie each indicator to the document that raised it.",
        "key" : "cite",
        "opens" : "findings",
        "title" : "Cite what supports each"
      },
      {
        "fields" : [
          {
            "help" : "Which indicators hold up and what they point to.",
            "key" : "assessment",
            "kind" : "longText",
            "label" : "Assessment",
            "required" : true
          }
        ],
        "hint" : "What the indicators collectively suggest — never conclude fraud here.",
        "key" : "weigh",
        "posts" : "ALG",
        "title" : "Weigh the pattern (your decision)"
      }
    ]
  },
  "siu.referral-report" : {
    "purpose" : "Assemble a referral-ready SIU report: recap, marshal the evidence, assess, recommend — a referral is a recommendation, never a finding of guilt.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "The picture so far.",
            "key" : "recap",
            "kind" : "longText",
            "label" : "Recap",
            "required" : true
          }
        ],
        "hint" : "Claim, scope, and the indicators found.",
        "key" : "recap",
        "opens" : "findings",
        "title" : "Recap the claim & indicators"
      },
      {
        "fields" : [
          {
            "help" : "What the record supports — and what it doesn't.",
            "key" : "evidence",
            "kind" : "longText",
            "label" : "Evidence"
          }
        ],
        "hint" : "Evidence for and against material misrepresentation (attach exhibits).",
        "key" : "marshal",
        "opens" : "findings",
        "title" : "Marshal the evidence"
      },
      {
        "fields" : [
          {
            "help" : "Strengths and gaps.",
            "key" : "assessment",
            "kind" : "longText",
            "label" : "Assessment"
          }
        ],
        "hint" : "What the evidence establishes.",
        "key" : "assess",
        "opens" : "matrix",
        "title" : "Assess the exposure"
      },
      {
        "fields" : [
          {
            "help" : "Your recommendation.",
            "key" : "recommendation",
            "kind" : "choice",
            "label" : "Recommendation",
            "options" : [
              "Refer (SIU/NICB/DOI)",
              "Do not refer",
              "Continue investigation"
            ],
            "required" : true
          },
          {
            "help" : "The basis for the recommendation.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "Recommend a disposition — not a finding of guilt.",
        "key" : "decide",
        "title" : "Recommendation (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this report.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the report with its sealed receipt.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the SIU report"
      }
    ]
  },
  "siu.source-vetting" : {
    "purpose" : "Assess the reliability and independence of statements and documents — a rating is a judgement, not a fact.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "One per line.",
            "key" : "sources",
            "kind" : "longText",
            "label" : "Sources",
            "required" : true
          }
        ],
        "hint" : "Each statement/document to vet.",
        "key" : "list",
        "opens" : "review",
        "title" : "List the sources"
      },
      {
        "fields" : [
          {
            "help" : "What strengthens or weakens each.",
            "key" : "factors",
            "kind" : "longText",
            "label" : "Factors"
          },
          {
            "help" : "High / Medium / Low — a judgement.",
            "key" : "rating",
            "kind" : "longText",
            "label" : "Reliability rating"
          }
        ],
        "hint" : "Consistency, corroboration, bias, provenance.",
        "key" : "assess",
        "opens" : "review",
        "title" : "Assess each"
      },
      {
        "fields" : [
          {
            "help" : "Confirm the ratings, noting they're judgements.",
            "key" : "basis",
            "kind" : "longText",
            "label" : "Basis",
            "required" : true
          }
        ],
        "hint" : "These are your judgements.",
        "key" : "decide",
        "title" : "Own the ratings (your decision)"
      },
      {
        "fields" : [
          {
            "help" : "Name this assessment.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the vetting.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the assessment"
      }
    ]
  },
  "siu.statements" : {
    "purpose" : "Compare statements point by point, preserving conflicting accounts rather than averaging them.",
    "steps" : [
      {
        "fields" : [
          {
            "help" : "Each account.",
            "key" : "accounts",
            "kind" : "longText",
            "label" : "Statements",
            "required" : true
          }
        ],
        "hint" : "Each statement, attributed and cited (attach recordings/notes).",
        "key" : "collect",
        "opens" : "findings",
        "title" : "Collect the statements"
      },
      {
        "fields" : [
          {
            "help" : "Both sides preserved.",
            "key" : "comparison",
            "kind" : "longText",
            "label" : "Agreement & conflict"
          }
        ],
        "hint" : "On each disputed point.",
        "key" : "compare",
        "opens" : "matrix",
        "title" : "Compare point by point"
      },
      {
        "fields" : [
          {
            "help" : "Never averaged.",
            "key" : "conflicts",
            "kind" : "longText",
            "label" : "Open conflicts"
          }
        ],
        "hint" : "Conflicts left open.",
        "key" : "conflicts",
        "opens" : "review",
        "title" : "Record unresolved conflicts"
      },
      {
        "fields" : [
          {
            "help" : "Name this comparison.",
            "key" : "title",
            "kind" : "text",
            "label" : "Title",
            "required" : true
          }
        ],
        "hint" : "Assemble the comparison.",
        "key" : "produce",
        "opens" : "handoff",
        "posts" : "RPT",
        "title" : "Produce the comparison"
      }
    ]
  }
}
"""##
}
