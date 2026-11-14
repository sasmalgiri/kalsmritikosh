//
//  ProceedingSharedNamePartTests.swift
//  KalsmritikoshTests
//
//  Public-data bench, 2026-11-03 (DOJ releases, 10 unrelated prosecutions): the releases of Jonathan
//  Taylor were unreadable scans, so no document names him. Another release names "Assistant U.S.
//  Attorney Brock Taylor"; the app answered Jonathan Taylor's office, plea, charges and document count
//  from that release. Same for "Christopher Lee" (the archive holds "Christopher Lee Saunders"). A
//  document that shares only one part of a person's name with a different full name is not about them.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Proceedings: a shared surname or given name is not the person", .serialized)
struct ProceedingSharedNamePartTests {

    static let reza = """
    U.S. Department of Justice
    District of New Mexico
    FOR IMMEDIATE RELEASE
    Tuesday, March 12, 2019
    Las Cruces Man Pleads Guilty to Methamphetamine Trafficking Charge
    LAS CRUCES – Joe Anthony Reza, 41, of Las Cruces, New Mexico, pleaded guilty today in federal court to possession with intent to distribute methamphetamine.
    In entering his guilty plea, Reza admitted that on June 3, 2018, he possessed 50 grams of methamphetamine which he intended to distribute.
    The case is being prosecuted by Assistant U.S. Attorney Brock Taylor of the U.S. Attorney’s Las Cruces Branch Office.
    """

    static let saunders = """
    U.S. Department of Justice
    Western District of Virginia
    FOR IMMEDIATE RELEASE
    Friday, August 9, 2019
    Roanoke Man Sentenced for Firearms Offense
    ROANOKE – Christopher Lee Saunders, 37, of Roanoke, was sentenced on August 8, 2019, to 84 months in federal prison for possession of a firearm by a convicted felon.
    Saunders pleaded guilty in April 2019.
    """

    static let releases: [(file: String, text: String)] = [("reza.txt", reza), ("saunders.txt", saunders)]

    // MARK: - Naming (pure)

    @Test("A four-word name keeps its last word behind a capitalised question word (ho22 adjudication X)")
    func fourWordNameBehindQuestionWord() {
        let name = "Arturo Carlos Murillo Prijic"
        for q in ["When Arturo Carlos Murillo Prijic was sentenced?", "What Arturo Carlos Murillo Prijic was charged with?",
                  "Did Arturo Carlos Murillo Prijic enter a guilty plea?", "Did Arturo Carlos Murillo Prijic plead guilty or not?",
                  "When was Arturo Carlos Murillo Prijic sentenced?", "Can you tell me the date on which Arturo Carlos Murillo Prijic was sentenced?"] {
            #expect(ProceedingAnswerer.person(in: q) == name, "\(q)")
        }
        // Shorter names are unchanged.
        #expect(ProceedingAnswerer.person(in: "When was Jonathan Taylor sentenced?") == "Jonathan Taylor")
        #expect(ProceedingAnswerer.person(in: "Did Gary L. Smith plead guilty?") == "Gary L. Smith")
        #expect(ProceedingAnswerer.person(in: "When Christi Machala's sentencing took place?") == "Christi Machala")
    }

    @Test("A full name is the person; one shared part with a different full name is not")
    func namesFully() {
        typealias P = ProceedingAnswerer
        #expect(!P.namesFully(Self.reza, person: "Jonathan Taylor"), "Brock Taylor is not Jonathan Taylor")
        #expect(!P.namesFully(Self.saunders, person: "Christopher Lee"), "Christopher Lee Saunders is not Christopher Lee")
        #expect(P.namesFully(Self.saunders, person: "Christopher Lee Saunders"))
        #expect(P.namesFully(Self.reza, person: "Joe Anthony Reza"))
        #expect(P.namesFully(Self.reza, person: "Joe Reza"), "a middle name between given name and surname")
        #expect(P.namesFully("Jonathan A. Taylor, 35, of Dayton, was sentenced.", person: "Jonathan Taylor"))
        #expect(P.namesFully("DEFENDANT: TAYLOR, Jonathan\nCase No. 3:19-cr-00012", person: "Jonathan Taylor"))
        #expect(P.namesFully("Jonathan “Jon” Taylor pleaded guilty.", person: "Jonathan Taylor"))
        #expect(P.namesFully("Dayton Man Jonathan Taylor Sentenced to 10 Years", person: "Jonathan Taylor"))
        #expect(P.namesFully("Christopher Lee, 29, was sentenced today.", person: "Christopher Lee"), "Christopher Lee in the text is Christopher Lee")
        // A list of people is not "Taylor, Jonathan"; two people in one sentence are not one name.
        #expect(!P.namesFully("Agents Brock Taylor, Jonathan Smith and others testified.", person: "Jonathan Taylor"))
        #expect(!P.namesFully("Jonathan Smith and Brock Taylor testified.", person: "Jonathan Taylor"))
        // The index pre-filter needs both name words.
        #expect(!P.hasNameWords(Self.reza, person: "Jonathan Taylor"))
        #expect(P.hasNameWords(Self.saunders, person: "Christopher Lee"))
    }

    @Test("The rules answer never reads a release naming another full name")
    func rulesAnswerIgnoresOtherFullNames() throws {
        let sources = Self.releases.map { ProceedingAnswerer.Source(objectID: UUID(), text: $0.text) }
        let lee = try #require(ProceedingAnswerer.parse("When was Christopher Lee sentenced?"))
        #expect(ProceedingAnswerer.answer(lee, sources: sources) == nil, "no document names Christopher Lee")
        let taylor = try #require(ProceedingAnswerer.parse("Did Jonathan Taylor enter a guilty plea?"))
        #expect(ProceedingAnswerer.answer(taylor, sources: sources) == nil)
        #expect(!ProceedingAnswerer.anySourceNames("Jonathan Taylor", in: sources))
        #expect(ProceedingAnswerer.namingSources("Christopher Lee", in: sources).isEmpty)
    }

    // MARK: - End to end over a ledger

    private func withArchive(_ releases: [(file: String, text: String)],
                             _ body: (MasterBrain) async throws -> Void) async throws {
        // Deep dive 2026-11-14 batch 1 — Fully private for this test's task tree only (never the process-wide argument domain).
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) { try await withArchiveBody(releases, body) }
    }

    private func withArchiveBody(_ releases: [(file: String, text: String)],
                                 _ body: (MasterBrain) async throws -> Void) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pj-namepart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("namepart.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest else {
            Issue.record("ledger did not boot"); return
        }
        for r in releases {
            let url = temp.appendingPathComponent(r.file)
            try r.text.write(to: url, atomically: true, encoding: .utf8)
            _ = try await ingest.ingest(fileAt: url)
        }
        try await body(await state.brain)
    }

    @Test("Questions about a person no document names are refused, never answered from another person's release")
    func sharedNamePartIsRefused() async throws {
        try await withArchive(Self.releases) { brain in
            let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
            let refused: [(q: String, person: String)] = [
                ("Which prosecutor's office handled the case against Jonathan Taylor?", "Jonathan Taylor"),
                ("Did Jonathan Taylor enter a guilty plea?", "Jonathan Taylor"),
                ("I'm trying to confirm — did Jonathan Taylor plead guilty in this case?", "Jonathan Taylor"),
                ("What charges was Jonathan Taylor facing?", "Jonathan Taylor"),
                ("How many press releases reference Jonathan Taylor?", "Jonathan Taylor"),
                ("When was Christopher Lee sentenced?", "Christopher Lee"),
            ]
            for (q, person) in refused {
                let a = await brain.answer(question: q, access: access)
                #expect(a.refused, "refused: \(q) → \(a.body.prefix(200))")
                #expect(a.citations.isEmpty, "nothing cited from another person's release: \(q)")
                #expect(a.body.contains("names \(person)"), "says no document names them: \(q) → \(a.body.prefix(200))")
                #expect(!a.body.contains("Reza") && !a.body.contains("Brock") && !a.body.contains("Saunders"), "no other person's text: \(q)")
            }
            // Controls: the people the documents do name are still answered from their own releases.
            let saunders = await brain.answer(question: "When was Christopher Lee Saunders sentenced?", access: access)
            #expect(!saunders.refused, "answered: \(saunders.refusalReason ?? "")")
            #expect(saunders.body.contains("August 8, 2019"), "his own release: \(saunders.body.prefix(200))")
            let reza = await brain.answer(question: "Did Joe Anthony Reza plead guilty?", access: access)
            #expect(!reza.refused, "answered: \(reza.refusalReason ?? "")")
            #expect(reza.body.hasPrefix("Yes"), "his own plea: \(reza.body.prefix(200))")
        }
    }

    @Test("'Jonathan A. Taylor' and 'TAYLOR, Jonathan' name Jonathan Taylor in the archive")
    func middleInitialAndSurnameFirstAreThePerson() async throws {
        let taylor: [(file: String, text: String)] = [
            ("taylor-a.txt", """
            U.S. Department of Justice
            Southern District of Ohio
            FOR IMMEDIATE RELEASE
            Monday, June 3, 2019
            Dayton Man Sentenced for Wire Fraud
            DAYTON – Jonathan A. Taylor, 52, of Dayton, was sentenced on May 31, 2019, to 30 months in federal prison for wire fraud.
            """),
            ("taylor-b.txt", """
            UNITED STATES DISTRICT COURT FOR THE SOUTHERN DISTRICT OF OHIO
            Criminal docket
            DEFENDANT: TAYLOR, Jonathan
            The defendant pleaded guilty on January 14, 2019, to one count of wire fraud.
            """),
        ]
        try await withArchive(Self.releases + taylor) { brain in
            let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
            let count = await brain.answer(question: "How many press releases reference Jonathan Taylor?", access: access)
            #expect(!count.refused, "answered: \(count.body.prefix(200))")
            #expect(count.body.hasPrefix("2 of the documents"), "both documents, not Reza's: \(count.body.prefix(300))")
            let sentenced = await brain.answer(question: "When was Jonathan Taylor sentenced?", access: access)
            #expect(!sentenced.refused && sentenced.body.contains("May 31, 2019"), "his own release: \(sentenced.body.prefix(200))")
        }
    }
}
