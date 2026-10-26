//
//  CaseFileDocuments.swift
//  Kalsmritikosh
//
//  The documents a case file produces (E-1 exhibit list, E-2 custody report, E-3 hold notice,
//  E-4 redaction log, P-2 statement for signature, S-2 person-data export, and the whole case file).
//  Pure functions over a snapshot, so what is exported is exactly what was read. Every document
//  says who produced it and when; nothing in them is a finding the investigator did not record.
//

import Foundation

/// Everything in one case file, read once.
public nonisolated struct CaseFileSnapshot: Sendable {
    public let caseHeader: InvestigationCase
    public let profile: CaseProfile
    public let allegations: [CaseAllegation]
    public let grid: [AllegationEvidence]
    public let tasks: [CaseTaskItem]
    public let journal: [CaseJournalEntry]
    public let people: [CasePerson]
    public let contacts: [CaseContact]
    public let interviews: [CaseInterview]
    public let credibility: [CredibilityNote]
    public let exhibits: [CaseExhibit]
    public let holds: [CaseHoldNotice]
    public let redactions: [CaseRedaction]
    public let batches: [CaseReviewBatch]
    public let conflicts: [CaseConflictCheck]
    public let actions: [CaseAction]
    public let custody: [CustodyManifestEntry]
    public let addenda: [StatementAddendum]

    public init(caseHeader: InvestigationCase, profile: CaseProfile, allegations: [CaseAllegation], grid: [AllegationEvidence],
                tasks: [CaseTaskItem], journal: [CaseJournalEntry], people: [CasePerson], contacts: [CaseContact],
                interviews: [CaseInterview], credibility: [CredibilityNote], exhibits: [CaseExhibit], holds: [CaseHoldNotice],
                redactions: [CaseRedaction], batches: [CaseReviewBatch], conflicts: [CaseConflictCheck], actions: [CaseAction],
                custody: [CustodyManifestEntry], addenda: [StatementAddendum] = []) {
        self.caseHeader = caseHeader; self.profile = profile; self.allegations = allegations; self.grid = grid; self.tasks = tasks
        self.journal = journal; self.people = people; self.contacts = contacts; self.interviews = interviews
        self.credibility = credibility; self.exhibits = exhibits; self.holds = holds; self.redactions = redactions
        self.batches = batches; self.conflicts = conflicts; self.actions = actions; self.custody = custody
        self.addenda = addenda
    }

    public func person(_ id: UUID?) -> CasePerson? { id.flatMap { pid in people.first { $0.id == pid } } }
}

extension CaseFileService {
    /// Read the whole case file (custody manifest passed in — it comes from the custody service).
    public func snapshot(caseID: UUID, custody: [CustodyManifestEntry]) async throws -> CaseFileSnapshot? {
        guard let header = try await caseHeader(caseID) else { return nil }
        return CaseFileSnapshot(
            caseHeader: header, profile: try await file.profile(caseID: caseID), allegations: try await file.allegations(caseID: caseID),
            grid: try await file.allegationEvidence(caseID: caseID), tasks: try await caseTasks(caseID: caseID),
            journal: try await file.journal(caseID: caseID), people: try await file.people(caseID: caseID),
            contacts: try await file.contacts(caseID: caseID), interviews: try await file.interviews(caseID: caseID),
            credibility: try await file.credibility(caseID: caseID), exhibits: try await file.exhibits(caseID: caseID, includeWithdrawn: true),
            holds: try await file.holdNotices(caseID: caseID), redactions: try await file.redactions(caseID: caseID),
            batches: try await file.reviewBatches(caseID: caseID), conflicts: try await file.conflictChecks(caseID: caseID),
            actions: try await file.actions(caseID: caseID), custody: custody, addenda: try await file.addenda(caseID: caseID))
    }
}

public nonisolated enum CaseFileDocuments {

    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    static func d(_ date: Date?) -> String { date.map { day.string(from: $0) } ?? "—" }
    static func t(_ date: Date?) -> String { date.map { stamp.string(from: $0) } ?? "—" }

    static func footer(_ by: String, _ at: Date) -> String {
        "\n---\nProduced by \(by) with Investigations Made Easy on \(t(at)). The investigator's record; judgement stays with the investigator.\n"
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    // MARK: E-1 exhibit list

    public static func exhibitListCSV(_ s: CaseFileSnapshot) -> String {
        csv([["Exhibit", "Description", "Source", "SHA-256", "Collected by", "Collected on", "Collected where", "Registered", "Status"]] +
            s.exhibits.map { e in
                [e.number, e.description, e.sourceRef ?? "", e.sha256 ?? "", e.collectedBy ?? "", d(e.collectedAt), e.collectedWhere ?? "",
                 t(e.createdAt), e.withdrawnAt == nil ? "Current" : "Withdrawn \(d(e.withdrawnAt))"]
            })
    }

    // MARK: E-2 custody report

    public static func custodyReport(_ s: CaseFileSnapshot, by: String, at: Date = Date()) -> String {
        var out = "# Chain of custody — \(s.caseHeader.title)\n\nCase opened \(d(s.caseHeader.createdAt)). \(s.custody.count) source(s) in scope.\n\n"
        for (i, e) in s.custody.enumerated() {
            let exhibit = s.exhibits.first { $0.sourceRef == e.sourceVersionID.uuidString }
            out += "## \(i + 1). \(exhibit.map { "\($0.number) — \($0.description)" } ?? "Source \(e.sourceVersionID.uuidString)")\n\n"
            out += "- Content SHA-256: `\(e.contentHash ?? "not recorded")`\n"
            if e.custodyEvents.isEmpty { out += "- No custody events recorded.\n" }
            for ev in e.custodyEvents.sorted(by: { $0.at < $1.at }) {
                out += "- \(t(ev.at)) · \(ev.kind.displayName) · \(ev.actor)" + (ev.detail.map { " · \($0)" } ?? "") + (ev.hash.map { " · `\($0)`" } ?? "") + "\n"
            }
            out += "\n"
        }
        return out + footer(by, at)
    }

    // MARK: E-3 hold notice

    public static func holdNoticeTemplate(caseTitle: String, custodian: String, organisation: String?, issuer: String, at: Date = Date()) -> String {
        """
        PRESERVATION NOTICE — PLEASE READ AND ACKNOWLEDGE

        To: \(custodian)
        From: \(issuer)\(organisation.map { ", \($0)" } ?? "")
        Date: \(d(at))
        Matter: \(caseTitle)

        You may hold documents or data relevant to the matter above. Until you are told in writing that this notice is released, please:

        1. Keep — do not delete, alter, overwrite or discard — any email, chat message, file, note, recording, device or paper record that may relate to the matter, wherever it is stored (work and personal devices, cloud accounts, paper files).
        2. Suspend any automatic deletion that could affect such material, or tell us so we can do it.
        3. Do not discuss the matter with anyone involved in it.

        Please reply to confirm you have read and will follow this notice. Questions to \(issuer).
        """
    }

    // MARK: E-4 redaction log

    public static func redactionLogCSV(_ s: CaseFileSnapshot) -> String {
        csv([["Document", "Where", "Reason", "Redacted by", "When"]] +
            s.redactions.map { [$0.sourceRef, $0.location, $0.reason, $0.redactedBy, t($0.at)] })
    }

    // MARK: P-2 statement for signature

    public static func statement(_ s: CaseFileSnapshot, interview: CaseInterview, by: String, at: Date = Date()) -> String {
        let who = s.person(interview.personID)?.name ?? "the interviewee"
        var out = "# Statement of \(who)\n\nMatter: \(s.caseHeader.title)\nInterview: \(t(interview.scheduledAt))" +
            (interview.location.map { " · \($0)" } ?? "") + (interview.mode.map { " · \($0)" } ?? "") + "\n\n"
        out += (interview.statementText ?? "(no statement recorded)") + "\n\n"
        if let attested = interview.attestedAt {
            out += "Confirmed as true and complete by \(interview.attestedBy ?? who) on \(t(attested)).\n"
            out += "Statement fingerprint (SHA-256): `\(interview.statementSHA256 ?? "")`" + (interview.statementIntact ? "" : " — **the text no longer matches the attested fingerprint**") + "\n"
        } else {
            out += "I have read this statement and it is true and complete to the best of my knowledge.\n\nSigned: ______________________   Date: ____________\n"
        }
        // Corrections follow the confirmed statement, in order; the statement itself is never edited.
        for (n, a) in s.addenda.filter({ $0.interviewID == interview.id }).enumerated() {
            out += "\n## Correction \(n + 1) — recorded \(t(a.recordedAt)) by \(a.recordedBy)\n\nReason: \(a.reason)\n\n\(a.text)\n\n"
            out += a.confirmedAt.map { "Confirmed by \(a.confirmedBy ?? who) on \(t($0)).\n" } ?? "Not yet confirmed by the interviewee.\n"
            out += "Correction fingerprint (SHA-256): `\(a.sha256)`" + (a.intact ? "" : " — **the text no longer matches its fingerprint**") + "\n"
        }
        return out + footer(by, at)
    }

    // MARK: S-2 person-data export

    /// Everything the case file holds about one named person (for a data-subject request): their
    /// person rows, contact log, interviews and statements, credibility notes, hold notices, and
    /// journal / chronology entries that name them. Documents in the case are listed separately by
    /// the existing person dossier; this covers the investigator's own record.
    public static func personDataExport(_ s: CaseFileSnapshot, name: String, by: String, at: Date = Date()) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = s.people.filter { $0.name.lowercased() == key }
        let ids = Set(rows.map(\.id))
        var out = "# Personal data held about \(name)\n\nCase: \(s.caseHeader.title)\n\n## Recorded as\n"
        out += rows.isEmpty ? "- Not recorded as a person in this case.\n" : rows.map { "- \($0.role.label)" + ($0.contact.map { " · contact: \($0)" } ?? "") + ($0.notes.map { " · notes: \($0)" } ?? "") }.joined(separator: "\n") + "\n"
        let contacts = s.contacts.filter { ids.contains($0.personID) }
        if !contacts.isEmpty { out += "\n## Contact log\n" + contacts.map { "- \(t($0.at)) · \($0.mode)" + ($0.note.map { " · \($0)" } ?? "") }.joined(separator: "\n") + "\n" }
        let ivs = s.interviews.filter { $0.personID.map(ids.contains) ?? false }
        for iv in ivs {
            out += "\n## Interview \(t(iv.scheduledAt)) (\(iv.status.label))\n"
            if let sum = iv.summary { out += "\nSummary: \(sum)\n" }
            if let st = iv.statementText { out += "\nStatement:\n\n\(st)\n" }
            let cred = s.credibility.filter { $0.interviewID == iv.id }
            if !cred.isEmpty { out += "\nCredibility notes:\n" + cred.map { "- \($0.factor.label): \($0.assessment.label)" + ($0.note.map { " — \($0)" } ?? "") }.joined(separator: "\n") + "\n" }
        }
        let holds = s.holds.filter { $0.custodian.lowercased() == key || ($0.personID.map(ids.contains) ?? false) }
        if !holds.isEmpty { out += "\n## Preservation notices\n" + holds.map { "- Issued \(d($0.issuedAt))" + ($0.acknowledgedAt.map { ", acknowledged \(d($0))" } ?? "") + ($0.releasedAt.map { ", released \(d($0))" } ?? "") }.joined(separator: "\n") + "\n" }
        let mentions = s.journal.filter { !key.isEmpty && $0.text.lowercased().contains(key) }
        if !mentions.isEmpty { out += "\n## Journal and chronology entries naming them\n" + mentions.map { "- \(d($0.eventDate ?? $0.createdAt)): \($0.text)" }.joined(separator: "\n") + "\n" }
        if s.profile.intake.complainant?.lowercased() == key { out += "\n## Intake\n- Recorded as the complainant.\n" }
        return out + footer(by, at)
    }

    // MARK: The whole case file

    public static func caseFileReport(_ s: CaseFileSnapshot, named: StudioCaseFacts? = nil, by: String, at: Date = Date()) -> String {
        let p = s.profile, c = s.caseHeader
        var o = "# \(c.title)\n\n"
        o += "Stage: **\(c.status == .closed ? CaseStage.closed.label : p.stage.label)**"
        o += p.triage.severity.map { " · Severity: \($0.label)" } ?? ""
        o += p.owner.map { " · Owner: \($0)" } ?? ""
        o += p.team.isEmpty ? "" : " · Team: \(p.team.joined(separator: ", "))"
        o += p.reviewer.map { " · Reviewer: \($0)" } ?? ""
        o += "\nOpened \(d(c.createdAt))" + (CaseTemplate.template(id: p.kind).map { " · \($0.title)" } ?? "") + "\n\n"

        o += "## Intake\n"
        let i = p.intake
        o += "- Received: \(d(i.receivedAt))" + (i.channel.map { " via \($0.label)" } ?? "") + "\n"
        o += "- Complainant: " + (i.anonymous ? "anonymous (no identity stored)" : (i.complainant ?? "—")) + "\n"
        if let a = i.allegationSummary { o += "- What was reported: \(a)\n" }
        if let x = i.incidentDate { o += "- When: \(x)\n" }
        if let x = i.incidentLocation { o += "- Where: \(x)\n" }
        if let x = i.peopleNamed { o += "- People named: \(x)\n" }
        if let t = p.triage.decision {
            o += "\n## Triage\n- Decision: \(t.label) by \(p.triage.decidedBy ?? "—") on \(d(p.triage.decidedAt))" + (p.triage.reason.map { " — \($0)" } ?? "") + "\n"
            if let r = p.triage.riskNote { o += "- Risk: \(r)\n" }
        }

        o += "\n## Scope and plan\n"
        if let x = c.purpose { o += "- Purpose: \(x)\n" }
        if let x = c.scopeStatement { o += "- In scope: \(x)\n" }
        if let x = c.outOfScopeStatement { o += "- Out of scope: \(x)\n" }
        if let x = p.plan.method { o += "- Method: \(x)\n" }
        if let x = p.plan.evidenceToCollect { o += "- Evidence to collect: \(x)\n" }
        if let x = p.plan.interviewsToHold { o += "- Interviews: \(x)\n" }
        if let x = p.plan.notes { o += "- Notes: \(x)\n" }

        o += "\n## Allegations and findings\n"
        if s.allegations.isEmpty { o += "No allegations recorded.\n" }
        for a in s.allegations {
            o += "\n### \(a.label). \(a.text)\n\n**\(a.disposition.label)**" + (a.decidedBy.map { " — decided by \($0) on \(d(a.decidedAt))" } ?? "") + "\n"
            if let r = a.rationale { o += "\n\(r)\n" }
            let ev = s.grid.filter { $0.allegationID == a.id }
            for st in GridStance.allCases {
                let items = ev.filter { $0.stance == st }
                guard !items.isEmpty else { continue }
                o += "\n\(st.label):\n" + items.map { "- \($0.label ?? $0.evidenceRef)" + ($0.note.map { " — \($0)" } ?? "") + " [\($0.evidenceRef)]" }.joined(separator: "\n") + "\n"
            }
        }

        let chron = s.journal.filter { $0.kind == .chronology }
        if !chron.isEmpty {
            o += "\n## Chronology (investigator entries)\n" + chron.map { "- \(d($0.eventDate)): \($0.text)" + ($0.evidenceRef.map { " [\($0)]" } ?? "") }.joined(separator: "\n") + "\n"
        }

        if let named { o += namedInDocuments(named) }
        if !s.people.isEmpty {
            o += "\n## People\n" + s.people.map { "- \($0.name) — \($0.role.label)" }.joined(separator: "\n") + "\n"
        }
        if !s.interviews.isEmpty {
            o += "\n## Interviews\n"
            for iv in s.interviews {
                o += "- \(s.person(iv.personID)?.name ?? "—") · \(t(iv.scheduledAt)) · \(iv.status.label)" +
                    (iv.attestedAt.map { " · statement attested \(d($0))" + (iv.statementIntact ? "" : " (TEXT CHANGED SINCE ATTESTATION)") } ?? "") + "\n"
                if let sum = iv.summary { o += "  - Summary: \(sum)\n" }
                for cr in s.credibility.filter({ $0.interviewID == iv.id }) {
                    o += "  - \(cr.factor.label): \(cr.assessment.label)" + (cr.note.map { " — \($0)" } ?? "") + "\n"
                }
            }
        }
        let current = s.exhibits.filter { $0.withdrawnAt == nil }
        if !current.isEmpty {
            o += "\n## Exhibits\n" + current.map { "- \($0.number): \($0.description)" + ($0.sha256.map { " · SHA-256 `\($0.prefix(16))…`" } ?? "") }.joined(separator: "\n") + "\n"
        }
        if !s.holds.isEmpty {
            o += "\n## Preservation notices\n" + s.holds.map { "- \($0.custodian): issued \(d($0.issuedAt))" + ($0.acknowledgedAt.map { ", acknowledged \(d($0))" } ?? ", not yet acknowledged") + ($0.releasedAt.map { ", released \(d($0))" } ?? "") }.joined(separator: "\n") + "\n"
        }
        if !s.tasks.isEmpty {
            o += "\n## Tasks\n" + s.tasks.map { "- [\($0.task.status == .completed ? "x" : " ")] \($0.task.title)" + ($0.deadline.map { " — due \(d($0.value.date))" } ?? "") + ($0.task.owner.map { " — \($0)" } ?? "") }.joined(separator: "\n") + "\n"
        }
        if !s.conflicts.isEmpty {
            o += "\n## Conflict-of-interest checks\n" + s.conflicts.map { "- \($0.investigator): \($0.result.rawValue)" + ($0.matched.map { " (matched \($0))" } ?? "") + ($0.note.map { " — \($0)" } ?? "") + " · \(d($0.checkedAt))" }.joined(separator: "\n") + "\n"
        }
        if !s.redactions.isEmpty { o += "\n## Redactions\n\(s.redactions.count) redaction(s) logged — see the redaction log.\n" }
        if let r = p.retentionPolicy { o += "\n## Retention\n- \(r)" + (p.retainUntil.map { " · review on \(d($0))" } ?? "") + "\n" }
        o += "\n## Case log\n\(s.actions.count) recorded action(s); first \(t(s.actions.first?.at)), last \(t(s.actions.last?.at)).\n"
        return o + footer(by, at)
    }

    // MARK: Named in the documents

    /// Who the case documents name and the amounts they state, each with its sentence — the same
    /// digest the studios print. Listed for the investigator; no role or finding is assigned.
    public static func namedInDocuments(_ facts: StudioCaseFacts) -> String {
        var p: StudioProvenance = [:]
        StudioPrefill.recordSourceDigest(from: facts, into: &p)
        return StudioExportGate.sourceDigest(p)
    }

    // MARK: S-4 action log

    public static func actionLogCSV(_ s: CaseFileSnapshot) -> String {
        csv([["#", "When", "Who", "Action", "Detail"]] + s.actions.map { [String($0.sequence), t($0.at), $0.actor, $0.action, $0.detail ?? ""] })
    }
}
