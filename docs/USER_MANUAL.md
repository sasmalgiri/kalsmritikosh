<!-- GENERATED from Kalsmritikosh/UI/Help/HelpRegistry.swift by HelpDocsRenderer; do not edit by hand. Regenerate: HELP_DOCS_WRITE=1 HelpRegistryTests.generatedDocsMatch -->
# Investigations Made Easy — user manual

Investigations Made Easy reads the documents and email you already have, on your Mac, and builds a record of what they say: people and organisations, dated events, a timeline, and the exact passage each fact came from. You start a matter, bring documents into its scope, run the jobs of your profession, ask questions, review what you keep, and export a report whose every claim cites its source — or says honestly that the documents do not answer. This manual is the same text as Help inside the app (⌘?), which works offline.

Single-user, English-language v1. The app documents and finds; the decisions are yours. It is not legal, accounting, medical or disciplinary advice.

## Get started

### Get started: from documents to an exported report

Ten steps that take a folder of documents to a cited, reviewed, exported report. Each step names the exact control. The isolated sample case (Help ▸ Replay the tutorial) walks the same path on bundled documents.

1. Add documents. Open Sources and press “Add Folder…”. Files are read where they are; nothing is moved or copied. Supported: PDF, Word (DOCX), text and Markdown, RTF, ODT, EPUB, Excel (XLSX), CSV, ODS, PowerPoint (PPTX), email (EML, EMLX, MBOX), HTML, images and scans (PNG, JPG, HEIC, TIFF, WebP — read by OCR), audio and video (transcribed on your Mac while importing while “Transcribe audio & video” is on in Settings ▸ Modules, which it is by default), and ZIP archives. Older Office formats (DOC, XLS, PPT), Outlook stores (MSG, PST), RAR and 7z are kept but not read. The indicator reads “Ready” when every file has been processed; a count “could not be read — see Needs attention” lists the files that failed and why.
2. Start a matter. Open Professional Jobs, choose your profession, and press “Start matter”. Name the matter and choose its workspace.
3. Bring documents into the case. Press “Add documents to this case”. The preview shows how many documents are in scope now, how many are new, and how many stay excluded — nothing is included until you confirm. Jobs and answers read only the documents in the case’s scope.
4. Run the first job. Each job card says what it needs and what it produces; press “Run”. A job that cannot run says why and what to do (for example, no documents in scope yet).
5. Ask a question. Open Ask, type the question and press “Send question”. The answer is built only from the documents in scope; each claim carries a citation, and a question the documents do not answer is said to be unanswered rather than guessed.
6. Open the exact citation. Press “Open source” on a result row, or “Open at this passage” under an answer, to see the quoted passage in the original document. Read it: the quotation is checked against the document, but the document itself can be wrong, out of date or one side of a dispute.
7. Review the result. In a job result, decide row by row or press “Accept shown” / “Reject shown”, add a note, then “Save review”. Unreviewed rows are marked as such wherever they are carried.
8. Choose what goes in the report. Press “Include in report” on a reviewed row (or “Exclude from report (reason = your note)”). Rows can also go to the case with “Add to case…” or “Add to chronology”.
9. Export. In the case file, press “Case file report…”, then “Export…”. The report is checked once more against the current evidence as it is written, protected identities are kept out, and the export is recorded in the case log with its digest. Reopen the exported file to confirm what the reader will see.
10. Make a complete backup and keep the recovery key. Settings ▸ Your data: “Complete backup” writes the ledger and every original with its SHA-256; the recovery key shown there unlocks the backup on another Mac. Without the key an encrypted backup cannot be opened by anyone, including us.

Private mode is the default: the app opens no connection for your documents. Online AI is optional, uses your own provider account (which may charge you), shows every send before it leaves, and is never switched on by subscribing.

Before a subscription, and after one ends, every case stays readable and exports, backups, recovery, Help and the privacy controls keep working; only creating, editing and analysing wait for a subscription.

Screen: **Professional Jobs**.

## How do I…

### A file could not be read, a scan has no text, or a recording was not transcribed

Every file ends in one recorded state: read, kept but not read, or failed with a reason. Nothing is silently skipped and nothing is invented for an unreadable file.

1. Open Sources. The indicator reads “Ready” when the folder is fully processed; a line “could not be read — see Needs attention” counts the failures.
2. Open Needs attention for the file’s reason: corrupt or password-protected file, an unsupported format (DOC, XLS, PPT, MSG, PST, RAR, 7z are kept but not read), a scan with too little text for OCR, or a recording that could not be transcribed.
3. Scans: OCR quality follows scan quality. Tools ▸ Documents ▸ Improved text recognition lists weak scans and can save a searchable copy.
4. Recordings: with “Transcribe audio & video” on (Settings ▸ Modules, the default) recordings are transcribed on your Mac while importing (Apple Speech, English). With it off, recordings are catalogued and kept, and can be transcribed on demand in Transcripts. Transcripts are evidence of what the speech model heard, not a certified transcript.
5. Fix the file (open it in its own app and re-save, remove the password, re-scan) and press “Ingest All”, or leave it: a failed file stays listed as failed so the gap is visible in the case.

Screen: **Sources**.

### Search, ask, and understand an honest refusal

Search finds passages; Ask builds a cited answer from the documents in scope. When the documents do not support an answer the app says so instead of guessing.

1. Search: plain words or the syntax `type:email`, `file:report`, `before:2024-06-01`, `after:2023-01-01`, `person:"Ann Lee"`, `org:acme`, `tag:urgent`, quoted phrases, `-word` to exclude. The coverage badge says how much of the archive the search covered.
2. Ask: type the question and press “Send question”. The badge under the answer gives its status; “Evidence for this answer” lists each cited passage.
3. A refusal (“Not an answer — the closest passage in your documents”) means no passage supported an answer. The closest passage is shown so you can judge for yourself; it is not presented as an answer.
4. With “Answer general questions too” on (Settings), general knowledge appears in a separate block marked “Not from your documents” — no sources, may be wrong, never part of the evidence or any export.

Screen: **Ask**.

### Read an evidence status

Every fact carries how it is known. The statuses are explained under “Words the app uses”; this topic says what to do with each.

1. Observed and Asserted: open the citation and read the passage; an asserted statement is proof that it was said, not that it is true.
2. Derived: check the inputs (for example the invoice date and the payment term) — a derived date is only as good as them.
3. Inferred: treat as a lead. Look for a document that states it directly before relying on it.
4. Contradicted: both versions are kept; open Findings ▸ Contradictions and decide, recording why.
5. Corroborated: counts independent documents. Copies, forwards and near-duplicates count once, and shared wording between two documents does not make them independent.
6. Unverified evidence link: the quoted passage could not be found again in the current version of the source. It is shown as unverified and never carried into a report as verified.

Screen: **Findings**.

### People, organisations and namesakes

Spellings and aliases of one real person or company are combined into one entity; two different people with the same name must stay apart.

1. Knowledge lists canonical people and organisations with their aliases and counts; Dossier shows everything about one of them.
2. Every automatic merge is listed under Knowledge ▸ Merged. If two namesakes were combined, press “Unmerge” — nothing is deleted, the split is recorded.
3. A merge is a judgement about identity, not a fact in the documents; the audit log records who merged or unmerged and when.
4. Erasing a person from a case keeps namesakes and evidence shared with other people (see “Erase, holds and what stays”).

Screen: **Knowledge**.

### Statements, interviews and who said what

Interviews are planned and recorded in the case file; statements carry the speaker only when the document attributes them.

1. In the case file press “Plan interview”, then after the interview “Record confirmation” for the confirmed statement, and “Export statement for signature…” when a signature is needed.
2. Speaker attribution follows the reporting verb in the document (“Lopez wrote…”). Where attribution is ambiguous the speaker is left unassigned rather than guessed.
3. “How an account changed” (Tools ▸ Writing & checking) compares what a person said at different times; a changed account is shown as a change, not labelled a lie.
4. Credibility notes (“Add credibility note”) are your assessment and are recorded as such, separate from the evidence.

Screen: **Cases**.

### Build a chronology and weigh alternative explanations

Timeline orders every dated fact; Findings shows the chronology by status; Competing Hypotheses ranks explanations by how much evidence is inconsistent with each.

1. Timeline: filter by date, entity or event kind; open an event for its participants and source. Date precision travels with the event (a month-only date is shown as such).
2. From a job result, “Add to chronology” carries a reviewed row, with its citations and review state, into the case chronology.
3. Competing Hypotheses: list the explanations, mark each piece of evidence consistent, inconsistent or not assessed. The matrix prefers the hypothesis with the fewest inconsistencies and says when there is no preference; “not assessed” is never counted as neutral support.
4. A gap in the timeline is a gap in the record, not proof that nothing happened; it tells you what to collect next.

Screen: **Timeline**.

### Money: amounts, duplicates, refunds and currencies

Amounts are read with their currency and the document they came from; matching figures are shown as matches for you to classify, never as proof.

1. Fund Flow and DataLab show amounts with their source rows; the query above a DataLab table can be edited and re-run, and “Unresolved only” narrows to what still needs a decision.
2. The same amount in two documents is a candidate duplicate, refund, instalment or coincidence. The app marks it as a match; you record which it is and why.
3. Currencies are kept as written. Amounts are not converted between currencies, so a USD figure and an INR figure are never summed.
4. Balances and tracing follow the rows you include; a tracing schedule lists the inputs it rests on so an omitted document is visible.

Screen: **Fund Flow**.

### Review, approve, redact and export

Nothing is a finding until you review it; nothing leaves the case except through the one output route that re-checks citations and keeps protected identities out.

1. Review each result (“Save review”); an unreviewed row carried anywhere stays marked unreviewed.
2. “Include in report” selects what the report contains; the case file report is built from the current evidence and lists its sources.
3. Redaction removes text from a PDF for real (flattened and verified); if anything is still readable, no file is produced.
4. Every export, copy and print of case content goes through one route: the content is frozen, each citation is re-verified, access is re-checked after the save dialog, protected identities are scrubbed, the file is written and read back, and the case log records it with its digest. A refused output is recorded too.
5. Print is available only when the build is entitled to print; otherwise the app says so plainly and records nothing.

Screen: **Cases**.

### Private and Online modes, and what a provider may charge

Private (the default) opens no connection for your documents. Online is optional and uses your own AI-provider account.

1. Settings ▸ Modules ▸ Connection switches Online on with your own Claude, OpenAI or Gemini key. A badge shows while it is on; one click returns to Private.
2. Before anything is sent you see exactly what will go, its size and destination, and must approve it. Document text goes only to providers whose terms you have confirmed; privileged or restricted passages are refused; protected identities are masked.
3. Each send is recorded before it leaves. Providers may retain what they receive under their own terms, and they bill your account — the subscription to this app includes no provider usage.
4. Subscribing never turns Online on. The test host and the sample case never send anything.

Screen: **Settings**.

### Encryption, backup, recovery key, erasure and holds

The ledger is encrypted on this Mac; a complete backup carries everything with a recovery key; erasure is complete or refused, and a hold you created blocks it.

1. The ledger is encrypted (SQLCipher, AES-256) with a key in this Mac’s Keychain. Original files in the vault rely on FileVault for encryption at rest — turn FileVault on.
2. Settings ▸ Your data ▸ “Complete backup”: the ledger and every original, each with its SHA-256. Keep the recovery key shown there; a backup cannot be opened without it. Restore checks integrity and refuses a backup made by a newer version.
3. Erase a case, a person or everything: the app either completes the erasure and verifies it empty, or refuses and says why. A legal hold, a draft, or a document that another case still needs blocks the erasure until released.
4. Not reached by erasure: your original files outside the app, backups you made, exports, sync folders and Spotlight entries — delete those yourself.

Screen: **Settings**.

### Get support without sending your documents

Support never needs your archive. Diagnostics stay on this Mac until you choose to share them.

1. Settings ▸ Help & feedback shows the diagnostics the app keeps (counts, errors, timings — no document text) and lets you save them to a file you can inspect before sending.
2. The support page (Help ▸ Support) lists what to include in a report: the version, what you did, what you expected, what happened, and the saved diagnostics file.
3. Never paste document text or names into a bug report; a description of the shape of the problem is enough.

Screen: **Settings**.

## By profession

Each recipe is derived from the jobs the profession ships with and their documentation. Content Creator ships behind its own module and is not one of the nine.

### Recipe for a Investigator

Who did what, when — with custody of every source. Intake, triage, plan, interviews, evidence per allegation, findings and closure.

1. Open Professional Jobs and choose “Investigator”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Case intake & scope”: Create a case and set its authorized evidence scope. Needs: Mandate text; scope; sources; date range.
4. Run “Ask (case-scoped)”: Answer a question over the case's authorized evidence only.
5. Run “Professional methods”: Run a professional method over case-authorized evidence.
6. Run “DataLab”: Prepare authorized-only datasets over the shared Workbench.
7. Run “Subject workup”: Work up a subject — the background dossier, citing exact in-scope evidence. Needs: Subject identity; sources.
8. Run “Identity resolution”: Resolve identity via the shared reversible merge, human-gated. Needs: Candidate identifiers; mentions.
9. Run “Analysis worksheet”: Brainstorm, 5W1H, evidence plan, and hypothesis matrix.
10. Run “Source reliability”: Assess case source reliability (rating ≠ fact). Needs: Sources; custody.
11. Run “Contradiction & gap desk”: Review in-scope contradictions and gaps (absence ≠ proof). Needs: Claims; contradictions; gaps.
12. Run “Causal analysis”: Five Whys / Fishbone / Root-cause over the shared method engine.
13. Run “Timeline & link analysis”: Timeline, link chart (people–objects–locations–events), and transaction/asset flow.
14. Run “CAPA register”: Corrective/preventive action register (human-closed). Needs: Confirmed/candidate causes.
15. Run “Effectiveness review”: Review CAPA effectiveness (human decision required). Needs: CAPA actions; new evidence.
16. Run “Chain of custody”: The evidence locker — the case custody manifest over authorized versions. Needs: Sources; custody events.
17. Run “Case report & export”: Assemble the case report — findings with a sealed receipt.
18. Run “Closure & reopen”: Close or reopen the case by an explicit human decision.
19. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Work products: Investigation Plan; Subject Dossier; Identity Resolution Decision log; Source Reliability Schedule; Contradiction Schedule; Missing-Evidence Register; CAPA Register; Effectiveness Review; Evidence/Custody Manifest.

Your decisions (the app waits for them): Confirm scope; Confirm subject identity; Confirm/reject merge; Confirm reliability rating; Confirm/dismiss; Confirm owner/due/action; Confirm effectiveness; Confirm custody entries.

Professional limits: The app records the investigation; it does not decide guilt, intent or disciplinary outcome. An uncorroborated statement stays uncorroborated however often it is repeated. Decide case merits Assert guilt Auto-merge without review Auto-rate as fact Average conflicting accounts Close CAPA autonomously Declare effective w/o evidence Break custody silently

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Lawyer / Professional Reviewer

Fact-finding, chronology, review coding, privilege log and production — every event linked to its source, every conflict preserved.

1. Open Professional Jobs and choose “Lawyer / Professional Reviewer”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Matter intake”: Open the matter and set its authorized, privilege-sensitive scope. Needs: Matter facts; scope; sources.
4. Run “Parties & issues”: Identify parties and issues linked to canonical objects. Needs: Parties; issues.
5. Run “Case chronology”: Build the case chronology — the spine of the matter (undated labelled, each fact cited). Needs: Events; dates.
6. Run “Fact–evidence matrix”: Map facts to evidence — both sides preserved, cites reopen. Needs: Claims; evidence.
7. Run “Witness profiles”: Profile witnesses; contradictions cite both sides. Needs: Transcripts; testimony.
8. Run “Document coding”: Code documents by recorded, reversible decisions. Needs: Documents; codebook.
9. Run “Privilege log”: Build the privilege log — candidates recorded with basis; privilege is NEVER auto-established. Needs: Documents.
10. Run “Obligations & clauses”: Compare obligations/clauses, each cell citing a clause locator. Needs: Contracts.
11. Run “Damages ledger”: Build a damages ledger; amounts cite source cells. Needs: Financial documents.
12. Run “Deadlines”: Track deadlines — a candidate until a human confirms it. Needs: Documents with dates.
13. Run “Deposition outline”: Draft a deposition outline; questions cite the record. Needs: Transcripts; Claims.
14. Run “Exhibit list & binder”: Assemble the exhibit list and trial binder; each exhibit cites its source version. Needs: Selected documents.
15. Run “Document production”: Produce the export set — every document carries a Bates-style number; report == receipt with custody hashes. Needs: Selected docs; scope.
16. Run “Redaction validation”: Validate text + visual redaction before production. Needs: Documents; redactions.
17. Run “Ask the case file”: Ask a question over the matter's record — every claim cited. Needs: Question; matter scope.
18. Run “Method workbench”: Run structured methods (5W1H, hypothesis matrix…) over the matter. Needs: Matter; method choice.
19. Run “Party & alias resolution”: Unify party names and aliases (reversible, human-reviewed). Needs: Candidate names; mentions.
20. Run “Source reliability desk”: Assess reliability and independence of record sources. Needs: Sources.
21. Run “Causation analysis”: Trace causation step by step — Five Whys / Fishbone over the record. Needs: Event; record.
22. Run “Remediation register”: Track remediation/undertaking actions to closure. Needs: Identified issues.
23. Run “Remediation effectiveness”: Verify a completed remediation actually resolved the issue. Needs: Closed remediation.
24. Run “Matter closure & reopen”: Close the matter (sealed); reopen preserves full history. Needs: Matter; open items.
25. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Work products: Matter profile; Issue register; Chronology / statement of facts; Fact-evidence matrix; Witness summaries; impeachment pack; Coding log; Privilege log; Obligations schedule; Damages ledger; Deadline calendar; Deposition outline; Exhibit list; binder; Production set; receipt; Redaction validation record; Cited answer; Method run record; Identity decision log; Reliability record; Causal chain record; Remediation record; Effectiveness record; Closure record.

Your decisions (the app waits for them): Confirm scope; Confirm parties/issues; Confirm facts; Confirm mappings; Confirm profile; Confirm codes; Confirm privilege; Confirm comparisons; Confirm figures; Confirm each deadline; Confirm outline; Confirm exhibits; Approve production; Confirm redactions; Accept/refine answer; Human review gates; Confirm/reject merge; Confirm assessment; Confirm root cause; Close each action; Effectiveness decision; Confirm closure.

Professional limits: No legal conclusion is stated by the app; privilege and responsiveness are your calls, the app only applies and records them. Produced sets exclude withheld documents by rule, not by promise — check the production log. Give legal advice Decide liability Assert disputed fact as settled Average disputed facts Assert credibility verdict Auto-exclude relevant docs App marks privilege established Interpret contract as advice Assert legal damages Fire unconfirmed deadline Assert answers Alter an exhibit Produce out-of-scope material Disclose redacted content Answer beyond the record Auto-confirm findings Auto-merge without review Declare a source true Assert legal causation as fact Mark remediated without evidence Infer effectiveness from closure Destroy history on close

Job descriptions and limits come from the job documentation of the 22 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Compliance / HR Investigator

A workplace complaint handled by a fair, documented process: scope, interviews, policy mapping, findings and the file that shows the process.

1. Open Professional Jobs and choose “Compliance / HR Investigator”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Complaint intake”: Open the case and set the authorized evidence scope.
4. Run “Ask the case file”: Ask a question over the case's documents — every answer cited.
5. Run “Allegation worksheet”: Frame each allegation (5W1H) — an allegation is unproven until found.
6. Run “Party profiles”: Profile complainant, respondent, and witnesses from cited evidence.
7. Run “Name resolution”: Confirm names and accounts belong to the same person (reversible).
8. Run “Incident timeline”: The incident chronology with relationship links, every event cited.
9. Run “Documentary evidence register”: Emails, records, and policies in a register with cited cells.
10. Run “Statement comparison”: Compare accounts — conflicts preserved so due process holds.
11. Run “Credibility assessment”: Assess reliability and independence of each account (rating ≠ fact).
12. Run “Interview preparation”: Prepare interview questions over the cited record.
13. Run “Root-cause analysis”: Why did it happen — Five Whys / Fishbone for systemic causes.
14. Run “Evidence log & custody”: Chain-of-custody log for collected evidence with integrity hashes.
15. Run “Findings memo”: Findings on the balance of probabilities, with a sealed receipt.
16. Run “Corrective actions”: Track corrective and preventive actions to closure.
17. Run “Action effectiveness”: Verify a completed action actually fixed the issue.
18. Run “Close the case”: Close or reopen the case by an explicit human decision.
19. Run “Endorsement & disclosure review (FTC)”: Check posts, ads and sponsored material for undisclosed material connections — sponsorships, affiliate links, gifts, AI-generated content — against the FTC Endorsement Guides; every finding cited to the material.
20. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Professional limits: Findings are about the evidence, not about a person’s character; no disciplinary decision is made by the app. A policy breach is recorded only where the policy text and the evidence are both cited.

Job descriptions and limits come from the job documentation of the 17 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Forensic Accountant

Funds tracing, net worth, duplicate and refund analysis — the schedule behind every figure, with the rows it rests on.

1. Open Professional Jobs and choose “Forensic Accountant”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Engagement intake”: Open the engagement and set the authorized records scope.
4. Run “Ask the records”: Ask a question over the engagement's records — every answer cited.
5. Run “Funds tracing & flow”: Follow the money — transaction flow, timelines, and relationship links.
6. Run “Tracing schedules”: Build tracing schedules (payments, transfers) — every cell cites its source.
7. Run “Payee / entity workup”: Work up a payee, vendor, or counterparty, citing exact in-scope evidence.
8. Run “Entity & alias resolution”: Resolve shell names and aliases to one entity (reversible, human-gated).
9. Run “Discrepancies & missing records”: Where the records disagree or are absent (absence ≠ proof).
10. Run “Record reliability”: Assess origin and reliability of ledgers, invoices, and statements.
11. Run “Analysis worksheet”: Hypotheses, 5W1H, and the evidence plan for the engagement.
12. Run “Method workbench”: Run structured methods over the engagement's cited record.
13. Run “Root-cause analysis”: Trace how the loss or misstatement occurred — Five Whys / Fishbone.
14. Run “Workpapers & custody”: The workpaper vault — custody-tracked originals with integrity hashes.
15. Run “Expert report & exhibits”: Assemble the expert report with cited exhibits and a sealed receipt.
16. Run “Recovery actions”: Track recovery and remediation actions to closure.
17. Run “Recovery effectiveness”: Verify a completed action actually recovered or remediated.
18. Run “Close the engagement”: Close or reopen the engagement by an explicit human decision.
19. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Professional limits: A matching amount is a candidate, not a finding; the app never labels a transaction fraudulent. Amounts are not converted between currencies; balances follow only the rows you include.

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Insurance Fraud (SIU)

A suspicious claim worked to a referral: red flags, the claim chronology, statements compared, and the SIU report.

1. Open Professional Jobs and choose “Insurance Fraud (SIU)”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Claim file intake”: Open the claim file and set the authorized document scope.
4. Run “Ask the claim file”: Ask a question over the claim's documents — every answer cited.
5. Run “Red-flag worksheet”: Record fraud indicators (5W1H) — red flags are indicators, never proof.
6. Run “Claimant workup”: The claimant/provider background workup, citing exact in-scope evidence.
7. Run “Identity resolution”: Confirm names, aliases, and entities are the same party (reversible, human-gated).
8. Run “Loss chronology & links”: The loss timeline, relationship links, and payment flow.
9. Run “Prior-claims register”: A register of prior/related claims with cited cells.
10. Run “Statement comparison”: Compare statements — conflicting accounts preserved, never averaged.
11. Run “Source vetting”: Assess reliability and independence of statements and documents.
12. Run “EUO / interview prep”: Prepare examination-under-oath questions over the cited record.
13. Run “Causation analysis”: Trace how the loss occurred — Five Whys / Fishbone over cited evidence.
14. Run “Chain of custody”: The claim evidence locker — custody manifest with integrity hashes.
15. Run “SIU report & referral”: Assemble the referral-ready SIU report with a sealed receipt.
16. Run “Recovery & referral actions”: Track recovery, NICB/DOI referral, and follow-up actions to closure.
17. Run “Action effectiveness”: Verify a completed action actually resolved the exposure.
18. Run “Close the claim file”: Close or reopen the file by an explicit human decision.
19. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Professional limits: Red flags are indicators for review, not evidence of fraud; the referral decision is the person’s. The report states what the documents show and what they do not.

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Journalist

Claims checked to sources, right of reply recorded, a fact-check that shows what is supported, what conflicts and what is missing.

1. Open Professional Jobs and choose “Journalist”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Story intake”: Define the story question, scope, and authorized sources. Needs: Story premise; scope; sources.
4. Run “Fact-check board”: Track every claim and its verification status — checked, unchecked, disputed. Needs: Claims; sources.
5. Run “Source map”: Map sources, people, and relationships. Needs: Sources; Claims.
6. Run “Source reliability”: Assess source reliability and independence. Needs: Sources.
7. Run “Interview plan”: Identify reporting gaps to fill by interview. Needs: Gaps; Claims.
8. Run “Quote book”: Collect quotes cited to their exact source. Needs: Sources; transcripts.
9. Run “Transcript correction”: Correct transcripts with locators; unheard words never asserted. Needs: Audio/transcripts.
10. Run “Tick-tock (timeline)”: Build the story's tick-tock — the reconstructed timeline (undated labelled, cited). Needs: Events; dates.
11. Run “Fact verification”: Verify claims; conflicting accounts preserved. Needs: Claims; evidence.
12. Run “Open questions”: The open-questions list — what's still unanswered (absence ≠ proof). Needs: Gaps.
13. Run “Right of reply”: Log subjects and their responses. Needs: Correspondence; Claims.
14. Run “Publication decision”: Record the human publication decision (never automated). Needs: Verification; legal review.
15. Run “Correction history”: Track post-publication corrections. Needs: Published items; new evidence.
16. Run “Publication package”: Assemble the verified publication package + sealed receipt. Needs: Verified claims; quotes.
17. Run “Ask the story file”: Ask a question over the story's sources — every claim cited. Needs: Question; story scope.
18. Run “Method workbench”: Run structured methods (5W1H, hypothesis matrix…) over the story. Needs: Story; method choice.
19. Run “Story data desk”: Build datasets over documents (logs, filings) with cited cells. Needs: Documents; fields.
20. Run “Who's who resolution”: Unify names and aliases to one subject (reversible, human-reviewed). Needs: Candidate names; mentions.
21. Run “Causal analysis”: Trace why events unfolded — Five Whys / Fishbone over cited evidence. Needs: Event; evidence.
22. Run “Source-document vault”: Custody-tracked vault for source documents with integrity hashes. Needs: Documents.
23. Run “Correction actions”: Track corrective actions on published errors to closure. Needs: Published error.
24. Run “Correction effectiveness”: Verify a published correction actually resolved the error. Needs: Closed correction.
25. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Work products: Story brief; Claim board export; Source map; Source reliability schedule; Interview plan; Quote book; Corrected transcript; Chronology; Verification log; Reporting-gap register; Right-of-reply log; Publication decision record; Correction log; Publication package; receipt; Cited answer; Method run record; Cited dataset; Identity decision log; Causal chain record; Custody log; Correction action record; Effectiveness record.

Your decisions (the app waits for them): Confirm premise; Confirm claim status; Confirm links; Confirm rating; Confirm questions; Confirm quote/context; Confirm corrections; Confirm inclusion; Confirm verification; Confirm gaps; Confirm responses; Human publication decision; Approve package; Accept/refine answer; Human review gates; Review derived values; Confirm/reject merge; Confirm root cause; Confirm custody events; Close each action; Effectiveness decision.

Professional limits: Shared wording between sources is not independent confirmation. Publication, naming and legal risk are editorial decisions outside the app. Decide truth of story Publish unverified claim Expose confidential source Auto-rate as fact Assert answers Alter a quote Invent speech Invent dates Mark verified w/o evidence Imply wrongdoing from absence Omit a reply silently App approves publication Rewrite record silently Include unverified fact Answer beyond sources Auto-confirm findings Fabricate a value Auto-merge without review Unsupported causal leap Alter originals Silently unpublish Infer effectiveness from closure

Job descriptions and limits come from the job documentation of the 22 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Researcher / Historian

What the papers and data actually show: an evidence review with dates at their real precision and uncertainty kept visible.

1. Open Professional Jobs and choose “Researcher / Historian”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Research protocol”: Define the research question, scope, and authorized corpus. Needs: Question; corpus; scope.
4. Run “Corpus catalogue”: Catalogue every authorized source with provenance. Needs: Sources.
5. Run “Metadata & finding aid”: Record structured metadata per source — your working finding aid, cited to the source. Needs: Sources.
6. Run “Transcription & coding”: Code passages into structured findings with locators. Needs: Audio/image sources.
7. Run “Authority control”: Unify names/terms to canonical authorities (reversible, human-reviewed). Needs: Entities; aliases.
8. Run “Source criticism”: Assess origin, bias, and reliability of sources. Needs: Sources.
9. Run “Screening (include / exclude)”: Screen sources in or out by recorded, reversible criteria — PRISMA-style. Needs: Corpus; criteria.
10. Run “Extraction & coding”: Extract coded findings, each citing an evidence block. Needs: Sources; codebook.
11. Run “Chronology & periodisation”: Build a periodised timeline (undated labelled, cited). Needs: Events; dates.
12. Run “Prosopography”: Compile a collective biography of a group, each cell cited. Needs: Entities; events.
13. Run “Interpretation comparison”: Compare competing interpretations — both accounts preserved. Needs: Claims; interpretations.
14. Run “Alternative histories”: Explore evidence-bounded counterfactuals (never mutates the ledger). Needs: Events; causal links.
15. Run “Bibliography & citation audit”: Verify every citation reopens its exact source. Needs: Citations; sources.
16. Run “Annotated edition”: Assemble an annotated edition/report with a sealed receipt. Needs: Selected sources; notes.
17. Run “Ask the corpus”: Ask a question over the authorized corpus — every claim cited. Needs: Question; matter scope.
18. Run “Method workbench”: Run structured methods (5W1H, hypothesis matrix, root cause…) over the matter. Needs: Matter; method choice.
19. Run “Causal analysis”: Trace why an event unfolded — Five Whys / Fishbone over cited evidence. Needs: Event; evidence.
20. Run “Errata register”: Track corrections to the edition as corrective actions to closure. Needs: Identified errors.
21. Run “Errata effectiveness review”: Verify a published correction actually resolved the issue. Needs: Closed erratum.
22. Run “Matter closure”: Close the research matter (sealed, reopenable with history). Needs: Matter; open items.
23. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Work products: Research Protocol; Corpus Catalogue; Metadata export; Corrected transcript; Authority file; Source Criticism notes; Screening log; Coded dataset; Chronology; Prosopography table; Interpretation comparison; Alternative-history note; Bibliography; citation audit; Annotated edition; receipt; Cited answer; Method run record; Causal chain record; Errata record; Effectiveness record; Closure record.

Your decisions (the app waits for them): Confirm protocol; Confirm inclusion; Confirm metadata; Confirm corrections; Confirm authority; Confirm assessment; Confirm screening; Confirm codes; Confirm periods; Confirm entries; Confirm interpretation; Confirm scenario scope; Confirm citations; Approve edition; Accept/refine answer; Human review gates; Confirm root cause; Close each erratum; Effectiveness decision; Confirm closure.

Professional limits: Date precision is preserved; the app never sharpens an approximate date. Inferred items are leads for the archive, not findings. Decide findings Assert authenticity Invent metadata Assert unheard words Auto-unify w/o review Declare truth from one source Auto-exclude silently Fabricate coded content Invent dates/periods Assert unknown biography Pick a winner Present scenario as fact Assert unresolved cite Alter source text silently Answer beyond the corpus Auto-confirm findings Unsupported causal leap Silently rewrite the edition Infer effectiveness from closure Destroy history on close

Job descriptions and limits come from the job documentation of the 20 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Genealogist / Family Historian

Who is who, worked to the Genealogical Proof Standard: sources cited, conflicts resolved in writing, a proof argument.

1. Open Professional Jobs and choose “Genealogist / Family Historian”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Research question & plan”: Fix the research question and the record scope before searching.
4. Run “Ask the family records”: Ask a question over your records — every answer cites its document.
5. Run “Research log”: The classic research log — what was searched, where, what it yielded.
6. Run “Ancestor profile”: Everything known about one ancestor, each fact cited.
7. Run “Same person?”: Resolve name variants to one person (reversible, you decide).
8. Run “Family lines & timeline”: Family relationships and life timelines, every event cited.
9. Run “Conflicting evidence”: Resolve records that disagree — both kept on file (GPS element 4).
10. Run “Source analysis”: Original or derivative? Primary or secondary information? (rating ≠ fact).
11. Run “Evidence correlation”: Correlate evidence across records (5W1H worksheets).
12. Run “Guided methods”: Structured checklists for reasonably exhaustive research.
13. Run “Why did they move?”: Trace causes — migration, name changes — step by step over cited records.
14. Run “Source citations & originals”: Custody-tracked originals; every citation reopens its exact source.
15. Run “Proof argument (GPS)”: The written, soundly-reasoned conclusion with a sealed receipt.
16. Run “Research to-dos”: Track follow-up searches and record orders to closure.
17. Run “Did it answer?”: Verify a completed search actually answered the question.
18. Run “Close the question”: Close or reopen the research question by explicit decision.
19. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Professional limits: Two records with the same name are not the same person until the proof argument says so. A derived date (for example from an age at death) is shown as derived.

Job descriptions and limits come from the job documentation of the 16 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

### Recipe for a Individual

A personal dispute — an insurance claim, a deposit, a job — your own file in order, with the documents behind each point.

1. Open Professional Jobs and choose “Individual”; press “Start matter”, name it and choose its workspace.
2. Press “Add documents to this case” and confirm the scope preview — only documents in scope are read.
3. Run “Personal records”: Bring in and organize your documents and records. Needs: Personal documents.
4. Run “Official-document versions”: Track versions of official documents. Needs: Documents.
5. Run “Career & education”: Summarize your career and education over time. Needs: Resumes; certificates.
6. Run “Family records”: Organize family members and relationships. Needs: Family documents.
7. Run “Property”: Keep a register of property and assets. Needs: Deeds; bills.
8. Run “Insurance”: Keep a register of insurance policies. Needs: Policies; correspondence.
9. Run “Health-record scope”: Summarize health records you choose to include. Needs: Health documents.
10. Run “Applications & cases”: Track applications and open cases. Needs: Application documents.
11. Run “Important dates & renewals”: Keep the confirmed dates that matter — renewals, expiries, deadlines. Needs: Documents with dates.
12. Run “Emergency binder (ICE)”: Assemble your in-case-of-emergency binder — what loved ones need, in one place. Needs: Key documents.
13. Run “Share safely (redacted)”: Prepare a redacted copy to share — sensitive details masked. Needs: Documents; recipients.
14. Run “Personal chronology”: See your personal timeline (undated labelled). Needs: Events; dates.
15. Run “Legacy binder”: Assemble the legacy binder — your records for the next generation, with a sealed receipt. Needs: Selected documents.
16. Run “Ask my records”: Ask a question over your records — every answer cites its document. Needs: Question.
17. Run “Guided methods”: Step-by-step structured methods (5W1H, checklists) over your records. Needs: Topic; method choice.
18. Run “Name & alias resolution”: Confirm two names are the same person/company (reversible, you decide). Needs: Candidate names.
19. Run “Document reliability”: Assess how reliable a document or its source is. Needs: Document.
20. Run “Conflicts & gaps”: See where your records disagree or are missing (absence ≠ proof). Needs: Records scope.
21. Run “Why did this happen?”: Trace causes step by step over your cited records. Needs: Event; records.
22. Run “Fix-it list”: Track corrective actions (renewals, disputes, fixes) to closure. Needs: Identified problems.
23. Run “Did the fix work?”: Verify a completed fix actually resolved the problem. Needs: Closed action.
24. Run “Document vault”: Custody-tracked vault for originals with integrity hashes. Needs: Documents.
25. Run “Close a matter”: Close a personal matter (sealed, reopenable with history). Needs: Matter; open items.
26. Review each result (“Save review”), choose what the report carries (“Include in report”), then export it from the case file (“Case file report…” → “Export…”) and reopen the file.

Work products: Records index; Version history; Career/education summary; Family record; Property register; Insurance register; Health summary; Application tracker; Reminder list; Emergency pack; Redacted export; Personal chronology; Legacy archive; receipt; Cited answer; Method run record; Identity decision log; Reliability record; Conflict/gap register; Causal chain record; Action record; Effectiveness record; Custody log; Closure record.

Your decisions (the app waits for them): Confirm categories; Confirm current version; Confirm entries; Confirm relationships; Confirm ownership; Confirm renewals; Confirm scope; Confirm submissions; Confirm each reminder; Confirm pack; Confirm redactions; Confirm inclusion; Approve archive; Accept/refine answer; Human review gates; You confirm/reject; Confirm assessment; Review each conflict; Confirm root cause; Close each action; You decide effectiveness; Confirm custody events; Confirm closure.

Professional limits: The app is not legal, financial or medical advice; it organises your documents so you and your advisers can see them. What the documents do not say is listed as missing, not filled in. Expose sensitive data Discard old version Invent credentials Assert relationship w/o evidence Assert title Auto-file a claim Diagnose leak health data Submit on user's behalf Fire unconfirmed reminder Expose data insecurely Leak redacted content Invent dates Alter records silently Answer beyond your records Auto-confirm findings Auto-merge without review Declare a document true Average conflicts away Unsupported causal leap Mark fixed without doing it Infer effectiveness from closure Alter originals Destroy history on close

Job descriptions and limits come from the job documentation of the 23 jobs this profession ships with; a job without documentation is listed from its card only.

Screen: **Professional Jobs**.

## The screens

### Cases — every investigation, intake to closure

Your caseload: what needs you next is at the top (overdue tasks, untriaged cases, holds not acknowledged). Open a case for its file: intake and triage, the plan and allegations with the evidence for and against each, tasks with due dates, people and interviews with confirmed statements, exhibits, holds, redactions, your chronology and notes, and a log of everything done. You record each finding; the app keeps the record.

Screen: **Cases**.

### Ask — cited answers from your evidence

Type a question in plain language. The answer is built only from your ingested sources: every claim cites its evidence, the badge shows how strongly it is established, and anything your sources don’t cover is listed as a gap instead of being guessed. With “Answer general questions too” on (Settings), questions outside your documents get a separate block marked “Not from your documents” — general knowledge from the on-device AI, no sources, may be wrong, and never part of your evidence or exports.

Screen: **Ask**.

### Findings — every fact by status

Four tabs: Timeline (events labelled by how they are known, with accept/reject review), Evidence (extracted claims with citations), Contradictions (where sources disagree — both sides kept), and Missing Proof (what the record does not establish).

Screen: **Findings**.

### History — the evidence-backed narrative

A readable reconstruction of what happened, composed from the dated events in your ledger, with every claim traceable to its source.

Screen: **History**.

### Sources — what the ledger knows

Add folders and files here. Text extracts directly from PDF, Word, Excel/CSV, PowerPoint (PPTX), EPUB, email (EML, MBOX, Apple Mail, MSG, PST, NSF), HTML, Markdown, and text. ZIP archives are opened and read file by file within safety limits; RAR and 7z archives are kept but not opened. Images and scans are read by OCR, so accuracy depends on the scan. With “Transcribe audio & video” on (the default), recordings are transcribed on-device while importing (Apple Speech, English). Reading is tuned for English: other languages are kept and keyword-searchable, but names, dates and facts in them may be missed. Every file is hashed, parsed into cited evidence, and indexed; duplicates are detected. Anything unreadable is recorded honestly — never faked.

Screen: **Sources**.

### Timeline — your documents as dated events

Every dated fact extracted from your sources, in order. Filter by date range, entity, or event kind. Open an event to see its participants, source document, and causal links.

Screen: **Timeline**.

### Search — exact or by meaning

Keyword mode finds exact terms, names, and numbers. Semantic mode finds passages that mean the same thing even with different words (needs an embedding model).

Screen: **Search**.

### Explore — the connection graph

Pick a person or organization and see who and what it is connected to. Select any node to re-center on it.

Screen: **Explore**.

### Dossier — everything about one entity

Search for a person or organization to get its full profile: timeline of events, relationships, aliases, distilled memory, and when it first and last appears in your sources.

Screen: **Dossier**.

### Insights — gaps, contradictions and patterns

Auto-surfaced signals the ledger found: missing-evidence gaps, conflicts between sources, and recurring patterns worth a look.

Screen: **Insights**.

### Knowledge — the structured base

Canonical people, organizations, projects, events, and distilled memory, with corpus-wide counts.

Screen: **Knowledge**.

### Assertions — claims with their evidence

Extracted subject-predicate-object claims, each carrying the specific evidence that backs it.

Screen: **Assertions**.

### Library — every document you’ve ingested

Browse the source files, their summaries, and distilled memories.

Screen: **Library**.

### Completeness — how fully your archive is processed

How much of your corpus is parsed, indexed, and searchable, with what remains.

Screen: **Completeness**.

### Convert — files between formats

Read PDF/Office/images/audio and write txt, md, json, html, csv, pdf, rtf, docx, xlsx, png.

Screen: **Convert**.

### Professional Jobs — the matter, its documents and the jobs

Choose your profession, start a matter (or resume one), bring documents into its scope with “Add documents to this case”, then run the jobs in their phases. Each card says what the job needs, what it produces, and — when it cannot run — why and what to do. Progress counts reviewed results and blockers, not clicks. Every run, review and document decision is in the work log.

Screen: **Professional Jobs**.

### Work Center — guided workflows

Step-by-step workflows for the jobs, with the fields each step needs and the work product at the end. The same jobs as Professional Jobs, laid out as a walkthrough.

Screen: **Work Center**.

### Logs & Trackers — the registers

The case’s structured registers: tasks, custody, exhibits, holds and the other trackers, each row cited to its source.

Screen: **Logs & Trackers**.

### DataLab — structured results you can query

A job result as a table: the question once above it, sort and filter, “Unresolved only”, a source pane for the selected row, and re-run with your edited query.

Screen: **DataLab**.

### Handoff & Review — carrying results into the case

Reviewed rows travel with every citation, their revision digest and their review state into the case question, the chronology or the report. A row whose source changed since is shown as stale.

Screen: **Handoff & Review**.

### Competing Hypotheses — weigh explanations

An Analysis of Competing Hypotheses matrix: evidence rows against hypotheses, each cell consistent, inconsistent or not assessed. Ranks by fewest inconsistencies, says when there is no preference, and cites each cell’s evidence.

Screen: **Competing Hypotheses**.

### Review — what waits for your decision

Results, links and documents that need a human decision before they count.

Screen: **Review**.

### Transcripts — recordings as text

Transcripts made on this Mac (Apple Speech, English): quotable, searchable, and marked as a speech model’s reading, not a certified transcript.

Screen: **Transcripts**.

### What Changed — differences between versions

What a later version of a document, result or account added, removed or changed.

Screen: **What Changed**.

### Settings — modes, privacy, data and subscription

System mode, Private/Online, modules, ingest options, Your data (backup, recovery key, erasure), Help & feedback, legal notices and the subscription.

Screen: **Settings**.

### Guide — this help

Searchable offline help: Get started, tasks, recipes by profession, the screens, the words the app uses, reading results carefully, subscription and troubleshooting.

Screen: **Guide**.

### Home — Start here — pick the lens that fits your work

Start here — pick the lens that fits your work

Screen: **Home**.

### Workspaces — Organize a matter, case, or project — a filtered view over your evidence

Organize a matter, case, or project — a filtered view over your evidence

Screen: **Workspaces**.

### Cross-Doc Matrix — Ask one question across every document — what each source says, cited

Ask one question across every document — what each source says, cited

Screen: **Cross-Doc Matrix**.

### Compare Documents — Compare two or more documents field by field — agreements, disagreements, and what no source settles

Compare two or more documents field by field — agreements, disagreements, and what no source settles

Screen: **Compare Documents**.

### Connections — Find the shortest chain of relationships linking two people or organizations

Find the shortest chain of relationships linking two people or organizations

Screen: **Connections**.

### Fund Flow — See how money moved between parties — payer to payee — drawn from your evidence

See how money moved between parties — payer to payee — drawn from your evidence

Screen: **Fund Flow**.

### Email Threads — A big email dump, deduplicated and grouped into conversations

A big email dump, deduplicated and grouped into conversations

Screen: **Email Threads**.

### Case Story — The whole cited story of a subject — timeline, parties, clauses, roadblocks, gaps

The whole cited story of a subject — timeline, parties, clauses, roadblocks, gaps

Screen: **Case Story**.

### Reasoning Studio — Run a root-cause investigation start to finish — brainstorm, 5 Whys, a fishbone diagram, a conclusion, and an approval-ready report

Run a root-cause investigation start to finish — brainstorm, 5 Whys, a fishbone diagram, a conclusion, and an approval-ready report

Screen: **Reasoning Studio**.

### HR Investigation — Run a workplace investigation the real-life way — mandate, allegations, evidence, credibility, classified findings — and produce the exact report an investigator signs

Run a workplace investigation the real-life way — mandate, allegations, evidence, credibility, classified findings — and produce the exact report an investigator signs

Screen: **HR Investigation**.

### Privilege Log — Build an FRCP 26(b)(5) privilege log — describe each withheld document enough to test the claim without revealing it, QC, and serve the exact table

Build an FRCP 26(b)(5) privilege log — describe each withheld document enough to test the claim without revealing it, QC, and serve the exact table

Screen: **Privilege Log**.

### SIU Report — Work a referred claim the SIU way — red flags against objective criteria, loss chronology, investigation, discrepancies, and the exact disposition report

Work a referred claim the SIU way — red flags against objective criteria, loss chronology, investigation, discrepancies, and the exact disposition report

Screen: **SIU Report**.

### Expert Report — Follow the money like a testifying expert — named tracing method, sourced schedule, findings distinct from opinion, and the FRCP 26(a)(2)(B) report

Follow the money like a testifying expert — named tracing method, sourced schedule, findings distinct from opinion, and the FRCP 26(a)(2)(B) report

Screen: **Expert Report**.

### Fact-Check — Prepare a contested story the newsroom way — claim-by-claim verification, a right-of-reply log with deadlines, and the pre-publication memo

Prepare a contested story the newsroom way — claim-by-claim verification, a right-of-reply log with deadlines, and the pre-publication memo

Screen: **Fact-Check**.

### Evidence Review — Run a review the published way — PRISMA screening counts, one extraction row per included study, and a GRADE-rated synthesis

Run a review the published way — PRISMA screening counts, one extraction row per included study, and a GRADE-rated synthesis

Screen: **Evidence Review**.

### Proof Argument — Answer a genealogical question to the Genealogical Proof Standard — research log with nil results, conflicts resolved, written proof argument

Answer a genealogical question to the Genealogical Proof Standard — research log with nil results, conflicts resolved, written proof argument

Screen: **Proof Argument**.

### Emergency Binder — Build the family emergency binder — key people, where every document and account lives, your instructions, printable

Build the family emergency binder — key people, where every document and account lives, your instructions, printable

Screen: **Emergency Binder**.

### Dispute File — Put a personal dispute on paper — insurance claim, deposit, employment or refund — with the timeline and the document behind each line, filled from your case

Put a personal dispute on paper — insurance claim, deposit, employment or refund — with the timeline and the document behind each line, filled from your case

Screen: **Dispute File**.

### Notebook — Your saved notes and working pages

Your saved notes and working pages

Screen: **Notebook**.

### Answers — Past answers with their evidence — replayable and auditable

Past answers with their evidence — replayable and auditable

Screen: **Answers**.

### Audit — Chain-of-custody and every human decision — the append-only record

Chain-of-custody and every human decision — the append-only record

Screen: **Audit**.

### Verify Receipt — Open an exported receipt and re-check its hash chain — genuine or tampered

Open an exported receipt and re-check its hash chain — genuine or tampered

Screen: **Verify Receipt**.

### Saved — Your bookmarked questions

Your bookmarked questions

Screen: **Saved**.

### Authenticity — Check a file's provenance — fingerprint, capture metadata, editing traces, PDF edit markers

Check a file's provenance — fingerprint, capture metadata, editing traces, PDF edit markers

Screen: **Authenticity**.

### Citations — Build layered Evidence Explained citations — full note, short note, bibliography

Build layered Evidence Explained citations — full note, short note, bibliography

Screen: **Citations**.

### Freshness — Confirmed facts ranked by how long since they were checked — catch stale ones before they're reused

Confirmed facts ranked by how long since they were checked — catch stale ones before they're reused

Screen: **Freshness**.

### Trends — Patterns across everything — activity over time, event types, entity makeup

Patterns across everything — activity over time, event types, entity makeup

Screen: **Trends**.

### Query — Ask a precise question of your ledger — pick a subject, add filters, run. No SQL to write; see the SQL if you want

Ask a precise question of your ledger — pick a subject, add filters, run. No SQL to write; see the SQL if you want

Screen: **Query**.

### Live — Live pipeline and background activity

Live pipeline and background activity

Screen: **Live**.

### Redaction — Remove text from a PDF for real — flattened and verified, not just a black box

Remove text from a PDF for real — flattened and verified, not just a black box

Screen: **Redaction**.

### Caseload — Every matter triaged by how much attention it needs

Every matter triaged by how much attention it needs

Screen: **Caseload**.

### Constitution — The constitution the app runs on — every phase, the tooling it earns, its obligations, human decisions, and prohibited conclusions

The constitution the app runs on — every phase, the tooling it earns, its obligations, human decisions, and prohibited conclusions

Screen: **Constitution**.

### Compliance Board — Every external SOP the app implements, at the edition verified, with periodic re-checks so compliance is maintained over time

Every external SOP the app implements, at the edition verified, with periodic re-checks so compliance is maintained over time

Screen: **Compliance Board**.

## Words the app uses

- **Observed** — Directly visible in a structured source — an email header, a log entry, a timestamp. Highest trust.
- **Asserted** — Stated in a document’s text with an explicit date. True that it was said; the statement itself may still be wrong.
- **Derived** — Computed deterministically from stated facts (e.g. invoice date + 30-day term).
- **Inferred** — Reconstructed from indirect evidence only (e.g. a file’s modification time). A lead, not a fact.
- **Contradicted** — Another source states a conflicting version. Both sides are preserved — check Contradictions.
- **Corroborated** — The same fact appears in two or more independent source documents.
- **Confidence** — The evidence gate’s own grading of how well the passages support this item, from 0 to 100. Not calibrated until validated on your archive: read 80 as “stronger than 60”, not as “right four times in five” — check the citations.
- **Citation** — The exact source (file, page, row) a statement came from. Open it to verify.
- **Missing Proof** — Evidence that would be needed to establish a claim but is absent from your sources.
- **Ingest** — Reading and filing your documents into searchable, dated, cited facts. Runs automatically when you add files — you don't press anything.
- **Distill memory** — Sums up where each main person and company stands right now, from all their scattered mentions. Optional; the app answers fine without it.
- **Background maintenance** — Lets the app tidy summaries and memory while your Mac is idle, and stop the moment you return. Off by default.
- **Private / Online** — Private (the default) runs everything on your Mac and makes no connection. Online is optional: Settings → Modules → Connection, with your own Claude, OpenAI or Gemini key. You see what will be sent first, a badge shows while it is on, and one click returns to Private.
- **Modules** — Every feature is a switch in Settings → Modules. Switched-off features disappear; stand-alone tools appear in the sidebar Tools menu while switched on.
- **Coalesce email threads** — Treats a whole email reply-chain as one item instead of one per message — cleaner memory. Needs a re-import to take effect.
- **Show low-quality (T3)** — Also shows the shaky, low-trust items. Off = cleaner answers; on = see everything, including weak guesses.
- **Ledger** — The app's structured memory — the one database where every fact, date, person, and source lives. The intelligence is here, not in the AI model.
- **Knowledge Object** — One document (or email) after the app has read and normalized it.
- **Chunk** — A small slice of a document, so search and the AI can handle it a piece at a time.
- **Entity** — A real-world thing the app recognizes: a person, company, place, phone number, or amount. Spellings and aliases are combined into one. Every merge is listed under Knowledge → Merged and can be undone with Unmerge; nothing is deleted.
- **Event** — A dated thing that happened ("invoice sent on 4 May"), placed on your Timeline.
- **Relationship** — A link between two entities ("Person A works at Company B"), shown in the connection graph.
- **Distilled memory** — A one-paragraph "where things stand now" for a person or company, rolled up from all their mentions and updated over time. Also called the subject's state.
- **Assertion** — A single claim in subject–verb–object form ("Contract → signed by → Party X"), each carrying the evidence that backs it.
- **Provenance** — The paper trail — exactly where in which file each fact came from. It's what makes every answer verifiable.
- **Keyword search** — Finds exact words, names, and numbers. Use it when you know the exact term.
- **Semantic search** — Finds passages that mean the same thing even in different words. Use it when you remember the idea, not the wording.
- **Reconstruct** — Rebuilds the story of what happened, in order, from your dated events — with every claim traceable to its source.
- **Evidence gate** — Before showing an answer the app decides: show it, soften it, refuse, or flag a conflict — based on how good the evidence is. It won't overclaim.
- **Ledger mode** — Fastest: rule-based reading and indexing with almost no AI at import. The default — you can search right away.
- **Hot / Warm / Cold** — Reads everything lightly, then spends extra AI effort only on the important ("hot") part.
- **Full AI** — Runs the AI over every slice of every document. Deepest, but can take hours on big archives.
- **Quality costs time** — Deeper analysis takes longer. The app defaults to fast and on-device (Private mode), and lets you opt into more depth.
- **OCR** — Reads text out of scanned pages and photos. Slower; used automatically for scans and images.
- **Transcription** — Turns audio and video into text on this Mac (Apple Speech, English). Runs while importing when “Transcribe audio & video” is on in Settings → Modules (the default); with it off, recordings are kept and can be transcribed later in Transcripts. A transcript is what the speech model heard, not a certified record.
- **Your database** — Tools → Import a DEVONthink database reads the documents stored in a .dtBase2 where they are, and turns Finder tags into tags. Groups are not read; add indexed folders in Sources.
- **Groups** — Use tags, smart collections or case slices — a document can carry many tags.
- **Smart groups / rules** — Tools → Smart collections and rules. Collections stay up to date; a rule is saved only after a dry run.
- **See Also** — The corroboration meter and near-duplicates: how many independent sources support a fact.
- **Annotations** — Highlights and notes, stored beside the source and never written into it.
- **Item links** — kalsmritikosh:// links open the exact passage.
- **Stamps / Bates** — Tools → Production sets: Bates PDFs, load files, privilege log and legal holds.
- **Sync** — None, by design. Your archive stays on this Mac; move it with a complete backup and its recovery key.
- **AI chat** — Ask answers only from your documents, each claim cited; conflicts are shown, never averaged.
- **Multilingual archives** — One semantic index that understands your documents' own languages — no translate-to-English shortcut.
- **Deeper story review** — Approve, correct, or reject story beats inline; your review feeds the next reconstruction.
- **More formats** — PowerPoint 97–2003 (PPT) and Keynote, which are kept but not read today.
- **Better transcription** — On-demand transcription improvements for long audio and video.
- **The promise that doesn't change** — Private mode stays the default: your documents are read on this Mac, and nothing is sent anywhere unless you turn on Online mode and approve each send.

## Reading results carefully

### Quotations are checked; sources can still be wrong

Every citation is re-verified against the document before it is shown or exported, so the quote is really there. The document itself can be mistaken, out of date, one side of a dispute, or written to mislead. Open the source and judge it as you would any document.

### Shared text is not independent corroboration

When two documents share wording — a forwarded email, a copied paragraph, a template — they count as one source. The source map labels this “shared text / possible relationship” and leaves independence unassessed rather than counting two.

### A repeated amount proves neither agreement nor fraud

The same figure in two places may be an instalment, a refund, a duplicate payment, a quote repeated in a reply, or a coincidence. The app shows the match and its two sources; the classification and its reason are recorded by you.

### A confidence figure is not calibrated until it has been validated

The confidence shown with an item is the evidence gate’s own grading of how well the passages support it. It has not been validated against outcomes for your archive, so treat 80 as “stronger than 60”, not as “right four times in five”. The citations, not the number, are what to check.

### The app documents and finds; the person decides

No job states a legal, accounting, medical or disciplinary conclusion. Results are drafts until reviewed; adverse findings are recorded with your reasons; exports carry what you selected. Professional training and judgement are not replaced by this app.

### What the on-device AI does and does not do

In Private mode the AI runs on this Mac and is used to read, extract and phrase. It can misread a document; that is why every claim carries a citation you can open and why answers outside your documents are marked “Not from your documents”. It does not add facts that are not in your documents to the evidence, and anything it wrote that a document does not support is shown as unsupported.

## Subscription and access

### Plans, the free trial, renewal and cancelling

One edition with all nine professions, as a monthly or annual subscription. Prices and periods are shown by the App Store for your country; the app never shows a made-up price.

1. A 14-day free introductory trial is offered when Apple finds your account eligible (one per account). The subscription screen shows the price that follows the trial and when it will be charged.
2. The subscription renews automatically unless cancelled at least a day before the period ends. Cancel in your Apple Account (Help ▸ Manage subscription, or the “Manage subscription” link on the subscription screen); Apple’s instructions are linked there.
3. Monthly and annual give the same access. Switching plan takes effect at the next renewal; Apple shows the details.
4. Payment, renewal, refunds and restore are handled by Apple. The app opens no connection for them and never sees your payment details. Subscribing does not turn on Online mode.

Screen: **Settings**.

### Restore purchases, another Mac, and being offline

Your subscription follows your Apple account; your archive does not.

1. On a new Mac, or after reinstalling, press “Restore purchases” (subscription screen or Settings ▸ Subscription). The App Store confirms what your account holds.
2. Offline, the last verified state is kept until its own verified end (for example the end of the paid period). The app never extends access beyond what was verified and never removes still-valid access because the store could not be reached.
3. The permanent unlock bought under the earlier plan is honoured for good and is never asked to subscribe. The earlier free 14-day product is a trial, not consent to billing.
4. Your documents and the ledger stay on this Mac. Move them with a complete backup and the recovery key (Settings ▸ Your data).

Screen: **Settings**.

### After the trial or subscription ends

Your work is never locked away or deleted by billing.

1. Every case stays readable. Exports, complete backups, recovery, Help, the sample case and the privacy and erasure controls keep working.
2. Creating, editing and analysing — adding documents, starting a matter, running jobs, asking, writing in the case file, drafting, editing a hypotheses matrix — open the subscription screen instead of running. Nothing is changed by the refusal.
3. A payment that did not go through keeps access during Apple’s verified grace period; after it, the app says plainly that payment failed and what to do.

Screen: **Settings**.

## When something goes wrong

### “The documents don’t say” when you believe they do

The evidence gate found no supporting passage in the documents in scope.

1. Check the case scope: press “Add documents to this case” and look at the counts — a document outside the scope is not read for this case.
2. Check Sources: a file that “could not be read” has no text to search; a scan with little text needs better OCR.
3. Try Search with the exact word or number; if Search finds it and Ask does not, the passage exists but does not support the question as asked — rephrase it.
4. Open Findings ▸ Missing Proof for what would be needed to establish the claim.

Screen: **Sources**.

### A button is greyed out

A disabled control carries the reason and the remedy as its tooltip and in its accessibility description; empty screens say which of five things is true.

1. Hover the control (or read it with VoiceOver): the reason — no documents in scope, nothing selected, a review not saved, no subscription, a hold in force — and the next safe action.
2. An empty screen distinguishes: no files added; files added but unreadable; files outside this case’s scope; evidence insufficient for the question; results waiting for review; an export blocked by a hold or an unverified citation.
3. A failure message says what failed, whether your work was saved, and the next safe action. Work in progress is saved as you go; a save that fails is named, not lost silently.

### Importing or answering is slow

First indexing of a large archive, OCR of scans and transcription of recordings take the longest; answers are faster once indexing has finished.

1. Sources shows what is still being read. Live shows the background pipeline.
2. Settings ▸ Your data ▸ File-type ingest guide estimates time per 100 MB for each file type and system mode.
3. Switch off “Transcribe audio & video” (Settings ▸ Modules) for a faster import; recordings are then kept and can be transcribed later in Transcripts.
4. Background maintenance (off by default) tidies summaries while the Mac is idle and stops the moment you return.

Screen: **Live**.

## The sample tutorial

Help ▸ Replay the Tutorial opens the isolated sample case (its own ledger, bundled Project Delta documents) and walks these steps; nothing touches your own archive.

1. **You are in the sample case.** The purple banner says this is the sample archive: its own ledger with eight bundled Project Delta documents (a supply contract, Amendment 7, two invoices, four emails). Open Sources to see them read. *You should see:* Sources lists the Project Delta folder and shows “Ready” once all eight files are processed. Your own documents are not here and were not opened.
2. **Choose the investigation question.** Open Professional Jobs, choose “Investigator” and press “Start matter”. Name it “Project Delta slip”. The question for this matter: why did the first delivery slip, and who approved the change? *You should see:* A matter named Project Delta slip, with its workspace, and the jobs grouped in phases with “Start here — open a matter” done.
3. **Inspect and authorise the case documents.** Press “Add documents to this case”. Read the preview: how many documents are in scope now, how many are new, how many stay excluded. Confirm. *You should see:* “Documents: 8 in scope”. Only these documents are read for this matter’s jobs and questions.
4. **Ask — one answerable question, one that is not.** Open Ask. Type “When was Amendment 7 approved, and who signed it?” and press “Send question”. Then ask “Was invoice 432 paid?”. *You should see:* The first answer: effective 2 May 2024, signed by John Carter (Northwind) and Maria Lopez (Supplier ABC), cited to the amendment and the 24 May status digest. The second: no document records a payment — the invoice was unpaid as of 14 June 2024 — so the app says the documents do not answer it instead of guessing.
5. **Open the exact citation.** Under the first answer press “Open at this passage” on the amendment citation. *You should see:* The amendment opens at the quoted sentence (“Signed by John Carter (Northwind) and Maria Lopez (Supplier ABC) on May 2, 2024.”). The quotation is checked against the document; whether the document is right is your judgement.
6. **Review conflicting accounts.** Open Findings ▸ Contradictions (or Timeline). Look at the first-lot delivery date: the 8 April email estimates about 13 May 2024; the 18 April email and the amendment say 28 May 2024. *You should see:* Both versions are kept with their sources. An estimate that was later revised is shown as a change of account, not labelled wrong — you decide what it means and record why.
7. **Save a reviewed result.** Back in Professional Jobs, press “Run” on the first job of the intake phase. In the result, decide the rows (or press “Accept shown”), add a note, and press “Save review”. *You should see:* The result shows your decisions and the review time. Unreviewed rows stay marked unreviewed wherever they are carried.
8. **Carry it into the report.** On a reviewed row press “Include in report”; try “Add to chronology” on a dated row. *You should see:* The case file’s report selection and chronology gain the rows with every citation and their review state. A row whose source changes later is shown as stale.
9. **Export the report and reopen it.** Open Cases, open the matter, press “Case file report…”, then “Export…”. Save the file, then open it from the Finder. *You should see:* The exported report lists what you included, each with its sources, and a section for what the evidence does not establish (invoice 432’s payment). The case log records the export with its digest.
10. **What you saw, and back to your own archive.** A supported conclusion (the amendment’s approval, two documents) and an insufficient one (the payment, no document). Press “Back to my archive” in the banner when you are done. *You should see:* The app relaunches on your own archive. Nothing from the sample was written to it; the tutorial can be replayed any time from Help.

