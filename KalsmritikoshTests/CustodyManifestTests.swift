//
//  CustodyManifestTests.swift
//  KalsmritikoshTests
//
//  HOST-8 — the chain of custody. Everything the HOST-* and DISC-* lanes built
//  reads evidence; this records where the evidence came from, which is what makes
//  the archive a case rather than a search index over a folder.
//
//  The invariants here are about NOT OVERSTATING, because that is the only way
//  this can do harm:
//    • Absence of custody must be a disclosed state, never look like documentation.
//    • "Complete chain of custody" is all-or-nothing; a partial chain must say so.
//    • Nothing is inferred — not the examiner, not the tool, not the date.
//    • An unreadable manifest is LOUDER than a missing one: someone meant to
//      document the chain and the documentation cannot be read.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Chain of custody (HOST-8)")
@MainActor
struct CustodyManifestTests {

    private let parser = CustodyManifestStructuralParser()

    private func parse(_ json: String,
                       _ filename: String = "kalsmritikosh-custody.json") async throws -> ParsedDocument {
        try await parser.parse(data: Data(json.utf8), filename: filename,
                               type: .custodyManifest, logicalSourceID: UUID(),
                               sourceVersionID: UUID())
    }
    private func facts(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .paragraph }.map(\.rawText)
    }
    private func field(_ doc: ParsedDocument, _ name: String) -> EvidenceBlock? {
        doc.blocks.first {
            if case .string(let v)? = $0.attributes["custodyField"]?.value { return v == name }
            return false
        }
    }

    /// A fully documented acquisition.
    private var completeManifest: String {
        #"""
        {
          "caseNumber": "2026-CR-114",
          "evidenceNumber": "E-07",
          "examiner": "Insp. R. Ahmed",
          "agency": "Cyber Cell",
          "authority": "Search warrant 412/2026, Ld. CJM Alipore, 2026-03-10",
          "acquisitionTool": "Cellebrite UFED 4PC 7.71",
          "acquisitionDate": "2026-03-12T14:05:00+05:30",
          "sourceDevice": "Apple MacBook Pro 14-inch (Mac15,3)",
          "sourceDeviceIdentifier": "C02XY1234567",
          "sourceTimeZone": "Asia/Kolkata",
          "imageHash": { "algorithm": "SHA-256", "value": "9f86d081884c7d659a2f" },
          "recordStatus": "live",
          "notes": "Write-blocked acquisition; two verification passes."
        }
        """#
    }

    // MARK: - Detection

    @Test("A custody manifest is detected by name, ahead of the .json mapping")
    func detectedByName() {
        // Without this precedence the chain of custody reads as an ordinary JSON
        // document and never reaches the ledger AS custody.
        for name in ["kalsmritikosh-custody.json", "custody.json", "chain-of-custody.json"] {
            #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/\(name)")) == .custodyManifest,
                    "\(name) not detected")
        }
        // An ordinary JSON file is still JSON.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/config.json")) == .json)
    }

    @Test("It is a document the examiner authored, not machine evidence")
    func categoryIsDocument() {
        #expect(SourceType.custodyManifest.category == .document)
    }

    // MARK: - Each fact citable on its own

    @Test("Every custody fact is its own block, so each is cited separately")
    func oneFactPerBlock() async throws {
        // A single summary paragraph would let a retrieved answer quote "acquired
        // by Insp. R. Ahmed" while dropping "under Search warrant 412/2026" — and
        // in a proceeding the authority is the part that matters.
        let doc = try await parse(completeManifest)
        #expect(doc.extractionStatus == .complete)
        let authority = try #require(field(doc, "authority"))
        #expect(authority.rawText.contains("Search warrant 412/2026"))
        #expect(authority.locator.sectionPath == ["Chain of custody", "authority"])
        #expect(field(doc, "examiner")?.rawText == "Examiner: Insp. R. Ahmed")
        #expect(field(doc, "sourceDeviceIdentifier")?.rawText.contains("C02XY1234567") == true)
    }

    @Test("The acquisition date is recorded as a real, zone-correct instant")
    func acquisitionDateIsAbsolute() async throws {
        let doc = try await parse(completeManifest)
        let block = try #require(field(doc, "acquisitionDate"))
        // 14:05 +05:30 is 08:35Z. A legal fact, so the offset must be honoured.
        #expect(block.rawText == "Acquired: 2026-03-12T08:35:00Z")
    }

    @Test("The image hash names its algorithm, or says it does not")
    func hashNeedsAnAlgorithm() async throws {
        let doc = try await parse(completeManifest)
        #expect(field(doc, "imageHash")?.rawText.contains("(SHA-256)") == true)

        // A bare digest an examiner cannot reproduce is not verification, so the
        // gap is named rather than presented as a verified hash.
        let noAlgorithm = #"{"examiner":"A","imageHash":{"value":"abc123"}}"#
        let thin = try await parse(noAlgorithm)
        #expect(field(thin, "imageHash")?.rawText.contains("unstated algorithm") == true)
        #expect(thin.warnings.contains { $0.code == "custody.hash_no_algorithm" })
    }

    @Test("Record status is always stated, including when the manifest omits it")
    func recordStatusAlwaysPresent() async throws {
        // Whether records are live or recovered changes what a finding MEANS, so
        // the field is never simply absent.
        let complete = try await parse(completeManifest)
        #expect(field(complete, "recordStatus")?.rawText == "Record status: live data")

        let silent = try await parse(#"{"examiner":"A","caseNumber":"1"}"#)
        #expect(field(silent, "recordStatus")?.rawText.contains("not stated") == true)
        #expect(silent.warnings.contains { $0.code == "custody.status_unstated" })
    }

    // MARK: - Not overstating

    @Test("A complete chain reports complete; the disclosure carries the facts")
    func completeChainIsComplete() async throws {
        let doc = try await parse(completeManifest)
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("evidence E-07"))
        #expect(header.rawText.contains("case 2026-CR-114"))
        #expect(header.rawText.contains("Insp. R. Ahmed"))
        #expect(header.rawText.contains("Search warrant 412/2026"))
        #expect(header.rawText.contains("live data"))
        // And it does NOT claim incompleteness.
        #expect(!header.rawText.contains("Incomplete chain"))
        #expect(!doc.warnings.contains { $0.code == "custody.incomplete" })
    }

    @Test("A partial chain says exactly which fields are missing")
    func partialChainNamesTheGaps() async throws {
        // "Complete chain of custody" is a claim with consequences, so it is
        // all-or-nothing, and the gaps are named rather than glossed.
        let partial = #"""
        {"examiner":"Insp. R. Ahmed","acquisitionTool":"UFED","recordStatus":"live"}
        """#
        let doc = try await parse(partial)
        #expect(doc.extractionStatus == .partial)
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("Incomplete chain"))
        for gap in ["case number", "evidence number", "legal authority",
                    "acquisition date", "source device", "image hash"] {
            #expect(header.rawText.contains(gap), "gap '\(gap)' not disclosed")
        }
        let warning = try #require(doc.warnings.first { $0.code == "custody.incomplete" })
        #expect(warning.message.contains("still usable"))
    }

    @Test("Undocumented evidence is a disclosed STATE, not an empty record")
    func undocumentedIsAState() {
        // The whole point: absence must never render the same as documentation.
        let none = CustodyRecord.undocumented
        #expect(!none.isDocumented)
        #expect(!none.isComplete)
        #expect(none.disclosure == "No chain of custody recorded for this evidence.")
        // And a documented record is distinguishable from it.
        #expect(CustodyRecord(examiner: "A").isDocumented)
    }

    @Test("Nothing is inferred — a record states only what the manifest said")
    func nothingIsInferred() async throws {
        // Custody is a human attestation. A guessed value presented beside real
        // ones would be worse than a gap, because it would look identical.
        let doc = try await parse(#"{"caseNumber":"2026-CR-114"}"#)
        #expect(field(doc, "examiner") == nil)
        #expect(field(doc, "acquisitionTool") == nil)
        #expect(field(doc, "acquisitionDate") == nil)
        #expect(field(doc, "imageHash") == nil)
    }

    @Test("An acquisition date in an unrecognised shape is nil, never guessed")
    func badDateIsNotGuessed() {
        #expect(CustodyRecord.parseDate("2026-03-12T14:05:00+05:30") != nil)
        #expect(CustodyRecord.parseDate("2026-03-12") != nil)
        // Ambiguous or free-form: an acquisition date is a legal fact.
        #expect(CustodyRecord.parseDate("12/03/2026") == nil)
        #expect(CustodyRecord.parseDate("last Tuesday") == nil)
    }

    // MARK: - Honesty on bad input

    @Test("An UNREADABLE manifest is louder than a missing one")
    func unreadableManifestIsLoud() async throws {
        // Someone intended to document the chain and the documentation cannot be
        // read. That is a different, worse fact than never having documented it.
        let doc = try await parse("{ this is not json")
        #expect(doc.extractionStatus == .corrupt)
        let warning = try #require(doc.warnings.first { $0.code == "custody.undecodable" })
        #expect(warning.severity == .error)
        #expect(warning.message.contains("NOT recorded"))
    }

    @Test("A manifest that decoded but states nothing is an empty attestation")
    func emptyAttestationIsReported() async throws {
        let doc = try await parse("{}")
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "custody.no_fields" })
    }

    @Test("A zero-byte manifest is empty, not corrupt")
    func zeroBytesIsEmpty() async throws {
        let doc = try await parser.parse(data: Data(), filename: "custody.json",
                                         type: .custodyManifest, logicalSourceID: UUID(),
                                         sourceVersionID: UUID())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "custody.empty" })
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let first = try await parse(completeManifest).blocks.map(\.rawText)
        let second = try await parse(completeManifest).blocks.map(\.rawText)
        #expect(first == second)
    }

    // MARK: - Loader and registry

    @Test("The loader carries custody completeness in metadata and confidence")
    func loaderCarriesCompleteness() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("custody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let full = dir.appendingPathComponent("kalsmritikosh-custody.json")
        try Data(completeManifest.utf8).write(to: full)
        let complete = try await CustodyManifestLoader().ingest(fileAt: full, type: .custodyManifest)
        #expect(complete.confidence == .high)
        if case .bool(let done)? = complete.metadata["custodyComplete"]?.value { #expect(done) }
        else { Issue.record("custodyComplete missing") }
        #expect(complete.content.contains("Search warrant 412/2026"))

        // A partial chain is medium confidence and names its gaps in metadata:
        // the facts are exactly as stated, the attestation around them is not.
        let thin = dir.appendingPathComponent("custody.json")
        try Data(#"{"examiner":"A","recordStatus":"recovered"}"#.utf8).write(to: thin)
        let partial = try await CustodyManifestLoader().ingest(fileAt: thin, type: .custodyManifest)
        #expect(partial.confidence == .medium)
        if case .string(let missing)? = partial.metadata["custodyMissing"]?.value {
            #expect(missing.contains("imageHash"))
            #expect(missing.contains("authority"))
        } else {
            Issue.record("custodyMissing not recorded")
        }
    }

    @Test("An unreadable manifest fails the read rather than ingesting as empty")
    func loaderRejectsUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("custody-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("custody.json")
        try Data("{ broken".utf8).write(to: url)

        await #expect(throws: (any Error).self) {
            _ = try await CustodyManifestLoader().ingest(fileAt: url, type: .custodyManifest)
        }
    }

    @Test("The universal registry gives custody a real immediate plugin")
    func registryOwnsCustody() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.custodyManifest)
        #expect(plugin.pluginID == "format.custodyManifest")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}
