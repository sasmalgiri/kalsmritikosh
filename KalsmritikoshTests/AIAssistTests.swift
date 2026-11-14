//
//  AIAssistTests.swift
//  KalsmritikoshTests
//
//  A5–A7 — translate, challenge, draft: what is sent (only the passages, labelled), what the prompts
//  forbid, the citation check on what comes back, and the translation document's header.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("AI assist: translate, challenge, draft (A5–A7)")
struct AIAssistTests {
    let a = UUID(), b = UUID()

    @Test("Passages are labelled once each, in order, and capped in size")
    func labelling() {
        let p = AIAssist.label([(a, "inv.pdf", "Paid 3 May."), (a, "inv.pdf", "Paid 3 May."), (b, "mail.eml", " Not paid. "), (b, "mail.eml", "  ")])
        #expect(p.map(\.label) == ["P1", "P2"] && p[1].text == "Not paid." && p[1].source == "mail.eml")
        let big = String(repeating: "x", count: AIAssist.maxPromptChars - 10)
        #expect(AIAssist.label([(a, "s", big), (b, "s", "more than ten characters")]).count == 1)
    }

    @Test("The challenge argues against the answer and forbids a conclusion; the draft cites every sentence and does not speculate")
    func prompts() {
        let p = AIAssist.label([(a, "inv.pdf", "Invoice 432 was paid on 3 May.")])
        let c = AIAssist.challengePrompt(question: "Was 432 paid?", answer: "Yes, on 3 May.", passages: p)
        #expect(c.contains("not to agree with it and not to reach a conclusion of your own"))
        #expect(c.contains("Other explanations") && c.contains("[P1] (inv.pdf)\nInvoice 432 was paid on 3 May."))
        let d = AIAssist.draftPrompt(question: "Was 432 paid?", answer: "Yes.", passages: p)
        #expect(d.contains("Every sentence must end with the label") && d.contains("do not speculate"))
        let t = AIAssist.translationPrompt(fileName: "carta.pdf", part: 1, of: 2, text: "Pagado el 3 de mayo.")
        #expect(t.contains("do not summarise") && t.contains("part 1 of 2") && t.hasSuffix("Pagado el 3 de mayo."))
    }

    @Test("The citation check flags invented passages and uncited sentences; a fully cited draft passes")
    func citationCheck() {
        let p = AIAssist.label([(a, "inv.pdf", "Paid 3 May."), (b, "mail.eml", "Not paid.")])
        let good = AIAssist.review(kind: "draft", text: "The ledger records invoice 432 as paid on 3 May 2026 [P1]. A later e-mail from the supplier says it was not paid [P2].", passages: p)
        #expect(good.isFullyCited)
        let bad = AIAssist.review(kind: "draft", text: "The payment was made by the finance director personally on 3 May [P7]. The supplier was clearly lying about the payment in its e-mail.", passages: p)
        #expect(bad.unknownCitations == ["P7"] && bad.uncitedSentences.count == 1 && !bad.isFullyCited)
        let silent = AIAssist.review(kind: "challenge", text: "4. What further evidence would settle it:\nThe passages do not say who authorised the payment or from which account it left.", passages: p)
        #expect(silent.isFullyCited, "a heading and an explicit 'do not say' need no citation")
    }

    @Test("Translation is split at paragraph breaks, every character kept; the document says it is not the original")
    func translationParts() {
        let para = String(repeating: "palabra ", count: 200)   // 1,600 chars
        let text = (0..<20).map { "\($0) \(para)" }.joined(separator: "\n\n")
        let parts = AIAssist.parts(of: text, size: 5_000)
        #expect(parts.count > 1 && parts.allSatisfy { $0.count <= 5_000 })
        #expect(parts.joined() == text)
        let doc = AIAssist.translationDocument(original: "carta.pdf", originalObjectID: a, provider: "Claude (Anthropic)", model: "claude-opus-5",
                                               at: Date(timeIntervalSince1970: 1_800_000_000), body: "Paid on 3 May.")
        #expect(doc.hasPrefix("AI TRANSLATION INTO ENGLISH — NOT THE ORIGINAL DOCUMENT"))
        #expect(doc.contains("Original: carta.pdf (document \(a.uuidString))") && doc.contains("Quote the original, not this translation"))
    }
}
