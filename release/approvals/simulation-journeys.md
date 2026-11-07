# Evidence — simulated end-to-end journeys per plan (gate `simulation-journeys`)

Candidate: 93a3870ddd0a6020559b038af4baf9560b51a294
Re-run on the candidate: agent (Claude), 2026-11-07 15:21 IST, Xcode MCP `RunSomeTests` on the Debug test host, committed tree at
93a3870d, no network. `PurchaseStoreKitTests` 16/16 passed, including all five `PlanJourneySimulationTests` (workbenchJourney,
aiIncludedJourney, aiProJourney, proLimitMatchesRelaySizeLimit, offlineJourney). The 2026-11-04 record below is kept as history.
Run by: agent (Claude), 2026-11-04, Xcode MCP `RunSomeTests` on the Debug test host (this Mac), no network.
Suite: `KalsmritikoshTests/PlanJourneySimulationTests.swift` (new, test code only), nested in `PurchaseStoreKitTests` so it is
serialised with the other StoreKit sessions (it therefore inherits that suite's "disabled on hosted CI" trait).

## What is real and what is simulated

Real: the StoreKit purchase (SKTestSession with `StoreKit/Kalsmritikosh.storekit`) → entitlement → credit meter → per-case
consent and the stored permission (fingerprint) → the whole-case answer service → the real Online provider's case read →
the answer verifier. Simulated: the network (a fake Anthropic API with prompt caching and usage, and a fake relay mirroring
`relay/src/index.ts` + `policy.ts` — reservation, ceilings, daily limit, allowance before packs, rounding up, refunds, receipt,
refusal codes); the consent sheet's answer; crediting a pack (no relay host in this build); choosing the whole-case limit from
the plan (no product code does this — see limits); the own-key tally recorded into a fixed past month.

## Results (as reported by the tool)

| Test | Result |
|---|---|
| `workbenchJourney` — 14-day trial; no AI tier/no relay id; own key: sheet once (dollars), direct to Anthropic, verified; cached 2nd question, own-key tally matches usage; new document re-asks; "Not now" sends nothing → search results | pass |
| `aiIncludedJourney` — purchase → 2,000 credits; sheet once (credits); confirmed large read; charge = actual rounded up ≤ reserve; receipt drives the meter; new document re-asks; allowance out → `credits-used` 402, nothing forwarded, nothing truncated; 500-credit pack bought with the subscription's appAccountToken, credited once; allowance then pack; `credits-used` again; `daily-limit` 429 | pass |
| `aiProJourney` — purchase → 6,000 credits, 3,000-credit read ceiling; ~600k-token case falls back under AI Included's limit, read whole under Pro's; same read to an AI Included relay → `too-costly` 413; ~820k tokens falls back ("the limit is 800,000") | pass |
| `offlineJourney` — nothing bought, no key, Online off: "Search results for …", no sheet, no send; direct case read refused | pass |
| `proLimitMatchesRelaySizeLimit` | expected failure (`withKnownIssue`) at the time — limit 3 below; **pass with no known-issue marker after the fix (see the update below)** |

New suite alone: 5 tests — 4 passed, 1 expected failure. With the neighbours in one run: 56 tests — 54 passed, 1 failed,
1 expected failure: CaseWholeReadingTests 14/14, AICreditsTests 8/8, AIIncludedTests 7/7, PurchaseTests 11/11,
PurchaseStoreKitTests 10/11 own tests. The failure (known StoreKit-environment failure on this Mac, also on the old .storekit):

`PurchaseStoreKitTests.swift:184 PurchaseStoreKitTests/billingRetryWithGraceKeepsAccessUntilGraceEnds(): Issue recorded: expected grace, got .subscribed(expiresAt: 2026-11-04 03:48:28 +0000, plan: Kalsmritikosh.SubscriptionPlan.monthly, willRenew: true)`

Relay: `npm test` inside `ci/guards/relay-host-match.sh` — pass 17, fail 0 (2026-11-04, this Mac).

## Update 2026-11-04 — the four limits fixed (working tree, uncommitted)

All four limits below are fixed in product code (see docs/RELEASE_CANDIDATE.md, known limits 1–4). Re-run by agent (Claude),
Xcode MCP `RunSomeTests`, Debug test host, no network: `PurchaseStoreKitTests` (with the nested `PlanJourneySimulationTests`)
+ `CaseReadBudgetTests` — 25 tests, 25 passed, 0 failed, 0 expected failures (the journey's plan → limit now calls the product's
`CaseReadLimits.limit`; it is no longer a simulated seam). Relay `npm test`: pass 19, fail 0. The candidate line above still
needs binding to a commit.

## Product limits the journeys found (fixed 2026-11-04 — kept for the record)

1. AI Pro never gets its larger whole-case read: `CaseReadLimits.current()` (`App/Online/CaseReadConsent.swift`) reads
   `kalsmritikosh.caseRead.planLimit`, which nothing writes, so AI Pro reads use the 300k default, not 800k. The listing's
   "larger whole-case reads" is therefore not delivered by this build.
2. The own-key monthly dollar limit is checked in `OnlineCloudProvider.generate` but not in `readCase`.
3. Near the AI Pro limit the app counts only case text (≈2.8M bytes) while the relay's large-read cap of 2,800,000 characters
   also counts the question: a case just under the app's limit is refused `too-large` by the relay.
4. `AICreditMeter.refusal(credits:largeRead:)` / `caseReadPrompt(credits:)` are used only by tests; the app relies on the relay
   to refuse (it does, and no document text reaches Claude when it refuses).
