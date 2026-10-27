//
//  VerifiedRecordExtractorTests.swift
//  KalsmritikoshTests
//
//  A model's proposed answer about a person's proceeding is shown only when it verifies against the
//  documents: the quote verbatim in the cited document, about the person asked, the date stated or
//  given by "today" against the printed date, a term in the quote, a charge that states an offence,
//  "No" to a plea only with a verdict at trial. Anything else is dropped (the rules answer stands).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Verified record extraction")
struct VerifiedRecordExtractorTests {

    static let release = """
        U.S. Department of Justice
        FOR IMMEDIATE RELEASE
        Friday, September 13, 2024

        Beckley Man Sentenced

        BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl. Smith pleaded guilty on May 1, 2024, to distribution of fentanyl. Gary Smith was sentenced on November 19, 2024, to five years of probation.
        """
    let sources = [ProceedingAnswerer.Source(objectID: UUID(), text: release)]

    func verify(_ q: String, _ json: String) throws -> VerifiedAnswer? {
        let parsed = try #require(ProceedingAnswerer.parse(q))
        let p = try #require(VerifiedRecordExtractor.parse(json))
        return VerifiedRecordExtractor.verify(p, parsed: parsed, sources: sources, docs: sources.map(\.text))
    }

    @Test("Sending document text to the cloud is its own switch, off by default, and says what it sends")
    func ownSwitch() {
        let m = KnowledgeModule.onlineRecordReading
        #expect(m.implemented && !m.defaultEnabled)
        #expect(m.detail.contains("up to eight of the documents") && m.detail.contains("7,000 characters") && m.detail.contains("Privileged material is never sent"))
        // The question interpreter's promise stays true for it: it sends no documents.
        #expect(KnowledgeModule.questionInterpreter.detail.contains("never your documents"))
        #expect(m != .questionInterpreter)
    }

    @Test("A verbatim, person-specific, date-consistent proposal is shown")
    func accepts() throws {
        let when = try #require(try verify("When was Leon Eugene Smith sentenced?",
            #"{"answer":"September 13, 2024","quote":"BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl.","doc":1,"value":"2024-09-13"}"#))
        #expect(when.body.hasPrefix("Leon Eugene Smith was sentenced on September 13, 2024."))
        #expect(when.intentKind == VerifiedAnswer.recordAnswerKind)
        let plea = try #require(try verify("When did Leon Eugene Smith plead guilty?",
            #"{"answer":"May 1, 2024","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":1,"value":"2024-05-01"}"#))
        #expect(plea.body.hasPrefix("Leon Eugene Smith pleaded guilty on May 1, 2024."))
        let term = try #require(try verify("What sentence did Leon Eugene Smith receive?",
            #"{"answer":"13 years and five months","quote":"BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl.","doc":1,"value":"13 years and five months in prison"}"#))
        #expect(term.body.hasPrefix("Leon Eugene Smith was sentenced to 13 years and five months in prison."))
    }

    @Test("A paraphrased quote, another person's sentence, a wrong date or an unsupported No is dropped")
    func rejects() throws {
        // Not verbatim.
        #expect(try verify("When was Leon Eugene Smith sentenced?",
            #"{"answer":"x","quote":"Leon Smith received his sentence on September 13, 2024 in Beckley court.","doc":1,"value":"2024-09-13"}"#) == nil)
        // Another person with the same surname.
        #expect(try verify("What sentence did Leon Eugene Smith receive?",
            #"{"answer":"five years","quote":"Gary Smith was sentenced on November 19, 2024, to five years of probation.","doc":1,"value":"five years of probation"}"#) == nil)
        // The date is not the one the quote gives.
        #expect(try verify("When did Leon Eugene Smith plead guilty?",
            #"{"answer":"May 2","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":1,"value":"2024-05-02"}"#) == nil)
        // "No" to a plea without a trial verdict in the quote.
        #expect(try verify("Did Leon Eugene Smith plead guilty?",
            #"{"answer":"No","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":1}"#) == nil)
        // A scheduled step is not a step taken.
        let scheduled = [ProceedingAnswerer.Source(objectID: UUID(), text: "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nMonday, June 3, 2019\n\nAtif Ullah, 30, pleaded guilty today. Sentencing is scheduled for October 4, 2019, before Judge Vilardo.")]
        let au = try #require(ProceedingAnswerer.parse("When was Atif Ullah sentenced?"))
        let sp = try #require(VerifiedRecordExtractor.parse(#"{"answer":"October 4, 2019","quote":"Sentencing is scheduled for October 4, 2019, before Judge Vilardo.","doc":1,"value":"2019-10-04"}"#))
        #expect(VerifiedRecordExtractor.verify(sp, parsed: au, sources: scheduled, docs: scheduled.map(\.text)) == nil)
        // Final brief §3.3 counterexamples. A term with an invented tail: the quote supports "13 years
        // and five months", not "… and a $50,000 fine".
        #expect(try verify("What sentence did Leon Eugene Smith receive?",
            #"{"answer":"x","quote":"BECKLEY, W.Va. – Leon Eugene Smith Jr., 43, of Beckley, was sentenced today to 13 years and five months in prison for distribution of fentanyl.","doc":1,"value":"13 years and five months in prison and a $50,000 fine"}"#) == nil)
        func one(_ text: String, _ q: String, _ json: String) throws -> VerifiedAnswer? {
            let src = [ProceedingAnswerer.Source(objectID: UUID(), text: "U.S. Department of Justice\nFOR IMMEDIATE RELEASE\nMonday, June 3, 2019\n\n" + text)]
            let parsed = try #require(ProceedingAnswerer.parse(q))
            return VerifiedRecordExtractor.verify(try #require(VerifiedRecordExtractor.parse(json)), parsed: parsed, sources: src, docs: src.map(\.text))
        }
        // Not yet sentenced: "Yes" refused.
        #expect(try one("Atif Ullah, 30, pleaded guilty today and will be sentenced on October 4, 2019.", "Was Atif Ullah sentenced?",
            #"{"answer":"Yes","quote":"Atif Ullah, 30, pleaded guilty today and will be sentenced on October 4, 2019.","doc":1}"#) == nil)
        // A proposed term is not the sentence imposed.
        #expect(try one("Prosecutors sought 87 months for Atif Ullah, 30, who was sentenced today by Judge Vilardo.", "What sentence did Atif Ullah receive?",
            #"{"answer":"87 months","quote":"Prosecutors sought 87 months for Atif Ullah, 30, who was sentenced today by Judge Vilardo.","doc":1,"value":"87 months"}"#) == nil)
        // A co-defendant's step.
        #expect(try one("Ullah's co-defendant Omar Khan was sentenced today to 40 months in prison. Atif Ullah, 30, pleaded guilty in March.", "What sentence did Atif Ullah receive?",
            #"{"answer":"40 months","quote":"Ullah's co-defendant Omar Khan was sentenced today to 40 months in prison.","doc":1,"value":"40 months in prison"}"#) == nil)
        // A sentence the record later vacates is not settled.
        #expect(try one("Atif Ullah, 30, was sentenced today to 60 months in prison. In 2021 the court of appeals vacated his sentence and he was resentenced to 48 months.", "What sentence did Atif Ullah receive?",
            #"{"answer":"60 months","quote":"Atif Ullah, 30, was sentenced today to 60 months in prison.","doc":1,"value":"60 months in prison"}"#) == nil)
        // A quote that never names the person, from a document that names several people.
        #expect(try one("Atif Ullah, 30, and Omar Khan, 41, appeared in court. The defendant was sentenced today to 40 months in prison.", "What sentence did Atif Ullah receive?",
            #"{"answer":"40 months","quote":"The defendant was sentenced today to 40 months in prison.","doc":1,"value":"40 months in prison"}"#) == nil)
        // A document number out of range, or nothing found.
        #expect(try verify("When was Leon Eugene Smith sentenced?", #"{"answer":"x","quote":"Smith pleaded guilty on May 1, 2024, to distribution of fentanyl.","doc":3,"value":"2024-05-01"}"#) == nil)
        #expect(try verify("When was Leon Eugene Smith sentenced?", #"{"answer":null}"#) == nil)
    }

    @Test("Review L2: documents go only to a provider reviewed for case material, after a confirmation against the current terms")
    func providerEligibility() {
        // OpenAI is not reviewed for case material: refused even when "confirmed".
        #expect(OnlineDocumentEligibility.refusal(kind: .openai, confirmedTermsVersion: OnlineProviderKind.openai.documentTermsVersion) != nil)
        // Eligible providers need the person's confirmation …
        for kind in [OnlineProviderKind.anthropic, .gemini] {
            #expect(kind.mayReceiveDocuments && !kind.documentAttestation.isEmpty && !kind.documentTerms.isEmpty)
            #expect(OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: nil)?.contains("Confirm") == true)
            // … against the terms as currently reviewed; an older confirmation lapses.
            #expect(OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: "2020-01-01")?.contains("changed") == true)
            #expect(OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: kind.documentTermsVersion) == nil)
        }
        // The terms shown say what the provider keeps, not only that the publisher receives nothing.
        #expect(OnlineProviderKind.anthropic.documentTerms.contains("30 days"))
        #expect(OnlineProviderKind.gemini.documentTerms.contains("PAID") && OnlineProviderKind.gemini.documentTerms.contains("unpaid"))
        // A document send is always previewed — "don't ask again this session" never covers it.
        let p = OutboundPreview(provider: "x", model: "m", host: "h", text: "t", bytes: 1, maskedCount: 0,
                                carriesDocuments: true, providerTerms: OnlineProviderKind.anthropic.documentTerms)
        #expect(p.carriesDocuments && p.providerTerms != nil)
    }


    @Test("Review L2: the general cloud route is a document send — an unconfirmed or ineligible provider receives nothing")
    func generalRouteIsADocumentSend() async {
        let provider = OnlineCloudProvider(outboundLog: nil, knownNames: { [] })
        let kind = OnlineSettings.kind
        // On a Mac where the provider is confirmed a send would wait for the consent sheet — nothing to test here.
        guard OnlineDocumentEligibility.refusal(kind: kind, confirmedTermsVersion: OnlineSettings.confirmedDocumentTerms(for: kind)) != nil else { return }
        do {
            _ = try await provider.generate(prompt: "Passage: the payment of ₹1,000 …", options: GenerationOptions(maxTokens: 16, temperature: 0))
            Issue.record("the general route sent without the document check")
        } catch let error as OnlineCloudProvider.OnlineError {
            // Unconfirmed (or OpenAI): refused by the document check before anything else.
            guard case .notEligibleForDocuments = error else { Issue.record("expected the document refusal, got \(error)"); return }
        } catch {
            Issue.record("expected the document refusal, got \(error)")
        }
    }

}
