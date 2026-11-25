//
//  AgentEvalStrictnessTests.swift
//  KalsmritikoshTests
//
//  The three over-strict mechanical checks fair run 3 found (docs/evidence/agent-eval-2026-11-23/FAIR3.md §8 items 1–3):
//  1. a year or date in a claim that is the cited document's own date ("The 2014 release says …") was required in the quote;
//  2. the AI's `about` had to be a literal substring of the passage ("Bradley Kerr" vs "BRADLEY J KERR");
//  3. the second look was not told which statements the checker dropped, or why.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("FAIR3 strictness fixes — own document date, about by name tokens, second look told what was dropped")
struct AgentEvalStrictnessTests {
    typealias C = VerifiedAnswerComposer

    static let release2014 = """
    Arrest Made In Ventura For $5 Million Movie Studio Construction Scam
    U.S. Attorney's Office, Eastern District of California — press release, November 6, 2014

    SACRAMENTO, Calif. — A 32-count indictment was unsealed today after the arrest of Carissa Carpenter. As a result of the scheme, investors, firms who did work for Carpenter and municipalities collectively lost over $5 million on the project. Further, during the investigation in July 2013, Carpenter told an FBI agent that she had used 50-75 percent of investor money for the project.
    """
    static let quote = "investors, firms who did work for Carpenter and municipalities collectively lost over $5 million on the project"

    static func claim(_ text: String, quote: String = quote, about: String? = nil) -> C.Claim {
        C.Claim(text: text, quote: quote, passage: 1, about: about)
    }

    // MARK: - 1. The cited document's own date

    @Test("1: the cited document's own year or date (dateline or file name) need not be in the quote; any other number still must")
    func ownDocumentDate() {
        let named = [C.Passage(objectID: UUID(), text: Self.release2014, fileName: "carpenter-2014-11-06-press-release.txt")]
        #expect(C.whyNot(Self.claim("The 2014 release says they collectively lost over $5 million."), passages: named) == nil)
        #expect(C.whyNot(Self.claim("The November 6, 2014 release says they lost over $5 million."), passages: named) == nil)
        #expect(C.whyNot(Self.claim("In November 2014 the release said they lost over $5 million."), passages: named) == nil)
        // The dateline alone is enough (no file name).
        let unnamed = [C.Passage(objectID: UUID(), text: Self.release2014)]
        #expect(C.whyNot(Self.claim("The 2014 release says they collectively lost over $5 million."), passages: unnamed) == nil)
        // The file name alone is enough (a document with no dated header).
        let body = "Investors, firms who did work for Carpenter and municipalities collectively lost over $5 million on the project."
        let fileOnly = [C.Passage(objectID: UUID(), text: body, fileName: "carpenter-2018-07-12-press-release.txt")]
        #expect(C.whyNot(Self.claim("The 2018 release says they lost over $5 million."), passages: fileOnly) == nil)
        #expect(C.whyNot(Self.claim("The 2014 release says they lost over $5 million."), passages: fileOnly) == "the number 2014 not in the quote")
        // Still required: another year, another date, an amount, a number — even when the document states them elsewhere.
        #expect(C.whyNot(Self.claim("The 2015 release says they lost over $5 million."), passages: named) == "the number 2015 not in the quote")
        #expect(C.whyNot(Self.claim("In 2013 they lost over $5 million."), passages: named) == "the number 2013 not in the quote",
                "a year in the body, not the header, is not the document's own")
        #expect(C.whyNot(Self.claim("On November 7, 2014 they lost over $5 million."), passages: named) == "the date not in the quote")
        #expect(C.whyNot(Self.claim("The 2014 release says they lost over $6 million."), passages: named) == "the amount not in the quote")
        #expect(C.whyNot(Self.claim("The 2014 release names 32 counts; they lost over $5 million."), passages: named) == "the number 32 not in the quote")
        // A long first line is a body paragraph, never a header: 2012 is not the document's own year …
        let longFirst = String(repeating: "Background of the matter in 2012. ", count: 6) + "\n" + body
        #expect(C.documentDates(passage: longFirst, fileName: nil).years.isEmpty)
        #expect(C.whyNot(Self.claim("In 2012 they lost over $5 million."), passages: [C.Passage(objectID: UUID(), text: longFirst)])
                == "the number 2012 not in the quote")
        // … but Accuracy D1 (FAIR5 berndale "the 2023 release"): a document with no own date may be NAMED by a year it writes.
        #expect(C.whyNot(Self.claim("The 2012 release says they lost over $5 million."), passages: [C.Passage(objectID: UUID(), text: longFirst)]) == nil)
        #expect(C.whyNot(Self.claim("The 2011 release says they lost over $5 million."), passages: [C.Passage(objectID: UUID(), text: longFirst)])
                == "the number 2011 not in the quote")
        // Other callers (no document dates passed) are unchanged.
        #expect(C.valueMissing(claim: "The 2014 release says they lost over $5 million.", quote: Self.quote, passage: Self.release2014) == "the number 2014")
    }

    @Test("1: the AI's conclusion may name the own year of a document a checked claim cites; another year is still withheld")
    func conclusionOwnYear() {
        let passages = [C.Passage(objectID: UUID(), text: Self.release2014, fileName: "carpenter-2014-11-06-press-release.txt")]
        let claims = [C.VerifiedClaim(text: "They lost over $5 million.", quote: Self.quote, passage: 1)]
        #expect(C.conclusionWithheld("The 2014 release says over $5 million was lost.", claims: claims, arithmetic: [], passages: passages) == nil)
        #expect(C.conclusionWithheld("The 2016 release says over $5 million was lost.", claims: claims, arithmetic: [], passages: passages) != nil)
        #expect(C.conclusionWithheld("The 2014 release says over $5 million was lost.", claims: claims, arithmetic: []) != nil,
                "without the passages nothing changes")
    }

    @Test("1: the document's own dates read from its header and file name")
    func documentDates() {
        let d = C.documentDates(passage: Self.release2014, fileName: "carpenter-2014-11-06-press-release.txt")
        #expect(d.years == [2014])
        #expect(d.dates.contains { $0.year == 2014 && $0.month == 11 && $0.day == 6 })
        #expect(!d.years.contains(2013), "July 2013 is in the body")
        #expect(C.documentDates(passage: "no header here", fileName: "statement_2026.pdf").years == [2026])
        #expect(C.documentDates(passage: "no header here", fileName: "invoice-1234.pdf").years.isEmpty)
    }

    // MARK: - 2. `about` by name tokens

    static let statement = """
    FIRST HARBOUR BANK — ACCOUNT STATEMENT
    Account holder: BRADLEY J KERR
    08 Jul 2026 Transfer to Pemberton Holdings 350,000.00
    """

    @Test("2: about matches a name ignoring case, punctuation, middle initials or names and order; never another given name or surname")
    func aboutByTokens() {
        let p = [C.Passage(objectID: UUID(), text: Self.statement)]
        let q = "08 Jul 2026 Transfer to Pemberton Holdings 350,000.00"
        func why(_ about: String, _ passages: [C.Passage] = p) -> String? {
            C.whyNot(C.Claim(text: "Kerr sent 350,000.00 to Pemberton on 08 Jul 2026.", quote: q, passage: 1, about: about), passages: passages)
        }
        #expect(why("Bradley Kerr") == nil)
        #expect(why("BRADLEY J KERR") == nil)
        #expect(why("Kerr, Bradley") == nil)
        #expect(why("Mr. Bradley Kerr") == nil)
        #expect(why("Bradley J. Kerr") == nil)
        #expect(why("bradley kerr") == nil)
        #expect(why("Brian Kerr") == "passage 1 does not contain \u{201C}Brian Kerr\u{201D}", "another given name")
        #expect(why("Bradley Smith") == "passage 1 does not contain \u{201C}Bradley Smith\u{201D}", "another surname")
        // A middle name in the passage is allowed; the AI's middle name must be in the passage.
        let middle = [C.Passage(objectID: UUID(), text: "Account holder: Bradley James Kerr\n" + q)]
        #expect(why("Bradley Kerr", middle) == nil)
        #expect(why("Bradley Thomas Kerr", middle) != nil)
        // The tokens must be one mention, not a given name here and a surname far away.
        let apart = [C.Passage(objectID: UUID(), text: "Bradley Smith opened the file. The branch manager signed it off later that week. Jane Kerr approved.\n" + q)]
        #expect(why("Bradley Kerr", apart) != nil)
        // A thing, not a name: still matched as written.
        #expect(why("Pemberton Holdings") == nil)
        #expect(why("Kiln Ltd") != nil)
    }

    // MARK: - 3. The second look is told what was dropped

    @Test("3: the second-look task lists each dropped statement with its document and reason; with none it is unchanged")
    func secondLookTask() {
        let plain = CaseReader.secondLookSuffix("Q?", answer: "A")
        #expect(plain.hasPrefix(UnifiedPathCaseTests.secondLookTask))
        #expect(!plain.contains(CaseReader.droppedLead))
        #expect(CaseReader.secondLookSuffix("Q?", answer: "A", dropped: []) == plain)
        let dropped = [C.DroppedClaim(text: "The 2018 release says they lost millions.", passage: 3, reason: "the number 2018 not in the quote"),
                       C.DroppedClaim(text: "Kerr lent $350,000.", passage: 2, reason: "passage 2 does not contain \u{201C}Brad Kerr\u{201D}")]
        let told = CaseReader.secondLookSuffix("Q?", answer: "A", dropped: dropped)
        #expect(told.hasPrefix(UnifiedPathCaseTests.secondLookTask))
        #expect(told.contains(CaseReader.droppedLead))
        #expect(told.contains("\u{201C}The 2018 release says they lost millions.\u{201D} (Document 3) — dropped: the number 2018 not in the quote"))
        #expect(told.contains("(Document 2) — dropped: Document 2 does not contain"))
        #expect(told.contains(#""addresses_question""#), "the reply schema is unchanged")
    }

    @Test("3: the dropped statements of a merged reply, with why, against the whole case")
    func droppedOfReply() {
        let docs = [CaseReader.Document(objectID: UUID(), fileName: "a-sentencing.txt", text: CaseWholeReadingTests.sentencing)]
        let reply = UnifiedPathCaseTests.json(["status": "answered", "answer": "x", "claims": [
            ["text": "John Smith was sentenced on March 3, 2021.", "quote": "On March 3, 2021, John Smith was sentenced to 60 months in prison", "passage": 1],
            ["text": "He was sentenced to 72 months.", "quote": "John Smith was sentenced to 60 months in prison", "passage": 1],
        ]])
        let d = CaseReader.droppedClaims(reply: reply, documents: docs)
        #expect(d == [C.DroppedClaim(text: "He was sentenced to 72 months.", passage: 1, reason: "the number 72 not in the quote")])
        #expect(CaseReader.droppedClaims(reply: "not json", documents: docs).isEmpty)
    }

    @Test("3: on the case path the second look is told the dropped statement; its re-quoted claim goes through the same verifier")
    func secondLookOnCasePath() async throws {
        let question = "When was John Smith sentenced, and to how long?"
        let first = UnifiedPathCaseTests.json(["status": "answered", "answer": "x", "answers_question": question, "claims": [
            ["text": "John Smith was sentenced on March 3, 2021.", "quote": "On March 3, 2021, John Smith was sentenced", "passage": 1],
            ["text": "He got 60 months for wire fraud on March 4, 2021.", "quote": "sentenced to 60 months in prison for wire fraud", "passage": 1],
        ]])
        // The re-quote holds every value; a second, still-unbacked re-quote is dropped again by the same verifier.
        let look = UnifiedPathCaseTests.json(["status": "answered", "addresses_question": "yes", "why": "ok", "answer": "", "claims": [
            ["text": "He got 60 months for wire fraud.", "quote": "sentenced to 60 months in prison for wire fraud", "passage": 1],
            ["text": "He got 72 months.", "quote": "sentenced to 60 months in prison for wire fraud", "passage": 1],
        ]])
        let f = try await UnifiedPathCaseTests.fixture(UnifiedPathCaseTests.docs(), reply: { send in
            send.suffix.hasPrefix(UnifiedPathCaseTests.secondLookTask) ? look : first
        })
        let a = try await f.service.answer(caseID: f.caseID, question: question, access: .testUnrestricted()).verified
        let looks = f.recorder.requests.filter { $0.purpose == "case.question" && $0.suffix.hasPrefix(UnifiedPathCaseTests.secondLookTask) }
        #expect(!looks.isEmpty)
        for l in looks {
            #expect(l.suffix.contains(CaseReader.droppedLead))
            // Accuracy F1 (2026-11-25): March 3, 2021 would now be backed by the verified same-document quote; March 4 is backed by none.
            #expect(l.suffix.contains("\u{201C}He got 60 months for wire fraud on March 4, 2021.\u{201D} (Document 1) — dropped: the date not in the quote"),
                    "\(l.suffix.suffix(900))")
        }
        #expect(a.body.contains("Also worth checking"), "\(a.body)")
        #expect(a.body.contains("sentenced to 60 months in prison for wire fraud"))
    }
}
