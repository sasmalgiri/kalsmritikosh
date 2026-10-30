# Release candidate — Investigations Made Easy v1 (candidate packet, not a release)

Prepared 2026-10-30. This packet freezes **one candidate** with its commit, build digests and the evidence
index. It is a candidate: the owner's verdict of 2026-10-29 ("not yet — do not ship publicly") stands until
the gates in `docs/RELEASE_READINESS.md` are met. Rows marked *owner* or *people* are filled by them, not by
the agent.

## 1. The candidate

| Field | Value |
|---|---|
| Branch / PR | `investigations-next`, PR #169 |
| Commit (code) | `460ae308` — last code change (held-out chronology 13 fixes); records and evidence commits follow it |
| Commit (packet) | the commit that adds this file (see `git log -1 -- docs/RELEASE_CANDIDATE.md`) |
| Hosted CI | all seven jobs green on `eac38eb5` (run 40862841271, 2026-10-29); later commits need their own run — see "Next CI" below |
| Unsigned Release build | built from this working tree with `xcodebuild -configuration Release CODE_SIGNING_ALLOWED=NO` into `build/dd-release`; digests in §2 |
| Signed Distribution build | *owner*: archive from the same commit in Xcode; record the archive's SHA-256 of `Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh` and the notarisation ticket here |
| Schema | v165 (`SchemaMigrations.latestVersion`; `MigrationMatrixTests` pin) |
| Contracts | 168 jobs: 20 studio, 97 executor, 51 service, 0 preparation, 0 gap (`docs/JOB_CONTRACTS.md`) |

## 2. Build digests (unsigned Release, this Mac)

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
| Engineering CI | `.github/workflows/build-and-guard.yml`, run 40862841271 | green on eac38eb5; re-run due on the packet commit |
| Advertised functionality | `docs/JOB_CONTRACTS.md`, `docs/JOB_OUTCOME_MATRIX.md`, `JobAcceptanceScenarioTests` (97 scenarios), `JobDeliverableTests` | met to integration level |
| Accuracy | `docs/FINAL_BRIEF_EXECUTION.md` §E3; `~/CaseBench/ho{9..13}-chron/MEASUREMENT-rules.txt`, `score-rules*.txt`; adjudication packs `~/CaseBench/adjudication/ho{9..13}-rules-*` | **not met by the automatic scorer** (fresh sets 1.1 %–1.7 % wrong); *people*: adjudicate; one more fresh draw after the ho13 fixes |
| Signed-build checks | `docs/evidence/ui-journeys-2026-10-30/JOURNEYS.md` (development build, sample archive) | journeys done on the development build; *owner*: the Distribution build, install/upgrade/restore, exports through the UI, StoreKit, accessibility |
| Legal / distribution | `docs/DISTRIBUTION_PACK.md`, `docs/LEGAL_REVIEW_PACK.md`, `docs/legal/SUPPLEMENTAL_TERMS_DRAFT.md`, `docs/legal/DECISION_MEMO.md` | prepared with recommended defaults; *counsel + owner* decide and record in `SHIP_DECISIONS.md` |
| Practitioner / pilot | `docs/PRACTITIONER_REVIEW_AGENT.md` | agent pass only; *people*: one practitioner per persona, pilot users |
| Records | `docs/FINAL_BRIEF_EXECUTION.md`, `docs/RELEASE_READINESS.md`, `SHIP_DECISIONS.md`, `PRODUCTION_STATUS.md` | reconciled to this commit |

## 4. Known open defects carried by the candidate

- Launch window can open taller than the screen on a 956-pt display (journey D1); cause not found.
- Command palette shows a "Home" row for "Professional Jobs" (journey D2).
- Export through the UI not exercised in a journey (save panel); covered by tests only.
- Data-lab result shows the three analysis fields on every row, not only the Analysis row.

## 5. Freeze rule

A change to product code after this packet is a new candidate: new commit, new digests, re-run of the
acceptance suites and a fresh held-out draw if the change touches the answer path.

## 6. How the digests were produced

```
xcodebuild -project Kalsmritikosh.xcodeproj -scheme Kalsmritikosh -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd-release CODE_SIGNING_ALLOWED=NO build
shasum -a 256 build/dd-release/Build/Products/Release/Kalsmritikosh.app/Contents/MacOS/Kalsmritikosh
```
