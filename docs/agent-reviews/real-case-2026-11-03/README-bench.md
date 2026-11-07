# Real solved cases — app-only investigators vs document-reading baselines

Six real, closed matters with a known outcome, each packed as an archive of real public records.
Investigator agents work a case **only through the app** (its test harness, `round.sh`) from a
starting brief; baseline agents read the case documents directly; a judge compares both with the
sealed key (the real outcome, derived from the records and quoted verbatim).

## The six cases

| case | source | documents | formats | why it is a real solved case |
|---|---|---|---|---|
| `rc-a-upfront-fee` | DOJ, USAO District of New Jersey, 2017–2023 | 5 releases: complaint → superseding indictment → jury verdict → two sentencing releases | PDF | Four defendants in a $1M advance-fee (standby letter of credit) wire-fraud conspiracy; three convicted at trial and sentenced (6 yrs, 3 yrs, 45 months); the fourth's outcome is not on file |
| `rc-b-hutchins` | DOJ, USAO Western District of New York, 2014–2026 | 8 releases: 4 on John L. Hutchins (COVID-relief loan fraud, plea, 14 months) + 3 on Patricia Hutchins (different person, PPP fraud, 16 months) + 1 on William Hutchins (cocaine, 37 months) | PDF | A finished prosecution followed to sentence, with same-surname, same-district, same-offence look-alikes as distractors |
| `rc-c-ntsb-moncks-corner` | NTSB ERA15MA259 (avall.mdb) | coded record page, factual narrative, analysis — probable cause withheld | TXT, PDF | The July 7, 2015 Cessna 150M / USAF F-16 midair collision; NTSB's probable cause (approach controller's failure to resolve the conflict; see-and-avoid limits contributing) is in the key only |
| `rc-d-enron-watkins` | CMU Enron Email Dataset (FERC) — mailboxes of Rick Buy, Kenneth Lay, Mark Haedicke, Chris Dorland | 60 messages, byte for byte: 12 on the episode (incl. look-alikes), 48 unrelated | EML | Sherron Watkins's 2001 accounting warning (Raptor/Condor/LJM): her Aug 14 e-mail to Buy, the August letter to Lay, the Aug 22 review with Lay, the Oct 24 forward to Lay, the Oct 30 note to Legal, the Nov 8 restatement |
| `rc-e-fda-bluebell` | openFDA food enforcement records | 7 recall-event records: Blue Bell 2015 Listeria (286 products), 5 later Blue Bell recalls, Jeni's 2015 Listeria recall (look-alike) | TXT | The 2015 Blue Bell Creameries Class I Listeria recall, initiated Mar 13 2015, terminated Nov 3 2016; later events separate (2016 supplier cookie dough, allergen/label/foreign-material recalls) |
| `rc-f-logan-arson` | DOJ, USAO Southern District of West Virginia, 2013–2014 | 5 releases: indictment → pleas → insurance agent's plea → two sentencing releases | scanned (image-only) PDF, DOCX, EML, PDF | Logan, WV arson-for-insurance ring: five defendants with distinct roles, all pleaded, sentenced 22 months – 7 yrs 3 months; releases disagree on the payment ($75k vs $50k), who spread the fuel, which camera filmed it |

The prosecutions (A, B, F) are outside every earlier bench set (`~/CaseBench/skip-chron` and all
other chronology truth files: 1,620 defendants excluded); the NTSB case is outside the tuned
NTSB sets (ccs/fresh/para-ntsb, probes, ai200*).

## Layout

- `briefs/<case>.md` — what an investigator receives at the start: the allegation or question and the
  archive's description; never the outcome.
- `packs/<case>/` — the case documents the app ingests. **Sealed from investigator agents.**
- `keys/<case>.json` — **sealed**: `real_outcome`, 10–15 `key_facts` (each with the document and a
  verbatim supporting sentence; Enron facts also carry Message-ID and date), `traps` (look-alikes,
  misleading passages, contradictions), `must_not_conclude`. `keys/sources/` maps every pack file to
  its raw record (DOJ page/line + URL, mdb table/field, maildir path, openFDA event).
- `runs/<case>/<round>/answers.md` — the app's output for one round.
- `tools/build_packs.py` (rebuild the packs from `~/CaseBench/raw`, seeded, deterministic),
  `tools/make_keys.py` (write the keys; fails if any quote is not verbatim in its document),
  `tools/answers_md.py` (results → answers.md). `work/` holds scratch (indexes, document texts) — sealed too.

## round.sh

    ~/CaseBench/realcase/round.sh CASE ROUND_NAME QUESTIONS_FILE      # one question per line; '#' lines ignored

1. Takes the lock `~/CaseBench/realcase/.lock` (waits while another round runs — one test host at a
   time; a lock whose process is dead and has no job loaded is cleared), refuses below 11 GB free
   (`df -g ~`; Vision OCR fails on a full disk), refuses if a `casebench.rc-*` job is still loaded or
   the round already exists (`FORCE=1` to redo).
2. Builds a one-case shard `runs/<case>/<round>/shard/realcase/shard-00000/` — the pack's documents
   hard-linked into `<case>/` (no copy; falls back to symlinks) and `truth.jsonl` with the questions as
   `q01…`.
3. Writes `job.sh` and submits it with `launchctl submit -l casebench.rc-<case>-<round>`: env
   `DEVELOPER_DIR`, `TEST_RUNNER_CASEBENCH_FULL=1` (every module on), `…_ASK_EVERY=1`,
   `…_WORKFLOW_EVERY=1`, `NOAI=1` (rules path, the app's default), running
   `DD=~/CaseBench/dd-final bash scripts/casebench/run.sh <shard> <results> 1 1` from the clean worktree
   `~/CaseBench/src-wt-c3e8c5b0` (commit c3e8c5b0). The job unloads itself when finished (a submitted
   job is otherwise relaunched).
4. Polls `done` (timeout `TIMEOUT_MIN`, default 30), then writes `answers.md`: documents ingested
   (chunks/entities/events/errors), every question's answer body, refused flag, confidence, cited
   documents and cited passages — first over the whole archive (Ask), then inside the case opened over
   its own documents — and the workflow block (custody, contradictions, gaps, findings text). The top
   carries `INVALID: OCR failed` if any document error mentions text recognition, `INCOMPLETE` on a
   timeout/harness failure, `NO RESULT` if nothing came back. Logs: `run.log`, `results/.workers/w0.log`.

Each round is a fresh ledger: the app keeps nothing between rounds, so an investigator's later
questions must be sent as a new round (all earlier questions may be repeated in it).

## Rules for agents

- **Investigator agents may read ONLY `briefs/<case>.md` and `runs/<case>/*/answers.md`** (and write
  question files and their own notes). They must never open `packs/`, `keys/`, `work/`, `tools/`
  output, the `shard/` or `results/` folders of a run, or the raw data in `~/CaseBench/raw`.
- Baseline agents read `briefs/<case>.md` and the documents in `packs/<case>/` — never `keys/` or `work/`.
- The judge reads everything, scores each final report against `keys/<case>.json`: key facts found,
  traps avoided, `must_not_conclude` respected, every claim traceable to a document.
