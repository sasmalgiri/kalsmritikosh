# MODULE_MATRIX — every switch in Investigations Made Easy

Generated from `ProductModule` and `KnowledgeModule`. Do not hand-edit.

A module runs only when its code has landed, its gates pass and its switch is on.
New modules default OFF until the owner promotes them. Off is never destructive.

## Product modules

Disposition is the 2026-11-06 scope decision (docs/IME_Core_and_Add_On_Scope_2026-11-06.md §6); the machine-readable inventory is docs/CAPABILITY_INVENTORY.json.

| Plan | Module | Disposition | Family | Built | Default | Gates | When off |
|---|---|---|---|---|---|---|---|
| W1-1 | Advanced search syntax | CORE | Core investigation workflow | yes | on | — | Plain keyword search, as before. |
| W1-2 | Search coverage badge | CORE | Core investigation workflow | yes | on | — | Results only; coverage is still recorded. |
| W1-3 | Signed import and export receipts | CORE | Core investigation workflow | yes | off | — | Unsigned receipts as before. |
| W1-4 | Tags | CORE | Core investigation workflow | yes | on | — | Tags are hidden but kept; turning this back on restores them. |
| W1-5 | Links to passages (kalsmritikosh://) | CORE | Core investigation workflow | yes | off | — | Links are not offered; existing links show a 'links are off' message. |
| W1-6 | Shortcuts actions | OPTIONAL | Connections and automation | yes | off | — | Actions refuse with a message to turn them on. |
| W1-7 | Command palette | CORE | Core investigation workflow | yes | on | — | Menus and toolbar only; ⌘K does nothing. |
| W1-8 | Move the ledger to another disk | OPTIONAL | Connections and automation | yes | off | — | Boot uses the copy on this Mac; a copy on another disk is left in place. |
| W1-9 | Import queue | CORE | Core investigation workflow | yes | off | — | Imports run in the order added, with progress in the toolbar. |
| I-1 | Proof bundles | SPLIT | Professional workflows | yes | off | — | Answers export as before, without a bundle. |
| I-2 | What is missing | MERGE | Core investigation workflow | yes | off | — | The existing Insights gap list stays; the grouped map and per-answer gaps are hidden. |
| I-3 | Source counts | MERGE | Core investigation workflow | yes | off | — | Citations only. |
| I-4 | Look for contradicting evidence | MERGE | Core investigation workflow | yes | off | — | Contradictions are shown only when they are found during the normal search. |
| I-5 | Filter by document date | SPLIT | Presentation and history exploration | yes | off | — | Answers always use all evidence. |
| I-6 | Fact-check my writing | MERGE | Core investigation workflow | yes | off | — | The fact-check tool is hidden. |
| I-7 | Archive self-test (diagnostic) | INTERNAL | Diagnostics | yes | off | — | No self-test runs. |
| I-8 | Send the least data | CORE | AI assistance | yes | off | Online mode, needs O-4 | Online answers send the passages the question needs, every send logged; no daily limit. No case document is sent until you allow AI for that case (questions inside an allowed case go without a further prompt). |
| I-9 | How an account changed | OPTIONAL | Advanced analysis | yes | off | — | Contradictions between documents only. |
| I-10 | Signed case slices | SPLIT | Professional workflows | yes | off | needs W1-4 | Work products export as documents only. |
| I-11 | How this answer was found | CORE | Core investigation workflow | yes | off | — | The answer and its citations only. |
| I-12 | Living dossiers | MERGE | Core investigation workflow | yes | off | — | Dossiers are built when opened, without the since-last-time strip. |
| W2-1 | Highlights and notes | CORE | Core investigation workflow | yes | on | — | Highlights are hidden but kept. |
| W2-2 | Email authenticity checks | SPLIT | Advanced analysis | yes | off | — | Emails are read as before; no authenticity result. |
| W2-3 | Outlook PST reader (MS-PST) | CORE | Core investigation workflow | yes | off | — | The current PST reader is used. |
| W2-4 | Near-duplicates | SPLIT | Advanced analysis | yes | off | — | Exact duplicates only. |
| W2-5 | Production sets | SPLIT | Professional workflows | yes | off | — | No Bates numbering or load files. Legal holds are part of the core (Tools ▸ Legal holds): they can be created and released, and they block forgetting and erasing, with this switched off. |
| W2-6 | More export formats | SPLIT | Professional workflows | yes | off | — | Core exports stay: case reports in PDF, Word and CSV from the case file, and the timeline, entities and sources as CSV, Word or PDF from Tools ▸ Export. |
| W2-7 | Lock with Touch ID | CORE | Core investigation workflow | yes | off | — | No app lock; the Mac's own login protects the data. |
| W2-8 | Very large items | CORE | Core investigation workflow | yes | off | — | Very large items are recorded as too large. |
| W3-1 | Import a DEVONthink database | OPTIONAL | Connections and automation | yes | off | — | DEVONthink databases are not recognised. |
| W3-2 | Send to DEVONthink | OPTIONAL | Connections and automation | yes | off | — | Not offered. |
| W3-3 | Timeline and relationship views | MERGE | Core investigation workflow | yes | off | — | Lists only. |
| W3-4 | Alerts | OPTIONAL | Connections and automation | yes | off | — | No alerts; contradictions still appear in answers. |
| W3-5 | Automatic rules | SPLIT | Connections and automation | yes | off | — | Saved searches stay part of the core (Tools ▸ Documents ▸ Saved searches); rules are kept but do not run. |
| W3-6 | Import from iPhone or iPad | SPLIT | Connections and automation | yes | off | — | “Save to Investigations Made Easy” in the Share and Services menus stays part of the core unless you switched this off yourself; importing from an iPhone or iPad is off. |
| W3-7 | Show in Spotlight | OPTIONAL | Connections and automation | yes | off | — | Nothing is given to Spotlight, and any earlier entries are removed. |
| N-1 | Issues and chronology | MERGE | Core investigation workflow | yes | off | — | Chronology without issues. |
| N-2 | Who talks to whom | OPTIONAL | Advanced analysis | yes | off | — | Threads only. |
| N-3 | Watchlists | OPTIONAL | Advanced analysis | yes | off | — | Lists are kept but not matched. |
| N-4 | Review coding | SPLIT | Professional workflows | yes | off | — | No coding. |
| N-5 | Briefings, FAQs and mind maps (retired) | RETIRE | Retired — kept for earlier work | yes | off | — | Not offered. Files made earlier are yours and are not touched. |
| N-6 | Ask from anywhere | OPTIONAL | Connections and automation | yes | off | — | Ask from the main window only. |
| N-7 | Similar images | OPTIONAL | Media and geography | yes | off | — | Images are searchable by their text only. |
| N-8 | Places | OPTIONAL | Media and geography | yes | off | — | Not shown. |
| N-9 | Import notes apps | OPTIONAL | Connections and automation | yes | off | — | These folders import as plain files. |
| N-10 | Mask personal details before sending | CORE | AI assistance | yes | off | Online mode, needs O-4 | Passages are sent unmasked. No case document is sent until you allow AI for that case (questions inside an allowed case go without a further prompt); every send is logged. |
| N-11 | Watch a question | OPTIONAL | Connections and automation | yes | off | — | Pinned questions are kept but not re-asked. |
| N-12 | Your own record types | OPTIONAL | Advanced analysis | yes | off | — | Types are kept but not filled. |
| N-13 | Review priority (documents) | SPLIT | Advanced analysis | yes | off | needs N-4 | Documents are listed in the order they were added. |
| W4-1 | Improved text recognition | CORE | Core investigation workflow | yes | off | — | The current text recognition. |
| W4-2 | More file types | SPLIT | Media and geography | yes | off | — | These files are kept but not read. |
| W4-3 | Deleted email recovery | OPTIONAL | Advanced analysis | yes | off | — | Only live mail is read. |
| W4-4 | Team review over a shared folder | DEFER | Not in this version | yes | off | — | Single-user cases. |
| O-4 | Answers with your own cloud AI key | OPTIONAL | AI assistance | yes | off | Online mode | All answers are made on your Mac. |
| P-2 | Your own notes | CORE | Core investigation workflow | yes | on | — | Notes are hidden but kept, with their versions; what the archive learned from them stays. |
| X-2 | Your own folders | MERGE | Core investigation workflow | yes | off | — | Groups are hidden but kept, with their members. |
| X-1 | See Also and filing suggestions | OPTIONAL | Connections and automation | yes | off | needs X-2 | No suggestions; groups and tags work as before. |
| X-3 | Rich text notes and PDF marks | SPLIT | Presentation and history exploration | yes | off | — | Rich notes and PDF marks are hidden but kept. |
| X-5 | Sync through a folder | OPTIONAL | Connections and automation | yes | off | — | Nothing is written to or read from the sync folder; everything stays on this Mac. |
| IF-A5 | Content creator persona (retired) | RETIRE | Retired — kept for earlier work | yes | off | — | The persona and its studio are hidden; saved publish packages are kept and return when this is turned on. |

_60 of 60 product modules built._

## Knowledge modules (ledger and answer internals)

| Module | Group | Built | Default | Gates |
|---|---|---|---|---|
| Topic minimization | Knowledge synthesis | yes | on | needs Auto-build topics |
| Auto-build topics | Knowledge synthesis | yes | on | — |
| Summaries at idle | Knowledge synthesis | yes | on | — |
| History at idle | Knowledge synthesis | yes | on | — |
| Event detail fill (5W+H) | Knowledge synthesis | yes | on | AI |
| Plain-document subject binding | Knowledge synthesis | yes | off | — |
| AI subject resolution (merge duplicate topics) | Knowledge synthesis | yes | off | AI, needs Auto-build topics |
| AI topic prose | Knowledge synthesis | yes | on | AI, needs Auto-build topics |
| Group by real-world subject | Knowledge synthesis | yes | on | — |
| Cross-encoder reranking | Retrieval | yes | on | — |
| Corrective re-retrieval | Retrieval | yes | on | — |
| Hypothetical query expansion | Retrieval | yes | on | AI |
| Boilerplate embed-skip | Retrieval | yes | on | — |
| Password-protected files | Retrieval | yes | on | — |
| Import & coverage lifecycle | Retrieval | yes | on | — |
| Transcribe audio & video | Retrieval | yes | on | — |
| Understand any wording of a question | Answer composition | yes | on | — |
| Let your cloud AI read the documents about a person (Online) | Answer composition | yes | off | — |
| AI writes every answer | Answer composition | yes | on | AI |
| Story review (approve / correct / reject) | Answer composition | yes | on | — |
| Actor answers (who did X) | Answer composition | yes | on | — |
| Progressive answer streaming | Answer composition | yes | on | — |
| Topic-first composition | Answer composition | yes | on | AI, needs Auto-build topics |
| Record why an import step failed | Import integrity | yes | on | — |
| Strict derivation (stop on a failed step) | Import integrity | yes | on | — |
| Track unfinished imports | Import integrity | yes | on | — |
| Read names from authorisation forms | Extraction & search | yes | on | — |
| Whole-document keyword search | Extraction & search | yes | on | — |
| Read labelled fields from any document | Universality | yes | on | — |
| Ask about any field we found | Universality | yes | on | needs Read labelled fields from any document |
| Group unfamiliar document kinds | Universality | yes | on | needs Read labelled fields from any document |
| Read documents no built-in rule recognises | Universality | yes | off | AI |
| Report what each format can give you | Universality | yes | on | — |
| State the English-only limit | Universality | yes | on | — |
| Story chapters & recorded disagreements | Extraction & search | yes | on | — |

## Not switchable, by design

- Nothing goes online without the user seeing what will be sent (O-5).
- Every online send is recorded with a receipt (O-5).
- Online answers pass the same claim–evidence check as private ones; cloud text is never primary evidence (O-6).
- If Online fails the app says so and offers a private answer; it never switches mode on its own (O-7).
- A new user starts in Private mode (owner decision 2026-10-15).
- The main app keeps no network permission; only the network helper has it (O-2, W0-C).
- Legal holds can be created and released with every module off, and a hold always blocks forgetting and erasing.
- Every case export re-checks its citations, privilege and access, whatever is switched on.
- Backup, restore and erasure (Settings ▸ Your data) are never behind a module or a purchase.
- What each search and case could and could not read is always recorded; a switch only changes how much is shown.
- No case document goes to an AI without that case's permission, whatever module is on.
- A persona preset or pack only switches modules on — never a safeguard off — and never switches on Online, Spotlight, sync or watched questions.
