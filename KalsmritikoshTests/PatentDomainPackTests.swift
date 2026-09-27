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

    @Test("A date after 'Patent' is never captured as a patent number")
    func dateNotAPatentNumber() {
        // Owner real-data case (2026-08-29): the number pattern's [\d,/]{5,}
        // swallowed "22/03/2023" out of "Patent : 22/03/2023".
        let f = PatentDomainPack.extractFacts(
            fromText: "Patent : 22/03/2023. Patent No. 555489 granted.",
            subjectLabel: "patent", blockID: block)
        let patents = f.filter { $0.field == "patentnumber" }.map(\.value)
        #expect(patents.contains { $0.contains("555489") }, "real patent number kept")
        #expect(!patents.contains { $0.contains("22/03/2023") || $0.contains("22032023") },
                "the date must not be a patent number: \(patents)")
        #expect(PatentDomainPack.isDateShapedNumber("Patent : 22/03/2023"))
        #expect(PatentDomainPack.isDateShapedNumber("2023-03-22"))
        #expect(!PatentDomainPack.isDateShapedNumber("Patent No. 555489"))
    }

    // MARK: - W-4 (owner witness, 2026-09-06) — permanent cases

    @Test("W-4: 'Patent Application-N' is an APPLICATION — the patent label may never claim it")
    func patentApplicationIsNotAPatentNumber() {
        let facts = PatentDomainPack.extractFacts(
            fromText: "Intimation regarding the Grant and Recordal of Patent Application-202331019665",
            subjectLabel: "s", blockID: UUID())
        print("W4-PROBE recordal:", facts.map { "\($0.field)=\($0.value)" })
        #expect(facts.contains { $0.field == "applicationnumber" && $0.value == "202331019665" })
        #expect(!facts.contains { $0.field == "patentnumber" && $0.value == "202331019665" },
                "the live register held patentnumber|202331019665 — this row keeps it dead")
    }

    @Test("W-4: prose letters never pose as a country code — 'ed202331019665' can never mint")
    func proseLettersAreNotACountryCode() {
        // The live junk: "…application … granted 202331019665" — under the old
        // pattern, 'ed' + space + digits matched as a prefixed identifier.
        let facts = PatentDomainPack.extractFacts(
            fromText: "The application for this invention was granted 202331019665 as its number",
            subjectLabel: "s", blockID: UUID())
        #expect(!facts.contains { $0.value.lowercased().hasPrefix("ed") },
                "got: \(facts.map(\.value))")
        // The validity gate itself, directly:
        #expect(PatentDomainPack.normalizeIdentifier("ed202331019665") == "")
        #expect(PatentDomainPack.normalizeIdentifier("202331019665(") == "202331019665",
                "edge punctuation is stripped, never stored")
        // Real country codes still work, attached and uppercase.
        #expect(PatentDomainPack.normalizeIdentifier("US1234567B2") == "US1234567B2")
        let us = PatentDomainPack.extractFacts(
            fromText: "Patent No. US1234567B2 was cited", subjectLabel: "s", blockID: UUID())
        print("W4-PROBE us:", us.map { "\($0.field)=\($0.value)" })
        #expect(us.contains { $0.field == "patentnumber" && $0.value == "US1234567B2" })
    }

    // MARK: - A1.1 (W-4c) — the role table

    @Test("W-4c: a labeled certificate line names applicant and inventor")
    func roleExtractionFromLabeledLines() {
        let cert = PatentDomainPack.extractFacts(
            fromText: "Applicant: Eco Sanskriti Innovation, Inventor: Shirshendu Sasmal",
            subjectLabel: "s", blockID: UUID())
        #expect(cert.contains { $0.field == "applicant" && $0.value.contains("Eco Sanskriti") })
        #expect(cert.contains { $0.field == "inventor" && $0.value.contains("Shirshendu") })
    }

    @Test("W-4c: the ask side — 'owner of this patent' resolves to the applicant field")
    func ownerResolvesToApplicantField() {
        let plan = QueryPlanCompiler().compile(
            intent: UserIntent(kind: .factualLookup, scope: .global, timeframe: nil,
                               entityHints: [], rawQuestion: "who is the owner of this patent?"),
            category: .fact, queryClass: .ordinary)
        #expect(plan.slotFieldIDs.contains("applicant"), "got: \(plan.slotFieldIDs)")
    }

    /// RED — a LOWERCASE POA grantor is counted, never stored. Two recorded
    /// owner witnesses are in direct conflict here, and this test records that
    /// rather than pretending it is settled:
    ///
    ///   W-4c asked for this exact POA to yield an applicant — the witnessed
    ///   gap was that the form plainly reads "I, shirshendu sasmal …" while the
    ///   answer said "Not found: identity".
    ///   W-5.1 then required that clause-shaped captures never reach the
    ///   register, after the live archive produced "acknowledge receipt" ×82
    ///   and "need patent agent" ×82 from the same `\bI …` pattern.
    ///
    /// W-5.1 won by requiring every name token to START uppercase, which this
    /// lowercase name fails. MEASURED, so the trade is not guesswork: the
    /// `roleStopwords` list alone does NOT catch "acknowledge receipt" or
    /// "need patent agent" (it does catch "am writing to state" and "wish to
    /// bring to your"), so the casing rule is load-bearing and relaxing it
    /// would readmit the witnessed junk.
    ///
    /// NOT fixed here deliberately. A sharper discriminator exists — the POA
    /// continuation set ("having" / "son of" / "nationality") is a document
    /// FORMULA, whereas the bare `of` alternative is what lets "I acknowledge
    /// receipt of …" match at all — so tightening the pattern could let casing
    /// relax. But the junk it guards against was counted on the owner's live
    /// archive, which cannot be re-measured here, so the change would ship
    /// unverified against the only data that justifies the gate. Owner call.
    @Test("W-4c vs W-5.1 — RULED: the POA formula recovers a lowercase grantor; the casing gate stays for clauses")
    func lowercasePOAGrantorIsNotStored() {
        let poa = "GENERAL POWER OF ATTORNEY (PATENTS) THE PATENTS ACT, 1970. Form of Authorization of an Agent. I, shirshendu sasmal having Nationality of India, hereby authorize the agent below. Application No. 202331019665."
        let facts = PatentDomainPack.extractFacts(fromText: poa, subjectLabel: "s", blockID: UUID())
        // Hard green: whatever is decided about the name, the POA's application
        // number must always extract. This half never regressed.
        #expect(facts.contains { $0.field == "applicationnumber" && $0.value == "202331019665" },
                "got: \(facts.map { "\($0.field)=\($0.value)" })")
        // Hard green: the casing rule is the ONLY thing standing in the way —
        // the same name Title-Cased passes every other gate. If this flips, the
        // cause is no longer casing and the note above is stale.
        #expect(!PatentDomainPack.isPlausibleRoleValue("shirshendu sasmal"))
        #expect(PatentDomainPack.isPlausibleRoleValue("Shirshendu Sasmal"))

        // RULED 2026-09-27 (P2.5): the formula-only `.poaGrantorRecovery` module
        // (default ON) recovers the grantor from the POA formula itself, so the
        // casing gate stays for everything else and this POA yields its applicant.
        // (W5FixTests pins both module states.) Was a known issue until then.
        #expect(facts.first { $0.field == "applicant" }?.value == "shirshendu sasmal",
                "got: \(facts.map { "\($0.field)=\($0.value)" })")
    }
}
