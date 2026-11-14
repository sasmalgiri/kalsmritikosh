# AGENT REVIEW — legal / privacy (not counsel; owner decision 2026-11-01)

- **Reviewer:** Claude agent acting as the legal/privacy reviewer, by the owner's decision of 2026-11-01 that agents
  replace human review gates for v1. This is not legal advice and not a lawyer's sign-off.
- **Date:** 2026-11-04
- **Candidate:** `7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0` (`investigations-next`). Line numbers are at this commit.
- **Baseline:** `legal-privacy.md` (81cf335f), `candidate-re-review-f766b035.md`, and product changes `0c5ec1c3..7d720fe1`
  (plans and credits, relay metering, the whole-case reader, consent once per case, offline search results, case
  analysis on the whole case, the accepted release decisions).
- **Method:** I read the code and the documents only. I did not build, run tests or launch the app. I checked what is
  sent, when, and under which consent in `OnlineCloudProvider.swift`, `CaseWholeReading.swift`, `AppState+CaseReading.swift`,
  `CaseReadPermission.swift`, `CaseReadConsentSheet.swift`, `OnlineViews.swift`, `relay/src`, `relay/schema.sql` and
  `relay/wrangler.toml`. I compared them with `docs/privacy.html`, `docs/terms.html`, `Core/LegalNotice.swift`,
  `PrivacyInfo.xcprivacy`, `release/APP_PRIVACY_LABEL.md`, `release/APP_STORE_LISTING.md`, `release/IAP_SETUP.md`,
  `release/OWNER_LAUNCH_CHECKLIST.md`, `StoreKit/Kalsmritikosh.storekit` and the public site (`docs/index.html`,
  `docs/for/*.html`, `docs/support.html`).

**Verdict: NOT APPROVED. There are two blocking findings.**

## Blocking

| # | Finding | Evidence |
|---|---|---|
| **LB1** | **Erasing a case leaves a full copy of its document text on the Mac.** Plan A writes the whole masked, defanged case text into `outbound_log.payload_text` once for each document set (`caseLogRecord`). Case erasure deletes only tables that carry `case_id`, and `outbound_log` has no `case_id`. The table is also declared "Append-only; nothing here is ever deleted". The erase screen still promises "Removes everything recorded for this case — its work, notes, results and history". With "Also erase the documents only this case uses" on, the documents are removed but their text survives in "What was sent". For an investigation tool this breaks a deliberate erasure: a data-subject request, or the end of a retention period. Before plan A only passages were logged; now a whole case is. The fix keeps the audit value: on case erase, replace `payload_text` in the entries tagged with that case or its document set by an erasure marker, and keep the SHA-256, size, time and destination. Then say so on the erase screen. | `Routing/Providers/Online/OnlineCloudProvider.swift:532-536, :591-605` (full copy recorded; later entries reference it by `case <uuid>`); `Storage/Schema/SchemaMigrations.swift:7025-7041` (no `case_id`, "nothing here is ever deleted"); `Personas/Investigator/CaseErasure.swift:163-166, 202`; `UI/CaseFileView.swift:507` |
| **LB2** | **The public site still says "no uploads" without qualification, against the policy and the paid product.** The flagship paid feature now sends whole cases to Anthropic, yet the Marketing URL entered in App Store Connect says: "Private by design — Runs 100% on your Mac using Apple's on-device model. No account, no uploads, no analytics." and "Runs 100% on your Mac — no accounts, no uploads". Its comparison table answers "Runs fully on your device" with a flat Yes. The privacy policy and label say the opposite for AI plans and own-key use. The 2026-11-01 review classed this kind of contradiction as a BLOCKER (B1, under 5.1.1(i) / 2.3.1 and consumer law). These lines were missed when the other instances were qualified. Qualify each one the way `docs/for/*.html:60` already does ("Nothing is uploaded unless you choose Online mode"). | `docs/index.html:269, :315, :467` |

## Should-fix

| # | Finding | Evidence |
|---|---|---|
| LS1 | **The permission sheet on an AI plan does not name Anthropic or the relay.** The sheet reads "its documents below are sent to AI Included or AI Pro (Claude Opus 5)". The recipient company (Anthropic), the publisher's relay and the retention terms appear only in Settings ▸ Online, beside the attestation the person must tick before any document is sent. Together the two screens meet 5.1.2(i): the attestation names Anthropic, Google, the relay and the 30-day retention, and the sheet asks for explicit permission per case. But the sheet is the permission screen, and the review notes tell App Review it shows "exactly which documents go to Anthropic". Say on the sheet "to Anthropic (Claude Opus 5) through the publisher's relay" (own key: "directly to Anthropic"). Add "your questions in this case are then sent without a further prompt" and one line on retention. | `UI/CaseReadConsentSheet.swift:17-19`; `Routing/Providers/Online/OnlineProviderKind.swift:52, :413, :420-428`; `release/APP_STORE_LISTING.md:145-149` |
| LS2 | **The policy says "The app shows these terms when it asks for your permission."** The once-per-case sheet shows no provider terms; only the per-send preview and Settings do. Either add the terms line to the sheet (LS1) or reword the policy. | `docs/privacy.html:100`; `UI/CaseReadConsentSheet.swift` |
| LS3 | **A case permission is not tied to the destination.** `CaseReadPermission` stores only case, fingerprint, time and count. A case allowed with the person's own key (directly to Anthropic) stays allowed after switching to an AI plan (through the publisher's relay and account), and the other way round, without a new sheet. Add the provider kind to the fingerprint, or re-ask when it changes. | `Core/Security/CaseReadPermission.swift:21-41`; `Personas/Investigator/CaseWholeReading.swift:133-148` |
| LS4 | **A case permission cannot be withdrawn on its own.** `CaseReadPermissionStore.revoke` is never called from product code, and the re-ask period (`reaskAfterDaysKey`) has no UI. The comment "erasing a case also revokes it" is not implemented. Withdrawal is possible only globally (Private mode, or switching provider off). Add "Stop AI for this case" in the case file and call `revoke` on case erase. | `Core/Security/CaseReadPermission.swift:76-127` (grep shows no caller of `revoke(caseID:)`) |
| LS5 | **The policy overstates per-send previews outside a case.** It says "elsewhere, the passages and your question each time". But a question-only send (no document text) can be allowed for the session ("Send and don't ask again this session" when "Ask before every send" is off). The sends that carry documents are always previewed (correct). Reword to "documents each time; a question alone, each time unless you choose 'don't ask again this session'". | `docs/privacy.html:103`; `App/Online/OnlineCenter.swift:174`; `UI/OnlineViews.swift:56-57` |
| LS6 | **Provider retention statements need re-checking at submission.** The policy states Anthropic's commercial-API default as "within 30 days". Confirm the current figure on Anthropic's site on the day of submission. Google's paid-API retention (abuse-monitoring logs kept for a limited period) is not stated at all, only "neither uses them for training". Add Google's retention in the policy and in the `.included` terms text. | `docs/privacy.html:98-100, :115`; `OnlineProviderKind.swift:413` |
| LS7 | **Stale wording.** `.included` documentTerms says "The relay keeps only counts (questions used, money spent)"; it now keeps credits. The in-app `liabilityStatement` caps liability at "the amount you paid for the app", while terms §7 caps it at "the App and its subscriptions and credit packs". The `Use AI to write answers` caption says "your own cloud AI key under Online mode (you approve every send)", which leaves out the AI plans and the once-per-case permission. | `OnlineProviderKind.swift:413`; `Core/LegalNotice.swift:136`; `docs/terms.html` §7; `UI/SettingsView.swift:1488` |
| LS8 | **The service capacity can lock out paying subscribers on day one.** With `GLOBAL_CAP_USD=20`, one AI Included subscriber (2,000 credits = US$20) or a third of one AI Pro month can reach the cap. The relay then pauses every AI plan until the 1st while subscription fees keep being charged. Terms and paywall disclose the pause, but the checklist raises the cap only *after* releasing (§12). Make "raise `GLOBAL_CAP_USD` and the console limit" a step **before** "Release this version". `GLOBAL_CAP_USD` is also set in `[vars]` in `wrangler.toml` *and* by `wrangler secret put` in the checklist. Cloudflare does not allow a var and a secret with the same binding name, so remove it from `[vars]` or use `vars` only. | `release/OWNER_LAUNCH_CHECKLIST.md:75, :151-160`; `relay/wrangler.toml:24`; `docs/terms.html` §2 (capacity clause) |
| LS9 | **The review notes leave out two steps needed to reach the permission sheet:** turning on "Use AI to write answers" and ticking the document-terms attestation (see user-evaluation UB1). If the reviewer follows the notes, Ask returns search results and no sheet appears. That is a Guideline 2.1 rejection risk for the AI IAPs. | `release/APP_STORE_LISTING.md:137-149`; `App/AppState+CaseReading.swift:41-42`; `Routing/EvidenceOnlyRelease.swift:20-31` |
| LS10 | **The candidate packet is out of date.** `docs/RELEASE_CANDIDATE.md` names `c30d2191`, but `7d720fe1` changed product code (36 files: AIRegion, own key = Anthropic only, the paywall, the network helper). Bind the packet and the simulation record to the commit that will be uploaded. | `docs/RELEASE_CANDIDATE.md:10`; `git show --stat 7d720fe1` |

## Fine (checked)

- **What is sent and when matches the policy.** No document text leaves without a stored per-case permission
  (`readCase` recomputes the fingerprint at the send, `OnlineCloudProvider.swift:447-451`) or a per-send preview
  (`:284-312`; "not switchable"). Privileged and restricted documents are withheld by `CloudSourceGate` and listed as
  "Not sent" with the reason (`CaseWholeReading.swift:116-119`, sheet `:36-41`). Protected identities are masked or stop the
  send (`:246, :490`). Every document is re-cleared at the send (`:323, :524`). There is no send without a record (`:347-348, :532-536`).
  Own-key document sends require the commercial-terms attestation (`OnlineProviderKind.swift:430-444`).
- **Relay keeps counts only.** `relay/schema.sql` has spend, allowance, daily, topups and status_cache only, with no content
  column. There is no `console.*` logging in `relay/src` and `[observability] enabled = false`. The retention purge
  (`store.ts:238-243`) matches the policy (13 months, 40 days, packs while credits remain + 25 months).
- **Label = manifest = policy.** The seven types are identical in `PrivacyInfo.xcprivacy` and `APP_PRIVACY_LABEL.md`. Content
  is not linked; User ID, Purchase History and Product Interaction are linked; no Diagnostics; no tracking. The network
  helper allow-list is `api.anthropic.com` + relay + five lookup hosts (`KalsmritikoshNetworkHelper.swift:19-25`), as the
  policy and review notes say.
- **Blocked storefronts:** the 13 countries are the same in `AIRegion.swift`, the policy, terms, listing, IAP sheet and
  checklist. In those storefronts the AI plans, the packs and the own-key option are hidden or refused in the app
  (`Purchase.swift:456-461, :778, :800-806`; `OnlineViews.swift:172-178`).
- **3.1.2:** the paywall shows each plan's title, period and StoreKit price. It shows the trial only to eligible accounts
  ("14-day free trial, then this price"), the auto-renew/cancel line, and what each plan includes. It has Restore, Manage
  subscription, Terms and Privacy (`PurchaseGate.swift:136-156, :200-240`; `Purchase.swift:102-116, :434-447`). The listing
  states prices, periods, credits, auto-renew and the EULA link. Upgrades take effect at once and downgrades at renewal,
  as Apple does.
- **3.1.1:** credit packs are consumables and never expire. Their being usable only while an AI plan is active is stated on
  the paywall, in Settings, the terms, the listing and the IAP descriptions. A pack can be bought only with an active AI
  plan (`Purchase.swift:808-811`). Refunded packs lose their remaining credits (stated). No unlocking happens outside IAP;
  the own key is the person's own third-party account.
- **Terms:** they supplement Apple's LAEULA with its minimum terms (§5), 18+, no accuracy guarantee (§3: "There is no
  guarantee of accuracy … every conclusion is the investigator's"), a liability cap, provider usage-policy flow-down,
  governing law with a consumer carve-out, and refunds through Apple.
- **No accuracy figure** appears on any public page. The FAQ and support page say accuracy has not been measured on this
  version (`docs/index.html:485`, `docs/support.html:81`). The qualitative claims ("won't guess") are dealt with in the
  accuracy record.

## Conditions to re-review

Fix LB1 and LB2 on a new commit, then re-run this review on that commit. LS1, LS3, LS8 and LS9 should land in the same commit
because they touch the submission directly.
