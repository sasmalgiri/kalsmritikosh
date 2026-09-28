# U-9 — Release-compliance ledger (RC-1…8), implement-all

Each RC item gets a green check or a named owner-gated exception. Folds in
the U-0…U-8 deltas.

## RC-1 — entitlements, privacy, export
| Item | Status | Evidence |
|---|---|---|
| Entitlements minimal, no network keys | ✅ | `Kalsmritikosh.entitlements` — `network.client=false`, no `.server`; U-0 removed the last path + toggle |
| No-network CI assertion | ✅ | `ci/guards/release-configuration.sh` §3c fails on `network.client/.server` |
| Privacy manifest | ✅ | `PrivacyInfo.xcprivacy` + `notices-coverage.sh`; #130 |
| Export compliance / Info.plist / age rating | ⧗ owner | ASC fields set at submission (owner-only Apple action) |
| EULA, privacy & support URLs live | ✅ doc / ⧗ owner-host | `release/TERMS_OF_USE.md`, `PRIVACY_POLICY.md`, `SUPPORT.md` — URLs go live when owner hosts |

## RC-2 — honest product surface
| Item | Status | Evidence |
|---|---|---|
| Requirements card live-checked | ✅ | onboarding requirements card |
| Deterministic mode as a state | ✅ | `PrivacyGate.offlineNoLLM` + Settings; disclaimer (U-2.5) |
| Indexing progress with counts + honest note | ✅ | LiveDashboard + U-3.1 embedding coverage |
| Scale claim witnessed or removed | ⧗ owner | claims gate holds it until witnessed |
| Scan markers | ✅ | U-4 OCR per-line confidence + U-3.6 file status |
| Roadmap in Help | ✅ | Help content |

## RC-3 — reviewer enablement
| Item | Status | Evidence |
|---|---|---|
| Sample archive bundled | ✅ | `App/DemoArchive.swift` |
| App Review notes | ✅ | `release/APP_STORE_LISTING.md` |
| PII-free screenshots / name / subtitle / keywords | ⧗ owner | owner produces at submission |

## RC-4 — acknowledgments & notices
| Item | Status | Evidence |
|---|---|---|
| Acknowledgments complete | ✅ | About panel + notices |
| CI notices ⊇ lockfile + model manifest | ✅ | `ci/guards/notices-coverage.sh`, `verify-model-pins.sh`, `COMPILED_MODEL_HASHES.json` |

## RC-5 — accessibility & states
| Item | Status | Evidence |
|---|---|---|
| Accessibility pass recorded | ✅ | #132 VoiceOver receipt; U-1 badge + U-3.3 panel carry a11y labels |
| Designed empty/error states | ✅ | empty/error states; U-1 Evidence "failed (reason)" |
| Help | ✅ | Help content |

## RC-6 — release recipe
| Item | Status | Evidence |
|---|---|---|
| Release recipe checklist | ✅ | `release/README.md`, `HOLD2_SCRIPT.md` |
| Version rule | ✅ | `release/VERSION_RULE.md` |
| Rollback plan | ✅ | `release/ROLLBACK_PLAN.md` |
| Support inbox live | ⧗ owner | `SUPPORT.md`; inbox owner-hosted |

## RC-7 — claims gate
| Item | Status | Evidence |
|---|---|---|
| One claims table → page / ASC / in-app | ✅ | `scripts/check-claims.sh`, `app-claims-coverage.sh`, `PROMISE_CARD_INVENTORY.md` |
| CI fails on unwitnessed assertions | ✅ | claims gate in CI |
| "How it compares", personas, availability re-verified | ⧗ owner | owner re-verifies at HOLD 2 |

## RC-8 — Language Contract
| Item | Status | Evidence |
|---|---|---|
| Lint over user strings + composer output | ✅ | `ci/guards/ui-language-contract.sh` (green) |
| Banned tokens ("claims", "Reported:", jargon) | ✅ | U-2.5 quality strip → "passage"; lint clean |
| One confidence presentation | ✅ | `QualityStrip.confidenceWord` + U-1 single trust note |
| Badge semantics table | ✅ | U-1 `AnswerBadge` (Supported · Partially supported · Unverified · Not found · Twin-verified · AI reading differed) |
| Adaptive disclaimer (model-free says so) | ✅ | U-2.5 "Answered from your records — no AI involved" |
| Real plurals | ✅ | U-6 EvidenceSufficiency; pluralization helpers |

## Owner-gated exceptions (the only non-green items)
All ⧗ rows above are **owner-only Apple/hosting actions** (ASC fields,
hosted URLs, submission screenshots, scale-claim witness, HOLD-2
re-verification) — none is an agent-completable code gap.

_Audit record for the end-check ledger; no code change in this unit._
