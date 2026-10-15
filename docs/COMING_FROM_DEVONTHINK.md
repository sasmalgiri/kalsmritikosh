# Coming from DEVONthink

This page is for people who already keep their documents in DEVONthink. It shows where each DEVONthink idea lives in Kalsmritikosh, what is different on purpose, and what Kalsmritikosh does not do.

The short version: **DEVONthink is a place to keep and organise documents. Kalsmritikosh reads the documents you already keep and builds a record of what they say** — who, what, when, which source — so you can ask questions and get answers that cite the exact passage.

Most features below are switches. Find them in **Settings → Modules**; switched-off features disappear from the app. Stand-alone tools appear in the sidebar **Tools** menu, grouped into a few windows with tabs, while their switch is on.

## Bringing your DEVONthink database across

1. Switch on **Import a DEVONthink database** (Settings → Modules), or tick *I'm coming from DEVONthink* during onboarding — that switches on the import and smart-collection tools for you.
2. Open **Tools → Bring documents in → Import a DEVONthink database** and choose your `.dtBase2` file.
3. Press **Add and read**. Kalsmritikosh reads the documents stored inside the database where they are. Nothing is copied out and nothing is written into the database, so DEVONthink keeps working exactly as before.
4. Press **Apply Finder tags** to turn your tags into Kalsmritikosh tags.
5. Press **Check every file is accounted for** when reading finishes.

What does not come across:

- **Groups.** DEVONthink keeps its group tree in its own undocumented files, so groups are not read. Use tags or smart collections instead.
- **Indexed items.** Files that DEVONthink only indexes live outside the database. Add those folders in **Sources** directly.

## Concept map

| In DEVONthink | In Kalsmritikosh | Notes |
|---|---|---|
| Database | Your sources (folders you add in **Sources**) plus one ledger | Files stay where they are; Kalsmritikosh never moves or copies your originals. |
| Group | Tags, smart collections or case slices | No folder tree inside the app; a document can carry many tags. |
| Tag | Tags (**Tags** switch) | Rename and merge tags without losing links. |
| Smart group | Smart collection (**Tools → Watch & alerts**) | Uses the search syntax, e.g. `type:email org:acme after:2024-01-01 "invoice"`. Counts stay up to date while open. |
| Smart rule | Rule (same tool) | "When a new document matches → tag it / alert me". A rule can be saved only after a dry run shows what it would match. |
| Search with operators | Search with the search syntax (**Advanced search syntax**) | `type:`, `file:`, `before:`, `after:`, `entity:`/`person:`/`org:`, `tag:`, quotes, `-` to exclude. A badge shows how much of your archive the search covered. |
| See Also / Classify | Corroboration meter, related entities, near-duplicates | Instead of "similar documents", answers say how many *independent* sources support a fact. |
| Concordance | Entities and the Dossier | People, companies, places and amounts are recognised and unified across spellings. |
| Annotation | **Highlights and notes** | Stored beside the source, never written into it. A note can say *I confirm this* or *I correct this*. |
| Duplicates | Exact duplicates + **Near-duplicates** | Drafts and forwards are linked as versions; nothing is merged or deleted. |
| Replicants | Not needed | One ledger points at your files; there is nothing to replicate. |
| Item links (`x-devonthink-item://`) | Passage links (`kalsmritikosh://`) | Links open the exact passage, not just the file. |
| Send to DEVONthink | **Send to DEVONthink** | Kalsmritikosh can send an answer and its sources back to DEVONthink. |
| AI chat | **Ask** | Answers come only from your documents, each claim with its citation. Conflicting sources are shown as a conflict, not averaged. |
| AI providers | **Answers with your own cloud AI key** (optional) | Private mode is the default and makes no connection. Online mode is opt-in, uses only your own Claude/OpenAI/Gemini key, shows a badge and returns to Private in one click. |
| OCR | Built-in text recognition + **Improved text recognition** | Searchable-PDF copies of scans. |
| Stamps and Bates numbering | **Production sets** | Bates-numbered PDFs, Concordance/Relativity load files, privilege log, and legal holds that block deletion. |
| Encrypted database | **Lock with Touch ID** + FileVault | Whole-database encryption is an open decision. |
| Web clipper / Sorter | **Share and capture** | Drop or paste into the capture window; each item gets a custody record. Share-menu and Safari extensions are planned. |
| Sync | None, by design | Team work uses **Team review over a shared folder** (preview) — signed logs, no server. |
| DEVONthink To Go | Not yet | A read-only iPhone/iPad viewer from a signed snapshot is planned. |

## What Kalsmritikosh adds

- **Dated facts and a timeline** built from every document, each with its source.
- **An evidence gate** that refuses to answer when the documents don't support an answer.
- **What is missing**: what would be needed to prove a claim and isn't there.
- **As of a date**: what the archive said on a given day.
- **Signed receipts and proof bundles** that anyone can check were not changed.
- **Email forensics**: DKIM/ARC checks against keys you supply, hidden timestamps, deleted mail that is still present.

## What Kalsmritikosh does not do

- It is not a document editor or a writing environment.
- It does not sync between your devices.
- It does not keep a group hierarchy.
- It does not read PowerPoint 97–2003 or 7z/RAR contents yet; those files are kept but not read. Keynote text is read in part (with **More file types** on).
