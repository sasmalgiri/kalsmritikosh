# Gate `user-evaluation` — AGENT review record (not a user study)

Decision: NOT APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT user-evaluation reviewer
Date: 2026-11-04
Commit: 7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0
Evidence: docs/agent-reviews/candidate-review-7d720fe1-user-evaluation.md (code and help-registry reading; no users, no GUI session)
Notes: No users took part. Blocking finding:
- UB1 — after buying AI Included or AI Pro, the AI never answers unless the person also turns on "Use AI to write answers" (Settings ▸ Modules, off by default) and ticks the document-terms attestation (Settings ▸ Online). Help, listing and App Review notes omit both. Ask then shows only "No AI is set up", with no pointer (EvidenceOnlyRelease.swift:20-31; AppState+CaseReading.swift:35-44; OnlineCloudProvider.swift:145-149; OfflineSearchResults.swift:44; APP_STORE_LISTING.md:72, :137-149). Also a Guideline 2.1 risk.
- Should-fix (price/credit text): one message for six causes of "no AI"; worst-case reservation shown as "needs about N credits"; "a typical question uses a few credits"; "while it stays open" (1-hour cache); help says every send is previewed; "every paid feature free for 14 days" (Workbench only); site "One plain plan" / "No processing fees, ever"; site's macOS 26 requirement for AI answers; owner economics — AI Pro yearly priced below its worst-case AI cost at 30 % commission and in VAT storefronts.
- Checked and fine: StoreKit prices only, trial shown only to eligible accounts, Restore/Manage/Terms/Privacy, credit meter, local refusal before sending with Buy credits/Upgrade, capacity pause wording, blocked-storefront explanations, lapsed-plan read-only access.
