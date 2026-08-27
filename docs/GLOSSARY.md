# Kalsmritikosh — Plain-Language Glossary

Every technical word this app uses, in the form:

> **Jargon** = what it really means = what it does for you. *(What to do.)*

Nothing here is invented — the app only ever answers from the documents **you**
add, and everything it tells you can be traced back to a source.

---

## 1. The one-line idea

**Kalsmritikosh** = a private memory of all your documents = you dump in your
files/emails, it reads them, and it answers questions with the receipts (which
file, which page). It runs entirely on your Mac — nothing leaves the machine.

---

## 2. Buttons & options you'll actually press

| You see | Plain meaning | What it does / what to do |
|---|---|---|
| **Add your documents / Sources** | "Give me the files." | Point it at folders/files. It reads them all. Start here. |
| **Ask** | Ask a question in plain English | The fastest way to an answer, with sources attached. |
| **Ingest** (happens automatically) | "Reading and filing your documents." | Turns raw files into searchable, dated, cited facts. You don't press anything — it runs when you add files. |
| **Distill memory now** | "Sum up where each person/company stands, right now." | Builds a one-paragraph, up-to-date summary for the main people and organizations in your files (see *Distilled memory* below). Press it once after a big import if you want subject summaries ready instantly. Optional — the app works without it. |
| **Background maintenance** | "Tidy up quietly while I'm not using the Mac." | Lets the app improve summaries/memory during idle time. **Off** by default. |
| **Allow cloud-routed providers** | "May I use an online AI model?" | Dev builds only. The shipping app has no cloud path at all — it is compiled out, so there is nothing to switch. |
| **Coalesce email threads** | "Treat a whole reply-chain as one item." | Cleaner memory for busy mailboxes. Needs a re-import to take effect. |
| **Show low-quality (T3) results** | "Also show me the shaky, low-trust stuff." | Off = cleaner answers. On = see everything, including guesses. |

---

## 3. How well a fact is known (the "trust" words)

These labels ride along with every fact so you know how much to lean on it.
(High trust at the top.)

| Word | Plain meaning |
|---|---|
| **Observed** | Seen directly in a solid source (an email header, a timestamp). Trust it most. |
| **Asserted** | A document *says* it, with a date. True that it was said — the claim itself could still be wrong. |
| **Derived** | Calculated from stated facts (e.g. invoice date + 30 days = due date). |
| **Inferred** | Pieced together from indirect clues (e.g. a file's edit date). A **lead, not a fact**. |
| **Corroborated** | The same fact shows up in **two or more independent** documents. Stronger. |
| **Contradicted** | Two sources disagree. The app keeps **both** and flags it — it never quietly picks one. Go check it. |
| **Confidence** | A 0–100% strength score for how well the evidence backs the item. Calibrated, not a vibe. |
| **Quality tier (T1 / T2 / T3)** | A trust grade. **T1** = high (clean, corroborated), **T2** = medium, **T3** = low (weak/garbled). The app never deletes T3 data — it just ranks it last. |
| **Citation** | The exact source of a statement (file → page/row/byte). Click it to see the original. |
| **Missing Proof / Gap** | Something you'd need to prove a claim, but it's **not in your files**. The app tells you what's missing instead of guessing. |

---

## 4. How the app stores what it learns (the "under the hood" words)

You rarely need these, but here's what the app means when it says them:

| Word | Plain meaning = what it does for you |
|---|---|
| **Ledger** | The app's structured memory of everything = the single database where all facts, dates, people, and sources live. The "brain" is this database, not the AI model. |
| **Ingest** | Reading + filing a document = extracting its text, dates, names, and facts, then indexing it so you can search and ask. |
| **Knowledge Object (KO)** | One ingested item (a file, an email) after the app has read it = the normalized unit everything else is built from. |
| **Chunk** | A small readable slice of a document = how long text is cut up so search and the AI can handle it a piece at a time. |
| **Entity** | A real-world "thing" the app recognizes = a person, company, place, phone number, amount, etc. |
| **Mention vs. Canonical entity** | *Mention* = a name as it appears in one document. *Canonical* = the single real person behind all the spellings/aliases. The app merges "S. Sasmal" and "Shirshendu Sasmal" into one. |
| **Event** | A dated thing that happened = "invoice sent on 4 May", built from your documents and placed on the Timeline. |
| **Relationship** | A link between two entities = "Person A works at Company B", shown in the connection graph. |
| **Assertion** | A single claim in subject–verb–object form = "Contract → signed by → Party X", each carrying its evidence. |
| **Summary** | A short auto-written recap of a document. |
| **Distilled memory / Subject state** | A one-paragraph "where things stand right now" for a person or company = the app reads all their scattered mentions and rolls them into one current, cited snapshot (and tracks how it changes over time). This is what **Distill memory** builds. |
| **Provenance / Source locator** | The paper trail = exactly where in which file a fact came from. It's what makes every answer verifiable. |
| **Audit trail / Custody** | A log of what the app did to your data and when = so nothing is a black box. |

---

## 5. How the app finds answers (search words)

| Word | Plain meaning | When to use |
|---|---|---|
| **Keyword search (FTS)** | Find exact words, names, numbers. | You know the exact term or spelling. |
| **Semantic search / Embeddings / Vector** | Find passages that **mean** the same thing, even in different words. | You remember the idea but not the wording. (Needs the meaning-model to be ready.) |
| **Embedding model** | The small on-device AI that turns text into "meaning fingerprints" so semantic search works. | Nothing to do — it warms up in the background. |
| **Reconstruct / Reconstruction** | Rebuild the story of what happened, in order, from your dated events — with sources. | "Reconstruct the timeline of X." |
| **Retrieval priority** | The order the app looks for answers: settled summaries → timeline → people → keyword → summaries → connections → meaning-match. | Nothing to do — it just means it prefers **structured facts** over fuzzy similarity. |

---

## 6. Speed vs. depth (processing modes)

The app trades **time for depth**. Faster = lighter reading; deeper = more AI work.

| Mode | Plain meaning |
|---|---|
| **Ledger (fastest)** | Rule-based reading + indexing, almost no AI at import. Quickest; you can search immediately. **This is the default.** |
| **Hot / Warm / Cold** | Reads everything lightly, then spends extra AI effort only on the important ("hot") part. |
| **Full LLM** | Runs the AI over every slice of every document. Deepest, but can take **hours** on big archives. |
| **Quality costs time** | The core rule: better/deeper analysis takes longer. The app defaults to fast + all-on-device, and lets you opt into more depth. |
| **OCR** | "Read text out of a scanned page or photo." | Slower, used automatically for scans/images. |
| **Transcription** | "Turn audio/video into text." | On demand only (Transcripts screen), fully on-device (Apple Speech, English in this version) — never automatic during ingest. |

---

## 7. The screens (tabs) and what each is for

| Screen | What it's for |
|---|---|
| **Home** | Start here — add documents, ask, or open the guide. |
| **Ask** | Ask a plain-English question; get a cited, evidence-gated answer. |
| **Search** | Exact-word or meaning-based lookup across everything. |
| **Timeline** | All your dated facts in order; filter by date, person, or kind. |
| **Findings / Insights** | Facts grouped by status: proven, contradicted, and what's missing. |
| **Dossier** | Everything about **one** person or company, in one profile. |
| **Explore / Graph** | The web of who's connected to whom. |
| **Knowledge / Library** | Browse the people, companies, documents, and summaries the app extracted. |
| **Assertions** | Every claim (yours and the app's) with its backing evidence; retract any you don't trust. |
| **Answer Journal** | A record of every answer you got, with its evidence, for later audit. |
| **Completeness** | How much of your archive is fully read and searchable, and what's left. |
| **Guide** | The in-app explainer for screens and trust words. |

---

## 8. Personas (just a "lens", not different apps)

**Persona / Template** = a preset lens for your kind of work = it picks the most
useful screens and example questions for you. Same engine underneath.

- **For Lawyers** — defensible case chronology; every event linked to its source.
- **For Investigators** — who knew what, when; connections and gaps.
- **For Journalists** — verify claims across a document dump; what conflicts.
- **For Researchers** — reconstruct past periods with honest uncertainty.
- **For Everyone** — your private, searchable memory of your own documents.

---

## 9. Other words you might spot

| Word | Plain meaning |
|---|---|
| **Evidence gate** | Before showing an answer the app decides: ship it, water it down, refuse, or show a conflict — based on how good the evidence is. It won't overclaim. |
| **Workspace** | A saved project space to gather evidence and build a work product. |
| **Work product** | A document you export (e.g. a chronology) with citations baked in. |
| **Quality strip** | The little bar on an answer showing confidence, source count, freshness, and conflicts. |
| **Redaction (coming)** | Hiding sensitive personal info before you share/export. |
| **On-device / Private** | Everything runs on your Mac. No file, question, or answer is sent anywhere. |

---

*If any word in the app isn't explained here, tell us the word — the glossary
should cover everything you can click or read.*
