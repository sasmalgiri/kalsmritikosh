# AGENT REVIEW — legal / privacy re-review (not counsel; owner decision 2026-11-01)

- **Reviewer:** Claude agent acting as the legal/privacy reviewer, by the owner's decision of 2026-11-01 that agents
  replace human review gates for v1. This is not legal advice and not a lawyer's sign-off.
- **Date:** 2026-11-04
- **Candidate:** `9da8a81d2357f78ba73da91e9240cb31b588e1f1` (`investigations-next`). Line numbers are at this commit (HEAD; the
  working tree differs only in Xcode-extracted `InfoPlist.xcstrings` and user metadata).
- **Baseline:** `candidate-review-7d720fe1-legal-privacy.md` (LB1, LB2, LS1–LS10), plus the items of the other 7d720fe1
  reviews that touch legal/privacy: user-evaluation UB1 (= LS9), practitioner PB1 (unsupported negative) and PB2 (= LB1).
- **Method:** I read the code and documents only. I did not build, run tests or launch the app. I read the 9da8a81d diffs of
  `CaseErasure.swift`, `AppState+Erasure.swift`, `OnlineCloudProvider.swift`, `CaseReadPermission.swift`,
  `CaseReadConsentSheet.swift`, `AISetup.swift`, `AISetupViews.swift`, `CaseFileView.swift`, `LegalNotice.swift`,
  `OnlineProviderKind.swift`, `Purchase.swift`, `PurchaseGate.swift`, `OnlineViews.swift`, `CaseReader.swift`,
  `OfflineSearchResults.swift`, `docs/index.html`, `docs/for/*.html`, `docs/privacy.html`, `docs/terms.html`, `relay/*` and
  `release/*`, and re-checked the unchanged `PrivacyInfo.xcprivacy`, `APP_PRIVACY_LABEL.md` and `Kalsmritikosh.entitlements`.

**Verdict: APPROVED. No blocking finding remains.** Both earlier blockers are fixed. The fix commit introduced no new
blocking issue. Five should-fix items remain, all small text or scope changes, listed below. I recommend landing them before upload.

## Earlier blockers

| # | Status | Evidence |
|---|---|---|
| **LB1** erasing a case left its document text in "What was sent" | **Fixed** | Every send made under a case clearance now carries the case marker in `detail`: a TaskLocal `logScope` set in `send` from `sourceClearance.binding.scopeID` (`OnlineCloudProvider.swift:208-220`, `scoped` `:679-682`, applied in `recordPending` `:661` and `log` `:692`). The whole-case full copy is tagged per case (`caseTextFullTag(_:caseID:)` `:607`, `:617`), and so are the references to it (`:622`). On erase, `CaseEraser.eraseOutboundText` (`CaseErasure.swift:268-295`, called at `:211-215`) replaces `payload_text` with `[Erased with case … (erasure …, time): the text sent was removed. The time, destination, size and SHA-256 … are kept.]`. It covers marked entries and the legacy full copies their references point to. The residue check reports any surviving entry (`:232-235`). The erase screen now says so: "…the AI permission and the case text kept in “What was sent” (that record keeps only when, where, the size and a fingerprint)" (`CaseFileView.swift:529-530`). Privacy policy: "Erasing a case removes its AI permission and the text it sent from the record of what was sent" (`privacy.html:186-188`). Test: `CaseErasureTests.caseEraseRemovesOutboundText` (4 entries, other case's entries stay). No trigger or FTS mirror on `outbound_log` (`SchemaMigrations.swift:7027-7041`), so the UPDATE is the only copy. Residual issue: see LN1. |
| **LB2** Marketing URL "100% on your Mac … no uploads" | **Fixed** | `index.html:269` is now "The app itself has no network access: in Private mode everything runs on your Mac. With an AI plan or your own Anthropic key, the documents of a case you allow are sent to Anthropic…". `:315` is now "…with Online AI … a case you allow is read by Anthropic". `:467` is now "Works on your device without uploading your documents (Private mode; Online AI sends only a case you allow)". The 12 `/for/*.html` pages changed "100% on your Mac" to "On your Mac by default … then only the documents of a case you allow go to Anthropic" (e.g. `for/siu.html:60`). A grep for `100 ?%|no uploads|fully on your|entirely on your` over `docs/*.html`, `docs/for/*.html` and the listing finds no remaining privacy claim. The "no network access" claim is true: `Kalsmritikosh.entitlements` sets `com.apple.security.network.client` = false; only the helper connects. Listing line 55 is rewritten the same way. Residual wording: see LN2. |
| PB1 (practitioner) "documents don't say" from a verifier failure | **Fixed** | "Documents don't say" now appears only when the reader returns `not_stated` or no claims. When claims fail the check, the app shows "The AI's reading could not be confirmed against the documents — nothing is shown as found", plus "The documents may still answer this", the pointed passages as unconfirmed search results, `refused: false` and `answerState: .unverified` (`CaseReader.swift` diff, `unconfirmed(...)`). |

## Earlier should-fix items

| # | Status | Evidence |
|---|---|---|
| LS1 sheet does not name Anthropic / relay | **Fixed** | Permission sheet: "Where it goes: to Anthropic (Claude Opus 5) through the publisher's relay, which keeps only counts and credits, never content; recordings … go to Google (Gemini)". With an own key: "directly to Anthropic … The publisher receives nothing" (`CaseReadConsentSheet.swift:22`, `AISetupViews.swift:81-85`). It adds "Once you allow this case, your questions in it are sent without a further prompt. You can stop AI for this case at any time" (`:25`) and the retention terms (`:28-31`). |
| LS2 policy "shows these terms when it asks for your permission" | **Fixed** | The sheet has a "The AI's terms: retention and use" disclosure with `documentTerms` (`CaseReadConsentSheet.swift:28-31`). The policy now reads "when you turn AI on, on the case permission sheet, and with every previewed send" (`privacy.html` §AI). |
| LS3 permission not tied to destination | **Fixed** | `CaseReadPermission.destination` is stored at grant time. `isGranted` refuses when `p.destination != current` (`CaseReadPermission.swift:102`); live destination = `OnlineSettings.kind` (`:142`). It fails closed for older permissions without a destination (nil ≠ current), so it asks again. Test: `CandidateReviewFixesTests` "tied to its destination". The provider's own gate uses this store (`OnlineCloudProvider.swift:55-57`). |
| LS4 no per-case withdrawal | **Fixed** | A new "AI for this case" section with "Stop AI for this case" → `withdraw(caseID:)` (`CaseFileView.swift:508-527`, `CaseReadPermission.swift:116`). Erasing a case withdraws the permission (`AppState+Erasure.swift:87`; skipped under the test host by design). Stated in the policy (`privacy.html:103-104, :186-188`). |
| LS5 policy overstated per-send previews | **Fixed** | "a send carrying document passages each time, and a question alone each time unless you turned off “Ask before every send” and chose “Send and don't ask again this session”" (`privacy.html:104-106`). |
| LS6 provider retention | **Partly (owner step)** | Google's paid-API abuse-monitoring retention is now stated in the policy and in the `.included` terms (`OnlineProviderKind.swift:413`). The Anthropic figure is "within 30 days by default". This stays correct as an upper bound if Anthropic's current default is shorter. The owner should still confirm it on the day of submission. |
| LS7 stale wording | **Fixed** | The relay now "keeps only counts and credits" (`OnlineProviderKind.swift:413`). In-app liability cap: "the amount you paid for the app, its subscriptions and credit packs" (`LegalNotice.swift:136`), matching terms §7. The `Use AI to write answers` caption names AI plans, own key and once-per-case (`SettingsView.swift:1488`). Terms version 1.11. |
| LS8 capacity cap + var/secret clash | **Fixed** | Checklist §12: "Global spend cap — before you press Release … Then release" (`OWNER_LAUNCH_CHECKLIST.md:159-167`). `GLOBAL_CAP_USD` is only in `[vars]` (`relay/wrangler.toml:24`), and the README and checklist say not to create a secret with that name. |
| LS9 / UB1 review notes miss setup steps (2.1) | **Fixed** | A one-step `AISetupSheet` appears after a verified AI purchase or restore (`Purchase.swift` `offerAISetup`), after saving a key (`OnlineViews.swift`), or from "Turn on AI…". It shows the terms, the destination, the attestation ("By allowing, you confirm: …"), the accuracy notice and what it turns on. Nothing is sent until each case asks (`AISetup.swift:13-14`, `AISetupViews.swift`). Offline results name the missing step (`OfflineSearchResults.present(reason:)`). Review notes steps 3 and 6 describe the sheet (`APP_STORE_LISTING.md:137-160`). The checklist asks for a Sandbox account in an AI-allowed storefront. |
| LS10 candidate packet out of date | **Not fixed** | `docs/RELEASE_CANDIDATE.md:24` still says `Candidate: c30d2191…`, and `:14` says the fixes are "uncommitted … updated by the owner's session once committed". This is not a legal blocker, but the packet must name the uploaded commit. |

## New issues (introduced or left by 9da8a81d)

| # | Severity | Finding | Evidence |
|---|---|---|---|
| LN1 | should-fix | **Question-only sends made while asking in a case are not erased with the case.** The case marker comes only from `sourceClearance.binding`, and question-only sends (`generateQuestionOnly`: the cloud question interpreter and rewriter) carry no clearance. Their `payload_text` (the typed question, which can name the subject of an erasure request) therefore survives `eraseOutboundText`. The `CaseErasure.swift` header claims "passages and questions of sends cleared for the case", and the policy says erasure removes "the text it sent". The fix: set `OnlineCloudProvider.$logScope` around the interpreter/rewriter calls when the question is asked in a case (the case ID is known to the answer service). Otherwise, narrow the erase-screen and policy wording to "the case's document text and the AI readings of it". | `OnlineCloudProvider.swift:153-155, :215-220`; `AppState+CaseReading.swift` `installCloudReaders` (cloud interpreter/rewriter closures); `CaseErasure.swift:15-18`; `privacy.html:186-188` |
| LN2 | should-fix | **"— nothing else" on the Marketing URL is an absolute again.** The card says "the documents of a case you allow are sent to Anthropic (and recordings you transcribe to Google) — nothing else". The privacy policy itself says that in Online mode, GLEIF and CourtListener searches "send the name you search to that service" and the ECB receives currency and date (`privacy.html:128-131`). Questions, and passages outside a case after a per-send preview, also go. Replace it with, for example, "— plus the Online lookups you run, as listed in the privacy policy". Same kind: the meta description still says "One plain plan" (three plans now). The "On-device AI — nothing to download" card says "answers all run locally". | `docs/index.html:269, :7, :452`; `docs/for/*.html:60` ("only the documents of a case you allow go to Anthropic") |
| LN3 | should-fix | **The one-step setup silently overrides "Fully private — no AI".** `ensureRegimeAllowsAI` switches the AI posture to `.gated` when it is `fullyPrivate` (`AISetup.swift:187`). The sheet's list of what it changes leaves this out and says "Nothing else changes" (`AISetupViews.swift:79`). The person clicked an explicit "Allow…" button, so this is not a consent defect, but the sheet should name the posture change. The `.gated` summary ("nothing leaves your Mac", `FeatureFlags.swift` `AIRegime.summary`) is also wrong once Online AI is on. | as cited |
| LN4 | should-fix (low) | **Erasing one case can erase another case's full copy.** For legacy full copies, `eraseOutboundText` matches `caseTextFullTag(d)` = "case text <d> (full copy)" with `instr`. That string is also a prefix of every per-case tag "… (full copy) · case <other>". A second case that sent byte-identical case text (same documents, same masking) therefore loses its full copy, and its later references point to an erased entry. This errs on the privacy side but costs that case its audit text. Restrict the digest match to entries whose `detail` has no " · case " suffix. | `CaseErasure.swift:281-287`; `OnlineCloudProvider.swift:605-607` |
| LN5 | fine (note) | The `.included` `documentTerms` text changed (Google retention, credits) while `documentTermsVersion` stays "2026-10-27" (`OnlineProviderKind.swift:395`), so earlier acceptances are not asked again. There are no released users, so this has no effect now. Bump the version on the next material change after release. | |
| LN6 | fine (note) | The fallback in `readCase.record` (`CaseLogRecord(payload: shownText, …, tag: nil)` when the log lookup throws) writes an entry without the case marker. It only happens when the log itself is failing (and then the send is refused, `:557-561`). Tagging it would close the gap fully. | `OnlineCloudProvider.swift:497-502` |

## Re-checked and fine

- **5.1.1 / 5.1.2(i):** Two explicit steps are needed before any document leaves. First the setup sheet: recipient,
  relay, terms, attestation and accuracy notice, sending nothing. Then the per-case sheet: document list, what is withheld,
  estimate, recipient, terms, the "questions without a further prompt" rule, and withdrawal. Withdrawal works per case, by
  erasure and globally (Private mode). The permission is re-asked when the destination or the documents change.
- **3.1.1:** credit packs are consumables that never expire, usable while an AI plan is active (stated). Nothing is unlocked
  outside IAP. Restore remains, and a restore of an AI plan offers the same setup sheet. AI plans are not offered in the 13 blocked
  storefronts or on macOS < 26 (`PlanOffer` `sellsAI: … && AISetup.onlineAIRunsOnThisMac`), where they could not work.
- **3.1.2:** the paywall shows each plan's own monthly allowance (`o.plan.monthlyCredits`: AI Pro yearly 5,400, monthly 6,000).
  The `.storekit` description, IAP sheet, listing, terms, LegalNotice, Settings and relay (`monthlyAllowance`,
  `yearlyMonthlyCredits`, `status_cache.yearly`) all say the same. The trial is described as Workbench-only ("no AI credits")
  in the listing. Auto-renew, cancel, Restore, Manage, Terms and Privacy are unchanged.
- **2.3:** no accuracy figure on any public page. "Won't guess" is replaced by behaviour-only wording ("statements that
  cannot be matched are left out. Answers can still be incomplete or wrong — check the cited source").
- **Label = manifest = policy:** unchanged since 7d720fe1 and still consistent. The relay schema still has no content column (only the
  `yearly` flag was added). 18+, the LAEULA supplement, the no-accuracy-guarantee clause and refunds through Apple are unchanged in the terms.

## Conditions

None blocking. Before upload: fix LN1–LN3 (text or scope, about one line each) and LS10 (bind the packet to the commit being uploaded),
and confirm Anthropic's retention figure (LS6). If any later commit changes sending, consent, erasure or public privacy text,
this review must be re-run on that commit.
