//
//  DisputeFile.swift
//  Kalsmritikosh
//
//  A4 (investigation focus) — the Individual's studio: a personal dispute file for an insurance
//  claim, a tenancy deposit, an employment complaint or a consumer refund. The real-life file a
//  person sends to an insurer, landlord, employer, ombudsman or small-claims court: who the
//  dispute is with and the reference they use, what is disputed and for how much, the timeline
//  with the document behind each line, the documents enclosed, and what the person is asking for.
//
//  Pure Codable model + pure renderer; filled from the case (StudioCasePrefill pattern).
//

import Foundation

public nonisolated enum DisputeKind: String, Codable, Sendable, CaseIterable, Equatable {
    case insurance, tenancy, employment, consumer, other
    public var label: String {
        switch self {
        case .insurance: return "Insurance claim"
        case .tenancy: return "Tenancy / deposit"
        case .employment: return "Employment"
        case .consumer: return "Consumer / refund"
        case .other: return "Other"
        }
    }
}

public struct DisputeTimelineEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: String = ""        // yyyy-MM-dd
    public var event: String = ""
    public var source: String = ""      // the document that shows it
    public init() {}
    public var isComplete: Bool { !date.trimmed.isEmpty && !event.trimmed.isEmpty && !source.trimmed.isEmpty }
}

public struct DisputeDocument: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String = ""
    public var why: String = ""         // what it proves
    public init() {}
}

public struct DisputeFile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?
    /// A2 — where each filled field came from (case evidence or investigator entry).
    public var provenance: StudioProvenance?

    // Stage 1 — The dispute.
    public var kind: DisputeKind = .insurance
    public var counterparty: String = ""   // insurer / landlord / employer / seller
    public var reference: String = ""      // claim / policy / account / case number they use
    public var myName: String = ""

    // Stage 2 — What is disputed.
    public var disputedAmount: String = ""
    public var summary: String = ""        // what happened and what is disputed, in plain words

    // Stage 3 — Timeline and documents.
    public var timeline: [DisputeTimelineEntry] = []
    public var documents: [DisputeDocument] = []

    // Stage 4 — What I am asking for.
    public var remedy: String = ""         // refund / payment / repair / apology / reinstatement
    public var deadline: String = ""       // the reply-by date the person sets
    public var escalation: String = ""     // where it goes if refused: ombudsman, regulator, court

    public init(title: String, now: Date) { self.title = title; createdAt = now; updatedAt = now }

    public enum Stage: Int, CaseIterable, Sendable {
        case dispute, disputed, evidence, request
        public var title: String {
            switch self {
            case .dispute: return "The dispute"
            case .disputed: return "What is disputed"
            case .evidence: return "Timeline & documents"
            case .request: return "What I ask for"
            }
        }
        public var systemImage: String {
            switch self {
            case .dispute: return "person.2"
            case .disputed: return "exclamationmark.bubble"
            case .evidence: return "calendar"
            case .request: return "envelope"
            }
        }
    }

    public func isComplete(_ s: Stage) -> Bool {
        switch s {
        case .dispute: return !counterparty.trimmed.isEmpty && !reference.trimmed.isEmpty
        case .disputed: return !summary.trimmed.isEmpty
        case .evidence: return !timeline.isEmpty && timeline.allSatisfy(\.isComplete)
        case .request: return !remedy.trimmed.isEmpty
        }
    }
    public var completionFraction: Double { Double(Stage.allCases.filter { isComplete($0) }.count) / Double(Stage.allCases.count) }

    public static func sample(now: Date) -> DisputeFile {
        var d = DisputeFile(title: "Water-damage claim — kitchen ceiling", now: now)
        d.kind = .insurance
        d.counterparty = "Example Home Insurance Ltd"
        d.reference = "Claim HX-204-118"
        d.myName = "A. Householder"
        d.disputedAmount = "$4,850.00"
        d.summary = "A pipe burst above the kitchen on 3 March 2026. The insurer declined the claim as \u{201C}gradual leakage\u{201D}; the plumber's report states a sudden failure of a compression fitting."
        var t1 = DisputeTimelineEntry(); t1.date = "2026-03-03"; t1.event = "Pipe burst; water through kitchen ceiling"; t1.source = "Photos 3 Mar 2026"
        var t2 = DisputeTimelineEntry(); t2.date = "2026-03-04"; t2.event = "Plumber attends: sudden failure of compression fitting"; t2.source = "Plumber's report #5521"
        var t3 = DisputeTimelineEntry(); t3.date = "2026-03-20"; t3.event = "Claim declined as gradual leakage"; t3.source = "Insurer's letter 20 Mar 2026"
        d.timeline = [t1, t2, t3]
        var doc = DisputeDocument(); doc.name = "Plumber's report #5521"; doc.why = "States the failure was sudden"
        d.documents = [doc]
        d.remedy = "Reconsider the claim and pay $4,850.00 for the repair."
        d.deadline = "2026-04-30"
        d.escalation = "Financial ombudsman"
        StudioAudit.record(&d.history, "Worked example created", at: now)
        return d
    }
}

public enum DisputeFileRenderer {
    public static func markdown(_ d: DisputeFile, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Dispute file — \(d.title.trimmed.isEmpty ? "Untitled" : d.title)\n\n"
        out += "**Type:** \(d.kind.label) · **With:** \(d.counterparty.orDashDF) · **Their reference:** \(d.reference.orDashDF)\n"
        out += "**From:** \(d.myName.orDashDF) · **Date:** \(df.string(from: generatedAt))\n\n"
        out += "## What is disputed\n\n"
        if !d.disputedAmount.trimmed.isEmpty { out += "**Amount in dispute:** \(d.disputedAmount)\n\n" }
        out += "\(d.summary.orDashDF)\n\n"
        out += "## Timeline\n\n| Date | What happened | Shown by |\n|---|---|---|\n"
        for t in d.timeline.sorted(by: { $0.date < $1.date }) {
            out += "| \(t.date.orDashDF) | \(t.event.orDashDF) | \(t.source.orDashDF) |\n"
        }
        if !d.documents.isEmpty {
            out += "\n## Documents enclosed\n\n"
            for (i, doc) in d.documents.enumerated() { out += "\(i + 1). \(doc.name.orDashDF)\(doc.why.trimmed.isEmpty ? "" : " — \(doc.why)")\n" }
        }
        out += "\n## What I am asking for\n\n\(d.remedy.orDashDF)\n\n"
        if !d.deadline.trimmed.isEmpty { out += "Please reply by **\(d.deadline)**.\n\n" }
        if !d.escalation.trimmed.isEmpty { out += "If the matter is not resolved, I intend to refer it to: \(d.escalation).\n" }
        out += StudioExportGate.provenanceAppendix(d.gateValues, provenance: d.provenance)
        out += StudioAudit.appendix(d.history)
        return out
    }
}

extension DisputeFile: CaseBackedStudio {
    public var gateValues: [String: String] {
        var v = ["counterparty": counterparty, "reference": reference, "myName": myName, "disputedAmount": disputedAmount,
                 "summary": summary, "remedy": remedy, "deadline": deadline, "escalation": escalation]
        for t in timeline {
            v["timeline.\(t.id.uuidString).date"] = t.date; v["timeline.\(t.id.uuidString).event"] = t.event
            v["timeline.\(t.id.uuidString).source"] = t.source
        }
        for doc in documents { v["documents.\(doc.id.uuidString).name"] = doc.name; v["documents.\(doc.id.uuidString).why"] = doc.why }
        return v
    }

    public mutating func prefill(from c: StudioCaseFacts) {
        var p = provenance ?? [:]
        StudioPrefill.set(&counterparty, path: "counterparty",
                          from: c.first(["insurer", "landlord", "employer", "seller", "counterparty", "recallingfirm", "defendant", "respondent"]), into: &p)
        StudioPrefill.set(&reference, path: "reference",
                          from: c.first(["claimnumber", "policynumber", "casenumber", "accountnumber", "referencenumber", "invoicenumber"]), into: &p)
        StudioPrefill.set(&disputedAmount, path: "disputedAmount", from: c.first(["claimedamount", "claimamount", "amount", "total"]), into: &p)
        let have = Set(timeline.map { "\($0.date)|\($0.event)" })
        for ev in c.events.prefix(60) {
            var t = DisputeTimelineEntry()
            t.date = StudioPrefill.isoDay(ev.date); t.event = ev.title
            guard !have.contains("\(t.date)|\(t.event)") else { continue }
            t.source = ev.refs.first?.quote.map { String($0.prefix(80)) } ?? "Case document"
            let k = "timeline.\(t.id.uuidString)"
            p["\(k).date"] = .fromCase(t.date, ev.refs); p["\(k).event"] = .fromCase(t.event, ev.refs); p["\(k).source"] = .fromCase(t.source, ev.refs)
            timeline.append(t)
        }
        let enclosed = Set(documents.map(\.name))
        for d in c.documents where !enclosed.contains(d.name) {
            var doc = DisputeDocument(); doc.name = d.name
            p["documents.\(doc.id.uuidString).name"] = .fromCase(doc.name, [StudioEvidenceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, quote: d.name)])
            documents.append(doc)
        }
        provenance = p
    }
}

private extension String {
    var orDashDF: String { trimmed.isEmpty ? "—" : self }
}
