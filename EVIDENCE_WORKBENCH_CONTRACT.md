# EVIDENCE_WORKBENCH_CONTRACT

**Status: CURRENT.** Created 2026-07-24 (MASTER-001). Scope + safety contract for the Evidence
Workbench / DataLab (Stage 5 of `WHOLE_PROJECT_COMPLETION_PROGRAM.md`). Authority: this file
sits under the program and `SHIP_DECISIONS.md`.

## 0. Porting rule (read first)

Port the **interaction architecture** proven in Datasimplify — layered data, editable cells,
safe parsed formulas, what-if scenarios, annotations, notebook entries, data-quality warnings,
pattern/anomaly views, multi-chart modes, and simple/intermediate/advanced mode separation.

**Do NOT** port Datasimplify's data/provider design. Datasimplify's DataLab fetches external
market data over web APIs. Kalsmritikosh's release contract is **fully local, no network
provider** (`SHIP_DECISIONS.md`). The workbench consumes ONLY the local evidence ledger and
user-entered scenario data. Do not copy crypto-specific code; do not add a network data source.
Reuse the tokenizer/parser *pattern* (no `eval`), not Datasimplify's symbols.

## 1. Canonical isolation (non-negotiable)

Canonical evidence is **read-only** to the workbench. Every workbench action produces a scenario
overlay, proposed correction, classification, calculated value, or annotation — never a mutation
of canonical Claims/events/entities/evidence. Promotion to canonical requires an explicit
reviewed action, exactly as in `WHOLE_PROJECT_COMPLETION_PROGRAM.md` §2.

Every cell knows its kind:
```
source value · deterministic calculation · user-entered scenario value · model proposal · reviewed value
```
Every derived value stores: `formula/transformation · input cell IDs · engine version · output`.

## 2. LAB-001 — Dataset model

```
WorkbenchDataset · WorkbenchField · WorkbenchRow · WorkbenchCell
WorkbenchSourceBinding · WorkbenchTransformation · WorkbenchScenario
WorkbenchNotebook · WorkbenchSavedView
```
Dataset sources: selected Claims; events; entities; evidence blocks; contradictions; gaps;
tasks; deadlines; transactions; imported spreadsheet/table rows; query results; user-created
scenario rows. A `WorkbenchSourceBinding` ties each source-derived cell back to its canonical
origin (Claim/event/block + exact locator) so the Evidence Inspector can open it.

## 3. LAB-002 — Safe transformation engine

Supported transforms: filter; sort; group; count; sum; average; min/max; date difference;
percentage; calculated column; deduplicate; pivot; join; compare; classify; bin; running total;
rolling calculation.

Formulas use a **safe parsed expression language** (tokenizer → parser → evaluator). **No
arbitrary code execution, no `eval`.** Every derived value persists its formula/transformation,
input cell IDs, engine version, and output so results are reproducible and auditable.

## 4. LAB-003 — Scenario & undo

Workbench edits create scenario overlays / proposed corrections / classifications / calculated
values / annotations. Provide: undo; redo; reset; compare-against-source; promote-through-review;
discard. A scenario never silently changes the ledger; promotion is a recorded reviewed action.

## 5. LAB-004 — Shared visual surfaces (reusable native canvases)

Table · Timeline · Matrix · Board · Relationship graph · Transaction flow · Chart · Fishbone ·
Five-Whys chain · Map/location view · Document comparison · Evidence wall · Checklist/form ·
Notebook/editor. **Every visual object supports one-action evidence inspection** (open the exact
source/locator behind any element).

## 6. LAB-005 — Data-quality warnings

Generalize Datasimplify's stale-data warning model to evidence quality:
missing values · stale source version · inaccessible source · ambiguous identity · mixed date
precision · unsupported transformation · duplicate source · non-independent corroboration ·
missing custody hash · unresolved contradiction · incomplete workspace scope · unreviewed
scenario values · low OCR confidence · formula-vs-displayed-value discrepancy.

## 7. LAB-006 — Modes (one truth ledger)

- **Simple:** guided presets; no formula editor; limited views; clear explanations; safe
  defaults.
- **Advanced:** custom datasets; formulas; multi-view layouts; methods; scenarios; saved
  templates; detailed provenance; export definitions.

There is **no separate truth mode** — both modes read the same evidence ledger with the same
truth rules.

## 8. LAB gate (Stage 5 acceptance)

A user must be able to:
```
select workspace Claims → build dataset → filter & calculate → create chart/matrix
→ add hypothesis note → run scenario → undo → inspect exact evidence → save view
→ export with a transformation manifest
```
The export manifest lists, for every derived value, its inputs + transformation + engine version,
and every source-bound cell reopens its exact evidence. SensitiveScope (OPS-003) governs what may
appear on screen, in a prompt, in a chart, and in an export.
