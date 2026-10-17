# Kalsmritikosh user manual

Kalsmritikosh reads the documents and email you already have, on your Mac, and builds a record of what they say: people and organisations, dated events, a timeline, and the exact passage each fact came from. You ask questions in plain language and get answers that cite their sources — or an honest "the documents don't say".

Kalsmritikosh works beside DEVONthink: it reads your DEVONthink database in place, sends answers back to it, and adds what DEVONthink does not do. Features DEVONthink already has start switched off (Settings → Modules → *Also in DEVONthink*). Coming from DEVONthink? Read [Coming from DEVONthink](COMING_FROM_DEVONTHINK.md) first.

## 1. Getting started

1. **Add your documents.** Open **Sources** and add a folder. Files are read where they are; nothing is moved or copied. Reading starts by itself and the progress bar shows how far it has got.
2. **Ask a question.** Open **Ask** and type, for example, *"When was the contract signed?"*. Each sentence of the answer carries numbered citations; click one to open the source at the quoted passage.
3. **Check how sure the answer is.** Under each answer, the quality strip shows confidence, how many sources support it, how recent they are, and any conflicts.

### Private and Online

Kalsmritikosh starts in **Private** mode: everything runs on your Mac and the app makes no network connection. **Online** mode is optional. Turn it on in **Settings → Modules → Connection** with your own Claude, OpenAI or Gemini key. Before anything is sent you see exactly what will go, personal details can be masked, and every request is logged. A badge shows when Online is on; one click returns you to Private.

### Turning features on and off

Every feature is a switch in **Settings → Modules**. A feature that is off disappears from the app, and the list says what happens instead. Stand-alone tools appear in the sidebar **Tools** menu, grouped into windows with tabs (Legal review, Watch & alerts, People & connections, Email forensics, Writing & checking, Documents, Bring documents in, Export, Team review), while their switch is on. Choosing your role in onboarding switches on the tools that role needs. Features marked *preview* are built but not yet verified; they appear only after **Show preview features** is turned on.

## 2. Finding things

- **Search** accepts plain words or the search syntax: `type:email`, `file:report`, `before:2024-06-01`, `after:2023-01-01`, `person:"Ann Lee"`, `org:acme`, `tag:urgent`, quoted phrases, and `-` to exclude. The coverage badge says how much of your archive the search actually covered.
- **Command palette** (⌘K) jumps to any screen or action.
- **Smart collections** (Tools) are saved searches that stay up to date.
- **Tags** can be added to any document; rename or merge them without losing links.
- **Ask from anywhere** puts a small Ask panel in the menu bar.

## 3. Trusting an answer

- **Corroboration meter**: how many *independent* sources support the answer. Copies, forwards and near-duplicates count once.
- **Look for contradicting evidence**: the app searches for documents that disagree and shows them.
- **How this answer was found**: the steps from question to sources.
- **What is missing**: the evidence that would settle the question but isn't in your archive.
- **As of a date**: the answer as your archive would have given it on a chosen day.
- **Accuracy on your archive** (Settings): measures how often answers are right on your own documents.

## 4. Recipes by role

### Lawyers

- **Build a chronology:** Tools → *Legal review* → *Issues and chronology*. Create issues, link events to them, and draft a chronology with citations.
- **Review documents:** Tools → *Legal review* → *Review coding*. Code documents Responsive, Not responsive, Privileged or Hot.
- **Produce documents:** Tools → *Legal review* → *Production sets*. Documents coded Responsive or Hot are produced as Bates-numbered PDFs with Concordance (DAT) and Opticon (OPT) load files. Privileged documents get a numbered slip sheet and a privilege-log line. Numbers are never reused.
- **Legal hold:** in the same tool, put the set on hold. Held documents cannot be forgotten or erased until the hold is released, even if the tool is switched off.
- **Redact a PDF:** text is burned in, and text inside scanned images is found and burned in too. The result is checked; if anything is still readable, no file is produced.
- **Share a case slice:** a signed, self-contained bundle of one issue's documents and facts.

### Investigators

- **Who talks to whom:** Tools → *People & connections* → *Who talks to whom*: message counts, first and last contact, and silences.
- **Relationship graph and timeline:** Tools → *People & connections*.
- **Watchlists:** Tools → *Watch & alerts*: names to watch for; new documents that mention them raise an alert. Smart collections and rules live in the same window.
- **Email authenticity:** Tools → *Email forensics*: DKIM and ARC (against keys you paste in), hidden timestamps, the Received trace, and signs of change.
- **Deleted mail:** Tools → *Email forensics* → *Deleted email recovery* lists messages a mail program marked deleted but did not erase.
- **Photos:** Tools → *Documents* → *Similar images* finds copies and crops of a photo. Face grouping is not part of this version. *Places* (photo locations and places named in documents) is a preview feature under *People & connections*.

### Journalists and researchers

- **Fact-check your writing:** Tools → *Writing & checking*. Paste a draft; each sentence is checked against your archive.
- **How an account changed:** Tools → *Writing & checking* → *How an account changed* compares what a person said at different times.
- **Briefings, FAQs and mind maps:** Tools → *Writing & checking*, built only from the ledger.
- **Notes apps:** add an Obsidian vault or a Notion export in Sources, then Tools → *Bring documents in* → *Import notes apps*. Links between notes become links you can follow both ways.

### Teams

- **Team review over a shared folder** (preview): Tools → *Team review*. Everyone opens the same case folder. Each reviewer's work is a signed log of their own; *Verify all logs* reports any tampering at the exact entry. *Apply team codes here* refuses to apply anything if a log fails verification.

## 5. Bringing documents in

- **Formats:** see `CAPABILITY_MATRIX.md` for every format and how fully it is read.
- **Capture:** Tools → *Bring documents in* → *Share and capture*. Drop files or paste text; each item is saved with a custody record (time, origin, SHA-256).
- **Import queue:** shows what is waiting, reading and done, with a receipt per import.
- **Very large items** (switch): an item over the size budget is kept by byte range. Its first part is searchable and it is marked partial, instead of failing.
- **Outlook PST:** the MS-PST reader switch reads Outlook files by Microsoft's published format and reports both readers' message counts.

## 6. Getting things out

- **Export:** Tools → *Export* writes the timeline, the entity list or a set of sources as CSV, JSON, Markdown, HTML, Word, Excel, PDF or mbox. A check shows counts first, and a signed receipt is written beside every export.
- **Proof bundles:** right-click an answer to export it with its sources and a signed receipt.
- **Searchable PDFs:** Tools → *Documents* → *Improved text recognition* saves a searchable copy of a scan.
- **Send to DEVONthink:** right-click an answer.

## 7. Safety and privacy

- **Lock with Touch ID:** locks on sleep or after idle time.
- **Move the ledger:** Settings → move the ledger to another disk.
- **Nothing is deleted** by the app's own processing. Removing something stamps it as removed and keeps it. The only erasing actions are *forget this folder* and *erase all data*, both blocked by any active legal hold.

## 8. When something looks wrong

- An answer says *the documents don't say*: the evidence gate found no supporting passage. Try **What is missing**.
- A file shows *kept but not read*: its format is preserved but not interpreted, or its switch is off. Check Settings → Modules and `CAPABILITY_MATRIX.md`.
- A scan has little text: Tools → *Documents* → *Improved text recognition* lists weak scans.
