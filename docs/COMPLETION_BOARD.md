# Completion board — autonomous completion mandate 2026-11-01

Governing file: `Investigations_Made_Easy_Autonomous_Completion_Instructions_2026-11-01.md` (outside the repo).
Baseline reviewed by the mandate: `37baf589`. Release status: **BLOCKED** until every gate below has evidence.
Resume from this table. A row is "done" only with a commit and a check that ran; "blocked" names the exact dependency.

| ID | Task | Depends on | Owner | Status | Commit | Check / evidence | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CI-0 | Current CI on the candidate (build-and-test failed on 6fccbd29 and 547ff645) | — | agent | open | — | run 41264235747 | read the failure, fix, re-run |
| N1 | Release checker false passes (NOT APPROVED, bad/empty manifest, unknown kind, mktemp failure) | — | agent | open | — | — | rewrite checker + negative fixtures in CI |
| N2 | Entitlement expiry enforced at the moment of use; deadline timer; injected clock | — | agent | open | — | — | — |
| N3 | Cached entitlement not an authority; test bypass unreachable in Release | N2 | agent | open | — | — | — |
| N4 | Paid-action boundary complete (Work Center, DataLab, sample exemption) | N2 | agent | open | — | — | — |
| N5 | Handoff uses the persisted row; reports print every citation | — | agent | open | — | — | — |
| N6 | Output packages revalidated at release | — | agent | open | — | — | — |
| N7 | Unreadable protection data blocks send/export; corrupt result rows surfaced | — | agent | open | — | — | — |
| N8 | OCR: test VNRequest.cancel, per-request failure attribution, page-level outcomes | — | agent | open | — | — | — |
| UI-K | Run k (UI automation repair + journeys) | N2–N8 | agent | open | — | — | diagnose host-callback timeouts |
| J-168 | 168 jobs / nine persona journeys on current code | UI-K | agent | open | — | — | — |
| ACC | Scorer review on consumed data, freeze, fresh set, adjudication packs | N1–N8 | agent → adjudicators | open | — | — | — |
| STUDY | Five-user + practitioner study materials | UI-K | agent → participants | open | — | — | — |
| BUY | StoreKit / Sandbox / TestFlight purchase matrix | N2–N4, ARCH | agent | open | — | — | — |
| SEC | Encryption, backup/restore, erasure, workload | — | agent | open | — | — | — |
| ARCH | Release archive, validation, upload, TestFlight acceptance | all engineering | agent | open | — | — | — |
| LEGAL | Decision sheet, listing, privacy label, review notes | ARCH | agent → owner | open | — | — | — |
| SUBMIT | App Review submission | everything | owner | open | — | — | — |
