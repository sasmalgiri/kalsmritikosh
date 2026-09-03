# R-2 Promise Card Inventory — the landing page as acceptance contract

Status: **DRAFT assembled during F7 (live drain in flight), finalized at F9.**
Law: every card on `docs/index.html` maps to a witnessed promise row, a
test-backed feature, or is rescoped before HOLD 1. A card with no row is a
page bug or a product gap — never left ambiguous.

Verification vocabulary:
- **WITNESSED** — exercised live on the real archive during a sealed run.
- **TEST-BACKED** — a named automated test proves it on every CI run.
- **VERIFY-AT-F9** — feature exists; the specific claim needs its named test
  or witness step identified before HOLD 1.
- **RESCOPE-CANDIDATE** — page promises more than the binary holds today;
  owner decides (page-promise changes are owner-only).

## 1. Claim-tagged cards (data-claim → I-8 scoreboard rows)

| Claim ID | Card | Status | Verification pointer |
|---|---|---|---|
| privacy.on-device (×4) | meta + hero + On-device AI | TEST-BACKED | no-network entitlement + grep guard; RC-1 adds CI assert |
| privacy.private-by-design (×2) | Private by design | TEST-BACKED | PrivacyGate tests; sandbox entitlements |
| privacy.never-leaves (×2) | Nothing is uploaded | TEST-BACKED | same as above; RC-1 network-entitlement CI assert |
| privacy.erase-everything (×2) | Delete anytime | TEST-BACKED | D-10 erase VACUUM (task #12); originals untouched by design (ingest-in-place) |
| privacy.nothing-collected | Nothing collected | TEST-BACKED | no telemetry anywhere; RC-1 PrivacyInfo.xcprivacy declares none |
| privacy.no-servers | No servers | TEST-BACKED | rides never-leaves |
| privacy.models-bundled + no-egress | On-device AI — nothing to download | TEST-BACKED | Apple-FM + bundled BGE; COMPILED_MODEL_HASHES.json |
| answers.traceable | Answers carry their sources | WITNESSED | rung-1 live (seal #3e, 4× byte-identical); claim–evidence contract tests |
| answers.refuses-unsupported | It won't guess | WITNESSED | rung-1n live GREEN (F8, 536b8cc): named, receipted abstention |
| answers.refuses-to-guess | refusal card | WITNESSED | same F8 path + evidence-gate tests |
| answers.evidence-gate | Evidence gate | TEST-BACKED | gate ship/downgrade/refuse/surface-conflict suite |
| conformance.standards-enforced + refused-conclusions | Real standards, enforced | TEST-BACKED | SOP conformance suite |
| conformance.fail-closed + frozen-hash | Encoded workflow conformance | TEST-BACKED | contractSnapshotSHA256 immutability tests |
| workflow.element-gates + strict-mode + approval-gate + classic-disclosure | The real deliverable | TEST-BACKED | workflow gating suite |
| studios.hardcopy | Hardcopy studio | VERIFY-AT-F9 | name the test/witness step |

## 2. Untagged feature cards (the R-2 rider's named four + the rest)

### ▦ DataLab — evidence into tables
| Bullet | Status | Pointer |
|---|---|---|
| Build from evidence (cited table, one click) | VERIFY-AT-F9 | DataLab build path + origin_case_id binding (task #2) |
| Profession templates (privilege log, research log, transaction ledger, allegation matrix) | VERIFY-AT-F9 | enumerate templates in code = the four named + more |
| Type, paste & bind (inline edit, Excel paste, cell→source binding) | VERIFY-AT-F9 | cell-binding tests |
| Analyse safely (totals/sorts, what-if, quality checks) | VERIFY-AT-F9 | non-destructive scenario tests |

### 🧭 Do the job & hand it off
| Bullet | Status | Pointer |
|---|---|---|
| Professional workflows — 10 professions, numbered document per step | VERIFY-AT-F9 + R-3 | ten-personas parity is the S2-U5 gate; count the shipped personas NOW vs "10" |
| Logs & registers (interviews, FOIA, research log + change history) | VERIFY-AT-F9 | Logs & Trackers suite |
| Review & handoff (conflicts, missing evidence, decision record) | TEST-BACKED | AEE review-loop + FactReview suites |
| Export with receipts (PDF/Word/Excel, citations baked, tamper-evident receipt) | VERIFY-AT-F9 | **export-citations guard rides here (R-2 rider): citations must survive every export format — name or write the guard test** |

### 📊 See the big picture
| Bullet | Status | Pointer |
|---|---|---|
| Caseload triage | VERIFY-AT-F9 | Caseload view + ranking test |
| Trends across archive | VERIFY-AT-F9 | Trends producer test |
| Completeness & Live | WITNESSED-ADJACENT | live window shipped (4-part UX); name the completeness metric test |
| Convert (files between formats, back and forth) | VERIFY-AT-F9 | conversion matrix — "back and forth" is a strong claim; RESCOPE if only one-way for any pair |

### 🗑️ Delete anytime
| Bullet | Status | Pointer |
|---|---|---|
| One click erases the entire ledger | TEST-BACKED | D-10 erase + VACUUM |
| Original files never touched | TEST-BACKED | ingest-in-place invariant; drain untouched-tables proof is the same law |

### Remaining cards (inventory completeness)
| Card | Status | Pointer |
|---|---|---|
| Answers carry sources / won't guess / conflicts surfaced | WITNESSED | rungs 1/1n live; conflict-preserved tests |
| A real timeline | WITNESSED at rung 2 **pending** | rung-2 is the R-1 diagnosis post-drain — this card's witness |
| Export with citations intact | VERIFY-AT-F9 | same export-citations guard |
| Instant & deterministic | TEST-BACKED | deterministic lane 0-generative tests + I-6 latency at P3-U5 |
| Deeper answers when you want them | TEST-BACKED | adaptive escalation (AEE) suite |
| 🔎 Ask & find | WITNESSED | the live seven |
| 🧩 Reconstruct the story (Timeline·History·Dossier·Connections·Fund Flow·Email Threads) | Mixed | Dossier/Connections/FundFlow/Threads shipped + tested; the cited NARRATIVE is rung 3 = Go 2 Phase 4 — page ships before rung 3, so History card wording must hold TODAY: VERIFY-AT-F9 what History view shows now |
| 🛡️ Trust, safety & upkeep (redaction, authenticity, findings-by-status, freshness, layered citations) | TEST-BACKED | F7 redaction + authenticity + findings suites; verify freshness monitor + Evidence Explained rendering at F9 |
| Persona cards (lawyers…genealogists, content creators, everyone) | R-3/S2-U5 | ten-personas parity gate |
| Comparison table rows | R-5 at P5-U2 | comparative claims verified at ship gate |
| Coming soon for Mac (posture) | DONE | R-4 shipped b12a204 |

## 3. Open items this inventory feeds F9
1. Name (or write) the **export-citations guard** — the one R-2 rider that is a test, not a mapping.
2. Count shipped professional workflows vs the page's "10 professions" (R-3 pre-check).
3. "Convert … back and forth" — verify the matrix is truly bidirectional or flag RESCOPE.
4. History card wording vs pre-rung-3 reality (story narrative is Go 2 Phase 4).
5. studios.hardcopy claim — locate its feature + test.
