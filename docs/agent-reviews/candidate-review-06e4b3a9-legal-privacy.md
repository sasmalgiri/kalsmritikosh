# AGENT REVIEW — legal / privacy confirmation re-review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-06
Commit: 06e4b3a93edfad2864b3e5a084ab4c187c349ebd

This is an agent review, not a lawyer's opinion or sign-off. It is read-only: I read the code and documents. I did not
build, run tests or use the app. It is a short confirmation review, as the conditions of
`candidate-review-572b5893-legal-privacy.md` allowed, of the commit that fixes that review's blocker LB3.

- **Candidate:** `06e4b3a9` on `investigations-next` (packages A `8a1a23cc` and B `572b5893` plus this fix). The working
  tree differs only in Xcode-extracted `InfoPlist.xcstrings` and user metadata.
- **Baseline:** `candidate-review-572b5893-legal-privacy.md` (NOT APPROVED, blocker LB3; should-fix LS10–LS16; carried LN4,
  LN6, LS6).
- **Method:** I read the full product, test and document diff of `git show 06e4b3a9` (the GUI-walk evidence files only by
  name). I traced every writer and eraser of the workspace and "not applicable" preferences. I then re-scanned
  `docs/*.html`, `docs/for/`, `docs/website/`, the listing, the label and the in-app copy (`Kalsmritikosh/UI`, `Core`, `App`,
  `Localizable.xcstrings`) for "never leave", "100 %", "no uploads", "entirely/fully on your", "all on your Mac", "nothing
  leaves", "every send" and "nothing else".

**Verdict: APPROVED.** LB3 is fixed, and the fix goes further than asked: the preference no longer holds document text at
all. LS10–LS16 are addressed (LS10 is left for the owner to fill in, which is correct). The diff introduces no new sending,
consent or retention path. The re-scan found no unqualified "never leave your Mac" or "100 % on your Mac" claim on any public
page or in the app. It did find two older "every send is previewed / you see exactly what will be sent" sentences that this
review's earlier greps missed. They are should-fix items (LS17, LS18), not blockers. The authoritative texts (the privacy
policy, the terms, the permission sheet and the help) state the actual behaviour correctly.

## LB3 — fixed

| Check | Result | Evidence |
|---|---|---|
| Full erase clears the workspace preference | **Yes** | `caseContentPreferencePrefixes` now holds `"kalsmritikosh.jobs.log."`, `"kalsmritikosh.jobs.ran."`, `"kalsmritikosh.jobs.na."` and `CaseWorkspaceStore.keyPrefix` (`"kalsmritikosh.case.workspace."`) (`App/AppState.swift:4343`). The full erase removes every key with one of these prefixes from `erasePreferences` (`:4461-4465`). |
| Full erase clears the `jobs.na` reasons | **Yes** | Same prefix list. The writer is `UI/PersonaJobsView.swift:118-125` (`kalsmritikosh.jobs.na.<case UUID>`, the person's typed reasons). A case erase already removed it, because the key contains the case UUID (`App/AppState+Erasure.swift:88-91`). |
| Same store written and erased | **Yes (in the app)** | The workspace is written to `AppDefaults.store` (`UI/CaseFileView.swift:64`), and `jobs.na` to `UserDefaults.standard`. In the app, both stores and `erasePreferences` are `.standard`. In a test host they are separate per-process suites by design (`App/AppDefaults.swift`), so the tests write straight into `erasePreferences`. |
| No document text in UserDefaults | **Yes** | `CaseSourcePosition` now stores only `objectID`, `origin` (a contradiction ID and side, or a case-entry ID) and `revision` (`Investigate/CaseFile/CaseWorkspace.swift:22-50`). The passage is re-read from the ledger (`passage(contradictions:entries:objectForVersion:)`). It is dropped when the document has a newer version. The name comes from loaded case data (`CaseFileView` `sourceName`). Both writers build the position from identifiers only (`UI/CaseContradictionsSection.swift:383, :447`; `CaseFileView` entry open). A state saved by an earlier build with `"quote"` is rewritten without it on its next load (`CaseWorkspace.swift` `load`), and a full erase removes it in any case. The other remaining fields are the tab, selected IDs, the filter and the person's own `contradictionSearch` text. These are disclosed in `DATA_FLOW_INVENTORY.md` L15 and erased both with the case and with everything. |
| Tests | **Present** | `DiagnosticEndToEndTests` (full erase → no `kalsmritikosh.jobs.na.*` and no `kalsmritikosh.case.workspace.*` key, `ImplementAllUnitsTests.swift:880-905`); `CaseErasureTests.caseEraseRemovesWorkspacePreference` (case erase removes only that case's key). |
| Inventory | **Updated** | `docs/DATA_FLOW_INVENTORY.md` L15 names the key, its fields and "identifiers only", the rewrite of older states, and both erasures. |

## LS10–LS16

| # | Status | Evidence |
|---|---|---|
| LS10 packet commit | **Addressed; owner step** | `docs/RELEASE_CANDIDATE.md` current section: schema v170, contents A/B/fixes, and `Candidate: [owner: …]`. That is a placeholder, so the evidence gate stays OPEN until the owner names the uploaded commit, which is correct. `ci/release-gates.json` `candidate_note` updated (v170, Opus 5.5). |
| LS11 `docs/website/index.html` | **Fixed** | "Three steps. Private by default." (`:170`); "By default, your documents never leave your Mac." (`:193`), with a lead that names the case documents and questions, Anthropic, both AI plans, the relay keeping only counts, and recordings to Google (Gemini), which matches `privacy.html:47, :89`. The FAQ adds the per-case permission. The remaining "entirely/fully on your Mac" lines say "In Private mode" (`:114`, `:211`). |
| LS12 terms date / version | **Fixed** | `docs/terms.html:41` "Last updated: 6 November 2026"; `LegalNotice.termsVersion = "1.12 (2026-11-06)"`. `documentTermsVersion` unchanged, so there is no re-acceptance, which is correct (see the 572b5893 review: the model change is not material). |
| LS13 ask-in-case → erase | **Fixed** | `CaseErasureTests.askInCaseThenEraseReplacesQuestionText`. It uses the real `investigationAnswers` service with the cloud interpreter and rewriter on a fake transport. It asserts the in-case question was sent and carries the case marker, that after the case erase the text is replaced with the erasure line (hash and size kept, no "SECRET"), and that a send outside the case keeps its text. |
| LS14 unlisted case documents | **Fixed** | `CaseCoverageReadout.make` counts scope versions missing from the manifest: as read when the ledger has text, otherwise "not read: no reading record". Other versions of a document are de-duplicated by logical source. Test: `PackageBTests.coverageCountsUnlistedCaseDocuments`. The new repository query is read-only. |
| LS15 Opus 5.5 decision recorded | **Fixed** | `SHIP_DECISIONS.md` §5 2026-11-06 entry. The "ship with Opus 5" wording is annotated in `RELEASE_CANDIDATE.md`, `ci/release-gates.json` and `OWNER_LAUNCH_CHECKLIST.md`. |
| LS16 Home "Private by default" | **Fixed** | `UI/HomeView.swift:231` "In Private mode your documents are read on this Mac …". The onboarding has the same qualifier, and "shows every send before it leaves" is removed. The trial is now "of Workbench (no AI)" (`UI/OnboardingView.swift:266, :269`). |

## Regression check of the 06e4b3a9 diff

- **No new network, sending or consent path.** The diff adds no `URLSession`, `NSWorkspace.open`, `mailto`,
  `NSSharingService` or `Task.detached`. `CaseReviewCommands` are menu key equivalents. The overview counts only navigate.
  The contradiction-check limit line is display text.
- **No new stored content.** The only preference change removes text. The coverage change reads `source_versions`. No
  schema change.
- **Copy changes are narrower, not broader.** The trial is now stated as Workbench only (it was unqualified). The onboarding
  sentence "no case document goes to the AI until you allow it for that case" is true: case sends need the case permission,
  and outside a case the general route refuses sends without a clearance.
- The help and manual changes describe navigation and keys only.

## Re-scan of public and in-app copy

There is **no unqualified "never leave(s) your Mac" or "100 % on your Mac"** on any public page or in the app. Every hit is
scoped: "In Private mode" or "By default" (`docs/index.html:257, :406, :449, :483`; `docs/privacy.html:43, :71`;
`docs/website/index.html:114, :172, :193, :211, :227`; `SettingsView.swift:2523`; listing `:55` "Without AI"), or "for this
request" (`OnlineViews.swift:24-25`), or it concerns things that truly never leave (Keychain key, protected identities,
MetricKit). The "100 %" hits are CSS widths and progress bars. Two "every send" overstatements remain (LS17, LS18 below).
`privacy.html:95, :109` ("Every send is recorded") and `ProductModule.swift:177` ("every send measured and logged") are true.

## Should-fix (none blocking)

| # | Finding | Evidence |
|---|---|---|
| LS17 | Public page, linked from `index.html` and `support.html`: "Online mode is opt-in and **every send is previewed**". Since `b66cf7a9`, a case the person allowed sends its documents and its questions without a further preview (as the privacy policy and terms 1.10+ say). Change it to "Online mode is opt-in, asks once per case, and every send is recorded". The span is `data-claims-exempt="mirror-of-register"`, so also change the register text it mirrors. This wording dates from `94c93618`. | `docs/sop-register.html:63` |
| LS18 | In-app module description (Settings ▸ Modules): "You see exactly what will be sent before it goes". Inside an allowed case, question-only sends and later reads go without a preview. Suggest: "Inside a case you allow the AI once, with the list of its documents; elsewhere you see what would be sent first. Every send is logged …" (as `ConnectivityMode.swift:35` already says). This wording dates from `9833d055`. | `App/Modules/ProductModule.swift:402` |
| LN4, LN6 | Carried over, unchanged: the legacy full-copy match can erase another case's identical copy (errs on the privacy side); an untagged fallback record is written when the log lookup throws. | `CaseErasure.swift:281-287`; `OnlineCloudProvider.swift` |
| LS6 | Owner step, carried over: confirm Anthropic's retention figure ("within 30 days by default") and Google's on the day of submission. | `docs/privacy.html:118, :188` |

## Conditions

- This approval names `06e4b3a9`. `scripts/release_check.py` passes the `legal-privacy` gate only when the candidate commit
  equals the `Commit:` field. If the owner uploads a later commit (including one that only adds these review files or
  LS17/LS18 copy fixes), the record must be re-pointed to that commit. A copy-only or docs-only change needs only a one-line
  confirmation.
- Re-run this review in full if a later commit changes sending, consent, erasure, preferences that hold case content, or the
  public privacy text beyond LS17/LS18.
