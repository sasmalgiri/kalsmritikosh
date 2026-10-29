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
| F3 | Nine persona journeys | service level done (`InvestigationCaseSimulationTests`, 9 personas); **UI journeys open** (tier 3) | — |
| F4 | Races, recovery, workload | T1 8/8 (`docs/RACE_MATRIX.md`); T2 done except the clean-machine restore (signed build); T3 measured on one Mac and bounded (`docs/SUPPORT_ENVELOPE.md`) | `NewerSchemaRefusalTests`, backup suites, `SupportEnvelopeTests` |
| F5 | Independent adjudication, then a fresh ho10 | **open** — ho9 is a regression set; its rates (rules 1.7 % wrong, Claude 1.5 %, on `f685315c`) fail the ≤1 % gate and do not describe the current code. Protocol and blinded packs prepared (ho9-claude-prev 126 items, ho9-rules-prev 132) | `docs/ADJUDICATION_PROTOCOL.md`, `scripts/casebench/adjudication_pack.py` |
| F6 | Legal and distribution pack | prepared, incl. a supplemental-terms draft for counsel; **owner/counsel decisions open** | `docs/DISTRIBUTION_PACK.md`, `docs/LEGAL_REVIEW_PACK.md`, `docs/legal/SUPPLEMENTAL_TERMS_DRAFT.md` |
| F7 | Pilot, practitioners, release packet | **open** | — |

## Exact blockers

0. ~~**Jobs reopened (F2):** 16 jobs are preparation~~ — **closed 2026-10-29** (release-block directive item 1): each
   deliverable (statement comparison, lineage chart, annotated edition, source-linked questions, figure tracing,
   source families, protected-name exclusion in exports and cloud sends, coding that withholds from production,
   analysis filters, date ranges and gaps, parties with human merges) is built, with its acceptance scenario and
   rules (`JobAcceptanceScenarioTests`, `JobDeliverableTests`; FINAL_BRIEF_EXECUTION §E2). Signed-build journeys
   and practitioner review of each remain under 3 and 4 below.
1. **Bench re-run (in Terminal):** benign accuracy on the corrected build is not re-measured. The driver is
   versioned: `scripts/casebench/heldout.sh ho9-chron --tag -b6` (regression), then adjudication
   (`docs/ADJUDICATION_PROTOCOL.md`), then `--generate <new seed>` for ho10, once. The agent's session
   cannot launch test runners ("Pseudo Terminal Setup Error, Errno 1"); a Terminal session on this Mac can.

2. **Accuracy (F5):** independent adjudication of the bench answers, then one run on a fresh held-out
   set (ho10), never tuned on. The wrong-answer rate must be ≤1 %. It was measured above that on
   ho9 on earlier code; the current code is not measured.
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
