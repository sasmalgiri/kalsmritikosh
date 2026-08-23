//
//  PrivilegeLog.swift
//  Kalsmritikosh
//
//  PERSONA STUDIO #2 (Lawyer) — the FRCP 26(b)(5) privilege log, the most
//  standardized deliverable in litigation: when a party withholds documents as
//  privileged it must "describe the nature of the documents … in a manner that
//  … will enable other parties to assess the claim" WITHOUT revealing the
//  protected content. The real hardcopy is a table: Entry No · Date · Document
//  type · Author · Recipients · CC · Privilege asserted · Description · Bates/
//  control number — under a case caption, with a definitions legend and a
//  certification line.
//
//  Real-life steps the studio walks: Matter (caption, producing/requesting
//  party) → Withheld documents (the entries) → QC review (each entry has a
//  basis; descriptions let the claim be tested without leaking content) → Log.
//
//  Pure Codable model + pure renderer (testable); persists on-device as JSON.
//

import Foundation

public nonisolated enum PrivilegeBasis: String, Codable, Sendable, CaseIterable, Equatable {
    case attorneyClient, workProduct, both, other
    public var label: String {
        switch self {
        case .attorneyClient: return "Attorney–Client (AC)"
        case .workProduct: return "Work Product (WP)"
        case .both: return "AC + WP"
        case .other: return "Other (state in description)"
        }
    }
    public var code: String {
        switch self {
        case .attorneyClient: return "AC"
        case .workProduct: return "WP"
        case .both: return "AC/WP"
        case .other: return "Other"
        }
    }
}

public struct PLEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: String = ""            // yyyy-MM-dd
    public var docType: String = ""         // Email / Memo / Letter / Notes …
    public var author: String = ""
    public var recipients: String = ""
    public var cc: String = ""
    public var privilege: PrivilegeBasis = .attorneyClient
    public var descriptionText: String = "" // enough to test the claim, never the content
    public var bates: String = ""           // Bates range or control number
    public init() {}

    /// A log entry is complete when the reader could assess the claim from it.
    public var isComplete: Bool {
        !date.trimmed.isEmpty && !docType.trimmed.isEmpty && !author.trimmed.isEmpty
            && !descriptionText.trimmed.isEmpty
    }
}

public struct PrivilegeLog: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    // Stage 1 — Matter.
    public var caption: String = ""          // "Doe v. Acme Corp., No. 1:26-cv-0421 (N.D. Ga.)"
    public var producingParty: String = ""
    public var requestingParty: String = ""
    public var preparedBy: String = ""

    // Stage 2 — Withheld documents.
    public var entries: [PLEntry] = []

    // Stage 3 — QC review (the real-life discipline before serving the log).
    public var descriptionsDoNotRevealContent = false
    public var everyEntryHasBasis = false

    public init(title: String, now: Date) {
        self.title = title; self.createdAt = now; self.updatedAt = now
    }

    public enum Stage: Int, CaseIterable, Sendable {
        case matter, entries, review, log
        public var title: String {
            switch self {
            case .matter: return "Matter"
            case .entries: return "Withheld documents"
            case .review: return "QC review"
            case .log: return "Log"
            }
        }
        public var systemImage: String {
            switch self {
            case .matter: return "briefcase"
            case .entries: return "doc.on.doc"
            case .review: return "checklist"
            case .log: return "tablecells"
            }
        }
    }

    public func isComplete(_ stage: Stage) -> Bool {
        switch stage {
        case .matter:  return !caption.trimmed.isEmpty && !producingParty.trimmed.isEmpty
        case .entries: return !entries.isEmpty && entries.allSatisfy(\.isComplete)
        case .review:  return descriptionsDoNotRevealContent && everyEntryHasBasis
        case .log:     return isComplete(.matter) && isComplete(.entries) && isComplete(.review)
        }
    }
    public var completionFraction: Double {
        let s: [Stage] = [.matter, .entries, .review]
        return Double(s.filter { isComplete($0) }.count) / Double(s.count)
    }

    /// A worked example so the finished log is one click away.
    public static func sample(now: Date) -> PrivilegeLog {
        var p = PrivilegeLog(title: "Doe v. Acme — first production", now: now)
        p.caption = "Doe v. Acme Corp., No. 1:26-cv-0421 (N.D. Ga.)"
        p.producingParty = "Acme Corp. (Defendant)"
        p.requestingParty = "Jane Doe (Plaintiff)"
        p.preparedBy = "A. Counsel, Mays & Kerr LLC"
        var e1 = PLEntry()
        e1.date = "2026-01-14"; e1.docType = "Email"
        e1.author = "R. Manager (Acme)"; e1.recipients = "A. Counsel (outside counsel)"; e1.cc = "HR Director"
        e1.privilege = .attorneyClient
        e1.descriptionText = "Email seeking legal advice regarding the termination decision at issue in the complaint."
        e1.bates = "ACME-PRIV-000001"
        var e2 = PLEntry()
        e2.date = "2026-02-02"; e2.docType = "Memorandum"
        e2.author = "A. Counsel"; e2.recipients = "Litigation file"
        e2.privilege = .workProduct
        e2.descriptionText = "Counsel's memorandum analyzing anticipated litigation strategy, prepared after receipt of the demand letter."
        e2.bates = "ACME-PRIV-000002–000005"
        var e3 = PLEntry()
        e3.date = "2026-02-10"; e3.docType = "Email thread"
        e3.author = "HR Director"; e3.recipients = "A. Counsel"; e3.cc = "R. Manager"
        e3.privilege = .both
        e3.descriptionText = "Thread requesting and reflecting legal advice on the investigation, including counsel's mental impressions."
        e3.bates = "ACME-PRIV-000006–000009"
        p.entries = [e1, e2, e3]
        p.descriptionsDoNotRevealContent = true
        p.everyEntryHasBasis = true
        StudioAudit.record(&p.history, "Worked example created", at: now)
        return p
    }
}

// MARK: - The hardcopy-faithful renderer

public enum PrivilegeLogRenderer {

    public static func markdown(_ p: PrivilegeLog, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Privilege Log — \(p.title.trimmed.isEmpty ? "Untitled" : p.title)\n\n"
        out += "**Pursuant to Fed. R. Civ. P. 26(b)(5)(A).**\n\n"
        out += "**Caption:** \(p.caption.orDashPL)\n"
        out += "**Producing party:** \(p.producingParty.orDashPL) · **Requesting party:** \(p.requestingParty.orDashPL)\n"
        out += "**Prepared by:** \(p.preparedBy.orDashPL) · **Date:** \(df.string(from: generatedAt))\n\n"

        // The log table — the hardcopy itself.
        out += "| No. | Date | Type | Author | Recipient(s) | CC | Privilege | Description | Bates / Control |\n"
        out += "|---|---|---|---|---|---|---|---|---|\n"
        for (i, e) in p.entries.enumerated() {
            out += "| \(i + 1) | \(e.date.orDashPL) | \(e.docType.orDashPL) | \(e.author.orDashPL) | \(e.recipients.orDashPL) | \(e.cc.orDashPL) | \(e.privilege.code) | \(e.descriptionText.orDashPL) | \(e.bates.orDashPL) |\n"
        }
        out += "\n"

        // Legend + the 26(b)(5) discipline stated on the document.
        out += "**Legend:** AC = attorney–client privilege · WP = attorney work product.\n\n"
        out += "_Each entry describes the nature of the withheld document in a manner intended to enable other parties to assess the claim, without revealing the privileged or protected information itself (Fed. R. Civ. P. 26(b)(5)(A))._\n\n"

        // Certification block.
        out += "---\n\n"
        out += "Certified: the descriptions above do not reveal privileged content, and a claim of privilege or work-product protection is asserted for every entry.\n\n"
        out += "Prepared by **\(p.preparedBy.orDashPL)** on behalf of **\(p.producingParty.orDashPL)**.\n"
        out += StudioAudit.appendix(p.history)
        return out
    }
}

private extension String {
    var orDashPL: String { trimmed.isEmpty ? "—" : self }
}
