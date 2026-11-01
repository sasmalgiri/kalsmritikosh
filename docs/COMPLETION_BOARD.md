# Completion board — autonomous completion mandate 2026-11-01

Governing file: `Investigations_Made_Easy_Autonomous_Completion_Instructions_2026-11-01.md` (outside the repo).
Baseline reviewed by the mandate: `37baf589`. Release status: **BLOCKED** until every gate below has evidence.
Resume from this table. A row is "done" only with a commit and a check that ran; "blocked" names the exact dependency.

| ID | Task | Depends on | Owner | Status | Commit | Check / evidence | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CI-0 | Current CI on the candidate (build-and-test failed on 6fccbd29 and 547ff645) | — | agent | open | — | run 41264235747 | read the failure, fix, re-run |
| N1 | Release checker false passes (NOT APPROVED, bad/empty manifest, unknown kind, mktemp failure) | — | agent | done | 718b1ccc | 15 fixtures, guard release-check-selftest | re-run on CI (macOS) |
| N2 | Entitlement expiry enforced at the moment of use; deadline timer; injected clock | — | agent | done (unit) | see N3 row | EntitlementBoundaryTests, PurchaseStoreKitTests | Sandbox/TestFlight under BUY |
| N3 | Cached entitlement not an authority; test bypass unreachable in Release | N2 | agent | done (unit + guard) | (N2–N4 commit) | cacheTrust, test-host-boundary guard | Release launch with test env var (ARCH) |
| N4 | Paid-action boundary complete (Work Center, DataLab, sample exemption) | N2 | agent | done (service + unit) | (N2–N4 commit) | serviceBoundary + 85 suites | UI check under UI-K; remaining minor surfaces (tags, collections, highlights, PDF marks, notes, screening) still UI-only ungated — listed |
| N5 | Handoff uses the persisted row; reports print every citation | — | agent | done (unit) | 41224c66 | JobResultHandoff, CaseFile citations | — |
| N6 | Output packages revalidated at release | — | agent | done (unit) | 41224c66 | CaseOutputService.release | — |
| N7 | Unreadable protection data blocks send/export; corrupt result rows surfaced | — | agent | done (unit) | 41224c66 | protectionUnreadable, strict JobResult rows | — |
| N8 | OCR: test VNRequest.cancel, per-request failure attribution, page-level outcomes | — | agent | done (unit; mid-request cancel unmeasurable — page reads in 63 ms) | 443bb0fa | VisionPerform tally | — |
| A1 | AI Included relay (Cloudflare Worker): Apple-verified subscribers, 300/month + top-ups, hard caps $20 Anthropic / $5 Gemini, counts only | — | agent | done (10 node tests) | e7368c8f | relay/test | owner deploys (relay/README.md) |
| A2 | AI Included in the app: plans, top-up, relay provider, paywall, Settings | A1 | agent | done (unit + StoreKit 41/42; grace test fails identically on baseline — environment) | 52ef33ce | AIIncludedTests, PurchaseTests, PurchaseStoreKitTests | relay host set after deploy |
| A3 | Per-country AI switch (StoreKit Storefront; China mainland off) | A2 | agent | done (unit) | (A3 commit) | AIIncludedTests/regionSwitch, relay grantsAI | other countries: provider supported-region list to re-check at release |
| A4 | Read with AI: scans the Mac could not read, page images to the Online AI, transcription added as a marked document citing the original | A2 | agent | done (unit + provider path) | (A4 commit) | ScanRescueTests | live read on a real scan with AI Included after deploy |
| A5–A7 | Translate into English (marked document); Challenge this answer (a review, never a finding); Draft a report paragraph — from cleared passages only, citations checked | A2 | agent | done (unit) | (A5–A7 commit) | AIAssistTests | live run with AI Included after deploy |
| A8–A11 | ECB exchange rate at a date; OFAC + UN sanctions lists matched on the Mac; GLEIF registry; CourtListener; web capture with record; recording transcription with speakers | A2 | agent | done (unit + client path) | (A8–A11 commit) | OnlineToolsTests | live lookups against the real sources at release (network) |
| A12 | Privacy label, terms, policy, Help for the online features | A4–A11 | agent | done (agent review; claims + help tests) | (A12 commit) | check-claims, HelpRegistryTests 10/10 | publisher legal name to match App Store Connect (docs say "Eco Sanskriti Innovation") |
| UI-K | Run k (UI automation repair + journeys) | N2–N8 | agent | open | — | — | diagnose host-callback timeouts |
| J-168 | 168 jobs / nine persona journeys on current code | UI-K | agent | open | — | — | — |
| ACC | Scorer review on consumed data, freeze, fresh set, adjudication packs | N1–N8 | agent → adjudicators | open | — | — | — |
| STUDY | Five-user + practitioner study materials | UI-K | agent → participants | open | — | — | — |
| BUY | StoreKit / Sandbox / TestFlight purchase matrix | N2–N4, ARCH | agent | open | — | — | — |
| SEC | Encryption, backup/restore, erasure, workload | — | agent | open | — | — | — |
| ARCH | Release archive, validation, upload, TestFlight acceptance | all engineering | agent | open | — | — | — |
| LEGAL | Decision sheet, listing, privacy label, review notes | ARCH | agent → owner | open | — | — | — |
| SUBMIT | App Review submission | everything | owner | open | — | — | — |
