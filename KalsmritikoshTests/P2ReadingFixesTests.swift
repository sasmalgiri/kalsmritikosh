//
//  P2ReadingFixesTests.swift
//  KalsmritikoshTests
//
//  P2 (real-case evaluation 2026-11-03) — fixtures reproduce the shapes of the quoted failures:
//  A. a proceeding answer must be the asked person's own (offline self-check) and, with the reader on, is
//     cross-checked by the verified composer (faked by a closure — no network, no model);
//  B. the interpreter's field choice belongs to one answer, never shared across answers or cases;
//  C. values from different records are not a "conflict"; "$50k" is $50,000, not "$50";
//  D. a when-question answered by a clock time is answered with the time, not refused.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P2 — proceeding self-check and cross-check, interpreter sessions, record conflicts, clock times", .serialized)
struct P2ReadingFixesTests {
    typealias C = VerifiedAnswerComposer

    // MARK: - Fixtures (shapes of the real failures)

    static let upfrontRelease = """
        U.S. Department of Justice
        District of New Jersey
        FOR IMMEDIATE RELEASE
        Friday, June 23, 2023

        Three Men Sentenced For Upfront Fee Scheme

        NEWARK, N.J. – U.S. District Judge John Michael Vazquez imposed the sentences on June 22, 2023. \
        Roy Johannes Gillar, 51, of Las Vegas, was sentenced to six years in prison; Harold Mignott, 60, of Voorhees, New Jersey, was sentenced to three years in prison. \
        Harold Mignott was convicted at trial of conspiracy to commit wire fraud.
        """

    static let loganRelease = """
        U.S. Department of Justice
        Southern District of West Virginia
        FOR IMMEDIATE RELEASE
        Friday, May 30, 2014

        Three More Defendants Sentenced In Logan Arson Ring

        CHARLESTON, W.Va. – Michael D. Williams, 44, of Logan, previously admitted his role in the fire. \
        Shawn C. Simon, 41, of Charleston, drove the getaway car for Miller and Williams and was sentenced Thursday to a term of 22 months in prison for destroying the digital video recorder.
        """

    static let solimanRelease = """
        U.S. Department of Justice
        Western District of New York
        FOR IMMEDIATE RELEASE
        Thursday, March 20, 2025

        Rapids Theatre owner pleads guilty to defrauding COVID relief programs out of more than $1.8 million

        BUFFALO, N.Y. – John L. Hutchins, 72, of Lewiston, NY, pleaded guilty today to conspiracy to commit wire fraud. \
        Roberto Soliman was named in the same indictment. Charges remain pending against Roberto Soliman.
        """

    static func source(_ text: String) -> ProceedingAnswerer.Source { .init(objectID: UUID(), text: text) }

    static func ask(_ q: String, _ text: String) -> VerifiedAnswer? {
        guard let parsed = ProceedingAnswerer.parse(q) else { return nil }
        return ProceedingAnswerer.answer(parsed, sources: [source(text)])
    }

    // MARK: - A, offline: the deterministic self-check

    @Test("A: 'Harold Mignott was sentenced to six years' — the term is read from Mignott's own clause: three years")
    func mignottTermFromOwnClause() throws {
        let a = try #require(Self.ask("What sentence did Harold Mignott receive?", Self.upfrontRelease))
        #expect(!a.refused)
        #expect(a.body.hasPrefix("Harold Mignott was sentenced to three years in prison"), "\(a.body)")
        #expect(!(a.answerText ?? "").hasPrefix("Harold Mignott was sentenced to six years"))
        // Gillar's own term is still his.
        let g = try #require(Self.ask("What sentence did Roy Johannes Gillar receive?", Self.upfrontRelease))
        #expect(g.body.hasPrefix("Roy Johannes Gillar was sentenced to six years in prison"), "\(g.body)")
    }

    @Test("A: 'Michael D. Williams was sentenced to 22 months' (Simon's sentence) — refused, not attributed")
    func williamsNotGivenSimonsTerm() throws {
        let a = try #require(Self.ask("What sentence did Michael D. Williams receive?", Self.loganRelease))
        #expect(!a.body.contains("22 months"), "\(a.body)")
        #expect(a.refused)
        let simon = try #require(Self.ask("What sentence did Shawn C. Simon receive?", Self.loganRelease))
        #expect(simon.body.contains("22 months"), "\(simon.body)")
    }

    @Test("A: 'Roberto Soliman was pleaded guilty' from a headline about the owner — not when his charges remain pending")
    func solimanHeadlineNotHisPlea() throws {
        let did = try #require(Self.ask("Did Roberto Soliman plead guilty?", Self.solimanRelease))
        #expect(!did.body.hasPrefix("Yes"), "\(did.body)")
        let when = try #require(Self.ask("When did Roberto Soliman plead guilty?", Self.solimanRelease))
        #expect(!when.body.contains("Roberto Soliman was pleaded guilty"), "\(when.body)")
        #expect(when.refused)
        // Hutchins, introduced in the lead, still pleaded guilty.
        let hutchins = try #require(Self.ask("Did John L. Hutchins plead guilty?", Self.solimanRelease))
        #expect(hutchins.body.hasPrefix("Yes"), "\(hutchins.body)")
    }

    @Test("A: clauses and introduced subjects")
    func clauseHelpers() {
        #expect(ProceedingAnswerer.clauses(of: "A was sentenced to six years; B was sentenced to three years.").count == 2)
        #expect(ProceedingAnswerer.introducedSubject("Shawn C. Simon, 41, of Charleston, drove the car") == "Shawn C. Simon")
        #expect(ProceedingAnswerer.clauseNames("drove the getaway car for Miller and Williams", person: "Michael D. Williams"))
        #expect(!ProceedingAnswerer.clauseNames("Brock Taylor handled the case", person: "Jonathan Taylor"))
    }

    // MARK: - A, online: the composer cross-checks the rules answer (fake reader)

    static func reply(_ claims: [(String, String, Int)], status: String = "answered") -> String {
        let items = claims.map { ["text": $0.0, "quote": $0.1, "passage": $0.2] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: ["status": status, "claims": items, "answer": "x"] as [String: Any])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func rules(_ text: String) -> VerifiedAnswer {
        VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind,
                       citations: [.init(objectID: UUID(), snippet: text)], confidence: Confidence(0.8))
    }

    static func crossCheck(_ q: String, text: String, rules: VerifiedAnswer, reply: String) async -> VerifiedAnswer? {
        let composer = C(generate: { _, _ in reply })
        let person = ProceedingAnswerer.person(in: q) ?? ""
        let passages = C.passages(from: [source(text)], person: person, stepWords: ["sentenc"])
        let outcome = await composer.compose(question: q, passages: passages, rules: rules, clearance: nil)
        return C.crossChecked(outcome, rules: rules)
    }

    @Test("A cloud: the reader states nothing while the rules assert a value → 'Needs review — could not confirm', lower confidence")
    func notStatedLowersRules() async throws {
        let rules = Self.rules("Roberto Soliman pleaded guilty on March 20, 2025.")
        let a = try #require(await Self.crossCheck("Did Roberto Soliman plead guilty?", text: Self.solimanRelease, rules: rules,
                                                   reply: Self.reply([], status: "not_stated")))
        #expect(a.body.hasPrefix("Needs review — the AI reading could not confirm this."), "\(a.body)")
        #expect(a.confidence.value <= 0.35)
        #expect(C.writer(of: a) == "needs-review")
        #expect(a.body.contains("Evidence-only reading: Roberto Soliman pleaded guilty"))
    }

    @Test("A cloud: the reader verifies a different term → Needs review with both; agreeing → rules answer confirmed")
    func disagreeAndAgree() async throws {
        let wrong = Self.rules("Harold Mignott was sentenced to six years in prison.")
        let quote = "Harold Mignott, 60, of Voorhees, New Jersey, was sentenced to three years in prison"
        let disagreeing = try #require(await Self.crossCheck("What sentence did Harold Mignott receive?", text: Self.upfrontRelease, rules: wrong,
                                                             reply: Self.reply([("Harold Mignott was sentenced to three years in prison.", quote, 1)])))
        #expect(C.writer(of: disagreeing) == "needs-review", "\(disagreeing.body)")
        #expect(disagreeing.body.contains("three years") && disagreeing.body.contains("six years"))
        #expect(disagreeing.confidence.value <= 0.45)

        let right = Self.rules("Harold Mignott was sentenced to three years in prison.")
        let agreeing = try #require(await Self.crossCheck("What sentence did Harold Mignott receive?", text: Self.upfrontRelease, rules: right,
                                                          reply: Self.reply([("Harold Mignott was sentenced to three years in prison.", quote, 1)])))
        #expect(agreeing.intentKind == VerifiedAnswer.recordAnswerKind)
        #expect(agreeing.body.hasPrefix("Harold Mignott was sentenced to three years in prison."))
        #expect(agreeing.body.contains("Confirmed by the AI reading"))
        #expect(agreeing.confidence.value == 0.8)
    }

    @Test("A cloud: a reader quote from Gillar's clause does not verify for Mignott; nothing sent → rules stand")
    func wrongClauseAndNotSent() async throws {
        let rules = Self.rules("Harold Mignott was sentenced to three years in prison.")
        let wrong = try #require(await Self.crossCheck("What sentence did Harold Mignott receive?", text: Self.upfrontRelease, rules: rules,
                                                       reply: Self.reply([("Harold Mignott was sentenced to six years in prison.",
                                                                           "Roy Johannes Gillar, 51, of Las Vegas, was sentenced to six years in prison", 1)])))
        #expect(!wrong.body.contains("Confirmed by the AI reading"))
        #expect(C.writer(of: wrong) == "needs-review")
        let composer = C(generate: { _, _ in throw C.NotSent("off") })
        let passages = C.passages(from: [Self.source(Self.upfrontRelease)], person: "Harold Mignott")
        let o = await composer.compose(question: "What sentence did Harold Mignott receive?", passages: passages, rules: rules, clearance: nil)
        #expect(C.crossChecked(o, rules: rules) == nil)
    }

    @Test("A: only passages naming the person go to the reader; the asked step's first")
    func passagesForThePerson() {
        let other = Self.source("Brock Taylor was sentenced to 87 months in prison.")
        let ps = C.passages(from: [Self.source(Self.upfrontRelease), other], person: "Harold Mignott", stepWords: ["sentenc"])
        #expect(!ps.isEmpty)
        #expect(ps.allSatisfy { $0.objectID != other.objectID })
        #expect(MasterBrain.crossCheckable(.sentenceImposed) && !MasterBrain.crossCheckable(.timeline))
    }

    // MARK: - B: one interpretation per answer

    final class Fixed: QuestionInterpreting, @unchecked Sendable {
        let answer: String
        init(_ answer: String) { self.answer = answer }
        func field(askedBy question: String, among fields: [String]) async -> String? { answer }
    }

    @Test("B: the same question in two cases never shares the interpreter's choice")
    func sessionsAreSeparate() async {
        let q = "How much did General Star hand over to the owner on the claim in this matter?"
        let fields: Set<String> = ["amount", "date", "status"]
        let caseA = QuestionUnderstanding.Session(), caseB = QuestionUnderstanding.Session()
        await QuestionUnderstanding.$session.withValue(caseA) {
            _ = await QuestionUnderstanding.interpret(question: q, fields: fields, onDevice: Fixed("amount"), cloud: nil, modelsAllowed: true)
            #expect(QuestionUnderstanding.interpretedField(for: q) == "amount")
            #expect(QuestionUnderstanding.interpretedField(for: q.lowercased()) == "amount")
        }
        await QuestionUnderstanding.$session.withValue(caseB) {
            #expect(QuestionUnderstanding.interpretedField(for: q) == nil, "case B must not read case A's choice")
            #expect(SlotFieldResolver.resolve(in: q, knownFields: fields).first?.domainGroup != "interpreted")
        }
        // Nothing leaked into the table used outside answers either.
        #expect(QuestionUnderstanding.interpretedField(for: q) == nil)
        // A later answer in case A starts fresh too.
        await QuestionUnderstanding.$session.withValue(QuestionUnderstanding.Session()) {
            #expect(QuestionUnderstanding.interpretedField(for: q) == nil)
        }
    }

    @Test("B: gate intents are per session too")
    func gateIntentsPerSession() async {
        let q = "Which bureau got the word out about \"Man Sentenced For Fraud\" today?"
        await QuestionUnderstanding.$session.withValue(QuestionUnderstanding.Session()) {
            _ = await QuestionUnderstanding.interpret(question: q, fields: ["date", "amount"], onDevice: Fixed("announcingoffice"),
                                                      cloud: nil, modelsAllowed: true)
            #expect(QuestionUnderstanding.gateIntent(for: q) == .announcingOffice)
        }
        await QuestionUnderstanding.$session.withValue(QuestionUnderstanding.Session()) {
            #expect(QuestionUnderstanding.gateIntent(for: q) == nil)
        }
    }

    // MARK: - C: a conflict is about one record

    func fact(_ field: String, _ value: String, subject: String = "doc") -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value, status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    func evalFor(_ f: GenericFact, objectID: UUID) -> ClaimEvaluation {
        let ev = [AssertabilityEvidence(objectID: objectID, blockID: f.sourceBlockIDs.first, independenceKey: objectID.uuidString)]
        let ctx = AssertabilityContextBuilder().build(assessment: f.assessment, evidence: ev)
        return ClaimEvaluation(id: f.id, claimKind: .genericFact, assessment: ctx.assessment, evidence: ev, context: ctx,
                               decision: AssertabilityPolicy.evaluate(ctx))
    }

    /// Recall events, one document each: (event id, classification).
    func recalls(_ rows: [(String, String)], subject: String = "FDA Enforcement Report") -> (facts: [GenericFact], evals: [ClaimEvaluation]) {
        var facts: [GenericFact] = [], evals: [ClaimEvaluation] = []
        for (event, cls) in rows {
            let obj = UUID()
            let e = fact("eventid", event, subject: subject), c = fact("classification", cls, subject: subject)
            facts += [e, c]; evals += [evalFor(e, objectID: obj), evalFor(c, objectID: obj)]
        }
        return (facts, evals)
    }

    @Test("C: Blue Bell — seven recall events are not 'conflicting values for classification'; answered per record")
    func blueBellPerRecord() throws {
        let r = recalls([("70738", "Class I"), ("74032", "Class II"), ("75254", "Class I"), ("80360", "Class III"),
                         ("84008", "Class II"), ("97481", "Class II"), ("71170", "Class I")])
        let c = try #require(SlotAnswerComposer.compose(slotFieldIDs: ["classification"], facts: r.facts, evaluations: r.evals,
                                                        authorityObjectIDs: [], documentsSearched: 7,
                                                        question: "What classification did FDA give the 2015 Blue Bell recall?"))
        #expect(!c.isConflict)
        #expect(!c.primaryText.lowercased().contains("conflicting"))
        #expect(c.primaryText.contains("70738: Class I"), "\(c.primaryText)")
        #expect(c.primaryText.contains("80360: Class III"))
        #expect(c.primaryText.contains("separate records"))
    }

    @Test("C: a question naming one recall event reads only that record")
    func namedRecordOnly() throws {
        let r = recalls([("70738", "Class I"), ("74032", "Class II"), ("80360", "Class III")])
        let c = try #require(SlotAnswerComposer.compose(slotFieldIDs: ["classification"], facts: r.facts, evaluations: r.evals,
                                                        authorityObjectIDs: [], documentsSearched: 3,
                                                        question: "What is the classification of recall event 74032?"))
        #expect(!c.isConflict)
        #expect(c.singleCanonicalValue)
        #expect(c.primaryText.contains("Class II") && !c.primaryText.contains("Class III"), "\(c.primaryText)")
    }

    @Test("C: two documents disagreeing about the SAME record is still a conflict")
    func sameRecordConflict() throws {
        let r = recalls([("70738", "Class I"), ("70738", "Class II")])
        let c = try #require(SlotAnswerComposer.compose(slotFieldIDs: ["classification"], facts: r.facts, evaluations: r.evals,
                                                        authorityObjectIDs: [], documentsSearched: 2))
        #expect(c.isConflict)
        #expect(c.primaryText.contains("Class I") && c.primaryText.contains("Class II"))
    }

    @Test("C: Logan — one release's '$50,000', '$50k' and '$10,000' are not a conflict, and '$50k' is $50,000")
    func loganAmounts() {
        let obj = UUID()
        let a = fact("amount", "$50,000"), b = fact("amount", "$50k"), d = fact("amount", "$10,000")
        let c = SlotAnswerComposer.compose(slotFieldIDs: ["amount"], facts: [a, b, d],
                                           evaluations: [a, b, d].map { evalFor($0, objectID: obj) },
                                           authorityObjectIDs: [], documentsSearched: 5,
                                           question: "How much did General Star pay Glick on the insurance claim?")
        #expect(c == nil || c?.isConflict == false, "\(c?.primaryText ?? "nil")")
        #expect(c?.primaryText.contains("$50\n") != true)
        #expect(SlotAnswerComposer.renderMoney(value: "$50k", unit: "USD") == "$50,000")
        #expect(SlotAnswerComposer.renderMoney(value: "$1 million", unit: nil) == "$1,000,000")
        #expect(SlotAnswerComposer.moneyAmount("$1.8 million") == 1_800_000)
        #expect(SlotAnswerComposer.renderMoney(value: "$1,200", unit: nil) == "$1,200")
        // The reader keeps the scale word: "$50k" is stored as $50,000.
        let facts = TransactionDomainPack.extractFacts(fromText: "William J. Thompson accepted $50k to help arsonist collect $1 million insurance payment",
                                                       subjectLabel: "release-03", blockID: UUID())
        #expect(facts.first { $0.field == "amount" }?.value == "$50,000")
        let million = TransactionDomainPack.extractFacts(fromText: "to collect more than $1 million in insurance proceeds", subjectLabel: "r", blockID: UUID())
        #expect(million.first { $0.field == "amount" }?.value == "$1,000,000")
    }

    @Test("C: upfront fee — three victims' amounts in three releases are not a conflict")
    func victimsAmounts() {
        var facts: [GenericFact] = [], evals: [ClaimEvaluation] = []
        for (i, v) in ["$250,000", "$800,000", "$90,000"].enumerated() {
            let f = fact("amount", v, subject: "release-0\(i + 1).pdf")
            facts.append(f); evals.append(evalFor(f, objectID: UUID()))
        }
        let c = SlotAnswerComposer.compose(slotFieldIDs: ["amount"], facts: facts, evaluations: evals, authorityObjectIDs: [],
                                           documentsSearched: 4, question: "How much did the victims pay?")
        #expect(c == nil || c?.isConflict == false)
    }

    // MARK: - D: clock times

    static func passageAnswer(_ quote: String) -> VerifiedAnswer {
        VerifiedAnswer(body: "The document states: \u{201C}\(quote)\u{201D}", answerText: "The document states: \u{201C}\(quote)\u{201D}",
                       citations: [.init(objectID: UUID(), snippet: quote)], confidence: Confidence(0.8))
    }

    @Test("D: 'At 1100:26 …' answers a when-question with the time (and the document's date of the events)")
    func clockTimeAnswers() {
        let q = "When did the controller tell the F-16 pilot to turn left?"
        let a = DateQuestionGate.apply(question: q, Self.passageAnswer("At 1100:26, the controller advised the F-16 pilot to turn left immediately."),
                                       sourceTexts: ["On July 7, 2015, about 1101 eastern daylight time, a Lockheed Martin F-16CM collided with a Cessna 150M."])
        #expect(!a.refused, "\(a.body)")
        #expect(a.body.contains("1100:26"))
        #expect(a.answerText?.contains("July 7, 2015") == true, "\(a.answerText ?? "")")
        #expect(a.refusalReason != "A when-question whose evidence states no date.")

        let b = DateQuestionGate.apply(question: "When did Buy reply to Watkins?", Self.passageAnswer("Sent: 15:27 RE: portrac — Wow, thanks."))
        #expect(!b.refused)
        #expect(b.answerText?.contains("15:27") == true)
        #expect(b.answerText?.contains("no date is stated") == true)

        #expect(DateQuestionGate.clockTime(in: "about 1101 eastern daylight time, the airplanes collided") == "1101")
        #expect(DateQuestionGate.clockTime(in: "He paid $1,100 to the agent.") == nil)
    }

    @Test("D: an answer with neither a date nor a time is still refused; a day question is not answered by a time")
    func noTimeStillRefused() {
        let a = DateQuestionGate.apply(question: "When was Hutchins sentenced?", Self.passageAnswer("Hutchins was sentenced today in Buffalo."))
        #expect(a.refused)
        let b = DateQuestionGate.apply(question: "On which day did the controller call?", Self.passageAnswer("At 1100:26, the controller called."))
        #expect(b.refused)
    }
}
