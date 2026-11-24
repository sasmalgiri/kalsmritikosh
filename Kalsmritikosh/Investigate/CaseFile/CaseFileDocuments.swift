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
                custody: [CustodyManifestEntry], addenda: [StatementAddendum] = [], reportItems: [CaseReportItem] = [],
                supersededOrigins: Set<String> = [], attestations: [CaseFactAttestation] = []) {
        self.caseHeader = caseHeader; self.profile = profile; self.allegations = allegations; self.grid = grid; self.tasks = tasks
        self.journal = journal; self.people = people; self.contacts = contacts; self.interviews = interviews
        self.credibility = credibility; self.exhibits = exhibits; self.holds = holds; self.redactions = redactions
        self.batches = batches; self.conflicts = conflicts; self.actions = actions; self.custody = custody
        self.addenda = addenda; self.reportItems = reportItems; self.supersededOrigins = supersededOrigins
        self.attestations = attestations
    }
    /// N3 — every person's verified mark / withdrawal on the case's chronology entries, oldest first.
    public let attestations: [CaseFactAttestation]
    /// I5 — the final report's explicit selection (included and excluded items with reasons).
    public let reportItems: [CaseReportItem]
    /// §3 — origins (carried rows) whose result revision is no longer the job's current one.
    public let supersededOrigins: Set<String>
    public func isSuperseded(_ origin: String?) -> Bool { origin.map { supersededOrigins.contains($0) } ?? false }
    /// Ease fixes B — the cited documents' names and places, read by the output door before the report is rendered, so
    /// each citation reads "document, p. 4". Empty: citations name no document and say the page is not recorded.
    public var citationPlaces = CaseCitationPlaces()

    /// Every cited version, record and passage of the snapshot (what the output door reads places for).
    public var citedIDs: (versions: Set<UUID>, objects: Set<UUID>, blocks: Set<UUID>) {
        var v = Set<UUID>(), o = Set<UUID>(), b = Set<UUID>()
        func add(_ r: StudioEvidenceRef) {
            if let x = r.sourceVersionID { v.insert(x) }
            if let x = r.objectID { o.insert(x) }
            if let x = r.blockID { b.insert(x) }
        }
        for e in grid {
            if let x = UUID(uuidString: e.evidenceRef) { v.insert(x) }
            if let x = e.blockID { b.insert(x) }
            if let x = e.objectID { o.insert(x) }
            if let p = e.passage { add(p) }
        }
        for e in journal {
            if let x = e.evidenceRef.flatMap(UUID.init(uuidString:)) { v.insert(x) }
            e.citations.forEach(add)
        }
        for i in reportItems {
            if let x = i.evidenceRef.flatMap(UUID.init(uuidString:)) { v.insert(x) }
            i.citations.forEach(add)
        }
        for c in custody { v.insert(c.sourceVersionID) }
        return (v, o, b)
    }

    public func person(_ id: UUID?) -> CasePerson? { id.flatMap { pid in people.first { $0.id == pid } } }
}

extension CaseFileService {
    /// Read the whole case file (custody manifest passed in — it comes from the custody service).
    public func snapshot(caseID: UUID, custody: [CustodyManifestEntry]) async throws -> CaseFileSnapshot? {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        return try await snapshot(caseID: caseID, custody: custody, journal: nil, forMap: false)
    }

    /// The case file as the case map reads it (M9 §13.3): `journal`, when given, is the case's journal as read by
    /// the caller (the map reads it incrementally); `forMap` leaves out what the map does not show — the contact
    /// log, credibility notes, hold notices, redactions, review batches, conflict checks and the action log —
    /// as empty lists. Every other part is read exactly as `snapshot(caseID:custody:)` reads it.
    public func snapshot(caseID: UUID, custody: [CustodyManifestEntry], journal given: [CaseJournalEntry]?,
                         forMap: Bool) async throws -> CaseFileSnapshot? {
        try await CaseAccessPolicy.requireRead(file.database, caseID: caseID)
        guard let header = try await caseHeader(caseID) else { return nil }
        let grid = try await file.allegationEvidence(caseID: caseID)
        let journal: [CaseJournalEntry]
        if let given { journal = given } else { journal = try await file.journal(caseID: caseID) }
        let items = try await file.reportItems(caseID: caseID)
        // §3 — a carried row whose result revision is no longer the job's current one is superseded:
        // the report says so and asks for re-review instead of silently showing the old revision as current.
        var superseded = Set<String>()
        let origins = Set((grid.compactMap(\.origin) + journal.compactMap(\.origin) + items.compactMap(\.origin)))
        if !origins.isEmpty {
            var latestByJob: [String: UUID?] = [:]
            for origin in origins {
                guard let job = JobResultHandoff.jobID(in: origin), let resultID = JobResultHandoff.resultID(in: origin) else { continue }
                if latestByJob[job] == nil { latestByJob[job] = try await results.latest(caseID: caseID, jobID: job)?.id }
                if latestByJob[job] ?? nil != resultID { superseded.insert(origin) }
            }
        }
        return CaseFileSnapshot(
            caseHeader: header, profile: try await file.profile(caseID: caseID), allegations: try await file.allegations(caseID: caseID),
            grid: grid, tasks: try await caseTasks(caseID: caseID),
            journal: journal, people: try await file.people(caseID: caseID),
            contacts: forMap ? [] : try await file.contacts(caseID: caseID), interviews: try await file.interviews(caseID: caseID),
            credibility: forMap ? [] : try await file.credibility(caseID: caseID), exhibits: try await file.exhibits(caseID: caseID, includeWithdrawn: true),
            holds: forMap ? [] : try await file.holdNotices(caseID: caseID), redactions: forMap ? [] : try await file.redactions(caseID: caseID),
            batches: forMap ? [] : try await file.reviewBatches(caseID: caseID), conflicts: forMap ? [] : try await file.conflictChecks(caseID: caseID),
            actions: forMap ? [] : try await file.actions(caseID: caseID), custody: custody, addenda: try await file.addenda(caseID: caseID),
            reportItems: items, supersededOrigins: superseded, attestations: try await file.attestations(caseID: caseID))
    }
}

public nonisolated enum CaseFileDocuments {

    /// ALCOA ALC-19 — the one export date style: a day as "3 Aug 2026", a time as ISO 8601 with the zone stated.
    static func d(_ date: Date?) -> String { ExportDateStyle.day(date) }
    /// S5 (TIME-02) — a chronology entry's date in the report: the day as before, or — for a coarser precision, a range, a
    /// bound, "approximately" or a recorded zone — the time model's wording, so the report never claims more precision.
    static func chronologyDate(_ e: CaseJournalEntry) -> String {
        let plain = [nil, .unknown, .day, .minute, .instant].contains(e.datePrecision)
        if plain, e.dateEnd == nil, e.dateQualifier == nil || e.dateQualifier == .stated, e.dateTimeZone == nil { return d(e.eventDate) }
        return e.timeValue?.label() ?? d(e.eventDate)
    }

    /// Every citation after the first, printed in full (N5, mandate 2026-11-01): its quoted passage and
    /// where it is — source version, document and block — so the report can be checked outside the app.
    /// A count of hidden citations ("+ 2 more") is not a checkable account.
    /// Ease fixes B — each place is printed as "document, p. 4" with its reference label; the identifiers go to the
    /// appendix (`references`).
    static func furtherCitations(_ refs: [StudioEvidenceRef], references: inout CaseReportReferences) -> String {
        guard refs.count > 1 else { return "" }
        var out = ""
        for (i, r) in refs.dropFirst().enumerated() {
            var line = "\n  - Citation \(i + 2) of \(refs.count):"
            if let q = r.quote, !q.isEmpty { line += " “\(q)”" } else { line += " (no quoted passage)" }
            if r.sourceVersionID != nil || r.objectID != nil || r.blockID != nil { line += " [\(references.cite(r))]" }
            out += line
        }
        return out
    }

    /// The first citation of an entry: its case reference, at the passage its first citation pins when that is the same
    /// document.
    static func mainCitation(_ ref: String, citations: [StudioEvidenceRef], references: inout CaseReportReferences) -> String {
        let first = citations.first
        if let v = UUID(uuidString: ref), let first, first.sourceVersionID == v {
            return references.cite(version: v, object: first.objectID, block: first.blockID)
        }
        return references.cite(evidenceRef: ref)
    }

    /// "(from <where it came from>; …)" for a carried item.
    static func originNote(_ origin: String?, review: String?, digest: String?, superseded: String?, references: inout CaseReportReferences) -> String {
        guard let origin else { return "" }
        var line = " (from \(references.origin(origin))"
        if let rs = review.flatMap(CarriedReviewState.init(rawValue:)) { line += "; \(rs.label)" }
        if let d = digest { line += "; revision \(d.prefix(12))" }
        if let superseded { line += "; \(superseded)" }
        return line + ")"
    }
    static func t(_ date: Date?) -> String { ExportDateStyle.stamp(date) }

    static func footer(_ by: String, _ at: Date) -> String {
        "\n---\nProduced by \(by) with Investigations Made Easy on \(t(at)). The investigator's record; judgement stays with the investigator.\n"
            + ExportDateStyle.zoneStatement(at: at) + "\n"
    }

    static func csv(_ rows: [[String]]) -> String {
        // S14 (SEC-10): a cell a spreadsheet would run as a formula is written as text.
        rows.map { $0.map { CSVFormulaGuard.csvField($0, alwaysQuote: true) }.joined(separator: ",") }.joined(separator: "\n") + "\n"
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
            let named = s.citationPlaces.versionNames[e.sourceVersionID]
            out += "## \(i + 1). \(exhibit.map { "\($0.number) — \($0.description)" } ?? named ?? "Source \(e.sourceVersionID.uuidString)")\n\n"
            if exhibit != nil || named != nil { out += "- Source version: `\(e.sourceVersionID.uuidString)`\n" }
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

    public static func caseFileReport(_ s: CaseFileSnapshot, named: StudioCaseFacts? = nil, coverage: CaseCoverageReadout? = nil,
                                      requests: [EvidenceRequestFile] = [], by: String, at: Date = Date()) -> String {
        let p = s.profile, c = s.caseHeader
        // Ease fixes B — every citation names its document and place; the identifiers go to the appendix at the end.
        var refs = CaseReportReferences(places: s.citationPlaces)
        let longSuperseded = "SUPERSEDED by a later result revision — re-review"
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
        o += "_Established, disputed and unknown are kept apart: a finding rests on the documentary passages linked below; an investigator's note is the investigator's own entry; a pending allegation is unresolved._\n"
        if s.allegations.isEmpty { o += "No allegations recorded.\n" }
        for a in s.allegations {
            let ev = s.grid.filter { $0.allegationID == a.id }
            let documentary = ev.filter { $0.isDocumentary && $0.stance == .supports }.count
            o += "\n### \(a.label). \(a.text)\n\n**\(a.disposition.label)**" + (a.decidedBy.map { " — decided by \($0) on \(d(a.decidedAt))" } ?? "")
            if a.disposition == .pending { o += " — unresolved" }
            else if documentary == 0 { o += " — typed disposition: no documentary evidence supports it" }
            o += "\n"
            if let r = a.rationale { o += "\n\(r)\n" }
            o += "\nResponse: " + (a.response.map { "“\($0)”" } ?? (a.exceptionNote.map { "none — exception: \($0)" } ?? "none recorded")) + "\n"
            for st in GridStance.allCases {
                let items = ev.filter { $0.stance == st }
                guard !items.isEmpty else { continue }
                var lines: [String] = []
                for e in items {
                    let cite = refs.cite(evidenceRef: e.evidenceRef, block: e.blockID ?? e.passage?.blockID, object: e.objectID)
                    var line = "- \(e.label ?? cite)"
                    line += " (\(e.support.label))"
                    if let q = e.quote { line += " — “\(q)”" }
                    if let n = e.note { line += " — \(n)" }
                    line += " [\(cite)]"
                    line += Self.originNote(e.origin, review: e.reviewState, digest: e.originDigest,
                                            superseded: s.isSuperseded(e.origin) ? longSuperseded : nil, references: &refs)
                    lines.append(line)
                }
                o += "\n\(st.label):\n" + lines.joined(separator: "\n") + "\n"
            }
            if ev.contains(where: { $0.stance == .contradicts }) == false, a.disposition != .pending {
                o += "\nNothing contrary is linked; absence of contrary evidence is not proof.\n"
            }
        }

        let chron = s.journal.filter { $0.kind == .chronology }
        if !chron.isEmpty {
            o += "\n## Chronology (investigator entries)\n"
            o += "_The label in parentheses is the app's check that the quoted words are in the cited source; “Verified by …” is a person's own verification of the entry._\n"
            var lines: [String] = []
            for e in chron {
                // S5 (TIME-02 / TIME-05) — the date at its own precision, range and zone; a day never gets a time.
                var line = "- \(Self.chronologyDate(e)): \(e.text)" + (e.quote.map { " — “\($0)”" } ?? "")
                if e.evidenceRef != nil || !e.citations.isEmpty { line += " (\(e.support.label))" }
                // N3 — a person's verification, kept apart from the machine check above.
                line += " · \(s.factMark(for: e).reportLabel)"
                if let ref = e.evidenceRef { line += " [\(Self.mainCitation(ref, citations: e.citations, references: &refs))]" }
                line += Self.furtherCitations(e.citations, references: &refs)
                line += Self.originNote(e.origin, review: e.reviewState, digest: nil,
                                        superseded: s.isSuperseded(e.origin) ? "SUPERSEDED — re-review" : nil, references: &refs)
                lines.append(line)
            }
            o += lines.joined(separator: "\n") + "\n"
            // S5 (TIME-05) — what the order of the list does not establish, and the time zone assumed.
            let arranged = CaseChronologyOrder.arrange(chron.compactMap { e in e.timeValue.map { CaseChronologyItem(id: e.id.uuidString, title: String(e.text.prefix(60)), time: $0) } })
            o += arranged.notes.map { "_\($0)_" }.joined(separator: "\n") + "\n"
        }

        func itemLine(_ i: CaseReportItem) -> String {
            var line = "- \(i.text)" + (i.quote.map { " — “\($0)”" } ?? "")
            if i.evidenceRef != nil || !i.citations.isEmpty { line += " (\(i.support.label))" }
            if let ref = i.evidenceRef { line += " [\(Self.mainCitation(ref, citations: i.citations, references: &refs))]" }
            line += Self.furtherCitations(i.citations, references: &refs)
            line += Self.originNote(i.origin, review: i.reviewState, digest: i.originDigest,
                                    superseded: s.isSuperseded(i.origin) ? longSuperseded : nil, references: &refs)
            line += i.allegationID.flatMap { id in s.allegations.first { $0.id == id }?.label }.map { " · \($0)" } ?? ""
            return line
        }
        let included = s.reportItems.filter(\.included), excluded = s.reportItems.filter { !$0.included }
        let accepted = included.filter(\.isAcceptedReview), provisional = included.filter { !$0.isAcceptedReview }
        if !accepted.isEmpty {
            o += "\n## Reviewed results included in this report\n_Each was accepted on review (or completed) in the result revision named; its passages were verified against the case's sources when carried, and re-verified for this report._\n"
                + accepted.map(itemLine).joined(separator: "\n") + "\n"
        }
        if !provisional.isEmpty {
            o += "\n## Provisional material included in this report\n_Carried from result rows NOT yet accepted on review (or added by hand). Provisional — not reviewed findings._\n"
                + provisional.map(itemLine).joined(separator: "\n") + "\n"
        }
        if !excluded.isEmpty {
            var lines: [String] = []
            for i in excluded {
                let cite = i.evidenceRef.map { " [\(Self.mainCitation($0, citations: i.citations, references: &refs))]" } ?? ""
                lines.append("- \(i.text)" + cite + " — excluded: \(i.exclusionReason ?? "no reason recorded")" + (i.decidedBy.map { " (\($0), \(d(i.decidedAt)))" } ?? ""))
            }
            o += "\n## Material excluded from this report\n" + lines.joined(separator: "\n") + "\n"
        }
        let unresolved = s.allegations.filter { $0.disposition == .pending }
        o += "\n## Unresolved questions and limitations\n"
        o += unresolved.isEmpty ? "- Every allegation has a recorded disposition.\n" : unresolved.map { "- \($0.label) \($0.text) — unresolved" }.joined(separator: "\n") + "\n"
        let noResponse = s.allegations.filter { $0.disposition == .substantiated && $0.response == nil }
        for a in noResponse { o += "- \(a.label) was decided without a recorded response" + (a.exceptionNote.map { " (exception: \($0))" } ?? "") + ".\n" }
        let unverified = s.grid.filter { $0.namesASource && !$0.isDocumentary }.count
        if unverified > 0 { o += "- \(unverified) evidence link(s) name a source but did not verify (the quoted words were not found, the source left the case or became inaccessible, or the exhibit was withdrawn); they are shown as unverified above and count for nothing.\n" }
        if !s.supersededOrigins.isEmpty { o += "- \(s.supersededOrigins.count) carried item(s) come from a result revision that has since been superseded; re-review them before relying on this report.\n" }
        o += "- This report states what the linked passages support; it reaches no conclusion beyond them, and the chronology entries are the investigator's.\n"
        // Package B (P1-D) — the reading limits and the collection status travel with the report.
        if let coverage { o += coverage.reportSection } else { o += "\n## What the app could read\n- Not available when this report was written; check the case overview.\n" }
        if !requests.isEmpty { o += evidenceRequestsSection(requests, allegations: s.allegations, places: s.citationPlaces) }

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
        return o + footer(by, at) + refs.appendix
    }

    /// Package B (P1-D) — each evidence request with its recorded status, what arrived (by document name since Ease
    /// fixes B; the source version stays in the request record) and what is still missing. A status is the investigator's
    /// recorded decision, never inferred.
    public static func evidenceRequestsSection(_ files: [EvidenceRequestFile], allegations: [CaseAllegation],
                                               places: CaseCitationPlaces = CaseCitationPlaces()) -> String {
        var o = "\n## Evidence requests\n_Status is the investigator's recorded decision; an arrival alone does not fulfil a request._\n"
        for f in files.sorted(by: { $0.request.createdAt < $1.request.createdAt }) {
            let r = f.request
            o += "- \(r.description) — **\(r.status.label)**"
            if let c = r.custodian { o += " · from \(c)" }
            if let due = r.dueAt { o += " · due \(d(due))" }
            if let aid = r.allegationID, let a = allegations.first(where: { $0.id == aid }) { o += " · for \(a.label)" }
            o += "\n  - \(f.progress.summary)\n"
            let received = f.receipts.filter(\.counts)
            if !received.isEmpty {
                let names = received.map { r -> String in
                    let name = places.name(version: r.sourceVersionID, object: r.knowledgeObjectID, block: nil) ?? CaseCitationText.unnamedDocument
                    return name + (r.contentHash.map { " (SHA-256 \($0.prefix(12)))" } ?? "")
                }
                o += "  - Received: " + names.joined(separator: "; ") + "\n"
            }
        }
        return o
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
