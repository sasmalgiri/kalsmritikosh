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
| I-5 | `answerAsOf` — same question re-asked through `InvestigationAnswerService.answer(scopedTo:)` (fail-closed SourceScopedRetriever) over source versions with file date ≤ the day; lists today's cited documents dated later; As-of control in the answer trust panel | (this commit) |
| I-6 | `SentenceFactChecker` (deterministic supported/contradicted/unsupported per sentence, reuses the I-4 extractors) + `FactCheckWritingView` (debounced, up to 40 sentences) from the sidebar. Plan said 'in the notebook editor' — no free-writing editor exists, so it is a standalone tool | (this commit) |
| I-9 | `StatementDrift` — statements naming a person + topic in date order; later statements on the same subject with a different date/amount or flipped polarity flagged with both quotes; `StatementDriftView`. New sidebar **Tools** menu (`ToolSheet`) lists only switched-on tools (fact-check, drift) | (this commit) |
| I-10 | `CaseSlice` — from a tag: redacted names + import fingerprints, dated events, 3 passages per document; PIIRedactor (emails, phones, listed terms); P-256 signature over sorted-key JSON; `CaseSliceView` exports and opens read-only with verify (Tools menu). Depends on tags | (this commit) |
| I-12 | `dossierChanges` — per-subject last-opened time; documents that entered the ledger since then mentioning the subject + their dated events; strip in DossierView header | (this commit) |
| O-1 | SHIP_DECISIONS change-control entry (owner decision 2026-10-15, written sign-off pending); release guard allows `network.client` ONLY in `KalsmritikoshNetwork/KalsmritikoshNetwork.entitlements`, never `network.server`, nothing in any other file | (this commit) |
| O-2 | Helper sources `KalsmritikoshNetwork/` (XPC service: HTTPS POST to 3 allowlisted hosts, ephemeral session, no storage) + README of owner steps; `NetworkHelperClient` in the app — **target not created (owner step)** | (this commit) |
| O-3 | `ConnectivityMode` (W0-M) + always-visible Online bar with one-click Switch to Private | (this commit) |
| O-4 | `OnlineCloudProvider` (Claude Messages API with fallbacks, OpenAI chat completions, Gemini generateContent), key in Keychain, registered in every build but eligible only when `OnlineSettings.cloudAllowed` (CapabilityRegistry.cloudEligible; generation only, never embeddings) and ranked first then | (this commit) |
| O-5 | `OutboundConsent` sheet before every send (not switchable); schema **v143** `outbound_log` + `OutboundLogRepository`; "What was sent" viewer | (this commit) |
| O-6 | By construction: the cloud provider is just a provider, so its text goes through the same claim–evidence gate and call budgets | (this commit) |
| O-7 | `OnlineStatus` failure banner; no automatic mode switch (the user presses Switch to Private) | (this commit) |
| I-8 | Daily byte limit (0 = send nothing), bytes measured per send; deterministic answers already make no call | (this commit) |
| N-10 | `OnlinePIIMasker` — ledger people/organisation names, emails, phones, 6+ digit IDs → placeholders, restored locally; preview shows the masked text | (this commit) |
| O-8 | `release/ONLINE_MODE_DISCLOSURE_DRAFT.md` — privacy-policy section, App Store privacy answers, review notes, listing sentence, consent text. **Draft only; live policy/listing unchanged pending owner/legal review** | (this commit) |
| W0-C | `scripts/verify-no-network.sh` (signed main app: sandboxed, no network.client/server, no ATS exceptions; helper if bundled: sandboxed, no network.server) + `NoNetworkAttestation` (reads own signed entitlements; unreadable = cannot demonstrate) shown in Settings ▸ Connection. CI wiring on an archived Release build is for the test phase | (this commit) |
| W2-7 | `AppLock` (locks on sleep / screen sleep / return after idle limit; Touch ID or Mac password via LocalAuthentication; never locks out a Mac that cannot authenticate) + `appLockOverlay`. Encryption at rest: FileVault + sandbox; SQLCipher remains an owner decision | (this commit) |
| — | Schema **v144** + `PlanFeatureRepositories` (watchlists, pinned questions, case issues, review codes, custom record types, alerts) — storage for N-1, N-3, N-4, N-11, N-12, W3-4 | (this commit) |
| N-3 | `WatchlistMatcher` (exact / reordered / Jaro-Winkler ≥0.92 / initials over entities + aliases) + `WatchlistView` (paste or import CSV/text, save lists, documents per match) in Tools | (this commit) |
| W3-4 | `runPostIngestChecksSinceLast` after every import path: watchlist names in new documents, new contradictions and gaps → `product_alerts`; `AlertsView` in Tools | (this commit) |
| N-11 | Pinned questions re-asked after each import (and on demand); alert only when answer, sources or contradictions changed, with before/now | (this commit) |
| N-1 | `IssueChronologyView` (issues, tag events, filter) + `ChronologyDrafter` — deterministic statement of facts (numbered, cited, grouped by issue) and deposition outline (questions anchored to events, exhibits) | (this commit) |
| N-4 | `CodingSuggester` (multinomial naive Bayes on the reviewer's own responsive/not codes, ≥3 per class; probability + top words as reasons) + `ReviewCodingView` (responsive / not / privileged / hot; recoding keeps history) | (this commit) |
| N-13 | `riskScores` — contradictions citing the doc (+3), watchlist names (+3), gaps (+1), added this week (+1), every point explained; 'Read first' sort in review coding | (this commit) |
| N-2 | `communicationReport` — sender→recipient pairs from `email_participant_occurrences`, monthly volume from each email's Date header, replies whose In-Reply-To Message-ID is not held (header evidence blocks, mapped to documents through their chunks); `CommunicationView` with a Swift Charts volume chart | (this commit) |
| W3-3 | `RelationshipGraphView` — top 40 people/organisations by relationship degree, deterministic `ForceLayout`, click a node or link for its evidence documents; event timeline (Swift Charts) by kind | (this commit) |
| N-12 | `CustomTypesView` — user types with fields, filled from open-field `generic_facts` by field name (value + source count; empty = no source states it) | (this commit) |
| N-5 | `StudioOutputsView` — deterministic briefing, FAQ, mind-map outline from the ledger, exported as Markdown, read aloud by AVSpeechSynthesizer (on-device) | (this commit) |
| N-6 | `MenuBarExtra` panel (Ask / Search → main window with sources) shown while the module is on; Ask now also picks up a question arriving while open. No global hotkey — it would need Accessibility permission (stated in the module text) | (this commit) |
| W3-2 | `sendToDevonthink` — answer → Markdown note with kalsmritikosh:// links per quote → `NSWorkspace.open(_:withApplicationAt:)` for DEVONthink (bundle ids tried), else shown in Finder; outcome reported | (this commit) |
| W3-7 | `syncSpotlight` — CoreSpotlight items (file name + 240-char snippet) after each import and when switched on; switching off deletes the app's domain; opening a result goes through the deep-link handler | (this commit) |
| W2-2 | Ported mailin `ForensicSignals` (hidden timestamps incl. Gmail boundary / X-GM ids / UUIDv1 / Outlook Thread-Index, Received trace, offline DKIM rsa/ed25519 + ARC chain against pasted keys, missing-DKIM expectations, tampering signals) into Ingestion/EmailForensics; `EmailAuthenticityView` for .eml/.emlx original bytes. Messages inside mbox/PST need exact original bytes — not covered yet | (this commit) |
| W4-3 | Native `RecoveryDetector` (Thunderbird expunged, X-Status D, Gmail Trash label, Deleted Items/Trash/Bin folders) + `MailRecoveryView` scan; tag all "Recovered". PST/NSF free-space carving NOT included (stated) | (this commit) |
| W2-4 | Schema **v145** (annotations, near-duplicate links, legal holds, Bates runs, smart collections, rules). `Knowledge/Review/NearDuplicateFinder` (MinHash LSH 16×4 over word 5-shingles → exact Jaccard check → union-find; method from mailin, native code). `computeNearDuplicates` stores groups in `near_duplicate_members` (derived links, recomputed; nothing merged or deleted). The corroboration meter (I-3) gives every member of a group one shared source key, so copies count once. Tools → Near-duplicates. | built |
| W2-1 | `AnnotationsRepository` over v145 `annotations` (now with `source_url` and `stance`). An annotation bar sits above every source opened from a citation: highlight the passage, add a note, mark it *I confirm this* (HUMAN_CONFIRMED) or *I correct this* (HUMAN_CORRECTED). Anchored to the document and to source file + exact quote, so it re-attaches after a re-ingest of an unchanged source. Tools → Highlights lists all and exports Markdown with or without notes. Removal stamps `removed_at`. Scope: highlights do not yet appear inside the PDF page view, and Proof bundle / dossier exports do not carry them yet. | built |
| W2-5 | `Export/LegalProduction`: page-level Bates PDFs (one single-page PDF per number, footer stamp + legend), extracted text, natives (skipped when redacted or privileged), Concordance DAT (þ / ASCII 20), Opticon OPT, privilege log with numbered slip sheets. Numbers continue after the highest ever produced for the prefix (`bates_runs`), never reused. Legal holds (`legal_holds`/`legal_hold_items`) block both destructive actions — *forget this folder* and *erase all data* — with a visible message, and stay in force even when the tool is switched off (module text updated). Set = review coding Responsive/Hot/Privileged + optional tag. Owner check: open a production in a review tool. | built |
| W3-5 | Smart collections (saved W1-1 searches with live document counts — refreshed every 15 s while open, so new documents appear without reopening) and rules (*when a new document matches → tag it / alert me*). A rule can be saved only after a dry run of exactly that query; it then runs after every ingest batch over documents added since the batch started (`runPostIngestChecks`). A tag rule with Tags switched off raises an alert instead of doing nothing. `ChunksRepository.objectsMatchingAdvanced` shares one SQL builder with search. Scripts (mailin ScriptEngine) not included. | built |
| W2-6 | `Export/ExportCenter` (`LedgerExport*`): one table model rendered to CSV, JSON, Markdown, HTML, Word, Excel, PDF and — for email sources — mbox (mboxrd quoting) from the original .eml/.emlx bytes (emlx read by its byte count). Subjects: timeline, entity list, a source set from a search or #tag. Pre-flight count first (and, for mbox, how many originals are readable); unreadable originals are listed, never silently dropped. A signed receipt (`.receipt.json`) is written beside every export, one entry per exported row. Tools → Export. Not included: MSG/TIFF output, resumable runs, dossier export through this tool. | built |
| N-8 | Places (Tools): photo GPS read on-device from each image's own metadata (ImageIO: signed degrees + original date) and place entities (address/city/country/location) with document counts. Private: list with coordinates, no request of any kind. **Change from plan:** no in-app map — MapKit would load tiles from inside the sandboxed app, which has no network entitlement and must not call out outside Routing/Providers; in Online mode a row can instead be handed to Apple Maps (a separate app). Module text updated. GPS is read at view time, not stored in the ledger. | built |
| N-7 | Tools → Similar images and faces (Vision, on-device): feature print per photo, union-find grouping under an adjustable closeness, and *where else does this photo appear* ranking. Faces: a separate switch inside the tool, **off by default**; faces detected and grouped by appearance, groups unnamed until the user names one, saved only as the user's own tag `Face: <name>`. No identity claims. Prints live only for the open window (not stored). Owner decision still listed: face-feature policy. | built |
| N-9 | Schema **v146** `note_links`. `Ingestion/Notes/NotesFormat` reads Obsidian [[wiki-links]] (alias/heading/embed forms), #tags and YAML `tags:`; Notion 32-hex page ids and Markdown file links; Apple Notes exports (no link structure). Tools → Notes apps links an already-ingested folder: links stored with backlinks (shown above any source opened from a citation), unresolved links kept as text and counted, tags applied as user tags. Re-run stamps `removed_at` on old links. Scope: CAPABILITY_MATRIX rows for these formats are written in the test phase. | built |
| W3-1 | Tools → DEVONthink: choose a `.dtBase2`; its `Files.noindex/` stored documents are registered as a read-only source and read in place (nothing written into the package), Finder tags become user tags, and an accounting compares files on disk with documents in the ledger. **Not imported (stated in the tool):** the group tree and DEVONthink metadata (undocumented `.dtMeta` files) and indexed items outside the package. Owner step: confirm the layout on a real DEVONthink database. | built (layout unverified) |
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

- `MigrationMatrixTests` pins `latestVersion == 141`; it is now **144** (v142 user tags, v143 outbound log, v144 plan feature tables). Update the pin.
- `PrivacyPostureTests` likely asserts the no-network promise; reconcile with O-1 (main app still has no network; only the helper may).
- Online mode cannot be exercised end to end until the helper target exists (O-2 owner step); test the request builders/parsers and masker with recorded responses.
- O-7 nuance: when an online call fails, the answer pipeline's existing error handling still produces a deterministic answer; the banner says the online answer did not go through. Verify the answer itself is labelled accordingly.
- Regenerate `MODULE_MATRIX.md` from `ModuleMatrixDocument.render()` and add a drift test.
- Each built item: write the tests named in its "Done means" column.
- W1-3: import receipts are written only for the Add-files path; the folder-watcher/bulk ingest path does not write one yet.
- W1-5: links do nothing until the `kalsmritikosh` URL type is registered (owner step).
- W3-7: opening a Spotlight result goes through `handleDeepLink`, which refuses when the Links module is off — decide whether Spotlight should bypass that.
- W2-2: re-run mailin's published worked examples (Metaspike boundary, ValiMail ARC suite) against the port.
- Search screen: a search with issues but zero hits shows the empty state, so the issues are not visible — check and fix.
