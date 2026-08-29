//
//  SlotFieldResolverTests.swift
//  KalsmritikoshTests
//
//  D-11 (P0 answer-quality pack) — identifier-class field routing. "What is
//  the granted patent number" resolves to the `patentnumber` fact field and
//  NEVER to `.definition`; genuine definition questions still map there.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("D-11 — slot field routing")
struct SlotFieldResolverTests {

    @Test("A dozen phrasings resolve to the right fact field and class")
    func phrasingsResolve() {
        let cases: [(q: String, field: String, class_: RequestedField)] = [
            ("what is the granted patent number", "patentnumber", .identifier),
            ("what is the patent number", "patentnumber", .identifier),
            ("patent no?", "patentnumber", .identifier),
            ("what is the application number", "applicationnumber", .identifier),
            ("give me the application no", "applicationnumber", .identifier),
            ("what is the publication number", "publicationnumber", .identifier),
            ("what is the invoice number for the march delivery", "invoicenumber", .identifier),
            ("what is the case number", "casenumber", .identifier),
            ("what is the pan", "pan", .identifier),
            ("what is the gstin", "gstin", .identifier),
            ("what is the grant date", "grantdate", .date),
            ("what is the date of filing", "filingdate", .date),
            ("on which date was the patent granted", "grantdate", .date),
        ]
        for c in cases {
            let resolved = SlotFieldResolver.resolve(in: c.q)
            #expect(resolved.first?.fieldID == c.field, "'\(c.q)' resolved \(resolved.map(\.fieldID))")
            #expect(resolved.first?.requestedField == c.class_, "'\(c.q)' class \(String(describing: resolved.first?.requestedField))")
        }
    }

    @Test("The compiled plan carries the slot and never maps it to definition")
    func planNeverDefinition() {
        for q in ["what is the granted patent number",
                  "what is the application number",
                  "what is the invoice number"] {
            let fields = QueryPlanCompiler.requestedFields(
                in: q, slots: SlotFieldResolver.resolve(in: q))
            #expect(!fields.contains(.definition), "'\(q)' mapped to definition")
            #expect(fields.contains(.identifier))
        }
    }

    @Test("Genuine definition questions still map to definition")
    func genuineDefinitionsSurvive() {
        for q in ["what is love", "what is a fiduciary duty", "explain the enrichment ladder"] {
            let slots = SlotFieldResolver.resolve(in: q)
            #expect(slots.isEmpty, "'\(q)' unexpectedly resolved \(slots.map(\.fieldID))")
            let fields = QueryPlanCompiler.requestedFields(in: q, slots: slots)
            #expect(fields.contains(.definition), "'\(q)' lost its definition mapping")
        }
    }

    @Test("Word boundaries hold — 'pan' never fires inside 'company' or 'panel'")
    func wordBoundaries() {
        #expect(SlotFieldResolver.resolve(in: "which company panel approved it").isEmpty)
        #expect(SlotFieldResolver.resolve(in: "what is the pan of the applicant").first?.fieldID == "pan")
    }

    @Test("Human labels for ledger field ids")
    func humanLabels() {
        #expect(SlotFieldResolver.humanLabel(forFieldID: "applicationnumber") == "Application number")
        #expect(SlotFieldResolver.humanLabel(forFieldID: "patentnumber") == "Patent number")
        #expect(SlotFieldResolver.humanLabel(forFieldID: "grantdate") == "Grant date")
        #expect(SlotFieldResolver.humanLabel(forFieldID: "employer") == "Employer")
        // Unknown fields keep the safe pre-D-12 fallback.
        #expect(SlotFieldResolver.humanLabel(forFieldID: "customfield") == "Customfield")
    }
}
