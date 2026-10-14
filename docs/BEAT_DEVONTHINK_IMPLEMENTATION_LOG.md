# Beat DEVONthink — implementation log

Owner rule (2026-10-15): implement everything first, **no tests during implementation**; one test phase at
the end against each item's "Done means" (see `BEAT_DEVONTHINK_FINAL_TODO.md`). Compile checks are run
to keep the tree building. Every feature is behind its `ProductModule` switch and defaults OFF.

## Built

| ID | What landed | Commit |
|---|---|---|
| W0-M | `ProductModule` (54 switches), `ConnectivityMode` (Private default / Online needs bundled helper), `ModuleInvariant`, Settings ▸ Modules (Connection + Features), `MODULE_MATRIX.md` | 9833d055 |
| I-3 | `CorroborationMeter` — independent sources per answer (conservative count) | cbc24fb3 |
| I-4 | `DisconfirmationScanner` — deterministic contradicting-evidence check over uncited passages | cbc24fb3 |
| I-7 | `ArchiveSelfScore` — accuracy on your archive + calibrated confidence note; Settings button | cbc24fb3 |
| I-11 | `AnswerPathExplainer` — plain-language "how this answer was found" | cbc24fb3 |
| W1-1 | `AdvancedSearchCompiler` + `ChunksRepository.searchAdvanced` — AND/OR/NOT, phrases, NEAR/n, prefix, brackets, type:/file:/before:/after:/entity:/tag: and negation; issues reported | (this commit) |
| W1-2 | `SearchCoverage` — matched fields, searchable-of-total, sources still indexing | (this commit) |
| W1-3 | `ReceiptSigner` — exported receipts carry an ECDSA P-256 signature (Secure Enclave/Keychain installation key) over title+seal; verifier shows signer fingerprint or FAILED; `writeImportReceipt` seals+signs one receipt per Add-files batch (content hash + size per file, or the error) into Receipts/ | (this commit) |
| W1-5 | `DeepLink` `kalsmritikosh://document/<id>?quote=` — parse, open at passage via `CitationSourceSheet`, missing-item / switched-off messages; Copy link on citation chips and search results | (this commit) |
| W1-6 | App Intents: Ask, Ask with receipt, Search, Add files, Open a passage link; Ask/Search App Shortcuts; refuse when off | 763e6055 |
| W1-7 | **False gap** — ⌘K palette and the ? shortcut sheet already existed. Gated on the module switch, which defaults ON so behaviour is unchanged | (this commit) |
| W1-8 | `LedgerRelocation` — VACUUM INTO + quick_check, every other file SHA-256 verified, security-scoped bookmark; boot follows it only when the disk is present and not behind this Mac's copy, else opens the local copy with a notice; Settings ▸ Your data | (this commit) |
| W1-9 | `ImportQueue` (one worker, pause between files, skip, move up/down, clear finished) + `ImportQueueView`; Add files and the Shortcuts Add-files action route through it when on; ends with an import receipt | (this commit) |
| I-1 | `ProofBundle` — bundle.json (quotes + hashes + source SHA-256, P-256 signature raw+DER) and a self-contained offline verify.html (WebCrypto signature check, re-hash chosen sources, quote-in-text check for text files); Ask answer context menu | (this commit) |
| I-2 | `WhatIsMissingView` (gaps grouped by kind, reason, likelihood, dismiss keeps) from Insights; per-answer gaps (cited documents or named entities) in the answer trust panel | (this commit) |
| W1-4 | Schema **v142** `user_tags` + `user_tag_links` (soft remove, merge retires), `TagsRepository`, `TagEditorSheet`, Tag button on results, `tag:` search filter | (this commit) |

## Pending from the owner

| ID | Needed |
|---|---|
| O-1 | Approve the SHIP_DECISIONS change-control entry (Online mode) |
| O-2 | Create the `KalsmritikoshNetwork` XPC service target in Xcode (network-client entitlement on the helper only) |
| W1-5 | Add the `kalsmritikosh` URL type in Xcode (Info tab ▸ URL Types) |
| W3-1 | A test DEVONthink database to verify the package layout |
| W3-6 | Share / Safari extension targets in Xcode |
| W0-A | DEVONthink trial + local model + API key; run DEVONthink's side of the benchmark |
| O-8 | Review privacy policy / App Store text |

## For the final test phase

- `MigrationMatrixTests` pins `latestVersion == 141`; it is now **142** (v142 user tags). Update the pin.
- Regenerate `MODULE_MATRIX.md` from `ModuleMatrixDocument.render()` and add a drift test.
- Each built item: write the tests named in its "Done means" column.
- W1-3: import receipts are written only for the Add-files path; the folder-watcher/bulk ingest path does not write one yet.
- W1-5: links do nothing until the `kalsmritikosh` URL type is registered (owner step).
- Search screen: a search with issues but zero hits shows the empty state, so the issues are not visible — check and fix.
