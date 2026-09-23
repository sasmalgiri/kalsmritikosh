//
//  DeviceIdentityTests.swift
//  KalsmritikoshTests
//
//  HOST-8d — device identity, so two extractions from one phone resolve to ONE
//  subject. The unit's whole argument is that a device needs no new machinery: it
//  is an `identifierAnchor`, which already gives merge, non-conflation and gate
//  passage. These tests prove each of those three is real rather than assumed.
//
//  The gate one matters most. A serial like `C02XY1234567` is mixed letters and
//  digits with no spaces — precisely the quality gate's `hostname-shape` HARD
//  JUNK rule, which crashed a write door earlier in this program. Routed as a
//  person or organization it would trip the assertion; routed as an anchor it is
//  correct. There is a test asserting exactly that pair of facts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Device identity (HOST-8d)")
@MainActor
struct DeviceIdentityTests {

    // MARK: - Merge: the property the unit exists for

    @Test("The same serial in two extractions produces ONE identity")
    func sameSerialMergesAcrossExtractions() {
        // This is the merge. `resolveOrCreateAnchor` ends in
        // ON CONFLICT(kind, normalized) DO UPDATE, keyed on this identity, so an
        // equal key means the same entity row — nothing new had to be written.
        let first = DeviceIdentity.claims(from: CustodyRecord(
            evidenceNumber: "E-07", sourceDeviceIdentifier: "C02XY1234567"))
        let second = DeviceIdentity.claims(from: CustodyRecord(
            evidenceNumber: "E-11", sourceDeviceIdentifier: "C02XY1234567"))
        let a = try! #require(DeviceIdentity.strongestIdentity(in: first))
        let b = try! #require(DeviceIdentity.strongestIdentity(in: second))
        #expect(a.identityKey == b.identityKey)
        #expect(DeviceIdentity.describeSameDevice(first, second))
    }

    @Test("Spacing and punctuation noise in a serial does not split the device")
    func canonicalisationSurvivesNoise() {
        // Artifacts write the same serial with different spacing; canonical value
        // is the same normalization the fact comparator uses, so they agree.
        let clean = DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: "C02XY1234567")
        let noisy = DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: " C02XY 123-4567 ")
        #expect(clean?.identityKey == noisy?.identityKey)
    }

    @Test("Two different devices stay two devices")
    func differentSerialsDoNotMerge() {
        let a = DeviceIdentity.claims(from: CustodyRecord(sourceDeviceIdentifier: "C02XY1234567"))
        let b = DeviceIdentity.claims(from: CustodyRecord(sourceDeviceIdentifier: "C02XY7654321"))
        #expect(!DeviceIdentity.describeSameDevice(a, b))
    }

    // MARK: - Non-conflation

    @Test("A serial and an IMEI sharing the same digits are NOT one device")
    func fieldsDoNotConflate() {
        // Identity is (anchorField, canonicalValue) exactly. Without the field in
        // the key, a serial that happened to match an IMEI would silently merge
        // two unrelated devices.
        let serial = DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: "356938035643809")
        let imei = DeviceIdentity.makeClaim(field: .imei, stated: "356938035643809")
        #expect(serial?.canonicalValue == imei?.canonicalValue)
        #expect(serial?.identityKey != imei?.identityKey)
    }

    @Test("An identifier's KIND is read from its shape, not assumed to be a serial")
    func identifierKindIsClassifiedByShape() {
        // The custody manifest has one identifier field and does not say which
        // kind it is. Calling a 15-digit IMEI a serial would be wrong, and would
        // also stop it merging with an IMEI read from a plist.
        #expect(DeviceIdentity.classify(identifier: "356938035643809") == .imei)
        #expect(DeviceIdentity.classify(identifier: "A1B2C3D4E5F607") == .meid)
        #expect(DeviceIdentity.classify(identifier: String(repeating: "a1", count: 20)) == .deviceUDID)
        #expect(DeviceIdentity.classify(identifier: "00:1A:2B:3C:4D:5E") == .deviceMACAddress)
        // The fallback is the WEAKEST reading, never the strongest.
        #expect(DeviceIdentity.classify(identifier: "C02XY1234567") == .deviceSerialNumber)
    }

    // MARK: - The quality gate

    @Test("A serial passes the gate as an ANCHOR but would be hard junk as a person")
    func anchorRoutingIsWhatSatisfiesTheGate() throws {
        // The crash earlier in this program was an ungated hostname-shape entity
        // reaching a write door. A serial has exactly that shape, so the routing
        // choice is what keeps this unit safe rather than a carve-out.
        let gate = EntityQualityGate()
        let serial = "C02XY1234567"

        let asPerson = Entity(kind: .person, value: serial, sourceObjectID: UUID())
        #expect(gate.classify(asPerson) == "hostname-shape")

        // As an anchor, the display name is machine-built from a label constant,
        // so what the gate sees is "Device serial C02XY1234567".
        let anchor = IdentifierAnchor.makeAnchor(
            field: DeviceIdentity.Field.deviceSerialNumber.rawValue,
            value: serial, sourceObjectID: UUID())
        #expect(anchor.kind == .identifierAnchor)
        let verdict = gate.classify(anchor)
        #expect(!EntitiesRepository.hardJunkClasses.contains(verdict ?? ""),
                "anchor classified as hard junk: \(verdict ?? "nil")")
    }

    @Test("The anchor's display name comes from a registered CONSTANT")
    func displayNameIsByConstant() {
        // Registered in displayLabel(forFieldID:), so the name is immune to how
        // an artifact spelled the key.
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "deviceSerialNumber") == "Device serial")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "imei") == "IMEI")
        #expect(IdentifierAnchor.displayName(field: "deviceSerialNumber",
                                             canonicalValue: "C02XY1234567")
                == "Device serial C02XY1234567")
    }

    // MARK: - Reading what artifacts actually stated

    @Test("An iOS backup's Info.plist key/values yield the device's identifiers")
    func plistKeyValuesYieldIdentifiers() throws {
        // These are the keys Apple actually writes, and the plist lane (HOST-1)
        // already emits them as key/value blocks.
        let claims = DeviceIdentity.claims(fromKeyValues: [
            ("Device Name", "Riyaz's iPhone"),
            ("Serial Number", "F2LXY1234567"),
            ("IMEI", "356938035643809"),
            ("Product Type", "iPhone15,3"),
            ("Unique Identifier", String(repeating: "AB", count: 20)),
            ("Last Backup Date", "2026-03-12T14:05:00Z")      // not an identifier
        ])
        let fields = Set(claims.map(\.field))
        #expect(fields.contains(.deviceSerialNumber))
        #expect(fields.contains(.imei))
        #expect(fields.contains(.deviceUDID))
        #expect(fields.contains(.computerName))          // "Device Name"
        #expect(fields.contains(.deviceProductType))
        #expect(claims.count == 5)                       // the date is not one

        // The serial is what merges; the device's NAME is not.
        let strongest = try #require(DeviceIdentity.strongestIdentity(in: claims))
        #expect(strongest.field == .deviceSerialNumber)
    }

    @Test("A registry path's LAST component is what matches, so full paths work")
    func registryPathsMatchOnTheLeaf() {
        let claims = DeviceIdentity.claims(fromKeyValues: [
            ("SYSTEM\\ControlSet001\\Control\\ComputerName\\ComputerName", "EVIDENCE-01"),
            ("SOFTWARE\\Microsoft\\Cryptography\\MachineGuid",
             "4c4c4544-0051-3210-8056-b8c04f564432")
        ])
        // The literal belongs on statedValue — "exactly as the artifact wrote it,
        // for citation". canonicalValue is normalised for identity, so asserting
        // the original casing against it was my error, not the code's.
        let name = try! #require(claims.first { $0.field == .computerName })
        #expect(name.statedValue == "EVIDENCE-01")
        #expect(claims.contains { $0.field == .deviceUDID })
    }

    @Test("A computer name alone never merges two extractions")
    func weakIdentityDoesNotMerge() {
        // Two machines are routinely called "MacBook Pro". Merging on that would
        // fuse unrelated devices into one subject, which is worse than leaving
        // them separate.
        let a = DeviceIdentity.claims(fromKeyValues: [("ComputerName", "MacBook Pro")])
        let b = DeviceIdentity.claims(fromKeyValues: [("ComputerName", "MacBook Pro")])
        #expect(!a.isEmpty)
        #expect(DeviceIdentity.strongestIdentity(in: a) == nil)
        #expect(!DeviceIdentity.describeSameDevice(a, b))
    }

    // MARK: - Honesty

    @Test("Placeholder identifiers are refused, or every device would merge")
    func placeholdersAreRefused() {
        // Manufacturers and imaging tools leave these behind. Anchoring on one
        // would merge every device that shares the placeholder into one subject.
        for junk in ["Unknown", "None", "0", "To Be Filled By O.E.M.",
                     "System Serial Number", "000000000000000"] {
            #expect(DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: junk) == nil,
                    "'\(junk)' was accepted as a device identifier")
        }
        // A real serial is still accepted.
        #expect(DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: "C02XY1234567") != nil)
    }

    @Test("Blank and one-character identifiers are refused")
    func emptyIdentifiersAreRefused() {
        #expect(DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: "") == nil)
        #expect(DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: "   ") == nil)
        #expect(DeviceIdentity.makeClaim(field: .deviceSerialNumber, stated: "X") == nil)
    }

    @Test("Nothing is inferred — a custody record with no device yields no claims")
    func nothingIsInferred() {
        #expect(DeviceIdentity.claims(from: .undocumented).isEmpty)
        #expect(DeviceIdentity.claims(from: CustodyRecord(examiner: "A")).isEmpty)
        #expect(DeviceIdentity.claims(fromKeyValues: []).isEmpty)
    }

    @Test("Reading the same artifact twice yields the same claims in the same order")
    func deterministic() {
        let pairs = [("Serial Number", "F2LXY1234567"), ("IMEI", "356938035643809"),
                     ("Device Name", "Riyaz's iPhone")]
        let first = DeviceIdentity.claims(fromKeyValues: pairs)
        let second = DeviceIdentity.claims(fromKeyValues: pairs)
        #expect(first == second)
    }

    @Test("A duplicated key does not produce two claims for one identifier")
    func duplicateKeysCollapse() {
        let claims = DeviceIdentity.claims(fromKeyValues: [
            ("Serial Number", "F2LXY1234567"),
            ("SerialNumber", "F2LXY1234567"),
            ("serial", " F2LXY1234567 ")
        ])
        #expect(claims.count == 1)
    }

    @Test("Every field declares whether it is strong enough to merge on")
    func everyFieldStatesItsStrength() {
        // A new field added without deciding this would default into one of the
        // two behaviours silently; the switch is exhaustive so it cannot.
        let strong = DeviceIdentity.Field.allCases.filter(\.isStrongIdentity)
        let weak = DeviceIdentity.Field.allCases.filter { !$0.isStrongIdentity }
        #expect(Set(strong) == [.deviceSerialNumber, .imei, .meid, .deviceUDID, .deviceMACAddress])
        #expect(Set(weak) == [.computerName, .deviceProductType])
        // And every field has a label, so no anchor can fall back to a bare value.
        for field in DeviceIdentity.Field.allCases {
            #expect(!field.label.isEmpty)
            #expect(SlotAnswerComposer.displayLabel(forFieldID: field.rawValue) == field.label,
                    "\(field.rawValue) is not registered in displayLabel")
        }
    }
}
