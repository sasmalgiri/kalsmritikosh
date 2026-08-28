//
//  PatentDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-007 — patent pack extracts patent number + official status as evidence-linked facts;
//  quiet on non-patent text.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-007 PatentDomainPack")
struct PatentDomainPackTests {

    private let block = UUID()

    @Test("Granted patent yields number + granted status")
    func granted() {
        let f = PatentDomainPack.extractFacts(fromText: "Patent No. 402349 has been granted.",
                                              subjectLabel: "patent", blockID: block)
        // GenericFact lowercases/normalizes field names, so "patentNumber" → "patentnumber".
        let byField = Dictionary(uniqueKeysWithValues: f.map { ($0.field, $0.value) })
        #expect(byField["patentnumber"]?.contains("402349") == true)
        #expect(byField["status"] == "granted")
        #expect(f.allSatisfy { $0.status == .sourceAsserted && $0.sourceBlockIDs == [block] })
    }

    @Test("Filed application maps to filed status")
    func filed() {
        #expect(PatentDomainPack.status(in: "Application No 2024110 filed and pending") == "filed")
    }

    @Test("Terminal states take priority (granted over pending wording)")
    func terminalPriority() {
        #expect(PatentDomainPack.status(in: "grant of patent; earlier pending") == "granted")
    }

    @Test("Non-patent text extracts nothing")
    func quiet() {
        #expect(PatentDomainPack.extractFacts(fromText: "Lunch at noon?", subjectLabel: "x", blockID: block).isEmpty)
    }

    @Test("Application and granted numbers are DISTINCT fields — the 555489 ground-truth case")
    func applicationVsGrantedNumberFields() {
        // Owner ground-truth failure (2026-08-28): a grant letter carries BOTH
        // numbers; the old extractor filed the first match only, under one
        // shared field, so the granted number lost the majority vote to the
        // application number and never surfaced in the answer.
        let text = "Title: Hybrid Reluctance Induction Motor. Indian Application No: 202331019665. "
            + "The application has been granted and the Patent No. 555489 accorded."
        let f = PatentDomainPack.extractFacts(fromText: text, subjectLabel: "patent", blockID: block)
        let values = Dictionary(grouping: f, by: \.field).mapValues { $0.map(\.value) }
        #expect(values["applicationnumber"]?.contains { $0.contains("202331019665") } == true,
                "application number under its OWN field")
        #expect(values["patentnumber"]?.contains { $0.contains("555489") } == true,
                "granted number under patentNumber")
        #expect(values["patentnumber"]?.contains { $0.contains("202331019665") } != true,
                "application number must NOT pollute patentNumber")
        #expect(values["status"] == ["granted"])
    }
}
