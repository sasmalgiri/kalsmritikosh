# Release readiness — Investigations Made Easy v1 (2026-10-28)

**Decision: not ready to release.** The blockers are named below. This page summarises
`docs/FINAL_BRIEF_EXECUTION.md` (the authority) as of `investigations-next`, after the F1–F6
agent-side work.

Testing cadence (agreed with the owner, 2026-10-28):
- each change: the suites it touches, plus the guards;
- each push: the full suite on CI;
- before ship: UI automation, the signed app, journeys and benchmarks.

## Gates

| Phase | Gate | State | Evidence |
|---|---|---|---|
| F0 | One execution record; SHIP_DECISIONS current | done | SHIP_DECISIONS §0, FINAL_BRIEF_EXECUTION |
| F1 | Shared kernel K1–K11 | **done** (unit/integration); one bounded item | K5 studio approvals carry no scope fingerprint (the export re-check covers it); K11 vault encryption is a recorded decision |
| F2 | All 168 jobs produce their intended result | **done to integration** — 20 studio, 97 executor, 51 service, 0 gap | `docs/JOB_CONTRACTS.md`, `docs/JOB_OUTCOME_MATRIX.md`, `JobFamilyExecutorTests` |
| F3 | Nine persona journeys | service level done (`InvestigationCaseSimulationTests`, 9 personas); **UI journeys open** (tier 3) | — |
| F4 | Races, recovery, workload | T1 7/8 + 1 partial (`docs/RACE_MATRIX.md`); T2 done except the clean-machine restore; **T3 support envelope open** (tier 3) | `NewerSchemaRefusalTests`, backup suites |
| F5 | Independent adjudication, then a fresh ho10 | **open** — needs human adjudicators; ho9 is a regression set (rules 96.6 % right / 1.7 % wrong; Claude 97.2 / 1.5); the ≤1 % wrong target is not met | — |
| F6 | Legal and distribution pack | prepared; **owner/counsel decisions open** | `docs/DISTRIBUTION_PACK.md`, `docs/LEGAL_REVIEW_PACK.md` |
| F7 | Pilot, practitioners, release packet | **open** | — |

## Exact blockers

1. **Accuracy (F5):** independent adjudication of the bench answers, then one run on a fresh held-out
   set (ho10), never tuned on. The wrong-answer rate must be ≤1 %. It was measured above that on
   ho9, and K9's guard has not been re-measured.
2. **Signed build (tier 3):**
   - UI journeys for all nine personas;
   - clean-machine install, upgrade and restore;
   - Private-mode no-egress;
   - the Online preview, cancel and privilege behaviour;
   - export-byte and redaction checks;
   - the StoreKit script (`DISTRIBUTION_PACK.md` §6).
3. **Support envelope (T3):** measured on named hardware — files, pages, emails, chunks, bytes,
   memory, disk, p50/p95 latency.
4. **Owner/counsel decisions (F6):**
   - the privacy-label answer;
   - Standard EULA plus supplement;
   - governing law;
   - trademark clearance of the name.
5. **Pilot and practitioner review (F7)**, then the release packet: commit, build and digest; enabled
   scope; job outcomes; limitations; CI results; signed-app results; legal texts; purchase setup;
   recovery instructions.

## Known limitations to state in the release notes

- Rule-based event extraction fires only on marker phrases. A document's dated sentences still reach
  the chronology as "date stated in text", but documents without either produce no chronology rows.
- Job executors produce drafts for a person to review. They never grade, conclude, total across
  currencies or clear anything for disclosure on their own.
- Saved answers that quoted later-erased documents are not purged by case erasure.
- Vault copies of originals rely on FileVault for encryption at rest.
