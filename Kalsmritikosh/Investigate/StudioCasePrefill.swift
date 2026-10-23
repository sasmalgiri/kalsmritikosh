//
//  StudioCasePrefill.swift
//  Kalsmritikosh
//
//  A4 (investigation focus) — each persona studio filled from its case. Only EMPTY fields are
//  filled, so nothing the investigator wrote is overwritten; every filled field records the
//  evidence it came from (StudioDraft.swift). Judgement fields — findings, opinions, privilege
//  bases, credibility, conclusions — are never filled: they stay the investigator's.
//

import Foundation

// MARK: - Lawyer — privilege log

extension PrivilegeLog: CaseBackedStudio {
    public static var needsPrivilegedSources: Bool { true }

    public var gateValues: [String: String] {
        var v = ["caption": caption, "producingParty": producingParty, "requestingParty": requestingParty, "preparedBy": preparedBy]
        for e in entries {
            let k = "entries.\(e.id.uuidString)"
            v["\(k).date"] = e.date; v["\(k).docType"] = e.docType; v["\(k).author"] = e.author
            v["\(k).recipients"] = e.recipients; v["\(k).cc"] = e.cc
            v["\(k).description"] = e.descriptionText; v["\(k).bates"] = e.bates
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        let plaintiff = c.first(["plaintiff", "petitioner", "appellant", "claimant", "complainant"])
        let defendant = c.first(["defendant", "respondent", "appellee", "accused"])
        if let pl = plaintiff, let df = defendant {
            let docket = c.first(["casenumber", "docketnumber"])
            let cap = "\(pl.value) v. \(df.value)" + (docket.map { ", No. \($0.value)" } ?? "")
            StudioPrefill.set(&caption, path: "caption", value: cap, refs: pl.refs + df.refs + (docket?.refs ?? []), into: &p)
        }
        StudioPrefill.set(&producingParty, path: "producingParty", from: defendant, into: &p)
        StudioPrefill.set(&requestingParty, path: "requestingParty", from: plaintiff, into: &p)
        // One entry per case document not yet on the log: its type from the file, the document
        // as the source. Date, author, recipients, basis and description stay the lawyer's.
        let listed = Set(entries.map(\.bates))
        for d in c.documents where !listed.contains(d.name) {
            var e = PLEntry()
            let ref = StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: d.name)
            let k = "entries.\(e.id.uuidString)"
            e.docType = Self.documentType(d.name); p["\(k).docType"] = .fromCase(e.docType, [ref])
            e.bates = d.name; p["\(k).bates"] = .fromCase(e.bates, [ref])
            entries.append(e)
        }
        provenance = p
    }

    nonisolated static func documentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "eml", "msg", "mbox", "emlx": return "Email"
        case "pdf": return "PDF document"
        case "doc", "docx", "rtf", "pages": return "Word-processor document"
        case "xls", "xlsx", "csv", "numbers": return "Spreadsheet"
        case "ppt", "pptx", "key": return "Presentation"
        case "txt", "md": return "Text note"
        case "png", "jpg", "jpeg", "heic", "tif", "tiff": return "Image"
        default: return "Document"
        }
    }
}

// MARK: - Compliance / HR — workplace investigation report

extension WorkplaceInvestigation: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["mandate": mandate, "investigator": investigator, "methodologyNote": methodologyNote, "submittedTo": submittedTo]
        for x in parties { v["parties.\(x.id.uuidString).name"] = x.name }
        for e in evidence {
            v["evidence.\(e.id.uuidString).description"] = e.descriptionText
            v["evidence.\(e.id.uuidString).source"] = e.source
            v["evidence.\(e.id.uuidString).date"] = e.date
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        let named = Set(parties.map { $0.name.lowercased() })
        let roles: [(fields: [String], role: WIPartyRole)] = [
            (["complainant", "claimant", "plaintiff", "victim"], .complainant),
            (["respondent", "accused", "defendant", "suspect"], .respondent),
            (["witness"], .witness)]
        for (fields, role) in roles {
            for v in c.all(fields) where !named.contains(v.value.lowercased()) {
                let party = WIParty(name: v.value, role: role)
                p["parties.\(party.id.uuidString).name"] = .fromCase(v.value, v.refs)
                parties.append(party)
            }
        }
        let considered = Set(evidence.map(\.source))
        for d in c.documents where !considered.contains(d.name) {
            let e = WIEvidence(descriptionText: d.name, source: d.name, date: d.date.map(StudioPrefill.isoDay) ?? "")
            let ref = StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: d.name)
            p["evidence.\(e.id.uuidString).description"] = .fromCase(e.descriptionText, [ref])
            p["evidence.\(e.id.uuidString).source"] = .fromCase(e.source, [ref])
            if !e.date.isEmpty { p["evidence.\(e.id.uuidString).date"] = .fromCase(e.date, [ref]) }
            evidence.append(e)
        }
        provenance = p
    }
}

// MARK: - SIU — referral

extension SIUReferral: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["claimNumber": claimNumber, "insured": insured, "policyNumber": policyNumber, "lossDate": lossDate,
                 "lossType": lossType, "claimedAmount": claimedAmount, "investigator": investigator]
        for e in chronology {
            v["chronology.\(e.id.uuidString).date"] = e.date
            v["chronology.\(e.id.uuidString).event"] = e.event
            v["chronology.\(e.id.uuidString).source"] = e.source
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        StudioPrefill.set(&claimNumber, path: "claimNumber", from: c.first(["claimnumber", "claimno", "casenumber", "referencenumber"]), into: &p)
        StudioPrefill.set(&insured, path: "insured", from: c.first(["insured", "policyholder", "claimant"]), into: &p)
        StudioPrefill.set(&policyNumber, path: "policyNumber", from: c.first(["policynumber", "policyno"]), into: &p)
        StudioPrefill.set(&lossDate, path: "lossDate", from: c.first(["lossdate", "dateofloss", "incidentdate", "accidentdate", "eventdate"]), into: &p)
        StudioPrefill.set(&lossType, path: "lossType", from: c.first(["losstype", "claimtype", "coverage"]), into: &p)
        StudioPrefill.set(&claimedAmount, path: "claimedAmount", from: c.first(["claimedamount", "claimamount", "amount"]), into: &p)
        // The chronology, from the case's dated events, each tied to its document.
        let have = Set(chronology.map { "\($0.date)|\($0.event)" })
        for ev in c.events.prefix(60) {
            var row = SIUChronologyEvent()
            row.date = StudioPrefill.isoDay(ev.date); row.event = ev.title
            guard !have.contains("\(row.date)|\(row.event)") else { continue }
            row.source = ev.refs.first?.quote.map { String($0.prefix(80)) } ?? "Case document"
            let k = "chronology.\(row.id.uuidString)"
            p["\(k).date"] = .fromCase(row.date, ev.refs); p["\(k).event"] = .fromCase(row.event, ev.refs)
            p["\(k).source"] = .fromCase(row.source, ev.refs)
            chronology.append(row)
        }
        provenance = p
    }
}

// MARK: - Forensic accountant — materials + transaction schedule

extension ForensicEngagement: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["scope": scope, "preparedFor": preparedFor, "expert": expert, "qualifications": qualifications,
                 "methodJustification": methodJustification]
        for m in materials { v["materials.\(m.id.uuidString).description"] = m.descriptionText; v["materials.\(m.id.uuidString).source"] = m.source }
        for t in schedule {
            let k = "schedule.\(t.id.uuidString)"
            v["\(k).date"] = t.date; v["\(k).description"] = t.descriptionText; v["\(k).payer"] = t.payer
            v["\(k).payee"] = t.payee; v["\(k).amount"] = t.amount; v["\(k).account"] = t.account; v["\(k).sourceDoc"] = t.sourceDoc
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        // Materials relied on: the case's documents.
        let listed = Set(materials.map(\.source))
        for d in c.documents where !listed.contains(d.name) {
            var m = FAMaterial(); m.descriptionText = d.name; m.source = d.name
            let ref = StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: d.name)
            p["materials.\(m.id.uuidString).description"] = .fromCase(m.descriptionText, [ref])
            p["materials.\(m.id.uuidString).source"] = .fromCase(m.source, [ref])
            materials.append(m)
        }
        // The schedule: each amount the case states, with the passage it comes from as the source
        // document — the rule that every row ties to a source.
        let have = Set(schedule.map(\.amount))
        for a in c.amounts.prefix(200) where !have.contains(a.value) {
            var t = FATransaction()
            t.amount = a.value
            t.descriptionText = a.refs.first?.quote.map { String($0.prefix(120)) } ?? a.label
            t.sourceDoc = a.refs.first?.quote.map { String($0.prefix(60)) } ?? "Case document"
            let k = "schedule.\(t.id.uuidString)"
            p["\(k).amount"] = .fromCase(t.amount, a.refs); p["\(k).description"] = .fromCase(t.descriptionText, a.refs)
            p["\(k).sourceDoc"] = .fromCase(t.sourceDoc, a.refs)
            schedule.append(t)
        }
        provenance = p
    }
}

// MARK: - Journalist — fact-check memo

extension FactCheckMemo: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["premise": premise, "reporter": reporter, "editor": editor]
        for c in claims {
            v["claims.\(c.id.uuidString).text"] = c.text; v["claims.\(c.id.uuidString).sources"] = c.sources
            v["claims.\(c.id.uuidString).corroboration"] = c.corroboration
        }
        for r in replies {
            let k = "replies.\(r.id.uuidString)"
            v["\(k).subject"] = r.subject; v["\(k).claimSummary"] = r.claimSummary; v["\(k).response"] = r.response
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        // Claims to check: the case's dated events, each with the document it rests on. Whether a
        // claim is verified stays the journalist's call.
        let have = Set(claims.map(\.text))
        for ev in c.events.prefix(40) where !have.contains(ev.title) {
            var claim = JClaim(text: ev.title)
            claim.sources = ev.refs.first?.quote.map { String($0.prefix(100)) } ?? "Case document"
            p["claims.\(claim.id.uuidString).text"] = .fromCase(claim.text, ev.refs)
            p["claims.\(claim.id.uuidString).sources"] = .fromCase(claim.sources, ev.refs)
            claims.append(claim)
        }
        // Right of reply: each named party the story is about.
        let asked = Set(replies.map { $0.subject.lowercased() })
        for party in c.parties.prefix(20) where !asked.contains(party.value.lowercased()) {
            var r = ReplyEntry(); r.subject = party.value
            p["replies.\(r.id.uuidString).subject"] = .fromCase(r.subject, party.refs)
            replies.append(r)
        }
        provenance = p
    }
}

// MARK: - Researcher — research appraisal

extension ResearchReview: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["question": question, "reviewer": reviewer, "synthesis": synthesis, "limitations": limitations]
        for s in studies {
            let k = "studies.\(s.id.uuidString)"
            v["\(k).study"] = s.study; v["\(k).design"] = s.design; v["\(k).sample"] = s.sample
            v["\(k).outcome"] = s.outcome; v["\(k).result"] = s.result; v["\(k).source"] = s.source
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        let have = Set(studies.map(\.source))
        for d in c.documents where !have.contains(d.name) {
            var s = RSStudy(); s.study = d.name; s.source = d.name
            let ref = StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: d.name)
            p["studies.\(s.id.uuidString).study"] = .fromCase(s.study, [ref])
            p["studies.\(s.id.uuidString).source"] = .fromCase(s.source, [ref])
            studies.append(s)
        }
        provenance = p
    }
}

// MARK: - Genealogist — GPS proof argument

extension ProofArgument: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["question": question, "researcher": researcher, "analysis": analysis,
                 "conflictResolution": conflictResolution, "conclusion": conclusion]
        for s in searches {
            let k = "searches.\(s.id.uuidString)"
            v["\(k).date"] = s.date; v["\(k).repository"] = s.repository; v["\(k).source"] = s.source; v["\(k).result"] = s.result
        }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.recordSourceDigest(from: c, into: &p)
        // GPS 1 — the record searches: each case document is a source consulted. Where it was found
        // (the repository) and the result of each search (including a nil) are the researcher's to
        // state — the case doesn't say, so the field stays empty rather than carrying a made-up label.
        let have = Set(searches.map(\.source))
        for d in c.documents where !have.contains(d.name) {
            var s = GNSearch(); s.source = d.name
            let ref = StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: d.name)
            p["searches.\(s.id.uuidString).source"] = .fromCase(s.source, [ref])
            searches.append(s)
        }
        provenance = p
    }
}
