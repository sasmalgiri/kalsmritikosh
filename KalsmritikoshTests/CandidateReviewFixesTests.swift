//
//  CandidateReviewFixesTests.swift
//  KalsmritikoshTests
//
//  The blockers of the AGENT candidate reviews of 7d720fe1 (docs/agent-reviews/candidate-review-7d720fe1-*.md):
//  UB1 (AI after buying a plan, no hidden switches; the six causes named), PB1 (an unverified reading is not
//  "the documents don't say"), AI Pro yearly economics (5,400 credits a month), LS3/LS4 (a case permission
//  is tied to its destination and withdrawable). LB1 (erasure of the outbound text) is in CaseErasureTests.
//  No network: settings are snapshots, switches are recorded, stores are in memory.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Candidate review 7d720fe1 fixes")
struct CandidateReviewFixesTests {

    // MARK: - UB1: the six causes, each with its action

    static func ready(_ kind: OnlineProviderKind = .included) -> AISetup.Snapshot {
        AISetup.Snapshot(aiAllowedHere: true, kind: kind, hasAIPlan: kind == .included, hasOwnKey: kind == .anthropic,
                         relayConfigured: true, onlineInBuild: true, onlineOn: true, onlineAnswersOn: true, aiSwitchOn: true,
                         regimeAllowsAI: true, documentReadingOn: true, termsAccepted: [kind], creditsLeft: 500, paused: false)
    }

    @Test("Ready: no cause. Each missing step is named, in order, with its one action")
    func sixCauses() {
        #expect(AISetup.cause(Self.ready()) == nil)
        #expect(AISetup.cause(Self.ready(.anthropic)) == nil)
        var s = Self.ready(); s.aiAllowedHere = false
        #expect(AISetup.cause(s) == .blockedStorefront && AISetupCause.blockedStorefront.actionTitle == nil)
        s = Self.ready(); s.hasAIPlan = false
        #expect(AISetup.cause(s) == .noPlanOrKey && AISetupCause.noPlanOrKey.actionTitle == "See plans")
        s = Self.ready(); s.onlineOn = false
        #expect(AISetup.cause(s) == .onlineOff)
        s = Self.ready(); s.onlineAnswersOn = false
        #expect(AISetup.cause(s) == .onlineOff)
        s = Self.ready(); s.aiSwitchOn = false
        #expect(AISetup.cause(s) == .aiSwitchOff && AISetupCause.aiSwitchOff.note.contains("Use AI to write answers"))
        s = Self.ready(); s.documentReadingOn = false
        #expect(AISetup.cause(s) == .aiSwitchOff)
        s = Self.ready(); s.termsAccepted = []
        #expect(AISetup.cause(s) == .termsNotAccepted)
        s = Self.ready(); s.relayConfigured = false
        #expect(AISetup.cause(s) == .relayUnavailable && AISetupCause.relayUnavailable.actionTitle != nil)
        s = Self.ready(); s.creditsLeft = 0
        #expect(AISetup.cause(s) == .creditsUsed && AISetupCause.creditsUsed.actionTitle == "Buy credits")
        s = Self.ready(); s.paused = true
        #expect(AISetup.cause(s) == .creditsUsed)
        for c in [AISetupCause.onlineOff, .aiSwitchOff, .termsNotAccepted] { #expect(c.actionTitle == "Turn on AI…") }
        // Every cause has its own words: "No AI is set up" is no longer said for all of them.
        #expect(Set(AISetupCause.allCases.map(\.note)).count == AISetupCause.allCases.count)
    }

    @Test("A plan bought while the own key is chosen: the setup switches to the plan (not 'no AI')")
    func planBoughtWithOwnKeyChosen() {
        var s = Self.ready(.included)
        s.kind = .anthropic; s.hasOwnKey = false
        #expect(AISetup.target(s) == .included)
        #expect(AISetup.cause(s) == .onlineOff, "the one-step setup switches the provider")
    }

    final class Recorded: @unchecked Sendable {
        var calls: [String] = []
        let lock = NSLock()
        func add(_ c: String) { lock.lock(); calls.append(c); lock.unlock() }
    }

    @Test("The one step turns on every switch AI reading needs and accepts the provider's terms — and sends nothing")
    func enableTurnsEverythingOn() {
        let r = Recorded()
        let switches = AISetup.Switches(setKind: { r.add("kind:\($0.rawValue)") }, setOnline: { r.add("online") },
                                        setOnlineAnswers: { r.add("onlineAnswers") }, setAIEnabled: { r.add("aiEnabled") },
                                        ensureRegimeAllowsAI: { r.add("regime") }, setDocumentReading: { r.add("documentReading") },
                                        acceptTerms: { r.add("terms:\($0.rawValue)") })
        AISetup.enable(.included, switches: switches)
        #expect(Set(r.calls) == ["kind:included", "online", "onlineAnswers", "aiEnabled", "regime", "documentReading", "terms:included"])
        // After the step, the snapshot those switches describe has no cause.
        var s = Self.ready(); s.onlineOn = true; s.aiSwitchOn = true; s.documentReadingOn = true; s.termsAccepted = [.included]
        #expect(AISetup.cause(s) == nil)
    }

    @Test("The setup sheet names Anthropic, the relay (counts only), the once-per-case rule, the accuracy notice and shows the terms")
    func setupSheetText() {
        #expect(AISetupText.destination(.included).contains("Anthropic") && AISetupText.destination(.included).contains("relay")
                && AISetupText.destination(.included).contains("counts and credits"))
        #expect(AISetupText.destination(.anthropic).contains("directly to Anthropic"))
        #expect(AISetupText.lead.contains("asked once") && AISetupText.lead.contains("without a further prompt") && AISetupText.lead.contains("Nothing is sent now"))
        #expect(AISetupText.accuracy.contains("has not been measured"))
        #expect(AISetupText.allowButton == "Allow AI to read case documents you permit")
        #expect(OnlineProviderKind.included.documentTerms.contains("counts and credits") && !OnlineProviderKind.included.documentTerms.contains("questions used"))
        #expect(OnlineProviderKind.included.documentTerms.contains("Gemini API keeps prompts and replies for a limited period"))
    }

    @Test("Offline search results say why no AI answered, in the missing step's words")
    func offlineReasonNamed() {
        let id = UUID()
        let a = VerifiedAnswer(body: "x", answerText: nil, intentKind: nil,
                               citations: [VerifiedAnswer.Citation(objectID: id, chunkID: nil, snippet: "The invoice was paid on May 2.")],
                               confidence: .zero, refused: false, source: .experts, answerState: .unknown)
        let shown = OfflineSearchResults.present(a, question: "When was the invoice paid?", reason: AISetupCause.aiSwitchOff.note)
        #expect(shown.body.contains("AI answers are switched off (Settings ▸ Modules ▸ Use AI to write answers), so no answer is written"), "\(shown.body)")
        #expect(OfflineSearchResults.present(a, question: "q").body.contains(OfflineSearchResults.defaultReason))
    }

    // MARK: - PB1

    static let doc = CaseReader.Document(objectID: UUID(), fileName: "judgment.txt",
                                         text: "On March 3, 2021, John Smith was sentenced to 60 months in prison for wire fraud.")

    @Test("Claims proposed but none verifies: 'could not be confirmed', not 'documents don't say'; the pointed passage shown as a search result")
    func unconfirmedIsNotNotStated() {
        let reply = #"{"status":"answered","claims":[{"text":"John Smith was sentenced on April 1, 2021.","quote":"John Smith was sentenced on April 1, 2021","passage":1}],"answer":"April 1, 2021"}"#
        guard case .notStated(let a) = CaseReader.verdict(reply: reply, question: "When was John Smith sentenced?", documents: [Self.doc], rules: nil) else {
            Issue.record("expected the not-shown outcome"); return
        }
        #expect(a.body.hasPrefix(CaseReader.unconfirmedLead))
        #expect(!a.body.contains("don't say") && !a.body.contains("April 1"), "\(a.body)")
        #expect(!a.refused && a.answerState != .notFound)
        #expect(a.intentKind == VerifiedAnswerComposer.unconfirmedKind && VerifiedAnswerComposer.writer(of: a) == "ai-unconfirmed")
        #expect(a.citations.map(\.objectID) == [Self.doc.objectID], "the document it pointed to, as a search result")
        #expect(a.body.contains("search results, not confirmed"))
        #expect(VerifiedAnswerComposer.wrote(a), "the shape gates leave it as written")
    }

    @Test("The reader itself says not_stated after reading the whole case: then 'the case's documents don't say'")
    func readerNotStated() {
        let reply = #"{"status":"not_stated","claims":[],"answer":""}"#
        guard case .notStated(let a) = CaseReader.verdict(reply: reply, question: "Was John Smith pardoned?", documents: [Self.doc], rules: nil) else {
            Issue.record("expected not stated"); return
        }
        #expect(a.body.hasPrefix("The case's documents don't say. The AI read all 1 document"))
        #expect(a.refused && a.answerState == .notFound)
    }

    @Test("A claim pointing outside the case (no such document) is still unconfirmed, with no made-up source")
    func unconfirmedOutOfRange() {
        let reply = #"{"status":"answered","claims":[{"text":"He was pardoned.","quote":"pardoned","passage":7}],"answer":"Yes"}"#
        guard case .notStated(let a) = CaseReader.verdict(reply: reply, question: "Was John Smith pardoned?", documents: [Self.doc], rules: nil) else {
            Issue.record("expected the not-shown outcome"); return
        }
        #expect(a.body.hasPrefix(CaseReader.unconfirmedLead) && a.citations.isEmpty)
    }

    // MARK: - AI Pro yearly economics

    @Test("AI Pro yearly: 5,400 credits a month; AI Pro monthly 6,000; AI Included 2,000 both — each covered at 27 % VAT and 15 %")
    func yearlyAllowance() {
        #expect(AIPricing.aiPro.yearlyMonthlyCredits == 5_400 && AIPricing.aiPro.monthlyCredits == 6_000)
        #expect(AIPricing.aiIncluded.yearlyMonthlyCredits == 2_000 && AIPricing.aiIncluded.monthlyCredits == 2_000)
        #expect(SubscriptionPlan.proAnnual.monthlyCredits == 5_400 && SubscriptionPlan.proMonthly.monthlyCredits == 6_000)
        #expect(SubscriptionPlan.aiAnnual.monthlyCredits == 2_000 && SubscriptionPlan.annual.monthlyCredits == 0)
        func netPerMonth(_ price: Double, months: Double) -> Double { price / 1.27 * 0.85 / months }
        let creditUSD = AIPricing.creditUSD
        #expect(netPerMonth(989.99, months: 12) >= Double(SubscriptionPlan.proAnnual.monthlyCredits) * creditUSD)
        #expect(netPerMonth(989.99, months: 12) < 6_000 * creditUSD, "6,000 a month would not be covered")
        #expect(netPerMonth(389.99, months: 12) >= Double(SubscriptionPlan.aiAnnual.monthlyCredits) * creditUSD)
        #expect(netPerMonth(99, months: 1) >= Double(SubscriptionPlan.proMonthly.monthlyCredits) * creditUSD)
        #expect(netPerMonth(39, months: 1) >= Double(SubscriptionPlan.aiMonthly.monthlyCredits) * creditUSD)
        let yearly = PlanOffer(plan: .proAnnual, displayPrice: "$989.99", periodText: "1 year", eligibleForTrial: false, trialDays: nil)
        #expect(yearly.disclosure.contains("5,400 AI credits a month") && !yearly.disclosure.contains("6,000 AI credits a month"))
        #expect(PlanTier.aiPro.includes.contains("5,400 a month on the yearly plan"))
        #expect(PlanTier.aiIncluded.includes.contains("first time") && !PlanTier.aiIncluded.includes.contains("a typical question uses a few credits"))
    }

    // MARK: - LS3 / LS4

    final class Destination: @unchecked Sendable { var value = "anthropic" }

    @Test("A case permission is tied to its destination: own key ↔ AI plan asks again; revoke withdraws it")
    func permissionDestination() {
        let d = Destination()
        let store = CaseReadPermissionStore.inMemory(destination: { d.value })
        let caseID = UUID()
        store.grant(caseID: caseID, fingerprint: "f", documentCount: 3)
        #expect(store.isGranted(caseID: caseID, fingerprint: "f"))
        #expect(store.permission(caseID: caseID)?.destination == "anthropic")
        d.value = "included"
        #expect(!store.isGranted(caseID: caseID, fingerprint: "f"), "switching to the AI plan re-asks")
        d.value = "anthropic"
        #expect(store.isGranted(caseID: caseID, fingerprint: "f"))
        store.revoke(caseID: caseID)
        #expect(!store.isGranted(caseID: caseID, fingerprint: "f") && store.permission(caseID: caseID) == nil, "Stop AI for this case")
        // A permission stored before destinations were recorded is asked again.
        let legacy = CaseReadPermissionStore(load: { _ in CaseReadPermission(caseID: caseID, fingerprint: "f", grantedAt: Date(), documentCount: 1) },
                                             save: { _, _ in }, destination: { "included" })
        #expect(!legacy.isGranted(caseID: caseID, fingerprint: "f"))
        // Decoding an old stored permission (no destination field) still works.
        let old = #"{"caseID":"\#(caseID.uuidString)","fingerprint":"f","grantedAt":0,"documentCount":1}"#
        #expect((try? JSONDecoder().decode(CaseReadPermission.self, from: Data(old.utf8)))?.destination == nil)
    }
}
