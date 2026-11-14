# AGENT REVIEW — not counsel, practitioners or users (owner direction 2026-11-01)

- **Reviewer:** Claude agent, standing in for counsel, practitioners and the user-evaluation lead. This is not legal
  advice, not a practitioner's sign-off and not a user study.
- **Date:** 2026-11-02
- **Candidate:** `f766b0357b18b7efd0e3ce43781bbf1cec35a512`. `git diff f766b035 HEAD -- Kalsmritikosh` is empty, so the
  line numbers below are the same in the working tree.
- **Baseline:** legal-privacy.md (81cf335f), the three practitioner reviews (81cf335f), re-review-2026-11-02.md
  (78e6d00d, fixed in a0500628) and user-evaluation-2026-11-02.md (f0bb8bfd, fixed in d555e1a3 … 4bd25660).
- **Method:**
  - Read-only reading of `git diff a0500628 f766b035 -- Kalsmritikosh` (17 files) and of the current code.
  - The a0500628 practitioner fixes were re-checked in the code, since no review had verified them yet.
  - The new `StateQuestionAnswerer` regexes were replayed in a standalone Python script with the same patterns.
  - No build, Swift test run or UI session was performed.

## Verdicts

| Area | Verdict |
|---|---|
| 1. Legal / privacy | **PASS WITH CONDITIONS** |
| 2. Practitioner | **FAIL** (one blocker: the protected-identity export promise; one answer-path blocker shared with area 3) |
| 3. User evaluation | **FAIL** (the M3 fix gives an unsupported "Yes"); everything else PASS WITH CONDITIONS |
| 4. Accuracy declaration | **NOT DECLARED** (as expected) |

---

## 1. Legal / privacy — PASS WITH CONDITIONS

No legal document changed between a0500628 and HEAD (`git diff --stat` covers privacy.html, terms.html, the sites,
support.html, release/, relay/, PrivacyInfo.xcprivacy, LegalNotice.swift and App/Store: only `docs/USER_MANUAL.md`
changed). The earlier findings hold as recorded.

| Item | Status | Evidence |
|---|---|---|
| B1 "no server / nothing uploaded" | **HOLDS** | Every remaining instance is qualified ("unless you choose Online mode"): `docs/index.html:7,410,452-453,483`, `docs/website/index.html:7,111,115,197`, `docs/support.html:46`. `docs/privacy.html:44` says "no servers that keep your content". |
| B2 Gemini named for recordings | **HOLDS** | `App/Store/Purchase.swift:405` (`aiTerms`), `docs/terms.html:58-62`. |
| B3 18+ | **HOLDS** | `release/APP_STORE_LISTING.md:16`, `docs/privacy.html:148-149`, `docs/terms.html:74`. |
| B4 blocked countries, app == relay | **HOLDS** | `App/Store/AIRegion.swift:28-35` (CHN + 12) = `relay/src/policy.ts:115` (13 alpha-3 codes); the alpha-2 list at `policy.ts:74` maps one to one. |
| B5 "up to 300 … shared monthly capacity" | **HOLDS** in every user-facing place | `UI/PurchaseGate.swift:207,232`, `Purchase.swift:405`, `UI/Help/HelpRegistry.swift:245`, `docs/USER_MANUAL.md:138`, listing `:19,:83`, terms `:58-62` ("a maximum, not a guarantee"). Not user-facing and still unqualified: `relay/README.md:5` and the code comment `Purchase.swift:37`. |
| B6 listing / review notes | **HOLDS** | No change since a0500628. |
| Seller "Shrabani Sasmal" | **HOLDS** | terms (3), privacy (3), support (1), listing (1). App copyright: `project.pbxproj:1062,1123`. No "Eco Sanskriti" remains in the public pages checked. |
| PrivacyInfo.xcprivacy | **HOLDS** | Unchanged since a0500628. |

### New Settings privacy text vs. entitlements — CORRECT

- **What Settings says:** `UI/SettingsView.swift:2523-2524`: "The app itself has no network permission. In Private
  mode — the default — nothing leaves this Mac." It adds that Online mode sends approved requests "through a separate
  sandboxed helper".
- **The entitlements agree:**
  - App: `Kalsmritikosh/Kalsmritikosh.entitlements:25-26` has `network.client` = false. Its build settings set
    `ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO` (`project.pbxproj:1042,1103`).
  - Network helper: `KalsmritikoshNetworkHelper` has `ENABLE_APP_SANDBOX = YES` and outgoing connections YES
    (`project.pbxproj:649-651,696-698`).
  - Share and Clipper extensions: no network.
- **Modules ▸ Connection:** `App/Modules/NoNetworkAttestation.swift:29` says the same thing.
- **The user-evaluation B1 claim:** it was a misreading of the entitlement; the commit message of d555e1a3 records
  that.
- **Wording nit (not a defect):** "Each send is shown to you first" is accurate for AI sends and Online-tools lookups
  (per the help topic "task-online-tools").

### New network calls outside Routing/Providers — NONE

The added lines of `git diff a0500628 f766b035 -- Kalsmritikosh` contain no `URLSession`, `URLRequest`,
`NWConnection`, URL literal or XPC. The new code (StateQuestionAnswerer, Review source viewer, Ask Save) is all local.

### ProtectedExport on the new and changed Ask routes — GATED in code; inventory stale

- **Copy (changed):** `UI/AskView.swift:568-589`. The plain text plus source file names goes through
  `ProtectedExport.prepare` (`:579`). If the protected-identity register is unread or the text is refused, the
  clipboard is left cleared, which fails closed. The file names are inside the gated text.
- **Save answer as text (NEW):** the button at `AskView.swift:591-597`, the menu item at `:743-747`, and the save
  itself at `:836-861`. The question, the answer and the source names are prepared before the panel opens (`:847`).
  A refusal stops the save.
- **Receipt and proof bundle:** `refuseIfPresent: true` (`:815`, `:902`). The receipt is named as such, and its
  panel says what it is for (`:908-909`).

**Condition L-C1 (inventory, must fix before RC freeze).** `docs/OUTPUT_ROUTES_INVENTORY.md` no longer matches the
code:
- (a) It has no row for "Save answer as text".
- (b) Route 20 (`:43`) and the "Known gaps" entry (`:72-74`) still say the Ask copy is "not scrubbed". Route 37 says it
  is.
- (c) It has no row for **Send to DEVONthink** (`App/SendToDevonthink.swift:36-57`). That route writes the question,
  the answer and up to 240 characters of every cited passage to a Markdown file, with no protected-identity check.
  The module is on by default (`App/Modules/ProductModule.swift:279-283`, `ModulePreset.everyone` `:494`). See P-B1.
- (d) It has no row for the AI review sheet's **Copy** (`AskView.swift:1533-1536`), which puts the AI text on the
  clipboard unchecked.

**Carried conditions (unchanged, SHOULD-FIX):**
- S4: the terms "supersede" Apple's EULA; `termsVersion`; governing law and liability cap.
- S6: no postal address; processors and retention not fully covered.
- N6: legal decision docs not marked superseded.
- `documentTermsVersion` was not bumped for the Google wording.
- The guard does not compare the relay's alpha-2 list.
- `relay/README.md:5`.

---

## 2. Practitioner — FAIL (one blocker)

### Earlier blockers: re-checked in the code

| Persona | Blocker | Status at f766b035 | Evidence |
|---|---|---|---|
| Lawyer | Production scoped to one matter | **FIXED** | `UI/LegalProductionView.swift:41-42` (`ids.formIntersection(inScope)`). |
| SIU | External referral needs contrary facts | **FIXED** | `Investigate/SIUReferral.swift:153`. |
| SIU / RES / all | Silent 40 / 200 output caps | **FIXED**, with a wording defect | Limits are 5,000 / 5,000 / 20,000 / 50,000 (`Investigate/StudioDraft.swift:238-243`). Truncation is detected at `:384,:416` and stated at `Personas/JobFamilyExecutors.swift:117-125`. The chronology states the limit too (`Personas/JobExecutors.swift:190`). **Defect (SHOULD-FIX):** the event notice says "only the **first** 50000 were read" (`JobFamilyExecutors.swift:124`), but the query keeps the **newest** (`ORDER BY e.date DESC`, `Storage/…/EventsRepository.swift:114`). The oldest events are the ones dropped. Also, exactly 50,000 events counts as truncated (`StudioDraft.swift:416`). |
| Journalist | Adverse claim needs a reply | **FIXED** | `Investigate/FactCheckMemo.swift:46-48,136`. |
| Journalist | Source-map protection protected a file name | **FIXED** | `confidentialSources` reads only `fields["identity"]` (`Personas/JobDeliverableExecutors.swift:862-871`). The field is at `Personas/JobFields.swift:109`. A confidential source without an identity blocks completion (`JobFields.swift:298-299`). The register is refreshed on save (`Personas/JobResult.swift:173`). |
| Journalist | Unscrubbed export routes | **FIXED for the listed routes**; see P-B1 | Gated: case slice `UI/CaseSliceView.swift:84`, matrix `UI/CrossDocumentMatrixView.swift:171,204`, comparison `UI/StructuredComparisonView.swift:152`, dossier `UI/KnowledgeView.swift:392`, notebook `UI/NotebookView.swift:408`, workspace `UI/WorkspacesView.swift:816,894`, and all four Ask routes. |
| Researcher | Bibliography date | **FIXED** | `JobFields.swift:87,341,349`. |
| Genealogist | Possessive fabricates kinship | **FIXED** | ``\b(?!['’]s\b)`` after the relative (`JobDeliverableExecutors.swift:1001,1005`). |
| Genealogist | Unreviewed rows drawn solid | **FIXED** | Solid only for accepted, sourced rows (`:1063`); unreviewed rows are dotted "not yet reviewed" (`:1064`). |
| Genealogist | No leading word boundary | **NOT FIXED** (now SHOULD-FIX, because the chart is no longer solid for unreviewed rows) | The patterns start with the escaped name, with no `\b` (`:1001,:1005`), and the person filter is a plain substring match (`:1019`). With persons "Asha Rao" and "Pasha Rao" in the case, "Pasha Rao, son of Dev Rao" yields the row "Asha Rao — son of — Dev Rao", stated by a source. Fix: prefix `(?<![\p{L}])` to `ea`, and use word-bounded matching at `:1019`. |
| Individual | "Sensitive details masked" promised, not done | **FIXED** | Emails and phones are masked (`UI/JobResultView.swift:700-701`). The job says exactly that (`Personas/Individual/IndividualPersonaPackage.swift:47`). |
| Individual | Renewal keyword | **FIXED** | Word-bounded regex (`JobFamilyExecutors.swift:177`). "due to", "procedure" and "overdue" no longer match. |

### BLOCKER P-B1: the new Help promises a protection that two default routes do not give

- **The promise:** the user-evaluation B2 fix added the Help topic "Keep a confidential source's name out of
  **everything** you export or send" (`UI/Help/HelpRegistry.swift:267-275`). Its step 3 says: "every report, copy and
  export replaces the name with [PROTECTED SOURCE]" (also `docs/USER_MANUAL.md`).
- **Route 1, Send to DEVONthink** (on by default, in the Ask answer menu at `UI/AskView.swift:753-763`). It writes the
  answer and every cited passage to `$TMPDIR/kalsmritikosh-devonthink/<question>.md` and opens it in DEVONthink or
  Finder. It never calls ProtectedExport (`App/SendToDevonthink.swift:36-57`). The DeepLink URL also carries the quote
  (`:40`).
- **Route 2, AI review Copy:** copies unchecked (`AskView.swift:1533-1536`).
- **Impact:** a journalist who follows the Help and sends an answer quoting a protected source's interview to
  DEVONthink exports the name in clear.
- **Fix:**
  - Run `ProtectedExport.prepare(note)` in `sendToDevonthink` before the write, and refuse on failure. With
    `refuseIfPresent: true` the link quotes need no altering.
  - Gate the AI-review Copy the same way.
  - Either gate the remaining archive-level routes (QueryView CSV, HighlightsView, ConvertView, PDFMarksController, the
    findings export with the register), or reword the Help step to name exactly which routes are protected.
  - Add the rows to the inventory (L-C1).

### Regressions checked from the later changes

- **R-1: StateQuestionAnswerer gives an unsupported Yes. BLOCKER, recorded as U-B1 below.** It also affects every
  persona's archive.
- **R-2: the lenient proceeding parse reroutes civil and billing questions. SHOULD-FIX, condition P-C1.**
  - `("pleading", .pleaded)` (`Brain/ProceedingAnswerer.swift:44`) makes the lawyer's "When was Maria Lopez's
    pleading filed?" a guilty-plea question.
  - Because the documents name her, it returns the refusal "The documents that name Maria Lopez don't record Maria
    Lopez being pleaded guilty." (`:392`), and `MasterBrain.swift:535,2119` keep the normal pipeline from answering.
  - The new last-resort rules (`:154-163`, guarded only by `asksSomethingElse` at `:169-171`) do the same to a
    forensic accountant's "Please pull the date John Carter was charged a late fee" (`.when(.charged)`) and to "the
    record of John Carter's charges on the invoice" (`.whether(.charged)`).
  - Nothing false is stated, but a legitimate question loses its answer and is reframed as criminal.
  - **Fix:** require "guilty" (or a criminal-proceeding word) for "pleading". Give the last-resort rules a negative
    list (fee, invoice, card, account, bill, filed, motion, complaint as a civil filing).
- **R-3: dump detection** (`Brain/EvidenceVerifier.swift:895-905`). A model-free claim equal to a passage head now
  counts as a dump. The quote floor and the honest not-found can then run. This loses recall in the safe direction; I
  found no route by which it states a new fact.
- **R-4: actor-question quote** (`Brain/SentenceQuoteComposer.swift:98-133`). It now needs the question's own verb
  stem: "Who executed …" no longer matches "signed …". This is a recall loss in the safe direction.
- **R-5: OpenFieldExtractor dash split** (`Knowledge/Ontology/OpenFieldExtractor.swift:184,200,231`). This is an
  ingestion-time change, so existing ledgers keep the "amendmentno7" fields until re-ingest. NOTE.
- **R-6: persona and matter restore** (`UI/PersonaJobsView.swift:322-339,352-366`).
  - The restore is limited to `openMatters` (closed or erased matters are not restored).
  - Picking a profession clears the stored matter (`:358`).
  - Writing `kalsmritikosh.persona` only changes the sidebar label (`UI/RootView.swift:917-926`). No `ModulePreset`
    is applied.
  - No cross-matter leak found. **NOTE:** after a relaunch, the last matter reopens silently apart from the "Resumed
    matter" line. Jobs then run in that scope.

---

## 3. User evaluation — FAIL (one blocker); rest PASS WITH CONDITIONS

### BLOCKER U-B1 (M3 fix): "Yes — the documents say invoice 432 was paid" quoting a sentence that says it was not

- **Where:** `Brain/StateQuestionAnswerer.swift:73-86`, used at `Brain/EvidenceVerifier.swift:909-926`.
- **Cause:** `statesOpposite` recognises only "un-", "not …" and "never …" plus a short opposite list. Contractions and
  other negations are therefore not opposites, and `statesState` accepts any clause that contains the state word. The
  patterns were replayed with Python's `re`:

| Clause in the document | Result | Answer shown |
|---|---|---|
| "Invoice 432 hasn't been paid yet" | YES | "Yes — the documents say invoice 432 was paid: “Invoice 432 hasn't been paid yet”" |
| "Invoice 432 wasn’t paid" | YES | (same) |
| "Has invoice 432 been paid?" (an e-mail asking) | YES | (same) |
| "Please confirm whether invoice 432 was paid" | YES | (same) |
| "No one has paid invoice 432" / "Nobody paid invoice 432" | YES | (same) |
| "Invoice 432 was only partially paid" | YES | (arguable) |

- **The answer path:** the answer ships with confidence 0.75, citations, and "Quoted verbatim … no model was
  consulted." This is an unsupported Yes behind the evidence gate.
- **Second defect, conflicts hidden:** when one clause states the state and others state the opposite, the Yes wins
  and the opposite clauses are dropped (`StateQuestionAnswerer.swift:105-111`). This breaks the invariant
  "conflicting evidence is shown … never averaged away".
- **Tests:** `KalsmritikoshTests/UsabilityFixesTests.swift` has no contraction, question or conflict case.
- **Fix:**
  - (a) Treat `n't`/`n’t`, "no one / nobody / never … paid", "has yet to", "partially / partly" as not stating the
    state.
  - (b) Skip interrogative sentences (ending "?") and clauses headed by "whether / if / confirm / ask".
  - (c) When both a stating clause and an opposite clause exist, return a conflict that quotes both.
  - (d) Add those cases to the tests.

### Recorded fixes, checked in code

| Finding | Status | Evidence | Remaining |
|---|---|---|---|
| B1 false privacy text | **FIXED** | `SettingsView.swift:2523-2524` (see area 1) | — |
| B2 how to protect a source | **FIXED (Help exists)** | `HelpRegistry.swift:267-275`. Keywords include confidential, protect, anonymous, redact. | The Help overpromises (P-B1). "hide name" now matches nothing new (the keywords have no "hide" or "name"). |
| B3 contradiction sources unnamed | **FIXED** in Review | `UI/ReviewView.swift:326-353` names each source by file name and opens `SourceViewer` at the claim. | The decision labels still read "Source A preferred" / "Source B preferred" without names (`Core/Models/ReviewVocabularies.swift:30-31`). Findings is still not in the sidebar or Jump-to for "contradiction". Insights was not checked. |
| M1 case names "…" | **FIXED in code** | `UI/CasesView.swift:93` (`.width(min: 200, ideal: 300)`) | Not UI-verified. |
| M2 copy without sources; save hidden | **FIXED** | `AskView.swift:568-597,743-747,836-861,1544-1561` | Not UI-verified. Inventory row missing (L-C1). |
| M3 dumps / badges | **PARTLY**, with a regression | `EvidenceVerifier.swift:895-926`, `SentenceQuoteComposer.swift:98-160`, `OpenFieldExtractor.swift:184-231` | U-B1. The badge rule (one source = "Partially supported") is still open as an owner decision. |
| M4 developer alarms | **FIXED** | Self-check chip DEBUG-only (`SettingsView.swift:147-151`). Model banner hidden when evidence-only (`:159`). AI toggles hidden (`:2405-2429`). Advanced collapsed each time (`:113`). | "Relevance-gated experts" and its "experts" text stay visible outside the guard (`:2431-2435`). |
| M5 sidebar reorders; persona reset | **FIXED in code** | `RootView.swift:1005-1014`, `PersonaJobsView.swift:322-339` | Not UI-verified. The restore is off in the test host, so it is untested. |
| Minor 4 answers listed twice | **FIXED** | `App/AppState.swift:3301-3306` | — |
| Minor 7 (Settings) jargon | **PARTLY** | Move A, T3, HISTORY Phase A, KO and knowledge.sqlite are gone from everyday Settings (`SettingsView.swift:1773,2530-2546`) | "experts" (`:2431-2435`). "KOs" remains in Advanced ▸ Diagnostics (`:437`, developer). The other screens are untouched. |
| Minor 8 persona cards off-screen | **FIXED** | `PersonaJobsView.swift:587-611` (`LazyVGrid`) | — |
| Minor 9 persona label | **FIXED** | `PersonaJobsView.swift:342-351,362-365` | — |

**Still open from the evaluation:**
- Minor 1: Work Center clipped.
- Minor 2: the source sheet highlights the wrong lines.
- Minor 3: names differ between Help, tutorial and app.
- Minor 5: tutorial content vs. what is shown.
- Minor 6: accessibility labels.
- Minor 7: other screens.
- Minor 10: the Siri dialog.
- The B3 residuals.
- The M3 badge policy.
- **Condition U-C1:** a second agent UI run on the candidate build. M1, M4 and M5 are "build only", and P2 and P3 must
  be repeated, since both failed before.

---

## 4. Accuracy declaration (≤ 3 % per path) — NOT DECLARED

- **Where the raise appears:** only internally, in `docs/agent-reviews/accuracy-adjudication-ho20.md:12,237,240` and in
  commit messages.
- **What is still public or binding:**
  - `ci/release-gates.json:77` still says "≤1 % wrong per mode and family".
  - The listing deliberately "quotes no accuracy figures" (`release/APP_STORE_LISTING.md:193`).
  - `Core/LegalNotice.swift:51-58` (`accuracyStatement`) gives no figure.
  - The site, terms, privacy, support, Help and manual give none either.

**What must be added before the RC is frozen:**
1. **A public statement** in `LegalNotice.accuracyStatement` (shown in the app), `docs/USER_MANUAL.md`, Help, the site
   FAQ and the listing description (and update the listing checklist at `:193`). It should say:
   - the release bar: up to 3 % of answers wrong, per answering path (rules-only and Online AI), on held-out sets;
   - the scope: closed-case DOJ press-release proceeding questions (dates, charges, sentences, pleas, offices, counts,
     timelines), English only, so it is not a general accuracy figure for every archive;
   - the latest measured figures (ho20: rules 0.75 % wrong, 1.18 % with misses; Opus 5 0.21 % / 0.64 %), and that
     these are AGENT-adjudicated, not human;
   - that the strict measure (wrong + partly) is 5.24 % / 4.27 %, above 3 % (mainly incomplete timelines);
   - a pointer to the method (`docs/ADJUDICATION_PROTOCOL.md`, or a public summary of it).
2. **Gate and record:** change `ci/release-gates.json:77` to ≤3 % with the decision date, and record the decision in
   `docs/RELEASE_CANDIDATE.md` and `docs/FINAL_BRIEF_EXECUTION.md` §E6.
3. **One wording everywhere:** the same figure and scope in every public place, as with the "up to 300" wording.

---

## Summary of what must change

| ID | Severity | File:line | Fix |
|---|---|---|---|
| U-B1 | BLOCKER | `Brain/StateQuestionAnswerer.swift:73-111` | Contractions and other negations; skip questions and "whether" clauses; surface conflicts; add tests. |
| P-B1 | BLOCKER | `App/SendToDevonthink.swift:36-57`, `UI/AskView.swift:1533-1536`, `UI/Help/HelpRegistry.swift:270-273` | Gate both routes with ProtectedExport, or make the Help name only the protected routes. |
| L-C1 | Condition | `docs/OUTPUT_ROUTES_INVENTORY.md:43,72-74` + new rows | Add Save-as-text, Send to DEVONthink and AI-review copy; retire the stale route-20 gap. |
| A-C1 | Condition | `Core/LegalNotice.swift:51`, manual, Help, site, listing `:193`, `ci/release-gates.json:77` | Declare ≤3 % with scope and figures. |
| P-C1 | SHOULD-FIX | `Brain/ProceedingAnswerer.swift:44,154-171` | Narrow "pleading" and the last-resort rules. |
| P-C2 | SHOULD-FIX | `Personas/JobDeliverableExecutors.swift:1001,1005,1019` | Leading word boundary for the person name. |
| P-C3 | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:124` | "first" → "newest" (the oldest events were not read). |
| U-C1 | Condition | — | An agent UI re-run on the candidate build (P2, P3; M1, M4, M5). |
