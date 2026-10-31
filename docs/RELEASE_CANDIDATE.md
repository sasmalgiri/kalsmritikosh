# Release candidate — Investigations Made Easy v1 (candidate packet, not a release)

One current section, then the historical candidates. A product-code change after a packet makes a new candidate (§5).
Unsigned digests identify compiled code and are supporting evidence only; the submitted artifact is the signed, uploaded
build, whose identifiers the *owner* records in `release/approvals/distribution-archive.md`. Release status is the output of
`bash scripts/release-check.sh` — currently **BLOCKED**.

> **2026-10-31:** the owner adopted subscriptions (updated completion instructions §11). A billing change creates a
> new candidate: `0d1ef99a` is superseded; the current candidate is the head after the §11 commit, and the Sandbox /
> TestFlight purchase matrix (DISTRIBUTION_PACK §6) must run on it.

## Current candidate (2026-10-31, after the App Store completion instructions §2–§5 and §11)

| Field | Value |
|---|---|
| Branch / PR | `investigations-next`, PR #169 (open) |
| Code commits since the last green head `4147e106` | `60c7421e` (§2 + §3, schema v168) · `a738c56b` (§4 one output service) · `7647249e` (§1 baseline, Release excludes the fixture) · `12aa3c71` (test-host isolation, Home first) · `933cedb3` (run-d fixes) · `0d1ef99a` (run-e fix) · the §11 subscription commit |
| Schema | **v168** (`SchemaMigrations.latestVersion`; `MigrationMatrixTests` pin; `scripts/release-check-schema-pin.sh`) |
| Hosted CI | **not yet run on these commits** — the last green head is `4147e106` (run 41051769092, seven jobs). Pushed in one batch with the next code change (Actions budget). |
| Unsigned Release digests | **not yet built for this tree** — produced at freeze with the command in §6 and recorded here |
| Signed Distribution build | none — *owner*: archive from the frozen commit in Xcode, record the archive's identifiers and the upload |
| Contracts | 168 jobs: 20 studio, 97 executor, 51 service (`docs/JOB_CONTRACTS.md`) |
| Gates | `ci/release-gates.json`; evidence and approval records under `release/approvals/` |

## Historical candidates (superseded — digests and defects kept for the record)

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
