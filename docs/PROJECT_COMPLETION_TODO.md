# Project completion TODO — kalsmritikosh 1.1 → shipped → post-ship

_Created 2026-09-27 on branch `v11-implement-all` (main frozen at `faebecf`)._
_Status keys: ☐ open · ◐ in progress · ☑ done · 🔒 owner-only · ⏳ gated._
_Acceptance = the check that must pass before the box is ticked. A build
passing is never acceptance on its own._

---

## PHASE 1 — Ledger correctness (the database must be right before answers can be)

| ID | Task | Owner | Acceptance |
|---|---|---|---|
| ☑ P1.1 | **Device-facts era bug** — `DeviceFactProducer` stamps `producer_version = 1`; the drain's orphan sweep (LedgerDrainCoordinator pass 2b) deletes every device fact each refresh. Stamp `DerivedProducerVersions.facts`. | agent | Unit test: device fact survives a drain; second drain writes 0. |
| ☑ P1.2 | **Finish the L3 real-ledger measurement** — rerun `OwnerLedgerRollupProbeTests` (audit folder `.txt`, now prints stale rows) with a 3-min cap. | agent | Stale facts reach 0; résumé classes, fact subjects, tree L1 sizes, current-history count printed. |
| ☑ P1.3 | **226-member topic-tree node** — confirm the df ceiling split it; if not, find the fusing terms. | agent | No L1 node > 25% of members on the owner copy. |
| ☐ P1.4 | **Receipt/invoice → counterparty rollup** (L3 remainder) — file a commercial document's facts under the issuing party, universal fallback = title/stem. | agent | Fixture receipts from 3 vendors → 3 subjects; non-commercial docs unchanged. |
| ☑ P1.5 | **Claims inflation** — root cause: claims outlived the events they projected (all 5,718 pointed at rewritten events) and the completed backfill never re-projected. Drain pass 2d removes unreviewed/unused orphans (reviewed ones only marked missingEvidence), resets the projection cursor, boot re-projects. Owner copy: 5,718 orphans → 4,798 live claims, 1,107 distinct statements (was 276). RULED: same statement from different sources = corroboration (claims are per-source by contract), not inflation. | agent | Claims resolve to live sources; ruling recorded. |
| ☑ P1.6 | **Bare digit-run "phones"** — decided by CONTEXT: a digits-only run stays a phone only when a phone label (Phone/Mob/Tel/Contact/M:/WhatsApp…, incl. list continuations) introduces one of its occurrences in its source text; otherwise retired as `unlabelled-digit-run` (reversible, audited, user restore wins). Punctuated numbers untouched. Owner copy: 803 → 100 live. | agent | Labelled phones kept; unlabelled runs retired. |
| ☑ P1.7 | **Re-type existing 'unknown' files** — drain pass 0 re-types from stored text; intake sniffer now recognises any RFC 822 header block (returned originals open with DKIM-Signature/ARC-Seal, delivery reports with Reporting-MTA). Owner copy: 13 → 0 unknown (12 eml, 1 svg→xml). Type only — their blocks/participants need the original bytes (lived in a temp folder): re-ingest to recover. | agent | 0 'unknown' text documents. |
| ☑ P1.8 | **Block-less chunks** — two causes fixed: (a) an early boot reindex stamped mailbox threads as packed before the drain linked their blocks, so they were never repacked → documents with lineage-less chunks that now own blocks are re-chunked regardless of stamp; (b) split children kept only the parent's first block → they inherit matched lineage. Owner copy: 185 → 35; the 35 are the re-typed attachments + an SVG + a zip whose structure needs their original bytes. | agent | Only byte-less residue lacks lineage. |
| ☑ P1.9 | **Participant occurrences + co-occurrence graph** — co-occurrence builder runs (fresh graph 3,293 edges after P1.14/P1.16). Participant occurrences: EmailParticipantBackfill had ZERO app callers and queried a non-existent column (`ko.metadata`); fixed (metadata_json + thread messages), wired into the boot pass, added to the reachability manifest. Owner copy: 0 → 1,955 occurrences over 247 emails. | agent | Both populated; second run writes 0. |
| ☑ P1.10 | **Event dedup** — EventDeduper collapses same-source repeats (source+kind+title+day) before insert, union of participants + `occurrences` count; events era 2→3. Owner copy: 595 → 474 events, all distinct. The "21 hearings" no longer reproduces (0 same-day hearing duplicates). | agent | No same-source duplicate events. |
| ☑ P1.12 | **Legacy duplicate histories** — rows from 2026-09-25 (two builds per anchor) are still both `current`; supersede-on-rebuild only fires for subjects rebuilt. One-time drain pass: keep the newest per (anchor_key, request_shape). | agent | Owner copy: ≤1 current history per subject. |
| ☑ P1.13 | **Transport/stem subjects** — TopicConsolidator: bounce/DSN notices and file-kind stems (image-, IMG-…-WA…, Picture-) are never standing topics (fold by ≥2 shared terms or stay out; facts remain); case/spacing duplicates merge. Owner copy: 79 → 69 topics. Residual: automated service notices ("… wants to chat", "Alert Generated for …") need the SENDER signal → P1.19. | agent | No bounce/stem-named topic. |
| ☑ P1.14 | **Date headers inside communities** — they were correctly typed `date`, but a pre-fix co-occurrence graph left 88 of ~350 level-0 members as dates. Detector now ignores attribute kinds; tree refreshes after each detection. Owner copy (fresh graph): 81 → 45 level-0, 0 dates, 8 level-1 nodes. Residual: a 100-member (cap) community of LOCATIONS → P1.16. | agent | Owner copy: 0 date-shaped community members. |
| ☐ P1.15 | **Topic AI-polish cost** — 12 topics ≈ 14 min (~70 s each) on the idle pass. Budget + batch it, never blocks boot. | agent | Polish pass time per topic logged; idle build of 79 topics bounded. |
| ☑ P1.16 | **Location hub community** — places excluded from co-occurrence + communities (attributes, like dates). Owner copy: the location hub is gone; the patent matter now forms ONE community (Khurana & Khurana, Controller, all 5 patent anchors) shown in Big Picture as "Patent No. 555489" (anchored single-community matters are promoted to level 1). Residual: that community hits the 100 cap and carries NER noise ("Chennai" as org, "Page", "Mam") → P1.18. | agent | No location hub; matter visible in Big Picture. |
| ☐ P1.17 | **Tree/topic label hygiene** — winner terms include encoded fragments ("capuxmjoemkzvp") and truncated identifiers ("2023310"). Term salience must drop base64/hex-like tokens and prefix-truncated identifiers. | agent | Owner copy: no L1 label contains a non-word token or a truncated anchor. |
| ☐ P1.18 | **NER noise inside the matter community + the 100 cap** — cities typed organization, "Page"/"Ltd"/"Mam"/"Shri" as parties; with hubs gone, revisit whether the cap should rise. | agent | Owner copy: matter community's person/org members are real parties; cap decision recorded. |
| ☐ P1.19 | **Automated-notification topics** — Google/portal notices become topics. Mark a message automated at ingest from its sender (no-reply, mailer, notification addresses — reuse EntityQualityGate.isAutomatedSender) and keep automated messages out of topic subjects. | agent | Owner copy: no notification-titled topic. |
| ☑ P1.20 | **Generic "patent" topic** — RULED no-change (2026-09-27): those emails carry no identifier; folding by one shared word violates the owner rule "a shared word is not evidence". It stays its own topic. | agent | Ruling recorded. |
| ☐ P1.11 | **L4 LedgerContractCheck** — invariants run in CI on every build: every fact has a resolved subject + evidence; no fact value is CSS/transport header/table furniture; every derived row cites a source; second boot writes zero. | agent | New CI guard/test green; fails red on a seeded violation of each rule. |

## PHASE 2 — Answers read the ledger (where the owner sees the difference)

| ID | Task | Owner | Acceptance |
|---|---|---|---|
| ☐ P2.1 | **W6 metrics harness** — per-shape precision/recall/context-precision on the gold sets + the owner-copy six questions. Baseline FIRST. | agent | Baseline numbers recorded in `docs/`. |
| ☐ P2.2 | **L5 subject-first answering** — resolve the question's subject (matter topic / anchor / person), read its topic + history + facts before passage retrieval. | agent | Owner-copy six questions: patent status = granted 28 Nov 2024 / 555489 cited; hearing = 14/08/2024; payment = total, no junk; jobs = employers listed; control = refusal. |
| ☐ P2.3 | Tune rerank / corrective re-retrieve / HyDE against P2.1 metrics (built + on, never measured). | agent | Each module's on/off delta recorded; any negative module defaulted off. |
| ☐ P2.4 | **W5 `.actor` shape** polish ("who drafted the claims?"). | agent | Drafter question cites the Khurana & Khurana passage. |
| ☐ P2.5 | **Known red test** `W5FixTests.poaLineProducesExactlyOneApplicant` vs `.poaGrantorRecovery` default ON — fix code or update the test with a recorded ruling. | agent | Test green; ruling in Self-Rulings Ledger. |
| ☐ P2.6 | Gold wall + AskTheLedger + GoldWall regression after every P2 change. | agent | Refusal 1.0 · hallucination 0 · false-not-found 0. |

## PHASE 3 — Remaining UI

| ID | Task | Owner | Acceptance |
|---|---|---|---|
| ☐ P3.1 | Story/History citations open in the in-app viewer at the quote (Ask already does). | agent | HistoryView tap → SourceViewer with highlight. |
| ☐ P3.2 | Sources "Refreshing N sources with newer rules…" line while the drain runs. | agent | Line shows during drain, reads 0 after. |
| ☐ P3.3 | Timeline axis gap markers. | agent | Gaps from the gaps panel drawn on the axis. |
| ☐ P3.4 | **Live check of the 2026-09-27 UI** — citation chips (PDF + email), closest-match on a not-found, Technical details, sample archive → banner → back, persona step. | 🔒 owner | Each behaves as described; any defect filed. |

## PHASE 4 — End-check and merge (branch law: main frozen until this passes)

| ID | Task | Owner | Acceptance |
|---|---|---|---|
| ☐ P4.1 | Full suite to completion (last time ~1,220 of ~4,700 never ran) — rerun every "No result" suite. | agent | Every suite reports; failures = 0 or ruled. |
| ☐ P4.2 | Double-Boot Zero-Write on the live-shaped copy. | agent | Second boot writes 0 rows. |
| ☐ P4.3 | Gold wall across persona archives. | agent | Absolute thresholds met; `PERSONA_STATUS.generated.md` regenerated. |
| ☐ P4.4 | Parity ×5 vs seal #10f, predicted-diff enumerated; bisect any surprise. | agent | observed ⊆ predicted; 5/5 stable. |
| ☐ P4.5 | Reseal (#11) + bless note. | agent | Seal captured; blessing written. |
| ☐ P4.6 | Regenerate scoreboard / kalverify / claims; all 14 guards green. | agent | `ci/guards/run-all.sh` clean; claims gates green. |
| ☐ P4.7 | PR `v11-implement-all` → main, two-run CI (PR head + main). | agent | Both CI legs green. |

## PHASE 5 — Ship (HOLD 2)

| ID | Task | Owner | Acceptance |
|---|---|---|---|
| ☐ P5.1 | Add the build-identity run-script phase in Xcode (`scripts/stamp-build-identity.sh`) — pbxproj is owner-only. | 🔒 owner | About shows a git SHA, not "development". |
| ☐ P5.2 | Copy the live ledger to the audit folder once after P4 so the agent can verify the real archive. | 🔒 owner | Agent reports live numbers (1 patent, 1 applicant, frontiers 0, junk 0). |
| ☐ P5.3 | HOLD 2 sitting per `release/HOLD2_SCRIPT.md` — 30-question triage (Wrong = STOP), GK flip, delete witness, big picture. | 🔒 owner | Zero Wrong; Marked items filed. |
| ☐ P5.4 | Read scoreboard, persona status, seal blessings, Self-Rulings Ledger. | 🔒 owner | Signed off. |
| ☐ P5.5 | Lawyer pass: privacy policy, terms/EULA, acknowledgments. | 🔒 owner | Approved text in `docs/`. |
| ☐ P5.6 | Release runbook steps 1–9, App Store listing, screenshots from the sample archive only, export-compliance answer. | 🔒 owner | Build uploaded. |
| ☐ P5.7 | Submit → App Review → "1.1 is live". | 🔒 owner | Live on the App Store. |

## PHASE 6 — Post-ship (Go 3, ⏳ opens on "1.1 is live")

| ID | Task | Owner | Notes |
|---|---|---|---|
| ⏳ P6.1 | Field-feedback amendment sweep — user-reported defects outrank everything below. | agent | |
| ⏳ P6.2 | Known reds: OCR substitution, page-break value split, causal explosion. | agent | |
| ⏳ P6.3 | Deep relationships, corpus-wide stories. | agent | |
| ⏳ P6.4 | Any-Question Stack (archive → shelf → general knowledge lanes). | agent | Owner may pull forward with "before ship". |
| ⏳ P6.5 | Model-training track; port-parity audit. | agent | |
| ⏳ P6.6 | Multilingual index (bge-m3) — v2. | 🔒 owner supplies the model | |
| ⏳ P6.7 | F7 redaction UI — after the owner's blind-PII test. | 🔒 owner gate | |
| ⏳ P6.8 | I2 fast/quality ingest tiers — needs an owner decision. | 🔒 owner gate | |

---

## Order of execution
P1.1 → P1.2 → P1.3 → P1.11 (L4) → P2.1 (baseline) → P2.2 (L5) → P1.5 / P1.10 / P1.9 →
remaining P1 → P2.3–P2.6 → P3.1–P3.3 → (owner P3.4 any time) → P4 → P5 → P6.

## Done recently (for reference)
L1 chunk packing `cbe669d` · L2 hygiene `0080de4` · L3 rollup `915ad95` ·
GK default ON + I-3 closed `3ccab86` · citation chips `e71a534` · closest match
`171721b` · Technical details `721b9a4` · sample archive ledger `b15382a` ·
persona step `c9d2eff`.
