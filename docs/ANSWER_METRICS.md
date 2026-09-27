# Answer metrics — the owner-copy acceptance set

_Measured 2026-09-27 on a copy of the owner's ledger (`~/Downloads/kalsmritikosh-pipeline-audit-2026-09-24/knowledge.sqlite`, 426 documents)
with `OwnerLedgerAnswerProbeTests` (local only — it needs the owner's copy; kept as `.txt` in the audit folder).
Each run boots a fresh copy, lets the background refresh converge, rebuilds the derived layers, then asks
through the real answer path (`MasterBrain.answerWithDiagnostics`). "Model calls" counts on-device AI calls._

**How to re-measure:** copy `OwnerLedgerAnswerProbeTests.swift.txt` into `KalsmritikoshTests/` as `.swift`, run it,
read the `=====ANSWER PROBE=====` block, delete the file again. Never commit it.

## Before → after

| # | Question | Before (baseline, 09:xx) | After (14:40 run) | Verdict |
|---|---|---|---|---|
| 1 | What is the status of patent application 202331019665? | Quoted a filing-form line; missed the grant · 287 s · 1 call | "Current status: granted — patent granted on 28 November 2024", earlier milestones listed · 0.0 s · 0 calls | ✅ |
| 2 | What happened at the hearing for application 202331019665? | Archive-wide history about a privacy-policy email · 1 call | 5 dated hearing records for the application, cited · 0.0 s · 0 calls | ✅ |
| 3 | Who is Gopinath and what did we discuss? | Dump of raw header passages · 38 s | Gopinath D <gopinath@iiprd.com>, the one real email (30 Nov 2022, "Patent requirement") · 0.0 s | ✅ |
| 4 | How much did I pay Khurana & Khurana? | Fact dump with junk, no total · 63–343 s | 3 cited UPI payments: ₹10,000 + ₹20,000 + ₹3,800 = ₹33,800 · 0.0 s | ✅ |
| 5 | What jobs have I held and at which companies? | Refused | Employers + roles from the owner's own records (owner resolved by address evidence) · 0.0 s | ✅ |
| 6 | What happened in 2024? | Sep–Dec only, capped at 2 chapters · 33–340 s · 2 calls | 118 dated records across 8 months, milestones first · 0.0 s | ✅ |
| 7 | What was decided in Case No. 73591248-ZQX? (control) | Correct refusal | Correct refusal | ✅ |
| 8 | Who drafted the claims? | The examiner's instruction ("shall be drafted afresh") · 311 s | The first-person drafting reports' senders (Khurana & Khurana staff), quoted · 0.0 s | ✅ |
| 9 | When was the patent granted? | List padded with export-listing lines | "Patent granted on 28 November 2024." · 0.0 s | ✅ |
| 10 | How many hearings were there? | "8 hearings" (counted notices, a reminder, a payment) | "2 hearings" · via the pipeline, 1 call | ✅ (slow cold) |
| 11 | Who is the applicant of the patent? | "Applicant: Shirshendu Sasmal." | Slot law (P2.3): "Applicant: Shirshendu Sasmal." · 0.80 · 1 citation · 12 s (was 0.30–0.80 with the model) | ✅ |
| 12 | Is the patent granted? | "Yes — intimation of grant…" | "Yes — patent granted on 28 November 2024." · 24 s | ✅ |

**Totals:** answered correctly 12/12 (baseline 3/12 fully right). Deterministic, zero-model answers: 10/12.
Refusal on the absent subject: 1.0. No answer cites a document outside its subject.

## Module deltas (P2.3, 2026-09-27 — one module off per run)
| Module off | Q1–Q9, Q7 refusal | Q10 | Q11 | Q12 |
|---|---|---|---|---|
| none (3 runs) | identical | 2 hearings | 0.80 slot sentence | yes, granted |
| HyDE expansion | identical | same | 0.40 — model abstained, fact dump | same |
| Corrective re-retrieval | identical | same | 0.30 — prose, also names the agent | same |
| Cross-encoder rerank | identical | same | 0.80 | same |

No module is shown negative; the Q11 swing is the model's. Q11 is now answered by the slot law before the model.

## Known limits (measured, not hidden)
- Q10 and Q12 still go through the general pipeline and pay the on-device model (Q11 makes one query-expansion call); cold in a fresh process the
  first such call took 289 s in the test host (P2.7: HyDE is now deadline-bounded and the model pre-warmed;
  live latency is the owner's measurement).
- Event dates bind to the nearest date in the text: two hearings are dated 5 and 13 Aug where the documents say
  06/08 and 14/08. An extraction-precision item, tracked with the other extraction work.
- The HNSW vector index took ~410 s to build on the copy; vector search falls back to exact search meanwhile.
