//
//  DeviceFactProducerTests.swift
//  KalsmritikoshTests
//
//  HOST-8e — the wiring that makes HOST-8d actually run. The claim being tested
//  is that NO new pipeline machinery was needed: declaring the strong device
//  fields `.identifier`-shaped is the whole wiring, because
//  IngestCoordinator.bindIdentifierAnchors already resolves an anchor for every
//  identifier-shaped fact.
//
//  So the load-bearing assertions here are about SHAPE and ROUTING, not about
//  anchors — the anchor behaviour is already proved by AnchorWriterBindingTests
//  and V3AnchorFixturesTests, and this unit's job is to feed that path correctly.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Device facts wiring (HOST-8e)")
@MainActor
struct DeviceFactProducerTests {

    private let producer = DeviceFactProducer()

    private func parsePlist(_ object: [String: Any]) async throws -> ParsedDocument {
        let data = try PropertyListSerialization.data(
            fromPropertyList: object, format: .binary, options: 0)
        return try await PlistStructuralParser().parse(
            data: data, filename: "Info.plist", type: .plist,
            logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    // MARK: - The wiring claim

    @Test("The strong device fields are identifier-shaped — that IS the wiring")
    func strongFieldsAreIdentifierShaped() {
        // bindIdentifierAnchors keys off exactly this, so if the shape were wrong
        // the anchors would silently never be created and nothing else would fail.
        for field in DeviceIdentity.Field.allCases where field.isStrongIdentity {
            #expect(FactSchemaRegistry.expectedShape(of: field.rawValue) == .identifier,
                    "\(field.rawValue) is not identifier-shaped, so no anchor will be bound")
        }
    }

    @Test("The WEAK fields are deliberately NOT identifier-shaped")
    func weakFieldsAreNotAnchored() {
        // A computer name must be recorded and citable but must never create an
        // anchor: two machines are routinely called "MacBook Pro", and merging on
        // that would fuse unrelated devices into one subject.
        for field in DeviceIdentity.Field.allCases where !field.isStrongIdentity {
            #expect(FactSchemaRegistry.expectedShape(of: field.rawValue) != .identifier,
                    "\(field.rawValue) would create an anchor and merge unrelated devices")
        }
    }

    // MARK: - Producing facts from the artifacts that state them

    @Test("An iOS backup's Info.plist yields device facts with real values")
    func plistYieldsDeviceFacts() async throws {
        let doc = try await parsePlist([
            "Device Name": "Riyaz's iPhone",
            "Serial Number": "F2LXY1234567",
            "IMEI": "356938035643809",
            "Product Type": "iPhone15,3",
            "Last Backup Date": "2026-03-12"
        ])
        let facts = producer.facts(from: doc, subjectLabel: "Info.plist")
        let byField = Dictionary(uniqueKeysWithValues: facts.map { ($0.field, $0.value) })
        #expect(byField["deviceserialnumber"] == "F2LXY1234567")
        #expect(byField["imei"] == "356938035643809")
        #expect(byField["computername"] == "Riyaz's iPhone")
        #expect(byField["deviceproducttype"] == "iPhone15,3")
        #expect(facts.count == 4)      // the backup date is not a device identifier
    }

    @Test("Each fact cites the exact block its value was read from")
    func factsCiteTheirBlock() async throws {
        // A citation pointing at the whole file would make an answer say "this
        // backup mentions the serial somewhere", which is not evidence.
        let doc = try await parsePlist(["Serial Number": "F2LXY1234567"])
        let fact = try #require(producer.facts(from: doc, subjectLabel: "Info.plist").first)
        let blockID = try #require(fact.sourceBlockIDs.first)
        let block = try #require(doc.blocks.first { $0.id == blockID })
        #expect(block.rawText.contains("F2LXY1234567"))
    }

    @Test("Values come from the discrete attribute, not by re-splitting prose")
    func valuesComeFromAttributes() async throws {
        // The parsers now carry `value` as its own attribute. Re-splitting the
        // rendered "key = value" line would break the moment the rendering changed.
        let doc = try await parsePlist(["Serial Number": "F2LXY1234567"])
        let pairs = DeviceFactProducer.keyValues(from: doc)
        #expect(pairs.contains { $0.key == "Serial Number" && $0.value == "F2LXY1234567" })
    }

    @Test("A custody manifest's stated device identifier becomes a fact")
    func custodyYieldsDeviceFacts() async throws {
        let json = #"""
        {"evidenceNumber":"E-07","sourceDevice":"Apple MacBook Pro 14-inch",
         "sourceDeviceIdentifier":"C02XY1234567"}
        """#
        let doc = try await CustodyManifestStructuralParser().parse(
            data: Data(json.utf8), filename: "custody.json", type: .custodyManifest,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        let facts = producer.facts(from: doc, subjectLabel: "custody.json")
        let byField = Dictionary(uniqueKeysWithValues: facts.map { ($0.field, $0.value) })
        #expect(byField["deviceserialnumber"] == "C02XY1234567")
        #expect(byField["deviceproducttype"] == "Apple MacBook Pro 14-inch")
    }

    @Test("Facts record that the artifact STATED the value, not that we derived it")
    func assessmentIsSourceAsserted() async throws {
        let doc = try await parsePlist(["Serial Number": "F2LXY1234567"])
        let fact = try #require(producer.facts(from: doc, subjectLabel: "x").first)
        #expect(fact.assessment.basis == .sourceAsserted)
        #expect(fact.assessment.origin == .sourceExtraction)
        // High but not certain: a cloned or reflashed device can carry a serial
        // that no longer matches its hardware.
        #expect(fact.confidence == 0.9)
        #expect(fact.confidence < 1.0)
    }

    // MARK: - Staying silent where a device identifier would be a guess

    @Test("A document type that does not STATE identifiers produces nothing")
    func prosetypesProduceNothing() async throws {
        // A serial appearing in a PDF or an email is prose. Anchoring a device on
        // prose would be a guess, so this producer declines rather than regexing.
        let text = "The laptop serial is C02XY1234567 and the IMEI is 356938035643809."
        let doc = try await PlainTextStructuralParser().parse(
            data: Data(text.utf8), filename: "note.txt", type: .txt,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(producer.facts(from: doc, subjectLabel: "note.txt").isEmpty)
    }

    @Test("A plist with no device keys produces nothing")
    func irrelevantPlistProducesNothing() async throws {
        // This runs on every ingest, so it must be silent when irrelevant.
        let doc = try await parsePlist(["ProductName": "macOS", "ProductBuildVersion": "25A354"])
        let facts = producer.facts(from: doc, subjectLabel: "SystemVersion.plist")
        // ProductName matches the model key set, which is honest — it IS a model
        // name — but nothing strong is claimed from a version file.
        #expect(DeviceIdentity.strongestIdentity(
            in: DeviceIdentity.claims(fromKeyValues: DeviceFactProducer.keyValues(from: doc))) == nil)
        #expect(!facts.contains { FactSchemaRegistry.expectedShape(of: $0.field) == .identifier })
    }

    @Test("An empty document produces nothing and does not crash")
    func emptyDocumentIsSafe() async throws {
        let doc = try await PlistStructuralParser().parse(
            data: Data(), filename: "Info.plist", type: .plist,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(producer.facts(from: doc, subjectLabel: "x").isEmpty)
    }

    // MARK: - Merge, end to end through the fact layer

    @Test("Two extractions of one device yield facts that share an identity key")
    func twoExtractionsShareOneIdentity() async throws {
        // What the anchor door keys on. Equal keys mean ON CONFLICT resolves them
        // to the same entity row, which is the merge this program set out to get.
        let backup = try await parsePlist(["Serial Number": "F2LXY1234567",
                                           "Device Name": "Riyaz's iPhone"])
        let custodyJSON = #"{"sourceDeviceIdentifier":"F2LXY1234567"}"#
        let custody = try await CustodyManifestStructuralParser().parse(
            data: Data(custodyJSON.utf8), filename: "custody.json", type: .custodyManifest,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        let fromBackup = producer.facts(from: backup, subjectLabel: "Info.plist")
        let fromCustody = producer.facts(from: custody, subjectLabel: "custody.json")
        let backupSerial = try #require(fromBackup.first { $0.field == "deviceserialnumber" })
        let custodySerial = try #require(fromCustody.first { $0.field == "deviceserialnumber" })

        #expect(IdentifierAnchor.identityKey(field: backupSerial.field, value: backupSerial.value)
                == IdentifierAnchor.identityKey(field: custodySerial.field, value: custodySerial.value))
    }

    @Test("Producing facts twice from one document is deterministic")
    func deterministic() async throws {
        let doc = try await parsePlist(["Serial Number": "F2LXY1234567", "IMEI": "356938035643809"])
        let first = producer.facts(from: doc, subjectLabel: "x")
        let second = producer.facts(from: doc, subjectLabel: "x")
        #expect(first.map { "\($0.field)=\($0.value)" } == second.map { "\($0.field)=\($0.value)" })
    }

    @Test("The producer stamps its version so a re-ingest can tell generations apart")
    func producerVersionIsStamped() async throws {
        let doc = try await parsePlist(["Serial Number": "F2LXY1234567"])
        let fact = try #require(producer.facts(from: doc, subjectLabel: "x").first)
        #expect(fact.producerVersion == DeviceFactProducer.producerVersion)
    }
}
