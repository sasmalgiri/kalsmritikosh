//
//  ALCOAGroup4Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 4 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): ALC-13 data integrity report,
//  ALC-17 certified copy + versioned cleaned text, ALC-18 legible (rejected AI writes kept, Ask transcripts retracted),
//  ALC-19 one export date style, ALC-20 archival PDF + retention register, ALC-21 key rotation, sealed exports, capture
//  hosts. No model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 4 — ALC-13/17/18/19/20/21", .serialized)
struct ALCOAGroup4Tests {

    // MARK: - ALC-19 consistent

    @Test("ALC-19: a day is '3 Aug 2026', a time is ISO 8601 with the zone stated, money always carries its ISO code")
    func oneExportDateStyle() throws {
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        var c = Calendar(identifier: .gregorian); c.timeZone = kolkata
        let at = try #require(c.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 14, minute: 5, second: 9)))
        #expect(ExportDateStyle.day(at, zone: kolkata) == "3 Aug 2026")
        #expect(ExportDateStyle.stamp(at, zone: kolkata) == "2026-08-03T14:05+05:30 (Asia/Kolkata)")
        #expect(ExportDateStyle.stamp(at, zone: kolkata, seconds: true) == "2026-08-03T14:05:09+05:30 (Asia/Kolkata)")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ExportDateStyle.stamp(at, zone: utc).hasSuffix("Z (\(utc.identifier))"))
        #expect(ExportDateStyle.zoneStatement(zone: kolkata, at: at).contains("Asia/Kolkata, UTC+05:30"))
        #expect(ExportDateStyle.money(Decimal(string: "50000")!, currency: "INR") == "INR 50,000.00")
        #expect(ExportDateStyle.money(Decimal(string: "12.5")!, currency: "") == "12.5 (currency not stated)")
        #expect(ExportDateStyle.money(Decimal(string: "7")!, currency: "$").contains("currency not stated"))
        #expect(CaseMapMoney(amount: Decimal(string: "18400.3")!, currency: "USD").display == "USD 18,400.30")
        // The case report's day and stamp, the chronology drafter and the persona report builders read the same style.
        #expect(CaseFileDocuments.d(at) == ExportDateStyle.day(at))
        #expect(CaseFileDocuments.t(at) == ExportDateStyle.stamp(at))
        #expect(ChronologyDrafter.day(at) == ExportDateStyle.day(at))
        #expect(ExportDateStyle.stampWriter.string(from: at) == ExportDateStyle.stamp(at))
        #expect(CaseFileDocuments.footer("Asha", at).contains("ISO 8601 with the zone stated"))
    }

    @Test("ALC-19: no report builder still uses a locale date style")
    func noLocaleDateStyleInReports() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh")
        for name in ["Investigate/ACHAnalysis.swift", "Investigate/RootCauseAnalysis.swift", "Investigate/PersonaDeliverables2.swift",
                     "Investigate/SIUReferral.swift", "Investigate/FactCheckMemo.swift", "Investigate/PrivilegeLog.swift",
                     "Investigate/DisputeFile.swift", "Investigate/WorkplaceInvestigation.swift", "Investigate/StudioAudit.swift",
                     "Investigate/CaseFile/CaseFileDocuments.swift", "Export/ChronologyDrafter.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("dateStyle = .long") && !text.contains("dateStyle = .medium"), "\(name)")
        }
    }
}
