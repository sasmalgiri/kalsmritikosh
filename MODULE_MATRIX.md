# MODULE_MATRIX — every switch in Kalsmritikosh

Generated from `ProductModule` and `KnowledgeModule`. Do not hand-edit.

A module runs only when its code has landed, its gates pass and its switch is on.
New modules default OFF until the owner promotes them. Off is never destructive.

## Product modules (beat-DEVONthink plan)

| Plan | Module | Group | Built | Default | Gates | When off |
|---|---|---|---|---|---|---|
| W1-1 | Advanced search syntax | Search & organise | yes | off | — | Plain keyword search, as before. |
| W1-2 | Search coverage badge | Search & organise | yes | off | — | Results only; coverage is still recorded. |
| W1-3 | Signed import and export receipts | Evidence & proof | yes | off | — | Unsigned receipts as before. |
| W1-4 | Tags | Search & organise | yes | off | — | Tags are hidden but kept; turning this back on restores them. |
| W1-5 | Links to passages (kalsmritikosh://) | Integration | yes | off | — | Links are not offered; existing links show a 'links are off' message. |
| W1-6 | Shortcuts actions | Integration | yes | off | — | Actions refuse with a message to turn them on. |
| W1-7 | Command palette | Integration | yes | on | — | Menus and toolbar only; ⌘K does nothing. |
| W1-8 | Move the ledger to another disk | Storage | yes | off | — | Boot uses the copy on this Mac; a copy on another disk is left in place. |
| W1-9 | Import queue | Storage | yes | off | — | Imports run in the order added, with progress in the toolbar. |
| I-1 | Proof bundles | Evidence & proof | yes | off | — | Answers export as before, without a bundle. |
| I-2 | What is missing | Investigation | yes | off | — | The existing Insights gap list stays; the grouped map and per-answer gaps are hidden. |
| I-3 | Corroboration meter | Evidence & proof | yes | off | — | Citations only. |
| I-4 | Look for contradicting evidence | Evidence & proof | yes | off | — | Contradictions are shown only when they are found during the normal search. |
| I-5 | As of a date | Investigation | yes | off | — | Answers always use all evidence. |
| I-6 | Fact-check my writing | Writing | yes | off | — | The fact-check tool is hidden. |
| I-7 | Accuracy on your archive | Evidence & proof | yes | off | — | No self-test runs; confidence uses the built-in scale. |
| I-8 | Send the least data | Online (your own key) | yes | off | Online mode, needs O-4 | Online answers send the passages the question needs, still previewed and logged; no daily limit. |
| I-9 | How an account changed | Investigation | yes | off | — | Contradictions between documents only. |
| I-10 | Signed case slices | Sharing | yes | off | needs W1-4 | Work products export as documents only. |
| I-11 | How this answer was found | Evidence & proof | yes | off | — | The answer and its citations only. |
| I-12 | Living dossiers | Investigation | yes | off | — | Dossiers are built when opened, without the since-last-time strip. |
| W2-1 | Highlights and notes | Writing | not yet | off | — | Highlights are hidden but kept. |
| W2-2 | Email authenticity checks | Email evidence | not yet | off | — | Emails are read as before; no authenticity result. |
| W2-3 | Outlook PST reader (MS-PST) | Email evidence | not yet | off | — | The current PST reader is used. |
| W2-4 | Near-duplicates | Search & organise | not yet | off | — | Exact duplicates only. |
| W2-5 | Production sets | Legal | not yet | off | — | Exports without Bates numbers or load files; holds are kept but not enforced. |
| W2-6 | More export formats | Sharing | not yet | off | — | The current export formats. |
| W2-7 | Lock with Touch ID | Storage | yes | off | — | No app lock; the Mac's own login protects the data. |
| W2-8 | Very large items | Storage | not yet | off | — | Very large items are recorded as too large. |
| W3-1 | Import a DEVONthink database | Integration | not yet | off | — | DEVONthink databases are not recognised. |
| W3-2 | Send to DEVONthink | Integration | not yet | off | — | Not offered. |
| W3-3 | Timeline and relationship views | Investigation | not yet | off | — | Lists only. |
| W3-4 | Alerts | Investigation | yes | off | — | No alerts; contradictions still appear in answers. |
| W3-5 | Smart collections and rules | Search & organise | not yet | off | — | Saved searches run only when opened; rules do not run. |
| W3-6 | Share and capture | Integration | not yet | off | — | Add files from inside the app only. |
| W3-7 | Show in Spotlight | Integration | not yet | off | — | Nothing is given to Spotlight, and any earlier entries are removed. |
| N-1 | Issues and chronology | Legal | yes | off | — | Chronology without issues. |
| N-2 | Who talks to whom | Email evidence | yes | off | — | Threads only. |
| N-3 | Watchlists | Investigation | yes | off | — | Lists are kept but not matched. |
| N-4 | Review coding | Legal | yes | off | — | No coding. |
| N-5 | Briefings, FAQs and mind maps | Writing | not yet | off | — | Not offered. |
| N-6 | Ask from anywhere | Integration | not yet | off | — | Ask from the main window only. |
| N-7 | Similar images and faces | Investigation | not yet | off | — | Images are searchable by their text only. |
| N-8 | Places | Investigation | not yet | off | — | Not shown. |
| N-9 | Import notes apps | Integration | not yet | off | — | These folders import as plain files. |
| N-10 | Mask personal details before sending | Online (your own key) | yes | off | Online mode, needs O-4 | Passages are sent unmasked, still previewed first. |
| N-11 | Watch a question | Investigation | yes | off | — | Pinned questions are kept but not re-asked. |
| N-12 | Your own record types | Search & organise | not yet | off | — | Types are kept but not filled. |
| N-13 | What to read first | Investigation | yes | off | needs N-4 | No score. |
| W4-1 | Improved text recognition | Reading files | not yet | off | — | The current text recognition. |
| W4-2 | More file types | Reading files | not yet | off | — | These files are kept but not read. |
| W4-3 | Deleted email recovery | Email evidence | not yet | off | — | Only live mail is read. |
| W4-4 | Team review over a shared folder | Sharing | not yet | off | — | Single-user cases. |
| O-4 | Answers with your own cloud AI key | Online (your own key) | yes | off | Online mode | All answers are made on your Mac. |

_31 of 54 product modules built._

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
