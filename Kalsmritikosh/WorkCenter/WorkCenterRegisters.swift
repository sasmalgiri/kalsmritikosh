//
//  WorkCenterRegisters.swift
//  Kalsmritikosh
//
//  REGISTERS (owner request 2026-08-20) — the day-to-day, human-input,
//  editable-with-history tools that persona research surfaced as recurring
//  gaps across multiple professions:
//
//   • Interview / Statement Log (INT) — PI, SIU, HR, Journalist. Who was
//     spoken to, what was asked, what they said, whether the account stayed
//     consistent (the SIU "story that keeps changing" signal), and what to
//     re-interview about (the HR complainant→accused→witness→re-interview
//     sequence). Recorded-statement / examination-under-oath modes included.
//   • Records Request Tracker (REQ) — Journalist FOIA, PI records requests,
//     Genealogist vital records. The lifecycle drafted → sent → due → received
//     → appealed, with the statutory deadline to chase. Requests are kept
//     SPECIFIC (the FOIA best practice: broad "all records related to…" invites
//     delay and denial).
//   • Research Log (LOG) — Genealogist, Historian. Every source searched, the
//     terms used (so the search is repeatable), and the result INCLUDING
//     negatives — because the Genealogical Proof Standard's "reasonably
//     exhaustive" element counts a documented negative search as evidence.
//
//  Unlike a WorkCenterEngine recipe (an ordered, gated, confirm-once workflow),
//  a register is a COLLECTION of same-shape records that stay EDITABLE. Each
//  record is a numbered work_center_documents row (INT/REQ/LOG); edits are
//  sealed into work_center_record_edits (migration v106) so an amended record
//  still shows who-changed-what-when. This file is PURE model + schema (no
//  store, no UI) — the same layering discipline as WorkCenterEngine.
//

import Foundation

// MARK: - Register template

/// A repeating-record tool: a named kind of editable record with a typed field
/// schema. Records post as numbered documents of `docType` and are edited in
/// place (with the change sealed to the edit log). Any persona may use any
/// register; `persona` is informational, like WCWorkflowDefinition.persona.
public nonisolated struct WCRegister: Identifiable, Equatable, Sendable {
    /// The document-type code records of this register carry (INT/REQ/LOG).
    public let docType: String
    public let name: String
    /// Personas this register was shaped for (informational).
    public let persona: String
    /// One-line purpose for the catalog card.
    public let purpose: String
    /// The record's typed fields (reuses the workflow engine's WCField).
    public let fields: [WCField]
    /// The field whose value titles the record in lists (falls back to the
    /// first required field, then the first field).
    public let titleKey: String
    /// Optional field key whose choice value is shown as the record's status
    /// chip (e.g. a request's lifecycle). nil = no status chip.
    public let statusKey: String?

    public var id: String { docType }

    /// Required fields missing from a candidate value map (reuses the pure
    /// workflow validator so registers and workflows agree on "required").
    public func missingRequired(_ values: [String: String]) -> [String] {
        WCFieldValidation.missingRequired(fields, values: values)
    }

    /// The record title for a value map: the titleKey value, else the first
    /// non-empty required/first field, else a generic label.
    public func title(for values: [String: String]) -> String {
        if let t = values[titleKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        for field in fields where !(values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return values[field.key] ?? name
        }
        return name
    }
}

// MARK: - The catalog — three registers, grounded in the persona research

public nonisolated enum WCRegisterCatalog {

    public static var all: [WCRegister] { [interviewLog, requestTracker, researchLog, contentCalendar] }

    public static func register(_ docType: String) -> WCRegister? {
        all.first { $0.docType == docType }
    }

    /// True for doc-type codes that are editable register records (as opposed
    /// to confirm-once workflow/step documents).
    public static func isRegisterType(_ docType: String) -> Bool {
        all.contains { $0.docType == docType }
    }

    private static func f(_ key: String, _ label: String, _ kind: WCField.Kind, _ help: String,
                          placeholder: String = "", required: Bool = false,
                          options: [String] = []) -> WCField {
        WCField(key: key, label: label, kind: kind, help: help,
                placeholder: placeholder, required: required, options: options)
    }

    // Interview / Statement Log — PI, SIU, HR, Journalist.
    public static let interviewLog = WCRegister(
        docType: "INT", name: "Interview & Statement Log",
        persona: "Investigator / SIU / Compliance / Journalist",
        purpose: "Log every person you speak with — what you asked, what they said, whether the account held together, and what to follow up. Each entry is editable and keeps its change history.",
        fields: [
            f("interviewee", "Person interviewed", .text,
              "Who you spoke with — the name that goes on the record.",
              placeholder: "Full name", required: true),
            f("role", "Their role", .choice,
              "How this person relates to the matter — sets how their account is weighed.",
              options: ["Complainant", "Accused / Subject", "Witness", "Claimant", "Source", "Expert", "Other"]),
            f("mode", "How it was taken", .choice,
              "The form of the interview — a recorded statement or examination under oath carries more weight than a hallway chat.",
              options: ["In person", "Phone", "Video call", "Recorded statement", "Examination under oath", "Written response"]),
            f("date", "Date", .date,
              "When the interview happened — anchors the account in time."),
            f("location", "Location / channel", .text,
              "Where it took place — office, site, or the platform used.",
              placeholder: "Conference room / Zoom"),
            f("questionsAsked", "Questions put", .longText,
              "The questions you actually asked — kept so the record shows what was, and wasn't, covered."),
            f("account", "Their account", .longText,
              "What they said, in their words or your contemporaneous summary — the substance of the statement.",
              required: true),
            f("consistency", "Account consistency", .choice,
              "Whether this account holds together with what's already on file — a story that keeps changing is itself a finding.",
              options: ["Consistent", "Minor discrepancies", "Account changed", "Not yet compared"]),
            f("followUp", "Follow-up / to verify", .longText,
              "What still needs checking or a second interview — the thread to pull next."),
        ],
        titleKey: "interviewee", statusKey: "consistency")

    // Records Request Tracker — Journalist FOIA, PI records, Genealogist vitals.
    public static let requestTracker = WCRegister(
        docType: "REQ", name: "Records Request Tracker",
        persona: "Journalist / Investigator / Genealogist",
        purpose: "Track every records request from draft to fulfilment or appeal — recipient, what you asked, the deadline to chase, and how it came back. Editable as the request moves.",
        fields: [
            f("recipient", "Sent to", .text,
              "The agency, court, or custodian you asked.",
              placeholder: "City Clerk / State Archives", required: true),
            f("subject", "What you requested", .text,
              "Keep it specific — a narrow request returns faster and fuller; broad “all records related to…” invites delay and denial.",
              placeholder: "Permit inspection reports, 123 Main St, 2024–2025", required: true),
            f("requestType", "Request type", .choice,
              "The kind of request — sets the rules and deadlines that apply.",
              options: ["FOIA / public records", "Subpoena", "Records request", "Vital records", "Court records", "Other"]),
            f("status", "Status", .choice,
              "Where the request stands right now — update it as things move.",
              options: ["Drafted", "Sent", "Acknowledged", "Partially fulfilled", "Fulfilled", "Denied", "Appealed"]),
            f("sentOn", "Sent on", .date,
              "The date you filed it — starts the clock."),
            f("dueOn", "Response due", .date,
              "The statutory deadline to chase — when to follow up if you've heard nothing."),
            f("reference", "Tracking / reference no.", .text,
              "Their reference number, so a follow-up cites the right file.",
              placeholder: "FOIA-2026-0451"),
            f("outcome", "Outcome", .longText,
              "What came back — records received, a partial release, or the basis they gave for a denial."),
            f("nextAction", "Next action", .longText,
              "What to do next — narrow and refile, appeal a denial, or mark it closed."),
        ],
        titleKey: "recipient", statusKey: "status")

    // Research Log — Genealogist, Historian (GPS "reasonably exhaustive").
    public static let researchLog = WCRegister(
        docType: "LOG", name: "Research Log",
        persona: "Genealogist / Researcher / Historian",
        purpose: "Log every source you search — the terms used and the result, including the ones that turned up nothing. Documented negative searches are what make a search “reasonably exhaustive.”",
        fields: [
            f("objective", "Research objective", .text,
              "The question this search was meant to answer — keeps the log tied to a goal.",
              placeholder: "Find John Doe's birth record, c.1880", required: true),
            f("sourceSearched", "Source searched", .text,
              "The repository, collection, database, or record set you looked in.",
              placeholder: "1880 US Census, Ohio", required: true),
            f("searchTerms", "Search terms / strategy", .text,
              "The names, dates, and terms you used — so the search can be repeated or refined.",
              placeholder: "Doe, John; b.1878–1882; Franklin Co."),
            f("date", "Date searched", .date,
              "When you ran this search."),
            f("result", "Result", .choice,
              "What the search yielded — a documented NEGATIVE result counts as evidence of a thorough search.",
              options: ["Positive — record found", "Negative — nothing found", "Partial — possible match", "Inconclusive"]),
            f("citation", "Source citation", .longText,
              "The full citation for the source (Evidence Explained style) — recorded as you go, not at the end."),
            f("findingsNote", "What it yielded", .longText,
              "What the source showed and how it correlates with — or conflicts with — what you already have."),
            f("nextStep", "Next source to try", .text,
              "The next place to look — turns the log into a plan.",
              placeholder: "Check county birth index"),
        ],
        titleKey: "objective", statusKey: "result")

    // Editorial / Content Calendar — Content Creator (and anyone running a
    // publishing pipeline). The stages a piece moves through from idea to
    // published, with the platform, publish date, angle, and the sources it
    // rests on — editable as the piece progresses, each change kept.
    public static let contentCalendar = WCRegister(
        docType: "CAL", name: "Content Calendar",
        persona: "Content Creator",
        purpose: "Plan and track each piece from idea to published — its stage, platform, publish date, angle, and the sources it rests on. Editable as the piece moves, with the full change history kept.",
        fields: [
            f("workingTitle", "Working title", .text,
              "What you're calling this piece for now — it can change before publish.",
              placeholder: "Why the permit was denied — explained", required: true),
            f("format", "Format", .choice,
              "The kind of piece — sets how much research and production it needs.",
              options: ["Video", "Short / Reel", "Podcast episode", "Article / blog", "Newsletter", "Social post", "Livestream"]),
            f("stage", "Stage", .choice,
              "Where this piece is in the pipeline right now — move it forward as you go.",
              options: ["Idea", "Researching", "Scripting / drafting", "Editing", "Scheduled", "Published", "Shelved"]),
            f("platform", "Platform / channel", .text,
              "Where it will go out — the channel or publication.",
              placeholder: "YouTube / Substack"),
            f("publishDate", "Target / publish date", .date,
              "When it's slated to go out — the date the calendar sorts and reminds on."),
            f("angle", "Angle / hook", .longText,
              "The thesis or hook — what this piece says and why it's worth the audience's time."),
            f("sourcesNote", "Sources & rights", .longText,
              "The key sources this piece rests on and whether clips or quotes are cleared to use — so rights aren't a last-minute scramble."),
            f("nextAction", "Next action", .text,
              "The next concrete step to move it forward.",
              placeholder: "Record the interview"),
        ],
        titleKey: "workingTitle", statusKey: "stage")
}
