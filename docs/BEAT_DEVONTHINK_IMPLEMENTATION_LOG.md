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
- Search screen: a search with issues but zero hits shows the empty state, so the issues are not visible — check and fix.
