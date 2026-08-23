# Battle Readiness — competitors, blocking vectors, and our counters (2026-08-23)

The pre-ship war-game the owner asked for: how competitors could block or hinder
us, what legal armor they carry that we lacked, and what was fixed in-app today.

## 1. The legal armor comparison (researched 2026-08-23)

What the strongest legal-tech competitors actually put in their terms, vs. us:

| Clause | Everlaw / Casefleet practice | Us before | Us now |
|---|---|---|---|
| "Not a law firm / no professional relationship" | Everlaw repeats it in ToS, professional-services addendum, even community rules | Only "not legal advice" | ✅ `noRelationshipStatement` — no attorney–client or any professional relationship; studios/standards references are not practice of a profession |
| Enumerated warranty disclaimer | "As is / as available" + merchantability, fitness, title, non-infringement | Bare "as is, no warranty" | ✅ `liabilityStatement` enumerates all four |
| Consequential-damages exclusion + liability cap | Casefleet: 6 months' fees or $500; Everlaw: as low as $100 | No cap, no enumeration | ✅ Cap = 12 months' payments (zero while free); indirect/consequential/lost-data excluded; risk-allocation sentence included |
| AI-output clause (2026 practice) | Output is probabilistic; customer must human-review before relying | Accuracy statement only | ✅ `aiOutputStatement` — probabilistic, human review REQUIRED before consequential use |
| Point-of-use disclosure (what 2025–26 enforcement rewards) | Varies; ToS-only disclosure gets less legal weight | ✅ Already strong — footer on every answer, disclaimer on page 1 of every report | ✅ Now stated explicitly as our posture (also the EU AI Act Art. 50 transparency position) |
| Data custody / backup responsibility | Casefleet: user solely responsible for backup | Silent | ✅ `responsibilityStatement` — everything is local; the developer holds NO copy; backup is the user's job |
| User indemnity for their content / unlawful use | Standard | Partial (lawful-use promise) | ✅ Explicit indemnity for user content and unlawful use |
| Export compliance | Expected by Apple for App Store apps | Missing | ✅ Included; Apple's standard EULA noted as fallback |
| Governing law + arbitration | Everlaw: California law + binding arbitration | Absent | ⚠️ OWNER + COUNSEL — jurisdiction choice is a business decision; do not self-draft |

All new clauses live in `Core/LegalNotice.swift` and are shown in
Settings ▸ Legal & Privacy (seven items now). The counsel note stays: these are
a good-faith baseline for a free launch, to be adapted by counsel before
commercial release.

## 2. The blocking vectors — how they could hinder us, and our counters

| Vector | Threat | Our counter |
|---|---|---|
| **Price dumping / free tiers** | Incumbents bundle a free tier to starve us | We ARE free at launch (owner decision) — they can't undercut zero; our cost base is $0/user (no cloud inference) |
| **Privacy-washing** | "We're private too" marketing while running cloud inference | Our claim is verifiable: no network calls outside model download, App Store "Data Not Collected", sandbox — invite audits; theirs can't pass this test |
| **Platform risk (Apple)** | App Review rejection: medical/legal-advice framing, model licensing | Disclaimers at point of use; "aid, not authority" positioning; Llama licence attribution shipped ("Built with Llama"); ITSAppUsesNonExemptEncryption owner item |
| **Model-licence attack** | Claim our bundled models breach their licences | Meta Llama Community Licence obligations tracked (MODEL_ATTRIBUTIONS.md); BGE is MIT; grep guard keeps model names out of core layers so swaps are cheap |
| **IP/patent assertion** | A troll or incumbent asserts a patent on RAG/timeline features | Our public repo docs (Sūtra, evidence-gate, claim–evidence contract) are dated prior art for our distinctive methods; we don't copy any competitor's UI or marks; generic-methods defence for the rest |
| **Trademark** | Name conflict on "Kalsmritikosh" | Distinctive Sanskrit coinage — low collision risk, but clearance search is an OWNER item before marketing spend |
| **Feature-copy by incumbents** | Everlaw/Casefleet clone the persona studios | Our moat is structural: on-device + evidence-gated + SOP-faithful studios wired to one ledger. A cloud vendor copying the UI can't copy "your data never leaves" |
| **FUD on AI accuracy** | "Their AI hallucinates evidence" | Evidence gate (ship/downgrade/refuse/surface-conflict), claim–evidence IDs, quality strip, human-review clause — we can demonstrate refusal behavior they can't |
| **EU AI Act (Aug 2026)** | Transparency obligations weaponised against small vendors | Point-of-use AI disclosure on every answer + report is exactly the Art. 50 posture; no high-risk-system classification sought |

## 3. What changed in code today

- `Core/LegalNotice.swift`: + `noRelationshipStatement`, `liabilityStatement`,
  `aiOutputStatement`, `responsibilityStatement`.
- `UI/SettingsView.swift`: Legal & Privacy section now surfaces all seven items.

## 4. Owner items (cannot be done in code)

1. Counsel review of all LegalNotice copy + choice of governing law / disputes
   clause before any paid release (the free launch lowers, not removes, exposure).
2. Trademark clearance for "Kalsmritikosh" in target markets.
3. App Store: "Data Not Collected" label, ITSAppUsesNonExemptEncryption,
   age rating, bundle the official Meta Llama licence text.
4. Keep the privacy policy line: "if you email us, we receive what you send."
5. If EU distribution: confirm AI Act Art. 50 transparency posture with counsel.

Sources: [Casefleet ToS](https://www.casefleet.com/legal/terms-of-service),
[Everlaw Customer ToS](https://www.everlaw.com/legal/customer-terms-of-service/),
[Everlaw Terms of Use](https://www.everlaw.com/legal/global-terms-of-use/),
[Everlaw Professional Services Addendum](https://www.everlaw.com/legal/everlaw-professional-services-addendum/),
[ToS for AI products in 2026](https://toslawyer.com/terms-of-service-for-ai-products-what-your-agreement-must-include-in-2026/),
[AI liability disclaimers](https://www.njbusiness-attorney.com/ai-liability-disclaimers/),
[AI output indemnification 2026](https://www.njbusiness-attorney.com/indemnification-for-ai-generated-outputs-who-pays-2026/),
[Jones Day on GenAI EULAs](https://www.jonesday.com/en/insights/2023/08/generative-ai-enduser-license-agreements),
[Apple standard app EULA](https://www.apple.com/legal/macapps/stdeula/).
