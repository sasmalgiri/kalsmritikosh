# Case bench report — real cases through the real app

Status: **interim** (2026-10-19). The full run toward 1,000,000 cases is running on the fixed
build (main 130eab3d; shard build notes in `~/CaseBench/results/BUILD-NOTES.txt`); this report is completed from its results. Method: `docs/CASE_BENCH_PLAN.md`.

Every number below is measured, in the evidence-only answer mode ("Fully private (no AI)"),
against each publisher's own coded record — never against the app's output.

## 1. Before and after the fixes (same cases)

1,500 NTSB aviation investigations, every 50th case asked (n = 30 per question; 6 for
fatalities). Baseline = the app before the case-bench fixes.

| Question | Before | After |
|---|---|---|
| When did it happen? | 7% | **100%** |
| Where? | 80% | **100%** |
| Aircraft involved | 93% | **100%** |
| Probable cause | 37% | **97%** |
| How many killed? | 17% | **100%** |
| Invented answer about a case not in the archive | 1 of 3 | **0** |
| Accident date on the timeline (all 1,500) | 1.3% | 33% (55% on the latest build's probe) |

## 1a. Full NTSB batch — 62,846 investigations (complete)

All 62,846 NTSB aviation investigations with a final narrative and probable cause (1982–present),
every 50th asked (1,257 cases), evidence-only mode, builds 94236056 → 130eab3d (before PR #162's
date-first answers).

| Question | n | Correct | Leads with the value (first 200 chars) |
|---|---|---|---|
| Aircraft involved | 1,257 | 100.0% | 75.5% |
| When did it happen? | 1,257 | 100.0% | 34.4% |
| Where? | 1,257 | 99.9% | 45.1% |
| Probable cause | 1,257 | 98.8% | — |
| How many killed? | 211 | 97.6% | 43.6% |
| Case not in the archive (one per shard) | 126 | **126 refused, 0 invented** | |

Extraction over all 62,846 cases: registrations 98.5%, accident date on the timeline 41.1%,
case number as an entity 12.7% (case numbers are still found through the text, which is what
anchoring uses). Zero ingest errors. 1.3 s per case end to end.

## 1b. Full OSHA batch — 146,483 workplace accident investigations (complete)

Every OSHA accident investigation summary with a narrative of 200+ characters, every 50th asked
(2,930 cases), evidence-only mode, builds 130eab3d → d4a24d2e (before PR #164).

| Question | n | Correct | Leads with the value (first 200 chars) |
|---|---|---|---|
| When did the accident happen? | 2,930 | 100.0% | 41.1% |
| Was anyone killed? | 1,186 | 100.0% | 99.5% |
| How many employees were hurt? | 2,930 | 99.5% | 98.8% |
| What happened? | 2,930 | 67.5% | — |
| Case not in the archive (one per shard) | 293 | **293 refused, 0 invented** | |

Gap found: "What happened?" was refused for 27.6% of cases ("no dated events … no history to
tell") although the summary tells it in prose. Root cause: the history path refused when no
incident event was extracted, and the incident extractor missed harm told sentences after the
narrative's dated opener. Fixed in PR #164 — on the 24 refused cases re-run: "what happened"
0% → 100% correct, date answers leading with the date 12.5% → 79%.

Extraction over all 146,483 cases: inspection numbers 100%, accident date on the timeline
71.9%, summary number as an entity 84.6%. Zero ingest errors.

## 1c. Full-power AI sample — 190 cases, 19 investigation categories (2026-10-21 → 23)

Apple's on-device model ("AFM 3 Core Advanced") answering, every knowledge and product module on,
every question asked, every second case worked as an investigation. 10 fresh cases per category
(the cases used to diagnose were not in the measured set); 621 answers; the model completed a
generation for 96% of them; median 25 s per answer (78 s at the 90th percentile).

Round 1 was the build before this program; rounds 2 and 3 after the fixes listed below.

| Category | Round 1 | Round 2 | Round 3 |
|---|---|---|---|
| court-civil | 48.2% | 44.6% | 42.9% |
| court-criminal | 66.7% | 68.5% | 75.9% |
| doj-cybercrime | 44.4% | 48.1% | 48.1% |
| doj-drug-trafficking | 42.3% | 38.5% | 50.0% |
| doj-environmental-crime | 25.9% | 40.7% | 48.1% |
| doj-financial-fraud | 20.0% | 28.0% | 28.0% |
| doj-health-care-and-pharma-fraud | 32.0% | 32.0% | 52.0% |
| doj-immigration-crime | 27.3% | 36.4% | 50.0% |
| doj-other-federal-crime | 38.5% | 42.3% | 38.5% |
| doj-police-misconduct | 12.0% | 16.0% | 16.0% |
| doj-public-corruption | 44.0% | 52.0% | 52.0% |
| doj-tax-crime | 14.8% | 14.8% | 37.0% |
| doj-violent-crime | 28.0% | 28.0% | 32.0% |
| fda-device-recall | 60.0% | 95.0% | 95.0% |
| fda-drug-recall | 47.5% | 90.0% | 92.5% |
| fda-food-recall | 60.0% | 97.5% | 100.0% |
| nhtsa-defect | 5.0% | 55.0% | 85.0% |
| ntsb-aviation | 65.0% | 72.5% | 87.5% |
| osha-workplace | 58.1% | 54.8% | 83.9% |
| **All 621 answers** | **41.9%** | **54.6%** | **62.8%** |

**Investigation workflow (round 3, 95 cases):** case opened over its own documents 95/95; every
source version hashed in custody (142/142); findings report built 94/95, all 1,389 citations inside
the case; the case's key date in its findings 35/39; questions asked inside the case 64.7% right.

**What the AI got wrong, and what was fixed.** With every answer composed by the model, round 1
answered *worse* than the evidence-only path: it rewrote exact ledger values ("E.D. Pa." →
"Supreme Court of Pennsylvania"), restated the question as the answer, and re-summarised the same
subjects on every ingest (157 model calls in 25 s). Fixes: the AI rewrite may not change a labelled
value, drop the asked value, or say the question back; value questions reach the field on file
(classification, recalling firm, component, manufacturer, date opened, Location) and take the
slot-law door before the experts; account questions quote the matter's lead; numbered entries are
counted; headings give way to their text; split court captions give docket, court and date; a
crash on case-changing lower-casing; memory distillation only when events change.

**Known limits of this benchmark.** DOJ press releases mostly do not print the announcing office or
the date ("today"), so the honest answer is a refusal; vague answers there are scored unsupported.
"What happened" is scored by word overlap with the release's lead and undercounts correct
paraphrases. Civil court dockets and outcomes remain the weakest questions (docket answers in a
shared multi-case ledger were dumps under the model — fixed in f824e864 after round 3).

## 2. By persona (probe: 20 cases per source, every question asked, latest build)

| Persona (source) | Question | Correct |
|---|---|---|
| Investigator (NTSB) | date / place / aircraft / cause / fatalities | 100% each |
| Compliance (OSHA) | date / injured / fatal | 100% each |
| Compliance (OSHA) | "What happened in investigation X?" | 75% (0% before) |
| Lawyer (court decisions) | parties | 100% |
| Lawyer | which court decided | 100% (44% before) |
| Lawyer | author of the opinion | 78–83% (72% before) |
| Lawyer | decision date | 78% (11% before) |
| Lawyer | docket number | 44–50% (0% before) |
| Lawyer | outcome (affirmed / reversed …) | 40% (0% before; 1 of the 5 expected values is a converter error) |
| All | invented answers about a case not in the archive | 0 of 5 (3 of 5 before) |

## 3. Gaps found, root causes, fixes

| # | Gap | Root cause | Status |
|---|---|---|---|
| 1 | Answers about a named case came from other cases | Retrieval ranked the question's shape; nothing anchored on the case number or caption | Fixed — `IdentifierAnchoredRetriever` (reference or caption → that case's documents) |
| 2 | Cited answers about cases that do not exist | Absent-subject gate missed interleaved numbers (MIA08MA051) and captions | Fixed — interleaved references + absent party words refuse |
| 3 | No incident chronology | Event extractor knew only business milestones | Fixed — `incidentOccurred` events (accident, injury, death, crime + full date) |
| 4 | Case numbers became field names ("ntsbsea08la057 = factual narrative") | Title lines with a dash read as `Label — value` | Fixed — a label carrying a reference is a title |
| 5 | "Inspection number", "Docket No.", "Event date" stayed plain text | Undeclared fields had no shape | Fixed — field names imply identifier/date shape |
| 6 | US docket numbers and decision dates never captured | Legal pack knew Indian caption forms only | Fixed — "No. 92-5255", "Decided …", caption date line, flowing-text dockets |
| 7 | "No document carries a decision date" about a document that does | Facts rode only on surfaced passages; anchored recall added passages without facts | Fixed — document facts ride with surfaced documents; anchored results re-attach facts |
| 8 | Court name wrong or missing | No US caption court rule; a bare "Supreme Court" in a body counted | Fixed — caption court names with a jurisdiction |
| 9 | No-AI "what happened" said "No prose available" / "No history found" unrefused | History chapters without prose stated nothing | Fixed — chapters state their events with citations; empty history refuses |
| 10 | Makers and airports typed as people ("person:Piper") | Name tagger's kind taken as is | Fixed — kinds corrected (never dropped) on strong signals |
| 11 | Answer latency grows with the archive (1.25 s → 9 s) | Cross-encoder re-rank per answer; embedder availability re-read the tokenizer vocabulary on every question | Partly fixed — availability cached; re-rank cost open |
| 12 | Outcome questions 0% | Normalization joined headings to the disposition sentence ("CONCLUSION The order … affirmed"); verb-less "Judgment affirmed."; a CITED caption pulled another decision's outcome | Fixed — 40%; caption anchoring prefers the document that opens with the caption |
| 13 | Facts from different documents with the same file name collide ("conflicting case numbers") | A fact's subject is the file NAME | Fixed — a title-like first line names the document first (PR #160) |
| 16 | Ingest slowed as the archive grew (180 s → 1,100 s per 500 cases) | Every ingest re-saved every claim of every subject it touched; hub subjects (an agency, the owner's own name) made it quadratic | Fixed — only the new file's claims are projected (PR #161); claim projection fell from ~75% of ingest samples to ~5% |
| 14 | Answer text repeats document titles | Composer echoes block headings | Open |
| 15 | Incident facts have no ontology type | FactType has no Incident | Open |

Data finding worth surfacing in the product: OSHA accident 200072106 — coded event date
3 Dec 2003, inspector's narrative "December 03, 2004". The ledger now holds both; the
contradiction view should show them side by side.

## 4. Not covered at scale

Individual (the CFPB bulk file no longer carries narratives), Journalist and Researcher need the
small start-to-end case packs in `docs/INVESTIGATION_FOCUS_TODO.md` §4. AI-mode answers are a
sample tier (78 s per case on one Mac).

## 5. Full run

Pending — see `tail ~/CaseBench/full-run.log`; scored with
`python3 scripts/casebench/score.py ~/CaseBench/cases ~/CaseBench/results`.
