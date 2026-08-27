# Legal Readiness — audit & checklist

**Honest framing.** This audits the app's legal *collateral and wiring*. It is **not legal advice**, and the drafted Privacy Policy / Terms / EULA are a good-faith starting point that **must be reviewed by qualified counsel** for your jurisdiction and distribution before public or commercial release (`LegalNotice.counselNote` says this in-app).

Status keys: ✅ done · ◻︎ owner/counsel action · ⚠️ verify.

---

## 1. In-app declarations (code) — ✅ solid
- ✅ **Single source of truth:** `Core/LegalNotice.swift` — answer footer, Ask entry line, full **report disclaimer**, accuracy / privacy / terms / third-party statements, and a counsel note. (The "Built with Llama" attribution was REMOVED 2026-08-27 — v1 ships no Llama model; it returns only if the optional v1.x GGUF path ships.)
- ✅ **Settings ▸ Legal & Privacy** (always visible, not behind Advanced): headline "an evidence aid, not an authority", accuracy, privacy, terms, acknowledgments, counsel note.
- ✅ **Per-answer disclaimer** on AI answers; **per-persona export disclaimers** (`PersonaTemplateCatalog.disclaimer(for:)`).
- ✅ **Every exported report leads with the disclaimer** — including the two studios shipped this cycle: **Reasoning Studio (RCA)** and **Competing Hypotheses (ACH)** reports now prepend `LegalNotice.reportDisclaimer` (locked by tests). "Not legal, financial, or professional advice" — which covers the illustrative **clinical differential** discipline (also flagged "not medical advice" in its Sūtra provenance).
- ✅ **AI SOP→Sūtra import** is framed as "a draft to review and ratify, not an authority"; the model can't invent tooling and nothing is auto-adopted.

## 2. Privacy posture — ✅ matches "Data Not Collected"
- ✅ Fully **on-device**: documents, ledger, questions, answers never leave the device; **no analytics or telemetry**; `PrivacyGate` filters cloud providers out of capability resolution.
- ✅ The only network use is an *optional, user-initiated* model download — user documents are never part of it (stated in `privacyStatement`).
- ◻︎ **App Store privacy label:** set **"Data Not Collected"** in App Store Connect (matches the above). *(owner)*
- ⚠️ Confirm no third-party SDK silently collects (there are none in the shipping target; re-verify before submission).

## 3. Third-party notices & model licences — ✅ present, ◻︎ one file to drop in
- ✅ `Legal/THIRD_PARTY_NOTICES.md`; `Legal/LICENSES/BGE_MIT_LICENSE.txt`; `Legal/LICENSES/LLAMA_LICENSE_README.md`.
- ✅ In-app acknowledgments (Apple frameworks; Apple Foundation Models on macOS 26+; BGE embedding/reranker MIT — notice bundled at `Kalsmritikosh/Resources/THIRD_PARTY_NOTICES.txt`).
- ✅ **N/A for v1** — no Llama model ships (SHIP_DECISIONS GOV-001); the Llama licence/attribution obligations apply only to the optional v1.x downloaded-GGUF path.
- ⚠️ Ensure the licence files are **bundled** in the app (Copy Bundle Resources), not just in the repo. *(owner — pbxproj)*

## 4. Website legal pages — ✅ present
- ✅ ONE canonical public version (D-4, 2026-08-27): the served `docs/privacy.html`, `terms.html`, `support.html` (v1.5). The old `docs/legal/` markdown drafts were REMOVED (they were publicly served as a second, stale version); `release/*.md` drafts are marked SUPERSEDED.
- ◻︎ Have counsel reconcile the website copy with the in-app `LegalNotice` copy so they don't diverge. *(counsel)*

## 5. Export compliance & Info.plist — ◻︎ owner (harness cannot edit pbxproj/Info.plist)
- ◻︎ **`ITSAppUsesNonExemptEncryption`** — set in Info.plist. The app uses only standard OS crypto (hashing/SHA-256 for custody) → typically **exempt**; declare accordingly. *(owner)*
- ◻︎ App Store **age rating** and **category** questionnaire. *(owner)*

## 6. Use-restriction / lawful-use terms — ✅ stated, ◻︎ counsel
- ✅ `termsStatement`: "as is", liability limitation, **you confirm the legal right to ingest/analyse the documents**, lawful-use only (no unlawful surveillance/harassment; no privileged material you aren't entitled to review).
- ◻︎ Counsel to strengthen for the surveillance-capable personas (Investigator/SIU) per target jurisdictions (e.g., wiretap/PI-licensing regimes). *(counsel)*

## 7. Professional-output guardrails — ✅ built
- ✅ The app **refuses to guess** (evidence gate), **surfaces conflicts** (never averaged), requires a **standard of proof** before findings approval, and **surfaces open items** — all of which reduce the "authoritative-looking but wrong" risk. The Sūtra **conformance certificate** records that these gates were met.

---

## Blocking items before submission (all owner/counsel — none are code)
1. ◻︎ Counsel review + jurisdiction adaptation of **Privacy Policy, Terms/EULA, disclaimers** (esp. investigative personas).
2. ◻︎ App Store Connect: **"Data Not Collected"** label; encryption declaration (`ITSAppUsesNonExemptEncryption`); age rating; category.
3. ✅ Bundle third-party licence text: DONE for v1 — the BGE MIT notice ships in the app bundle (`Resources/THIRD_PARTY_NOTICES.txt`, verified in the built app). Llama licence N/A for v1 (no Llama model ships).
4. ⚠️ Final pass: confirm no telemetry/third-party SDK in the shipping target.

**Bottom line:** the app is **legally hardened in code** — private by design, disclaimed on every AI output and every exported report (now including the new studios), lawful-use terms in place, notices present. What remains is **not code**: counsel review of the policy text and the App-Store/Info.plist declarations, which only the owner can complete.
