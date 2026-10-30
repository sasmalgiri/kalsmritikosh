# Release readiness — Investigations Made Easy v1 (2026-10-29, revised after the completion instructions on 0ce29931)

**Decision: not ready to release.** The blockers are named below. This page summarises
`docs/FINAL_BRIEF_EXECUTION.md` (the authority) as of `investigations-next`, after the B1–B5 engineering pass
(§E1 of the execution record is the one evidence table).

Testing cadence (agreed with the owner, 2026-10-28):
- each change: the suites it touches, plus the guards;
- each push: the full suite on CI;
- before ship: UI automation, the signed app, journeys and benchmarks.

## Gates

| Phase | Gate | State | Evidence |
|---|---|---|---|
| F0 | One execution record; SHIP_DECISIONS current | done | SHIP_DECISIONS §0, FINAL_BRIEF_EXECUTION |
| F1 | Shared kernel K1–K11 | **done** (unit/integration), incl. audit A3–A7 and B1 (erasure fails closed), B2 (job-result integrity), B4 (case-scoped cloud sends); bounded items recorded | K5 studio approvals carry no scope fingerprint (the export re-check covers it); K11 vault encryption is a recorded decision |
| F2 | All 168 jobs produce their intended result | **met to integration level** — 20 studio, 97 executor (each checked against its own acceptance scenario; the 16 B3 had reopened now have their own executors, scenarios, completion rules and enforcement — FINAL_BRIEF_EXECUTION §E2), 51 service, 0 preparation, 0 gap. Open: UI journeys on the signed build; practitioner review of each deliverable | `docs/JOB_CONTRACTS.md`, `docs/JOB_OUTCOME_MATRIX.md`, `JobAcceptanceScenarioTests`, `JobDeliverableTests` |
| F3 | Nine persona journeys | service level done (`InvestigationCaseSimulationTests`, 9 personas); **UI journeys done on the development-signed Debug build in sample-archive mode (2026-10-30)**, every persona to a result screen, four UI findings (two fixed); **open on the Distribution build** (tier 3), and export through the UI not exercised | `docs/evidence/ui-journeys-2026-10-30/JOURNEYS.md` |
| F4 | Races, recovery, workload | T1 8/8 (`docs/RACE_MATRIX.md`); T2 done except the clean-machine restore (signed build); T3 measured on one Mac and bounded (`docs/SUPPORT_ENVELOPE.md`) | `NewerSchemaRefusalTests`, backup suites, `SupportEnvelopeTests` |
| F5 | Independent adjudication, then a fresh held-out set | **measured on the current code, gate not yet met by the automatic scorer; human adjudication open.** Rules path (AI off), run from the agent through Xcode's test host via a bundled pack (FINAL_BRIEF_EXECUTION §E3): fresh one-shot sets ho10 2.2 % → ho11 3.2 % → ho12 1.1 % → ho13 1.7 % wrong (automatic scorer), each followed by targeted fixes with unit tests; the latest fixes (89d0f16e→) are not yet measured on a fresh set. By the agent's own reading of every flagged item, most remaining "wrong" are answer-key artefacts (the key assumes the release date where the text gives the day; a byte-identical duplicate release; an agreement to plead counted as a plea), but that reading is not independent. Blinded packs: ho9-rules-b6, ho10-rules, ho11-rules, ho12-rules, ho13-rules (`~/CaseBench/adjudication/`). The claude path is not measured (no key in the sandboxed host) | `docs/ADJUDICATION_PROTOCOL.md`, `scripts/casebench/pack_local.py`, `~/CaseBench/ho1x-chron/MEASUREMENT-rules.txt` |
| F6 | Legal and distribution pack | prepared, incl. a supplemental-terms draft for counsel; **owner/counsel decisions open** | `docs/DISTRIBUTION_PACK.md`, `docs/LEGAL_REVIEW_PACK.md`, `docs/legal/SUPPLEMENTAL_TERMS_DRAFT.md` |
| F7 | Pilot, practitioners, release packet | **open** | — |

## Exact blockers

0. ~~**Jobs reopened (F2):** 16 jobs are preparation~~ — **closed 2026-10-29** (release-block directive item 1): each
   deliverable (statement comparison, lineage chart, annotated edition, source-linked questions, figure tracing,
   source families, protected-name exclusion in exports and cloud sends, coding that withholds from production,
   analysis filters, date ranges and gaps, parties with human merges) is built, with its acceptance scenario and
   rules (`JobAcceptanceScenarioTests`, `JobDeliverableTests`; FINAL_BRIEF_EXECUTION §E2). Signed-build journeys
   and practitioner review of each remain under 3 and 4 below.
1. ~~**Bench re-run (in Terminal)**~~ — **done from the agent (2026-10-29/30)** through Xcode's test host with a
   bundled pack (`scripts/casebench/pack_local.py`, `unpack_results.py`; `CaseBenchRunner` reads the pack when no
   `CASEBENCH_DIR` is set). The Terminal driver `scripts/casebench/heldout.sh` is unchanged and also measures
   the claude path, which the sandboxed host cannot.

2. **Accuracy (F5):** the ≤1 % wrong gate is **not yet met by the automatic scorer** on a fresh set: ho12 1.1 %
   (c3f07ebd), ho13 1.7 % (89d0f16e), each followed by fixes; the fixes after ho13 need one more fresh draw
   (`chronology.py --seed <new> --skip-keys ~/CaseBench/skip-chron`, x1–x15 now used). Independent human
   adjudication of the packs decides which flagged items are real; the agent's reading says most are
   answer-key artefacts, but it is not independent.
3. **Signed build (tier 3):**
   - UI journeys for all nine personas;
   - clean-machine install, upgrade and restore;
   - Private-mode no-egress;
   - the Online preview, cancel and privilege behaviour;
   - export-byte and redaction checks;
   - the StoreKit script (`DISTRIBUTION_PACK.md` §6).
4. **Support envelope (T3):** measured (`docs/SUPPORT_ENVELOPE.md`); larger or scan-heavy archives and other hardware are not claimed.
5. **Owner/counsel decisions (F6):**
   - the privacy-label answer;
   - Standard EULA plus supplement;
   - governing law;
   - trademark clearance of the name.
6. **Pilot and practitioner review (F7)**, then the release packet: commit, build and digest; enabled
   scope; job outcomes; limitations; CI results; signed-app results; legal texts; purchase setup;
   recovery instructions.

## Known limitations to state in the release notes

- Rule-based event extraction fires only on marker phrases. A document's dated sentences still reach
  the chronology as "date stated in text", but documents without either produce no chronology rows.
- Method jobs save a started run with the person's worksheet; completing the run in the method engine is separate.
- Bates numbers in job results are proposals; production assigns the final numbers.
- Funds tracing is a manual workpaper; the app does not compute LIBR/FIFO allocations.
- Job executors produce drafts for a person to review. They never grade, conclude, total across
  currencies or clear anything for disclosure on their own.
- Erasure reaches what the app holds on the Mac. It does not reach external originals, backups,
  snapshots, sync folders, exports or Keychain items.
- Vault copies of originals rely on FileVault for encryption at rest.
