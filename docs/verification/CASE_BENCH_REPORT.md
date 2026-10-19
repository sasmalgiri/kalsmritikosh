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
