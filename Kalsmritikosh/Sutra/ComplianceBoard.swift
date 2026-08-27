//
//  ComplianceBoard.swift
//  Kalsmritikosh
//
//  Step 6 of the SOP lifecycle: the standing board. Every external SOP the app
//  implements is tracked here with the exact edition we verified against, when
//  we verified, and when the next periodic re-check is due — so compliance is
//  MAINTAINED over time, not just achieved once. Fully on-device: the board
//  never phones home; "periodic check" means the app surfaces what is due and
//  the owner re-verifies against the governing body's current text.
//

import Foundation

public nonisolated struct SOPRecord: Sendable, Identifiable, Equatable, Codable {
    public let id: String                  // stable key, e.g. "sop.prisma"
    public let title: String               // the external SOP
    public let governingBody: String
    public let editionImplemented: String  // the exact current version we verified against
    public let implementedIn: String       // where in the app it is enforced
    public let verifiedOn: String          // yyyy-mm-dd of last verification
    public let reviewIntervalDays: Int     // periodic-check cadence

    /// The date this record's periodic re-check falls due (verifiedOn +
    /// interval), or nil when verifiedOn fails to parse (D-8).
    public func dueDate(calendar: Calendar = .current) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let base = f.date(from: verifiedOn) else { return nil }
        return calendar.date(byAdding: .day, value: reviewIntervalDays, to: base)
    }

    /// Due when `now` is past verifiedOn + interval (or the date fails to parse).
    public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = dueDate(calendar: calendar) else { return true }
        return now >= due
    }

    /// The same record with an owner-review override applied (D-8).
    public func withVerifiedOn(_ date: String) -> SOPRecord {
        SOPRecord(id: id, title: title, governingBody: governingBody,
                  editionImplemented: editionImplemented, implementedIn: implementedIn,
                  verifiedOn: date, reviewIntervalDays: reviewIntervalDays)
    }
}

public nonisolated enum ComplianceBoard {

    /// The tracked SOPs, seeded at the editions verified during the 2026-08
    /// persona-studio program. Re-verification updates `verifiedOn` via a new
    /// app release (the board is part of the constitution, so it amends — it
    /// is never silently edited).
    public static let records: [SOPRecord] = [
        SOPRecord(id: "sop.prisma", title: "PRISMA statement", governingBody: "PRISMA Group (BMJ)",
                  editionImplemented: "PRISMA 2020", implementedIn: "Evidence Review Studio — screening funnel",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.grade", title: "GRADE certainty of evidence", governingBody: "GRADE Working Group",
                  editionImplemented: "GRADE handbook (current)", implementedIn: "Evidence Review Studio — synthesis gate",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.8d", title: "8D problem solving (dual root cause)", governingBody: "Industry (Ford G8D lineage / ISO 9001 CAPA)",
                  editionImplemented: "G8D — occurrence + escape cause", implementedIn: "Reasoning Studio — RCA conclusion + cause→action linkage",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 730),
        SOPRecord(id: "sop.ach", title: "Analysis of Competing Hypotheses", governingBody: "Heuer, CIA tradecraft",
                  editionImplemented: "Heuer 1999", implementedIn: "Hypotheses (ACH) studio — matrix, diagnosticity, no-verdict rule",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 730),
        SOPRecord(id: "sop.admiralty", title: "Source reliability scale", governingBody: "NATO (Admiralty code)",
                  editionImplemented: "STANAG A–F × 1–6", implementedIn: "Source reliability rating — AdmiraltyCode",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 730),
        SOPRecord(id: "sop.frcp26b5", title: "Privilege log requirements", governingBody: "US Federal Rules of Civil Procedure",
                  editionImplemented: "FRCP 26(b)(5)(A), 2015 am.", implementedIn: "Privilege Log Studio — describe-without-revealing gates",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.frcp26a2b", title: "Expert report contents", governingBody: "US FRCP + Daubert",
                  editionImplemented: "FRCP 26(a)(2)(B); Daubert (1993)", implementedIn: "Forensic Studio — 8-section report, method justification",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.naic901", title: "Insurance fraud reporting", governingBody: "NAIC / NICB",
                  editionImplemented: "NAIC Model #901 + NICB indicators", implementedIn: "SIU Studio — red flags, good-faith referral gate",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.gps", title: "Genealogical Proof Standard", governingBody: "Board for Certification of Genealogists",
                  editionImplemented: "GPS, 5 elements (2019 ed.)", implementedIn: "Proof Argument Studio — five-element gates",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 730),
        SOPRecord(id: "sop.ftc", title: "Endorsement & disclosure guides", governingBody: "US FTC",
                  editionImplemented: "Guides, 2023 revision", implementedIn: "Publish Package Studio — disclosure gate",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.custody", title: "Digital evidence handling", governingBody: "SWGDE / NIST (intl. ISO/IEC 27037)",
                  editionImplemented: "SWGDE best practices (current)", implementedIn: "Chain of custody — CustodyEvent, early hashing",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 365),
        SOPRecord(id: "sop.aiact", title: "AI transparency disclosure", governingBody: "EU AI Act",
                  editionImplemented: "Art. 50 (in force 2026-08)", implementedIn: "Point-of-use AI disclosure — answers + report page 1",
                  verifiedOn: "2026-08-23", reviewIntervalDays: 180),
    ]

    /// Records whose periodic re-check is due, honoring owner review overrides
    /// (id → yyyy-mm-dd of the most recent manual verification).
    public static func due(now: Date, overrides: [String: String] = [:]) -> [SOPRecord] {
        records.filter { r in
            effective(r, overrides: overrides).isDue(now: now)
        }
    }

    /// The record with its owner override (if any) applied.
    private static func effective(_ r: SOPRecord, overrides: [String: String]) -> SOPRecord {
        overrides[r.id].map { r.withVerifiedOn($0) } ?? r
    }

    /// The next periodic review to fall due across the whole board, honoring
    /// owner overrides (D-8): the record with the EARLIEST due date, so the
    /// findings/approval surface can print "next periodic review …" honestly.
    /// nil only if every record's date fails to parse.
    public static func nextDue(now: Date, overrides: [String: String] = [:]) -> (record: SOPRecord, date: Date)? {
        records
            .compactMap { r -> (record: SOPRecord, date: Date)? in
                let e = effective(r, overrides: overrides)
                guard let d = e.dueDate() else { return nil }
                return (e, d)
            }
            .min { $0.date < $1.date }
    }

    /// The board as a hardcopy — exportable, like every other deliverable.
    public static func markdown(now: Date, overrides: [String: String] = [:]) -> String {
        let f = DateFormatter(); f.dateStyle = .long
        var out = "# SOP Compliance Board — \(f.string(from: now))\n\n"
        out += "| SOP | Governing body | Edition implemented | Enforced in | Verified | Check |\n|---|---|---|---|---|---|\n"
        for r in records {
            let verified = overrides[r.id] ?? r.verifiedOn
            let effective = SOPRecord(id: r.id, title: r.title, governingBody: r.governingBody,
                                      editionImplemented: r.editionImplemented, implementedIn: r.implementedIn,
                                      verifiedOn: verified, reviewIntervalDays: r.reviewIntervalDays)
            out += "| \(r.title) | \(r.governingBody) | \(r.editionImplemented) | \(r.implementedIn) | \(verified) | \(effective.isDue(now: now) ? "⚠️ review due" : "✓ current") |\n"
        }
        out += "\nPeriodic checks are on-device reminders; re-verification is a human act against the governing body's current text, recorded with a date.\n"
        out += "\n_\(LegalNotice.conformanceScopeNote)_\n"
        return out
    }
}
