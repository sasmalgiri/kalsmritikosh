# Release candidate — Investigations Made Easy v1 (candidate packet, not a release)

One current section, then the historical candidates. A product-code change after a packet makes a new candidate (§5).
Unsigned digests identify compiled code and are supporting evidence only; the submitted artifact is the signed, uploaded
build, whose identifiers the *owner* records in `release/approvals/distribution-archive.md`. Release status is the output of
`bash scripts/release-check.sh` — currently **BLOCKED**.

## Current candidate (2026-11-04, plans and credits + whole-case reader) — simulation-tested only

Candidate: c30d21916fbc030ea5b16dc33045273d0587c96e

| Field | Value |
|---|---|
| Branch / PR | `investigations-next`, PR #169 (open) |
| Code commits since the 2026-10-31 packet | … `67ba9bfb` (plans, AI credits, relay metering) · `7bb6323b` (whole-case reader, consent once per case, offline search results) · `b66cf7a9` (case analysis on the whole case, outbound log keeps the case text once, no second preview) · `70897448` (release package) · `c30d2191` (AI Pro limit from the plan, one size estimator, own-key limit on case reads, local credit pre-check, no public accuracy figures) |
| Working tree at packet time | clean apart from Xcode user metadata (`xcschememanagement.plist`) and Xcode-extracted `InfoPlist.xcstrings` entries — no product code uncommitted |
| Schema | **v169** (`SchemaMigrations.latestVersion`; `MigrationMatrixTests` pin; `scripts/release-check-schema-pin.sh` PASS) |
| Testing mode | **Simulation only** (owner decision 2026-11-04: no paid live testing). StoreKit in-process (SKTestSession), fake relay mirroring `relay/src`, fake Anthropic API, no-network replay reader. The owner funds US$20 on the relay's Anthropic key for App Review only |
| Hosted CI | **not run** on `67ba9bfb` … `c30d2191` (Actions budget; last green head `4147e106`) |
| Unsigned Release digests | not built for this tree |
| Signed Distribution build | none — *owner* (`release/OWNER_LAUNCH_CHECKLIST.md` §8) |
| Relay | not deployed; `AIIncludedRelay.host` empty → gate `relay-host-configured` FAIL until the owner deploys (§5–§6 of the checklist) |
| Release package | `release/APP_STORE_LISTING.md`, `release/APP_PRIVACY_LABEL.md`, `release/IAP_SETUP.md`, `release/OWNER_LAUNCH_CHECKLIST.md`; policy and terms `docs/privacy.html`, `docs/terms.html` (4 November 2026; notices version 1.9) |

### Simulation evidence on this tree (agent run, 2026-11-04, this Mac — not hosted CI)

| Suite | Result | What it covers |
|---|---|---|
| `PlanJourneySimulationTests` (new) | pass (the AI Pro size-limit known issue fixed in `c30d2191`) | one end-to-end journey per plan: Workbench trial → own-key case read; AI Included purchase → consent once per case → metered whole-case read → allowance out → pack → refusal codes; AI Pro large case; offline search results. Details `release/approvals/simulation-journeys.md` |
| `CaseWholeReadingTests` | 14/14 | one call per question, cached prefix, verifier, too-large fallback, consent once per document set, privileged excluded, offline search, masking, replay simulation |
| `AICreditsTests` / `AIIncludedTests` / `PurchaseTests` | 8/8 · 7/7 · 11/11 | credit meter, relay request shapes, region switch, entitlement states |
| `PurchaseStoreKitTests` (own tests) + `CaseReadBudgetTests` | 25/25 on `c30d2191` | `billingRetryWithGraceKeepsAccessUntilGraceEnds` passed this run; it has failed intermittently on this Mac (StoreKit environment, also with the old .storekit) |
| Relay `npm test` | 19/19 | reservation, refunds, ceilings, daily limit, packs, global cap and the 90 % stop, retention, nothing stored |
| Guards / claims / schema pin / debug args | PASS | `bash scripts/release-check.sh` |

The commit messages of `67ba9bfb` and `7bb6323b` record wider agent runs (104/104; 250/252 with 2 explained; 188/189 — one
sandbox CSV-write test); those were not re-run for this packet.

### Accuracy — the bar was NOT measured live on this candidate (owner decision)

- Held-out bench ho22 (public DOJ releases, agent adjudication) on `e49783fd` — **before** the whole-case reader: rules 0.00 %,
  Opus 5 0.22 % wrong; ≤3 % met there. Not repeated on `7bb6323b`, whose answer path changed.
- Real solved cases (agent judge, `docs/agent-reviews/real-case-*.md`): AI off 14 % correct per question; Opus 5 everywhere
  (`14e0708b`, round 1 of five tuned cases) 44 % correct, 2.5 wrong-at-confidence per 100 questions; the six new cases are
  incomplete (bench key out of credit) — **not a result**, and **not** a pass of the ≤3 % wrong / ≥90 % bar. The whole-case
  reader (`7bb6323b`) has not been evaluated on real cases at all.

### Known limits carried by this candidate

1–4. **Fixed in the working tree (2026-11-04, uncommitted; not yet on a bound candidate commit)** — the four limits the plan
   journeys found: (1) the whole-case limit is derived from the verified plan (`CaseReadLimits.limit`, AIPricing
   `caseReadTokens`, mirrored from `PLANS` in relay/src/policy.ts: own key 300k setting, AI Included 300k, AI Pro 800k), capped
   so the worst-case reservation always fits the plan's case-read credits and the relay's size limit; (2) one size estimator
   (3 characters a token + 64, images 1,600) in policy.ts and AIPricing, checked by `ci/guards/relay-host-match.sh`, golden
   numbers in relay/test and `CaseReadBudgetTests`; (3) the own-key monthly dollar limit is checked against the worst case and
   tallied on whole-case reads too; (4) the credit meter refuses locally (credits-used / daily-limit / too-costly, the relay's
   words, Buy credits / Upgrade) when a fresh receipt shows the relay would; unknown or stale → sent, the relay decides.
   `PlanJourneySimulationTests` 5/5 with no known-issue marker; `CaseReadBudgetTests` 9/9; relay 19/19.
5. StoreKit `billingRetryWithGrace` test fails in this Mac's StoreKit environment; real grace behaviour unverified until Sandbox.
6. GUI not re-walked for the once-per-case permission sheet, the plan picker, the credit meter or offline search results (gate
   `ui-consent-and-plans`).
7. Hosted CI not run; relay not deployed; no Sandbox/TestFlight purchase matrix; no signed build.
8. Carried from earlier packets: first screen restores the last visited screen; UI export not exercised in a journey; archive Q&A
   copy-answer does not scrub protected identities (route 20).

### Status

`bash scripts/release-check.sh` → **BLOCKED** (see the output recorded with this packet).

## Historical candidates (superseded — digests and defects kept for the record)

### 1b. The 2026-10-31 candidate (after §2–§5 and §11 subscriptions)

Commits `60c7421e` · `a738c56b` · `7647249e` · `12aa3c71` · `933cedb3` · `0d1ef99a` · the §11 subscription commit; schema v168;
hosted CI not run; no digests. Superseded by the 2026-11-04 plans/credits and whole-case-reader commits.

### 1a. The superseding candidate (after the workflow review)

| Field | Value |
|---|---|
| Commits | `db5d75d5` (I3) · `0a741ac7` (I6, I7) · `585bb2a4` (I1) · `00590051` (I2) · `22f8d9d9` (I4, I5) · `9aa8f479` (I8) · `25091949` (I9) · `bcb9af60` (acceptance case) · `517e9ae5` (UI-journey fixes) · `4ca1e1a3` (run c records) · `d014d2e7` (amount pattern, ingest indicator) — last code change `d014d2e7`; records commits follow it |
| Schema | v167 (`SchemaMigrations.latestVersion`; `MigrationMatrixTests` pin) — v166 ACH unassessed cells + citations, v167 passage-level case evidence, allegation response/exception, report items |
| Unsigned Release digests | §2a below, built from the working tree at `d014d2e7` |
| Hosted CI | **all seven jobs green on `4147e106`** (run 41051769092, 2026-10-30: architecture-guards, migration-matrix, parser-fixtures, sensitive-export, report-receipt-integrity, release-build, build-and-test) |

### 2a. Build digests of the superseding candidate (unsigned Release, this Mac, tree at `d014d2e7`)

| Artifact | SHA-256 |
|---|---|
| `Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh` | `002ecb1c43b183f1c193a6ea15d6ea01d6ade0fe52a9ea72bf203d905fa83531` |
| `…/Extensions/KalsmritikoshNetworkHelper.appex/Contents/MacOS/KalsmritikoshNetworkHelper` | `6de4964778762a62395e3533fb526ac05d9f04ad1ff4e6fa4c0117026db0b33d` (unchanged) |
| `…/PlugIns/KalsmritikoshClipper.appex/Contents/MacOS/KalsmritikoshClipper` | `cd5b1da0f30dcddd96176b034b0cd816de5fda305cff14d1d4a2d4ff58a72ab3` (unchanged) |
| `…/PlugIns/KalsmritikoshShare.appex/Contents/MacOS/KalsmritikoshShare` | `ac960b529c43f2c769f4beccfb7a9bb9142ce21ffca5b36db71663cc19a61b53` (unchanged) |

Same command as §6. The *owner* records the signed Distribution build's digests beside these.

### 1. The candidate (da42fb08, 2026-10-30 morning)

| Field | Value |
|---|---|
| Branch / PR | `investigations-next`, PR #169 |
| Commit (code) | `460ae308` — last code change (held-out chronology 13 fixes); records and evidence commits follow it |
| Commit (packet) | the commit that adds this file (see `git log -1 -- docs/RELEASE_CANDIDATE.md`) |
| Hosted CI | all seven jobs green on `da42fb08`, the packet commit (run 41002107045, 2026-10-30) |
| Unsigned Release build | built from this working tree with `xcodebuild -configuration Release CODE_SIGNING_ALLOWED=NO` into `build/dd-release`; digests in §2 |
| Signed Distribution build | *owner*: archive from the same commit in Xcode; record the archive's SHA-256 of `Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh` and the notarisation ticket here |
| Schema | v165 (`SchemaMigrations.latestVersion`; `MigrationMatrixTests` pin) |
| Contracts | 168 jobs: 20 studio, 97 executor, 51 service, 0 preparation, 0 gap (`docs/JOB_CONTRACTS.md`) |

### 2. Build digests (unsigned Release, this Mac)

| Artifact | SHA-256 |
|---|---|
| `Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh` | `ded3689c2742812e37e3f1794ba324dd4240314b344d1f2c70d6e9487e01b999` |
| `Kalsmritikosh.app/Contents/Extensions/KalsmritikoshNetworkHelper.appex/Contents/MacOS/KalsmritikoshNetworkHelper` (ExtensionKit extension) | `6de4964778762a62395e3533fb526ac05d9f04ad1ff4e6fa4c0117026db0b33d` |
| `Kalsmritikosh.app/Contents/PlugIns/KalsmritikoshClipper.appex/Contents/MacOS/KalsmritikoshClipper` | `cd5b1da0f30dcddd96176b034b0cd816de5fda305cff14d1d4a2d4ff58a72ab3` |
| `Kalsmritikosh.app/Contents/PlugIns/KalsmritikoshShare.appex/Contents/MacOS/KalsmritikoshShare` | `ac960b529c43f2c769f4beccfb7a9bb9142ce21ffca5b36db71663cc19a61b53` |

An unsigned digest identifies the compiled code, not the shipped artifact: signing and notarisation change
the bundle. The *owner* records the signed digests beside these.

## 3. Evidence index

| Gate | Evidence | State |
|---|---|---|
| Engineering CI | `.github/workflows/build-and-guard.yml` | green on `4147e106` (run 41051769092); **not yet run on the current candidate's commits** |
| Advertised functionality | `docs/JOB_CONTRACTS.md`, `docs/JOB_OUTCOME_MATRIX.md`, `JobAcceptanceScenarioTests` (97 scenarios), `JobDeliverableTests` | met to integration level |
| Accuracy | `docs/FINAL_BRIEF_EXECUTION.md` §E3; `~/CaseBench/ho{9..13}-chron/MEASUREMENT-rules.txt`, `score-rules*.txt`; adjudication packs `~/CaseBench/adjudication/ho{9..13}-rules-*` | **not met by the automatic scorer** (fresh sets 1.1 %–1.7 % wrong); *people*: adjudicate; one more fresh draw after the ho13 fixes |
| Signed-build checks | `docs/evidence/ui-journeys-2026-10-30/JOURNEYS.md`, `…-2026-10-30b/JOURNEYS.md` (development build) | journeys and the acceptance case done on the development build **before §2–§4**; *agent*: re-check on the current code; *owner*: the Distribution build, install/upgrade/restore, exports through the UI, StoreKit, accessibility |
| Legal / distribution | `docs/DISTRIBUTION_PACK.md`, `docs/LEGAL_REVIEW_PACK.md`, `docs/legal/SUPPLEMENTAL_TERMS_DRAFT.md`, `docs/legal/DECISION_MEMO.md` | prepared with recommended defaults; *counsel + owner* decide and record in `SHIP_DECISIONS.md` |
| Practitioner / pilot | `docs/PRACTITIONER_REVIEW_AGENT.md` | agent pass only; *people*: one practitioner per persona, pilot users |
| Records | `docs/FINAL_BRIEF_EXECUTION.md` §E6 (the one current table), `docs/RELEASE_READINESS.md`, `SHIP_DECISIONS.md`, `PRODUCTION_STATUS.md` | reconciled 2026-10-30 |
| Output routes | `docs/OUTPUT_ROUTES_INVENTORY.md`, `CaseOutputServiceTests` | 24 routes inventoried; case routes through one service; two recorded gaps |

## 4. Known open defects carried by the current candidate

- First screen restores the last visited screen, so a fresh launch may open on Cases (journey D-5; Home is one toolbar press away).
- Export through the UI not yet exercised in a journey on the current code (save panel); covered by `CaseOutputServiceTests`.
- Ask's copy-answer button (archive Q&A, outside cases) does not scrub protected source identities (`docs/OUTPUT_ROUTES_INVENTORY.md` route 20).
- Historical (fixed): launch window taller than the screen (D1, fitted); palette "Home" row (D2, rows keyed by entry id); Data Lab three fields on every row (I8).

## 5. Freeze rule

A change to product code after this packet is a new candidate: new commit, new digests, re-run of the
acceptance suites and a fresh held-out draw if the change touches the answer path.

## 6. How the digests were produced

```
xcodebuild -project Kalsmritikosh.xcodeproj -scheme Kalsmritikosh -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd-release CODE_SIGNING_ALLOWED=NO build
shasum -a 256 build/dd-release/Build/Products/Release/Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh
```
