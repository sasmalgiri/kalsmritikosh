//
//  IdentifierAnchorTests.swift
//  KalsmritikoshTests
//
//  V3 3a — anchor identity infra (behavior-neutral until bound at 3c). Locks the
//  D1/D2 ruling: one kind specialized by field-data, identity = (field,
//  canonicalValue) exactly, display by constant, resolve-or-create by exact
//  normalized equality only (the resolver cage's coincidence rule).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V3 3a — IdentifierAnchor identity")
struct IdentifierAnchorTests {

    @Test("Canonical value + identity key normalize spelling; identity is (field, canonicalValue)")
    func identityKey() {
        // Label/spacing spellings of one number → one canonical value → one key.
        #expect(IdentifierAnchor.canonicalValue("Patent No. 555489") == "555489")
        #expect(IdentifierAnchor.identityKey(field: "patentNumber", value: "Patent No. 555489")
                == IdentifierAnchor.identityKey(field: "patentnumber", value: "555489"))
    }

    @Test("Coincidence (D2): same value under two fields → TWO distinct anchors, never conflated")
    func sameValueTwoFieldsTwoAnchors() {
        let patentKey = IdentifierAnchor.identityKey(field: "patentNumber", value: "555489")
        let appKey = IdentifierAnchor.identityKey(field: "applicationNumber", value: "555489")
        #expect(patentKey != appKey, "patent 555489 and application 555489 must be distinct anchors")
    }

    @Test("Display name is by CONSTANT: displayLabel + canonical atom")
    func displayByConstant() {
        #expect(IdentifierAnchor.displayName(field: "patentnumber", canonicalValue: "555489") == "Patent No. 555489")
        #expect(IdentifierAnchor.displayName(field: "applicationnumber", canonicalValue: "202211045678") == "Application No. 202211045678")
        // A field with no label falls back to the bare atom (never fuses a spelling).
        #expect(IdentifierAnchor.displayName(field: "casenumber", canonicalValue: "44/2024") == "44/2024")
    }

    @Test("makeAnchor carries the field as data, stores the canonical atom, renders by constant")
    func makeAnchorShape() {
        let a = IdentifierAnchor.makeAnchor(field: "patentNumber", value: "Patent No 555489", sourceObjectID: UUID())
        #expect(a.kind == .identifierAnchor)
        #expect(a.normalizedValue == "555489")
        #expect(a.value == "Patent No. 555489")
        #expect(IdentifierAnchor.anchorField(of: a) == "patentnumber")
        #expect(a.qualityTier == .t1)
    }

    @Test("resolve-or-create: exact-normalized match resolves; coincidence + OCR-corrupt create separate")
    func resolveOrCreate() {
        let obj = UUID()
        let patent = IdentifierAnchor.makeAnchor(field: "patentNumber", value: "555489", sourceObjectID: obj)
        let app = IdentifierAnchor.makeAnchor(field: "applicationNumber", value: "555489", sourceObjectID: obj)
        let candidates = [patent, app]
        // A spelling variant of the same (field, value) resolves to the existing anchor.
        #expect(IdentifierAnchor.resolve(field: "patentnumber", value: "Patent No. 555489", among: candidates)
                == .existing(patent.id))
        // Same value, other field → resolves to that field's anchor, not the patent.
        #expect(IdentifierAnchor.resolve(field: "applicationNumber", value: "555489", among: candidates)
                == .existing(app.id))
        // OCR-corrupt identifier (555480) is a SEPARATE anchor — no fuzzy fold.
        #expect(IdentifierAnchor.resolve(field: "patentNumber", value: "555480", among: candidates) == .create)
        // Empty candidate set → create.
        #expect(IdentifierAnchor.resolve(field: "patentNumber", value: "555489", among: []) == .create)
    }
}
