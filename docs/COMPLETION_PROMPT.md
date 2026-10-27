# Completion prompt — Investigations Made Easy (kalsmritikosh)

Paste everything below the line into a new agent session. It is written so that nothing discussed
so far is lost, nothing is left to the agent's imagination, and "done" is decided by measurements,
not by the agent's opinion.

---

## 0. Who you are working for, and the one rule above all

You are completing **Investigations Made Easy** (code name kalsmritikosh), a macOS app that takes
an investigator's whole archive (documents, PDFs, scans, emails, mailboxes, spreadsheets, audio
transcripts) and answers questions about it **only from the evidence, with a citation for every
fact, or says plainly that the documents do not give the answer**. It organises a case; it never
"solves" one. It must never state anything the documents do not support — a wrong answer is worse
than no answer.

Read first, in this order, and obey them: `CLAUDE.md`; the memory index `MEMORY.md` and the files
it marks READ FIRST; `docs/CLOSED_CASE_SIMULATION.md`; `docs/INVESTIGATIONS_MADE_EASY_TODO.md`;
`release/APP_STORE_LISTING.md`. Where they disagree, CLAUDE.md's authority chain decides. If a
task below conflicts with the code or with those documents, **stop and report the conflict** —
do not improvise.

Work autonomously, in the order of section 6. Do not ask for permission between steps. Ask the
owner only for the items in section 7 (things only the owner can do).

## 1. Locked product decisions (do not reopen)

1. **Evidence only.** Every value answer (a date, a name, a count, an office, a sentence) is read
   from the documents by the evidence engine and cited. AI models never rewrite a value. Models may
   write *accounts* (what happened / why / summaries) only from cited evidence.
2. **Understanding cascade, cheapest first** (owner decision 2026-10-25):
   1. **Rules** — free, instant, nothing sent. Includes the courtesy-wrapper normaliser.
   2. **Apple's on-device model** — free, nothing leaves the Mac — only for wordings the rules miss.
   3. **The cloud model (Claude via the person's key, or via our subscription server)** — last, only in
      Online mode, only the *question and the case's field names / canonical forms*, never a
      document. It only chooses a field or a canonical form; the answer is still read from the
      documents.
   Measured: on 1,088 held-out questions Claude chose the right field 96.1 % of the time vs 72.1 % for
   Apple's model; on Claude-written rewordings of real closed cases the cloud step lifted the NTSB set
   from 81.8 % to 95.7 %. Keep measuring both; never let a model choose something the records lack.
3. **Fully private means no model at all**, not even on-device. Online mode is a separate, explicit
   opt-in with consent screen, masking and a daily limit.
4. **English only for v1.** Multilingual is v2 (bge-m3), not translate-to-English.
5. **Transcription** is Apple on-device speech recognition (not Whisper). The app transcribes what
   is said; it does not understand video. Marketing copy must say so.
6. **Commercial model**: App Store app with an in-app subscription; Online features go through **our
   own small server** (e.g. a Cloudflare Worker) that holds the Anthropic key, checks the App Store
   subscription (App Store Server API), enforces per-user daily limits, calls Claude Haiku for
   understanding, keeps no record of questions. The key is **never** in the app binary. Bring-your-
   own-key stays available. Guidelines that apply: 3.1.1 (IAP), 5.1.1 and 5.1.2 (disclose and get
   permission before any personal data goes to a third-party AI). The App Store privacy label and the
   listing must match exactly what is sent.
7. Architecture invariants in CLAUDE.md are absolute: capability discipline (no model names in
   Experts/Brain/Knowledge/Retrieval/Ingestion), one ledger behind `actor Database`, experts are
   stateless, formats die at ingestion, network only in Routing/Providers through the network helper,
   versioned SAVEPOINT migrations only, no `try!`/`fatalError` outside UI, AtlasLog/KalsmritikoshLog in
   every catch, no third-party dependencies without an explicit task, pbxproj edits are the owner's.

## 2. What exists (do not rebuild)

- Evidence engine with slot law, gates (date, office, count, yes/no, absent attribute, conclusion,
  record line), the engine split, ProceedingEventExtractor/ProceedingAnswerer (a person's
  proceeding across documents), EmailHeaderAnswerer (+ ledger email lookup), QuestionCanonicalizer
  (normaliser + rewriter cascade, on-device and cloud rewriters), QuestionUnderstanding (field and
  gate-intent interpreter cascade).
- Case benches under `scripts/casebench/` and `~/CaseBench/`: fixed-wording, wide, held-out wording
  sets ai200h…h5; closed-case simulations (chronology.py, ntsb_hidden.py, enron.py) with fresh draws
  (`--seed --skip-keys`); Claude rewordings (paraphrase.py); Claude failure judge (judge.py);
  scorers score.py / ccsscore.py / widescore.py / bykind.py. The 10k-per-category run (e2e10k).
- The owner's Claude key is at `~/CaseBench/.anthropic-key` (mode 600, outside the repo). Use it only
  for bench measurement, rewording generation and judging. Never commit it, never send owner data.

## 3. How "done" is measured (the acceptance gate)

A number counts only if it comes from a run on **cases and wordings not used while fixing** (a
fresh draw with a new seed, and fresh Claude rewordings). Report every number with its build
hash, the mode (Fully private / Gated on-device / Online with Claude), n, right %, wrong %.

| Gate | Target | Measured on |
|---|---|---|
| Wrong answers (states something the documents don't support) | **≤ 1 %** in every set and mode | all sets below |
| Right (correct or honest refusal) — fixed wordings | ≥ 97 % | ai200 |
| Right — fresh held-out wordings, Fully private | ≥ 90 % | a new ai200h6 (write it first, never tune on it) |
| Right — Claude rewordings of fresh closed cases, Online | ≥ 95 % per set | chronology, NTSB-withheld, Enron |
| Right — same, Fully private | ≥ 88 % per set | same |
| Conclusion withheld: a narrative passed off as a finding | **0** | NTSB-withheld |
| A step / email / record the documents don't contain | 100 % refused | absent controls |
| Questions reaching any model | ≤ 25 % (Online), report the cost per 1,000 questions | Online runs |
| 10k-per-category run | finished, published, ≤ 1 % wrong | e2e10k |
| Full test target | green locally and on CI (two-run protocol) | CI |

Use `judge.py` on every miss of every final run and publish the cause histogram. A miss judged
"bench" must be fixed in the bench (with the reason), not hidden.

## 4. Open gaps to close (from the closed-case simulation; see that document for evidence)

Close each, add a unit test with the real failing text, rerun the affected set, update the table.

1. **O-1 "What was X charged with?"** (70–73 %): an offence extractor — counts, statute, description
   — from charging, plea and verdict sentences; normalise ("seven counts of wire fraud").
2. **O-2 Sentence terms** (73–82 %): a sentence-term grammar ("to serve 87 months", "time served",
   "probation", life, consecutive/concurrent, two terms); several sentences shown as a list.
3. **O-3 Email counts over everything in scope** — done via EmailParticipantRepository; verify on
   the Enron fresh draw that counts are exact; add Cc/Bcc and display-name aliases (keep X-From /
   X-To display names in the email loader's header block — O-8).
4. **O-4 Which office** (72–89 %): list every office the release credits; the heading line; "prosecuted
   by … for the … District of …"; never an office another case's release names.
5. **O-5 Date conflicts** (record page vs narrative, UTC vs local): surface both as a conflict, per the
   conflict rule — never pick one silently.
6. **O-6 Gap analysis** found 0 gaps in 200 prosecutions: add procedural-gap rules (a charge and a
   sentence but no plea or verdict; a sentencing with no date; an arrest with no charge).
7. **O-7 Pronouns** ("He was sentenced …"): a bounded coreference pass within a document about one
   person.
8. **O-9 Exact-subject retrieval** for long or punctuated subjects — done via the ledger lookup; verify.
9. **O-10 Measure every mode**: Fully private, Gated (Apple on-device), Online (Claude) on all sets.
10. **Email timezone**: answer the header's own day; when asked "on what date", say the time zone.
11. **Absent controls for organisation senders** and records never ingested.
12. **Conflicts across documents** generally: two releases giving different sentences or dates for
    one person must be shown as a conflict with both citations.
13. **Wide question variety per case kind** (yes/no, absent attribute, rephrase) on the closed-case
    sets, not just their fixed question types.
14. **Investigation workflow**: the case workspace answers, contradictions, gaps and findings export
    must reach the same numbers as archive-wide asks; report both.

## 5. Product completion items (beyond accuracy)

1. **Online mode for real users**: Settings flow to add a key; the consent screen states exactly what
   is sent; masking on; daily limit. **Corrected 2026-10-27 (final brief §3.5):** Online has two
   separate capabilities with their own switches. *Understand any wording* sends only the question and
   field/form names, never documents. *Let your cloud AI read the documents about a person* (module
   `onlineRecordReading`, OFF by default) sends up to eight document excerpts (≤ 7,000 characters each)
   naming that person — privileged material is filtered out before the send, every send is previewed
   with its exact text, destination and size, needs consent, and is recorded; answers are shown only
   when their quote verifies word for word. "Never documents" applies to the first capability only.
2. **SUPERSEDED (2026-10-27): no subscription server.** The authoritative commercial decision is
   SHIP_DECISIONS 2026-10-18: a free 14-day trial and one $79 non-consumable unlock, no subscription
   (`Kalsmritikosh/App/Store/Purchase.swift`). Nothing below is built; a shared online service would
   need a new owner decision with its own authentication, server-held key, purchase verification,
   limits, billing, data policy and outage behaviour. Original proposal kept for the record:
   **Subscription server** (separate small repo or `server/` folder, owner approval before
   deploying): App Store Server API receipt check, per-user daily limit, Anthropic call, no logging of
   question text, spend cap, health check. App side: a provider kind "Investigations Made Easy
   service" beside bring-your-own-key; StoreKit 2 subscription product; restore purchases.
3. **Privacy**: privacy policy text, App Store privacy label, listing copy — Fully private / Online
   distinctions stated in plain words; "nothing leaves your Mac" only for the offline modes.
4. **Owner-visible proof**: a "How this was answered" line on every answer (rules / on-device /
   cloud; the canonical question used; citations).
5. **Docs**: user guide sections for closed-case workflows (person timeline, email who-knew-what,
   records), and what the app will not do (solve cases, understand video, guess).

## 6. Order of work

1. Build green; run `ci/guards/run-all.sh`; run every suite touching what you change (grep the tests
   for the changed types); keep the main branch frozen; work on a feature branch.
2. Write the fresh honest sets first (ai200h6 wordings; closed-case fresh draws with a new seed and
   `--skip-keys`; Claude rewordings of them). Run all modes once and record the baseline. Never read
   these sets' failures while fixing — fix from the older sets and from judge.py output on them.
3. Close section 4 in order of how many answers each gap costs (use judge.py's histogram).
4. Section 5 items 1, 3, 4, 5 (app side). Section 5 item 2 (server) up to "ready to deploy".
5. Final runs of every gate in section 3 on a fresh build; publish `docs/CLOSED_CASE_SIMULATION.md`
   and a release report with every number, build hash and mode.
6. Two-run CI protocol: one stacked commit set → one PR-head CI → merge → one main CI. Batch pushes
   (GitHub Actions minutes are limited). Commit messages explain the failure that motivated each
   change; end them with the Co-Authored-By line.

## 7. Only the owner can do these (ask once, then continue with everything else)

- Rotate the Anthropic key pasted in chat; create an organisation API key for the product.
- Create the Cloudflare (or other) account and deploy the server you prepared.
- App Store Connect: the subscription product, pricing, privacy label, screenshots, review notes.
- Xcode project changes (pbxproj), signing, notarisation, the `.storekit` scheme selection.
- Press "Ask" in the real app on the real archive for the final GUI check.

## 8. Reporting rules

- Never say "done", "fixed" or "verified" without the run that shows it; give the numbers.
- Say what was not run and why. A flaky test is reported with its rerun evidence.
- Keep the gap list current: every gap is either closed with a measurement or still listed.
