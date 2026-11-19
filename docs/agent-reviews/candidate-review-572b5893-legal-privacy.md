# AGENT REVIEW — legal / privacy re-review (not counsel; owner decision 2026-11-01)

Decision: NOT APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-06
Commit: 572b5893c9130fcb31bb8ffd784ea32798c6286b

This is an agent review, not a lawyer's opinion or sign-off. It is read-only: I read the code and documents. I did not
build, run tests or use the app. The commit field above records the commit reviewed. It does not approve it.
`release/approvals/legal-privacy.md` still names `9da8a81d`, so the `legal-privacy` gate stays OPEN for this candidate,
which is correct while this review is NOT APPROVED.

- **Candidate:** `572b5893` (Package B) on `investigations-next`, together with `8a1a23cc` (Package A, schema v170) before it.
  Line numbers are at `572b5893`. The working tree differs only in Xcode-extracted `InfoPlist.xcstrings` and user metadata.
- **Baseline:** `candidate-review-9da8a81d-legal-privacy.md` (APPROVED; should-fix LN1–LN6, open LS6 and LS10).
- **Method:** I read the full diffs of `8a1a23cc` and `572b5893`. I traced `CaseSendScope` from `InvestigationAnswerService`
  to `OnlineCloudProvider.send` and checked for detached tasks on the question path. I read the v170 migration against
  `CaseEraser` (generic `case_id` sweep, erase markers in the append-only triggers) and against the case and full erase of
  preferences (`AppState+Erasure.swift`, `AppState.deleteAllData`). I also read the coverage readout and its three
  surfaces, the evidence-request draft path, every changed public page, `terms.html`, `privacy.html`, the listing, the label,
  `PrivacyInfo.xcprivacy`, the `.storekit` descriptions, the in-app plan text, the relay diff, and how the app records
  terms acceptance (`LegalNotice.termsVersion`, `OnlineProviderKind.documentTermsVersion`, `AISetup.termsAccepted`,
  `CaseReadPermission.destination`).

**Verdict: NOT APPROVED. One blocker (LB3), introduced by `8a1a23cc`; it is a one-line fix plus a test.** LN1–LN3 are fixed.
The model change is disclosed consistently. Draft letters are never sent. Case erasure covers the v170 tables. The
coverage display makes no completeness claim. Once LB3 is fixed, the rest can ship as should-fix.

## Blocker

| # | Finding | Evidence |
|---|---|---|
| **LB3** | **"Delete all my data" leaves document text from every case in the plain preferences file.** Package A stores a per-case workspace state in the preferences: `lastSource.quote` (the verbatim passage the person opened, from a contradiction side or a chronology/case entry), `lastSource.label` (the document's name) and `contradictionSearch` (free text the person typed, which can be a name). Erasing a single case removes it, because the sweep matches the case UUID (`AppState+Erasure.swift:88-91`; key `kalsmritikosh.case.workspace.<UUID>`). The full erase does not. It clears only `caseContentPreferenceKeys` and the prefixes `kalsmritikosh.jobs.log.` / `kalsmritikosh.jobs.ran.` (`AppState.swift:4336-4341`, `:4459-4463`). After a full erase, a quote from each erased case's documents therefore survives, unencrypted, outside the SQLCipher ledger. This contradicts the confirmation "Erase everything … all ingested documents, the extracted ledger…" (`SettingsView.swift:2177`), the policy's "you control and can delete it (Settings ▸ Your data)" (`privacy.html:184-185`) and the site's "Erase everything in one click" (`index.html:269`). It also puts document text next to the listing's "the knowledge base is encrypted on disk" (`APP_STORE_LISTING.md:55`) without saying so. This is the same class as LB1 (erased content surviving an erasure), which was a blocker on 7d720fe1. **Fix:** add `"kalsmritikosh.case.workspace."` to `caseContentPreferencePrefixes` and add a test (full erase → no `kalsmritikosh.case.workspace.*` key). Also add the workspace state (quote, document name, search text) to `DATA_FLOW_INVENTORY.md` L15. Optionally, store only `objectID` and drop `quote`/`label`, re-reading them from the ledger. | `Investigate/CaseFile/CaseWorkspace.swift:17-46, :51`; writers `UI/CaseContradictionsSection.swift:418`, `UI/CaseFileView.swift:1647`; `App/AppState.swift:4341, :4459-4463`; `docs/DATA_FLOW_INVENTORY.md:58` |

## Earlier should-fix items (9da8a81d)

| # | Status | Evidence |
|---|---|---|
| **LN1** question-only sends in a case survive erasure | **Fixed** | New TaskLocal `CaseSendScope.caseID` (`Core/Security/CaseReadPermission.swift:84-86`). It is set around the whole case answer (`InvestigationAnswerService.swift:144-150`, the only case-ask entry point; the one caller is `PersonaJobService.swift:132`). `send` falls back to it when there is no clearance binding (`OnlineCloudProvider.swift:217`), so the interpreter's and rewriter's `generateQuestionOnly` records carry `case <uuid>` and `CaseEraser.eraseOutboundText` replaces their text. The question path has no `Task.detached` (the four in `MasterBrain` are post-answer persistence/distillation; the general `generate` route refuses sends without a clearance, `:131-138`), so the TaskLocal reaches the provider. It only labels the record and widens nothing. Test: `PackageBTests.questionOnlySendCarriesCaseMarker` (marker inside the case, none outside). Erasure by marker is already covered by `CaseErasureTests.caseEraseRemovesOutboundText`. The `CaseErasure.swift:15-18` header and `privacy.html:186-188` ("the text it sent") are now accurate. Residual: the test is unit-level (provider plus TaskLocal), with no end-to-end answer → erase test; see LS13. |
| **LN2** site wording | **Fixed on the Marketing URL; residue on an unlinked page** | `index.html:269` now reads "…the documents of a case you allow and your questions in it are sent to Anthropic …, plus the Online lookups you run, as listed in the privacy policy". The meta description now says "Three plans" (`:7`). The "On-device AI" card is qualified "In Private mode … (with Online AI on, a case you allow is read by Anthropic)" (`:452`). Steps and caption say "in Private mode nothing leaves" (`:257`, `:406`). All 12 `/for/*.html` pages name documents, questions and the lookups (e.g. `for/siu.html:60`). A grep for `100 ?%`, `no uploads`, `entirely/fully on your`, `nothing else`, `never leave` over `docs/*.html`, `docs/for/*.html` and the listing finds no unqualified claim. Residue in `docs/website/index.html` (old Kalsmritikosh page, not linked, but published by Pages at `/kalsmritikosh/website/` because `docs/.nojekyll` exists): see LS11. |
| **LN3** setup silently overrides Fully private | **Fixed** | `AISetupText.turnsOn(regime:)` is rendered with the live regime (`AISetupViews.swift:44, :81-86`). From Fully private it says "It also changes the AI setting from “Fully private — no AI” to “AI · evidence-gated” …, because no AI can answer while Fully private is on". The `.gated` and `.free` summaries no longer say "nothing leaves your Mac" or "100% on-device"; they say "The on-device model itself sends nothing; only Online mode, when you turn it on, sends a case you allow to Anthropic" (`FeatureFlags.swift:219-221`). Test: `PackageBTests.setupSheetNamesPostureChange`. |
| LN4 legacy full-copy match can erase another case's copy | **Not fixed** (low; errs on the privacy side) | `CaseErasure.swift:281-287` is unchanged. |
| LN5 `.included` terms text changed without a version bump | **Note, see "Model change" below** | |
| LN6 untagged fallback record when the log lookup throws | **Not fixed** (note) | `OnlineCloudProvider.swift` `readCase.record` fallback is unchanged. |
| LS6 Anthropic retention figure | **Owner step, open** | Unchanged ("within 30 days by default"). Confirm on the day of submission. |
| LS10 candidate packet names the wrong commit | **Not fixed** | `docs/RELEASE_CANDIDATE.md:24` still `Candidate: c30d2191…`. `ci/release-gates.json` `candidate_note` still `7bb6323b (schema v169)`; the schema is v170. |

## Model change: relay on Claude Opus 5.5 (own key stays Opus 5)

**Disclosed consistently.** "Claude Opus 5.5" for the AI plans appears in: `terms.html:67`; the in-app plan text shown with
every AI price (`Purchase.swift:457`); the provider name "AI Included or AI Pro (Claude Opus 5.5)" (`OnlineProviderKind.swift:52`);
the `.included` provider terms shown on the permission and setup sheets (`:416`); the setup sheet's destination line
(`AISetupViews.swift:89`); the App Review notes (`APP_STORE_LISTING.md:145`); and `relay/wrangler.toml:27`. Each keeps the
fallback disclosure "if Anthropic declines a request, another Claude model may answer it". This matches the relay: the
server-side fallback goes to `claude-opus-5` / `claude-opus-4-8`, the reservation is held at the dearest rates, and each
reply is billed at the rates of the model that answered (`relay/src/policy.ts`, `index.ts`). "Each request is charged its
actual cost" stays true. `privacy.html`, `APP_PRIVACY_LABEL.md`, the `.storekit` descriptions and the help say only
"Anthropic (Claude)", with no version, so they are unaffected and still true. No public or in-app text names "Opus 5" for
the AI plans any more. The own-key path correctly still says just "Claude", with default `claude-opus-5`. The relay stores
nothing new (no content column; only rates, effort and the billed model changed).

**Does the model name need a terms version bump or re-acceptance? No, not for v1.** How the app records acceptance:
- The general notices have no click-through. `LegalNotice.termsVersion` ("1.11 (2026-11-04)") is displayed, and changes
  bind on "continued use after notice" (`LegalNotice.swift:184-211`).
- The only recorded acceptances are per destination: `confirmedDocumentTerms == kind.documentTermsVersion` ("2026-10-27",
  `OnlineProviderKind.swift:398, :435-440`), the `AISetup` `termsAccepted` set per `OnlineProviderKind`, and the case
  permission tied to `destination = OnlineSettings.kind` (`CaseReadPermission`).

None of these is keyed to the model, and that is the right granularity. The recipient (Anthropic's commercial API via the
publisher's relay), the purposes, the retention and the no-training terms are unchanged. The credit unit (US$0.01) is
unchanged, and a credit buys more tokens, so the change is not adverse to the person. It is therefore not a material
change requiring re-acceptance. There are also no released users, so no acceptance exists that could be stale. Two
housekeeping items remain:
- `terms.html:41` still says "Last updated: 4 November 2026", but its text changed on 6 November. See LS12.
- After release, a change of **recipient or retention** (not of model) must bump `documentTermsVersion` so each
  acceptance is asked again. A model change alone should bump `LegalNotice.termsVersion` and the date only.

## Other checks

- **Evidence-request draft letters are never sent.** The draft is a template from the record
  (`EvidenceRequestFollowUp.swift:285-288`, no AI). It opens in a sheet that says "Edit and send it yourself; the app does
  not send it. Copying it records nothing", and offers only Copy (`NSPasteboard`) and Close
  (`CaseEvidenceRequestsSection.swift:76-87`). Neither commit adds `mailto`, `NSSharingService`, `NSWorkspace.open` or
  `URLSession`. "Record sent" records the person's own act, and status changes only by a recorded decision. The tutorial
  says "The app sends nothing" (`HelpTutorial`).
- **Case erasure covers v170.** All new tables carry `case_id`: `investigation_review_decisions`, the rebuilt
  `investigation_evidence_requests` (FK cascade), `…_items`, `…_receipts` and `…_events`. `CaseEraser` deletes every user
  table with a `case_id` column except the four erasure-record tables (`CaseErasure.swift:73, :167-209`), and the residue
  check re-counts them (`:229`). The append-only `BEFORE DELETE` triggers allow deletion under `ledger_case_erase` /
  `ledger_full_erase` (v170 migration), so erasure is not blocked. Receipts reference source versions by ID only. The
  per-case workspace preference is removed by the case-UUID sweep. The full erase misses it (LB3).
- **In-case question sends** are erased with the case (LN1 above).
- **Coverage display makes no false completeness claim.** `CaseCoverageReadout` gives counts only ("Read: N · Partly read: N
  · Not read: N" with reasons), with no percentage and no "all read". It is shown on the overview
  (`CaseFileView.swift` `CaseCoverageBlock`), the permission sheet ("Not read, or read only in part, on this Mac (n) — what
  was not read cannot be sent", `CaseReadConsentSheet.swift`) and the report and export notice. When it is unavailable, the
  report says "Not available when this report was written" and does not imply it is complete. "A document not read here was
  not searched, quoted or sent to an AI" is shown only when there are unread entries, and is true for not-read documents.
  Partly read ones are labelled "partly read". Note: sources in the case scope that are missing from the workspace manifest
  are not counted in any bucket. The counts are not called complete, so this is acceptable, but see LS14.
- **5.1.1 / 5.1.2(i):** Consent is unchanged: the setup sheet, then once per case, tied to the destination and the
  documents, with withdrawal per case. It is now clearer: the posture change is named (LN3), and unreadable documents and
  the credit balance are shown beside the estimate. No new data leaves the Mac. Package A data is local ledger data plus one
  UI preference. The label and `PrivacyInfo.xcprivacy` are unchanged and still correct (UserDefaults CA92.1 covers the new
  preference).
- **3.1.1:** "Buy credits…" and "See plans…" open the IAP paywall. The own-key alternative is the existing Workbench BYO
  key. No new unlock path exists outside IAP.
- **3.1.2:** The allowances are unchanged (2,000 / 6,000 / 5,400) and match across the paywall, `.storekit`, terms,
  LegalNotice and relay. Cost lines ("charged N credits (the actual cost)", cancel "only what it actually used is charged
  and the rest of what was held is returned") match the relay's reserve and settle (`relay/src/index.ts:124-152`).
- **2.1:** The recovery sheet names one cause and one fix for each failure, and the tutorial covers the new screens. This
  helps the review.
- **2.3:** No accuracy figure appears on any public page. The setup sheet still says accuracy has not been measured.
  Internal records still say the owner decided to "ship with Opus 5" (`docs/RELEASE_CANDIDATE.md:10`,
  `release/OWNER_LAUNCH_CHECKLIST.md:129`, `ci/release-gates.json` `owner_decision_2026_11_04_gates`), while the AI plans now
  answer with Opus 5.5. See LS15.

## Should-fix (not blocking once LB3 is fixed)

| # | Finding | Evidence |
|---|---|---|
| LS11 | `docs/website/index.html` is publicly reachable and still has the unqualified heading "Your documents never leave your Mac." (`:193`) and "Three steps. All on your Mac." (`:170`). Its lead names only "AI Included" and omits AI Pro and questions (`:194`, `:197`). Delete the page, or apply the `index.html` wording. | `docs/website/index.html:170, :193-197`; `docs/.nojekyll` |
| LS12 | `terms.html` text changed (Opus 5.5) but the "Last updated" date is still 4 November 2026. Set it to 6 November 2026. For consistency, bump `LegalNotice.termsVersion` to 1.12 (2026-11-06) (not material; see above). | `docs/terms.html:41, :67`; `Core/LegalNotice.swift:185` |
| LS13 | Add one end-to-end test: ask in a case with a cloud interpreter installed → erase the case → no outbound entry still holds the question text. This locks LN1 against a future `Task.detached` on the question path. | `PackageBTests.swift:52-73` |
| LS14 | Coverage: count case-scope sources that are missing from the workspace manifest as "not read: not yet recorded" instead of dropping them, so `total` equals the documents in the case. | `CaseCoverageReadout.swift:68-77` |
| LS15 | Record the owner's decision to run the AI plans on Opus 5.5 where the records still say "ship with Opus 5", and bind the packet to the uploaded commit and schema v170 (with LS10). | `docs/RELEASE_CANDIDATE.md:10, :24`; `release/OWNER_LAUNCH_CHECKLIST.md:129`; `ci/release-gates.json` |
| LS16 | Home "Private by default": "Your documents are read on this Mac and the app opens no connection for them. Online AI is optional … before that case's documents go". The first clause is absolute. Prefix "In Private mode". | `UI/HomeView.swift:231` |
| LN4, LN6, LS6 | Carried over (see above). | |

## Conditions

Fix LB3 (the prefix, the test and the inventory line) and re-run this review on that commit. If LB3 is the only product
change, a short confirmation re-review is enough. Land LS10–LS12 and LS15 before upload. LS13, LS14, LS16, LN4 and LN6 may
follow. Confirm Anthropic's retention figure (LS6) on submission day. If any later commit changes sending, consent,
erasure, preferences that hold case content or public privacy text, this review must be re-run.
