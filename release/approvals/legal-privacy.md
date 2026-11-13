# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-13
Commit: 0fb6a57b5e137658d0537fc594dd87ca8569ad15

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: this confirmation review covers 4af12048..0fb6a57b: LS25, D1, smart-map M1 and slices S1–S18, schema v176 → v190. No blocker.
- Network: no new network API, entitlement, helper host or provider. The relay credential is now the StoreKit signed transaction (JWS). The relay checks it, keeps it only in memory for at most 5 minutes, and stores only the original transaction number as before. AI plans: Claude Opus 5.5. Own key: Anthropic only.
- AI permission: still once per case. It is now also bound to the model and to a digest of the own key, so changing either asks again.
- AI assistant (S10): proposals only, always labelled. Privileged and restricted documents are withheld, and the model is told only their count. Its send path is not reachable from the UI in this build.
- Vault encryption: the IN-02 texts (`privacy.html`, THREAT_MODEL T2, DATA_FLOW L1, `STORAGE_KEY_INVENTORY`, Settings, Help) match `EvidenceVault`. Only new copies are sealed; the stores that rely on FileVault are named; nothing claims that everything is encrypted.
- Erasure: LS25 is fixed in code. Erasure is wider: origin-only tables, tasks, sync side tables, this Mac's own sync batches, Spotlight, and full erase stopping sync. An erasure gap from an unescaped `'%_fts%'` is fixed.
- Diagnostics: cleaned before they are saved or offered. File names are now logged as private.
- Test-only paths: `TestHost` is constant `false` in Release.
- App Privacy label and `PrivacyInfo.xcprivacy`: still accurate.

New items, none blocking:
- LS26 (should-fix, before upload): with managed copies now on by default (existing installs included), "Stop and forget everything from this folder" (`AppState.swift:4739-4749` → `FilesRepository.deleteAllUnderRoot`) leaves a sealed vault copy of every file, which only a full erase removes. Fix: remove the root's unshared vault copies and their opened copies through the recorded case-erasure file step, with count-back and a test; or rename the button and state the retention in Settings, ST-03 and DATA_FLOW L1.
- LS27 (should-fix, wording, before upload):
  - (a) `privacy.html:59`: the opened copy stays "until the app next starts", not only "while you view it".
  - (b) `privacy.html:188`, DATA_FLOW L15 and THREAT_MODEL §6a: the stored AI permission also holds the model and a short one-way digest of the own key.
  - (c) `privacy.html:117` and DATA_FLOW N6: say the signed transaction also carries the storefront country, price, currency and the account token (confirm the device-verification fields against a real sandbox JWS).
  - (d) Update the "Last updated" date (`privacy.html:40`).
- LS28 (should-fix, latent; required before the AI assistant's run is wired to the UI): the assistant also sends the case's open allegations, task titles, evidence-request descriptions, the investigator's note and tool results without a preview. Preview them, or disclose them on the per-case permission sheet, in `privacy.html` and in a DATA_FLOW N-row.
- LN13: DATA_FLOW L14 and THREAT_MODEL T12 still say file names are logged as public, which S16 changed (says more than is true).
- LN14: record in THREAT_MODEL T15 that tests again wrote into the owner's folders (S18), and the guard that now stops it.
- LN15: the managed-copies default changes on update without a notice (local only).
- LN16: other devices' sync batches are not reached by erasure (disclosed in general terms).
- LN17: the case tables added in S1–S18 are covered by the inventory test, not checked one by one.
- LS25: closed in code; confirm its `CaseErasureTests` case passes in CI.
- LN4, LN6, LN8, LN9, LN10, LN11 and LN12, and the owner steps LS6 and LS10, carry over.

If the uploaded commit is not 0fb6a57b, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-0fb6a57b-legal-privacy.md](../../docs/agent-reviews/candidate-review-0fb6a57b-legal-privacy.md)
