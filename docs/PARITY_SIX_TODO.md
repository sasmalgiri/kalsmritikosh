# The last six — DEVONthink parity without the network

Owner request 2026-10-17: build all six remaining gaps, offline. Order of work:
**plan → verify the plan → implement all → test + push → fix bugs and edge cases →
simulate each workflow on real open-source material.**

Standing rules for every item:

- **No network.** The app never opens a connection; no new network entitlement. Moving
  files between devices is done by a folder the person chooses (iCloud Drive, Dropbox,
  SMB, USB) or by the system (AirDrop, Files). The architecture guards stay green.
- **No entitlement changes** on the Mac app (an App Group already exists and is reused).
- **Nothing is destroyed.** Removals stamp `removed_at` / `retired_at`; originals are
  never written to.
- **Evidence is untouched.** User organisation (groups, annotations, suggestions) never
  changes what the evidence says. Brain/Knowledge/Retrieval do not branch on any of it.
- **One switch per feature** in `ProductModule`, default OFF, in the also-in-DEVONthink
  set (so the standalone preset turns them on). MODULE_MATRIX regenerated.
- **Schema changes** only in new versioned migrations (v147+); `MigrationMatrixTests` pin
  updated; `latestVersion` bumped once per migration.
- **No third-party code.** Apple frameworks only (PDFKit, AppKit text system, CryptoKit,
  SafariServices, the bundled embedder).

---

## X-1 Filing suggestions — "See Also" and "where should this go?"

DEVONthink: See Also & Classify (AI suggests related documents and the group to file into).

| # | Task | Done means |
|---|---|---|
| X-1.1 | `DocumentSimilarity` (Knowledge/Organise): a document vector = mean of its chunk embeddings (same model id as the store), computed on demand and cached in a new table `document_vectors(object_id, model_id, dims, vector BLOB, chunk_count, computed_at)` (v147). Recomputed when the document's chunk set changes (evidence revision counter). | A document with no embedded chunks has no vector and is reported "not yet embedded", never as "nothing similar". |
| X-1.2 | `seeAlso(objectID, limit)`: cosine nearest documents (not chunks), excluding itself and its near-duplicate group members (they are shown separately as duplicates), scope-filtered by the screen authoriser. | Results carry the score and the best matching passage pair as the reason. |
| X-1.3 | `suggestGroups(objectID)`: for each group (X-2) with ≥ 2 members, centroid of member vectors; rank groups by cosine; also tag suggestions from user tags with ≥ 2 tagged documents. Threshold + "no confident suggestion" outcome. | Never auto-files. A suggestion is accepted only by the person (one click), recorded as a normal group membership. |
| X-1.4 | UI: a "See Also" panel in the source viewer + "File into…" suggestions; Tools ▸ Organise ▸ Unfiled documents with suggestions. | Works with the module on; hidden with it off; nothing stored is lost when off. |
| X-1.5 | Module `filingSuggestions` (X-1). | MODULE_MATRIX row. |
| X-1.6 | Tests: vector mean/normalisation, exclusion of self and duplicates, empty/unembedded document, threshold behaviour, scope filtering, determinism (ties by id). | Suite green. |

## X-2 Your own folders — groups and replicants

DEVONthink: groups (folders) inside a database; a replicant is the same document in several groups; duplicates are separate copies.

| # | Task | Done means |
|---|---|---|
| X-2.1 | v148: `user_groups(id, name, parent_id, sort_index, created_at, retired_at)` and `user_group_members(group_id, object_id, added_at, removed_at, PRIMARY KEY(group_id, object_id))`. | Migration in SAVEPOINT; matrix pin updated. |
| X-2.2 | `GroupRepository`: create, rename, move (re-parent, with cycle refusal), reorder, retire (stamps; members stay restorable), add/remove member (stamp), replicate (= add to another group), list tree, members of a group, groups of a document, "unfiled" documents. | Cycle, duplicate-name-under-same-parent, retired-parent and missing-object cases refused with a sentence. |
| X-2.3 | "Mirror folders": optionally create the group tree from a source root's folder structure once (never changes files on disk). | A re-run adds only what is new; it never removes groups the person edited. |
| X-2.4 | Group as a scope: `group:` field in advanced search syntax and as an Ask scope (same path as `tag:`). | A group scope restricts results exactly like a tag scope; a retired group is reported, not silently empty. |
| X-2.5 | UI: Organise window — sidebar tree (drag to re-parent, drag documents in = replicate with ⌥, move without), group contents, "in N groups" badge, unfiled list. | Keyboard and VoiceOver labels. |
| X-2.6 | Module `userGroups` (X-2). | MODULE_MATRIX row. |
| X-2.7 | Tests: tree operations, cycles, replicant counts, retire/restore, unfiled, search scope, migration. | Suite green. |

## X-3 Rich text notes and PDF annotation

DEVONthink: rich text/RTF documents edited in place; PDF highlight, underline, strike, notes, ink, stored in the PDF.

| # | Task | Done means |
|---|---|---|
| X-3.1 | Notes (P-2) gain a format: Markdown **or** rich text (`.rtf`). Rich text edited with an `NSTextView` wrapper (bold, italic, underline, lists, links, font/colour). Same versions and trash. `.rtfd` (images inside) is **not** offered: no ingestion path reads it today (plan check), so pictures go in as their own documents. | A rich note is read in by the existing RTF parser (checked: `RTFStructuralParser`), searchable and askable. |
| X-3.2 | PDF annotation editor on top of `SourceViewer`'s `PDFView`: highlight / underline / strike-out on the selection, free-text note, and comment pop-ups; colour choice. | Annotations are never written into the original file. |
| X-3.3 | Storage: annotations kept in the ledger (`pdf_annotations(id, object_id, page, kind, bounds_json, quads_json, color, contents, created_at, removed_at)`, v149) and rendered as PDFKit annotations on open. | Re-opening shows them; removing stamps `removed_at`. |
| X-3.4 | "Export annotated copy": writes a new PDF with the annotations embedded (PDFKit), plus a Markdown summary; the original's SHA-256 is unchanged (verified). | Copy opens in Preview with the marks. |
| X-3.5 | Highlighted text becomes a W2-1 annotation too (quote + note), so it shows in Highlights and can scope questions. | One highlight, one record per surface — no double counting. |
| X-3.6 | Module `richDocuments` (X-3). | MODULE_MATRIX row. |
| X-3.7 | Tests: RTF round trip through NotesStore and the parser; PDF annotation persistence, removal, export with original hash unchanged, quads on rotated pages, encrypted PDF refused with a sentence, scanned (image-only) page annotated by region. | Suite green. |

## X-4 Safari web clipper

DEVONthink: Clip to DEVONthink (page, selection, as PDF/web archive/Markdown, with the URL).

| # | Task | Done means |
|---|---|---|
| X-4.1 | New target `KalsmritikoshClipper`: Safari Web Extension (appex, `com.apple.Safari.web-extension`), embedded in the Mac app, App Group shared with the Share extension. | Builds in Debug and Release; release guard updated for the new target. |
| X-4.2 | Extension resources: `manifest.json` (MV3; permissions `activeTab`, `scripting`, `nativeMessaging`, `contextMenus` — **no host permissions, no `webRequest`**), a toolbar popup (Clip page / Clip selection / Clip as Markdown), and a content script that serialises the page the browser already has: `document.documentElement.outerHTML`, selection HTML/text, title, URL, time. | The extension never fetches anything; the guard greps its JS for `fetch(`/`XMLHttpRequest`/`WebSocket` and fails if present. |
| X-4.3 | `SafariWebExtensionHandler` (native side) writes each clip into the App Group `Inbox/<stamp>-<uuid>/` with `item.json` (name, sha256, origin "Safari clipper", URL, title) — the same hand-over format as the Share extension, so `ShareInbox.drain` imports it unchanged. Size cap with a clear refusal. | A clip lands in the intake with its custody line. |
| X-4.4 | Formats: HTML page (default), selection only, Markdown conversion of the readable part (native `HTMLToMarkdown` on the Mac side, no third-party library). | Each format is searchable after import. |
| X-4.5 | Module: reuse **Share and capture** (`captureExtensions`); the switch is mirrored to the App Group (as for the Share extension) and the handler refuses when it is off. | Off ⇒ the popup says how to turn it on; nothing is written. |
| X-4.6 | Tests: handler payload → inbox item (pure function), size cap, name sanitising, Markdown conversion on real pages, the no-fetch guard. | Suite green; guard in `ci/guards`. |

## X-5 Sync between Macs (and the iPhone/iPad app), through a folder you choose

DEVONthink: sync stores (Bonjour, iCloud, Dropbox, WebDAV, local folder). Ours: **local/synced folder only** — the app writes and reads files; the folder service, not the app, moves them.

| # | Task | Done means |
|---|---|---|
| X-5.1 | Sync store layout (modelled on TeamCase, which already proves the pattern): `<store>/store.json` (id, format version, created), `<store>/devices/<deviceID>.json` (name, Ed25519 public key), `<store>/log/<deviceID>/<seq>.kchg` (one encrypted, signed change batch per file), `<store>/blobs/<sha256>` (encrypted file bytes). Each device writes only its own files ⇒ two Macs never write the same file. | Layout documented; format versioned. |
| X-5.2 | Encryption: a **sync passphrase** chosen once and entered on every device; key = HKDF-SHA256 over a PBKDF2 (CryptoKit + CommonCrypto) of the passphrase with the store's salt; every batch and blob sealed with AES-GCM. Ed25519 signature per batch (device key in the Keychain, test host in memory as for the ledger key). | Wrong passphrase ⇒ "cannot read this sync store", never a partial import. A changed byte fails authentication. |
| X-5.3 | What syncs (the person's own layer + the bytes needed to rebuild the rest): notes (files), tags + links, groups + members, annotations (W2-1 and PDF X-3), smart collections and rules, review codes, watchlists, pinned questions, **and the bytes of imported files that live inside the app** (intake, notes). Derived data (chunks, facts, entities, vectors) is **not** synced: each device rebuilds it with the same pipeline, so evidence is always derived locally from bytes it can verify. Watched folders on disk are matched by content hash; a document the other device cannot find is listed as "known on another Mac, file not here". | A two-device simulation ends with equal user layers and equal answerable document sets for shared files. |
| X-5.4 | Change capture: `SyncJournal` records every user-layer write as an operation (`op`, table, row id, fields, Lamport clock, device) through the repositories (no triggers on evidence tables). | Every repository write path above emits exactly one op (a test greps the repositories). |
| X-5.5 | Merge: operations applied in (Lamport, device id) order; last-writer-wins per field for scalar edits; set semantics with stamps for memberships/links (add-wins over a concurrent remove, recorded); a note edited on two devices concurrently keeps **both** texts (the loser becomes a version, and the person is told). Idempotent: applying a batch twice changes nothing. | Conflicts are shown in Settings ▸ Sync, never silently dropped. |
| X-5.6 | Engine: export pending ops + new blobs → batch; import unseen batches from other devices → verify → decrypt → apply in one savepoint per batch; a cursor per remote device. Runs on demand ("Sync now") and on a timer while the app is open; pauses when the folder is unavailable. | A batch that fails verification is quarantined and reported; the rest continues. |
| X-5.7 | UI: Settings ▸ Sync — choose folder, passphrase, this device's name, last sync, devices seen, conflicts, quarantined batches, "Stop syncing" (keeps everything local). | Clear states for: no folder, folder offline, wrong passphrase, newer format. |
| X-5.8 | Module `folderSync` (X-5). | MODULE_MATRIX row. |
| X-5.9 | Tests: crypto round trip and tamper; signature; Lamport ordering; LWW; add-wins sets; concurrent note edits; idempotence; partial/corrupt files; two and three simulated devices against one temp folder; blob dedupe; wrong passphrase; format version gate. | Suite green. |

## X-6 iPhone / iPad app that edits and syncs

DEVONthink To Go: browse, search, read, annotate, tag, write notes, capture; syncs with the Mac.

| # | Task | Done means |
|---|---|---|
| X-6.1 | Shared sync core: the pure parts of X-5 (format, crypto, ops, merge) live in `Kalsmritikosh/Sync/Core/` and are copied into the viewer target by `scripts/generate-sync-core.sh` with a CI staleness check (the same pattern as `kalverify`), so both platforms use byte-identical code. | `git diff --exit-code` after regeneration in CI. |
| X-6.2 | The viewer opens a **sync store** (via the Files app: iCloud Drive, Dropbox, On My iPhone) in addition to snapshots: it rebuilds a small local read model (documents, passages for files whose bytes are in the store, notes, tags, groups, annotations) from the batches. | Works with no Mac reachable; read-only snapshot mode still works. |
| X-6.3 | Edits on iPhone/iPad: write notes (Markdown), tag / untag, add to group, highlight a passage with a note, review code. Each edit is an op in the device's own log, written to the store. | The Mac applies them on its next sync; the iOS app shows its own pending edits until confirmed. |
| X-6.4 | Capture on iPhone/iPad: camera / document scan (VisionKit) and Files import → blob + "add document" op; the Mac reads it in. | A scanned page becomes searchable on the Mac after sync. |
| X-6.5 | Search on device over the local read model (full-text); questions are answered on the Mac (marked "ask on your Mac"). | Honest: no answer is invented on the phone. |
| X-6.6 | Tests: the shared-core tests run in the Mac test target against the generated copy; viewer build in CI (iOS simulator build step). | CI builds the viewer. |

---

## Simulation on real open-source material (final phase)

Every workflow is run end to end on real, openly licensed material checked into
`KalsmritikoshTests/Fixtures/OpenCorpus/` with a `SOURCES.md` (origin, licence, SHA-256):

| Workflow | Material (licence) | What is checked |
|---|---|---|
| X-1 filing | Wikipedia articles in 4 known categories (CC BY-SA 4.0), ~5 each | See Also stays within category for ≥ 80 % of top-3; each document's suggested group is its true category when ≥ 2 members exist; "no confident suggestion" for an off-topic article. |
| X-2 folders | A public-domain US federal document set arranged in folders (e.g. GovInfo / Federal Register PDFs) | Mirror folders reproduces the tree; replicate, move, retire, restore; group-scoped search returns only members. |
| X-3 rich/PDF | US court opinions as PDF (public domain) + Project Gutenberg text to RTF (public domain) | Highlight/note/strike round trip; annotated copy opens; original hash unchanged; rich note searchable. |
| X-4 clipper | Saved Wikipedia HTML pages (CC BY-SA) fed through the handler | Page, selection and Markdown clips land in the intake and are searchable; title/URL kept. |
| X-5 sync | Two simulated Macs (two temp ledgers, one temp sync folder) working on the Enron email subset (public record, released by FERC) + the Wikipedia set | Equal user layers after concurrent work; conflicts listed; tampered batch quarantined. |
| X-6 iOS | The iOS core driven against the same store | Phone edits appear on the Mac; Mac edits appear in the phone's read model. |

## Verification of this plan (done before implementation)

Each item was checked against the code before any implementation:

| Check | Finding | Plan change |
|---|---|---|
| Can a document vector be built from what is stored? | `chunk_embeddings` holds int8 vectors + scale per (chunk, model); `SQLiteVectorStore` already decodes them. | None — X-1.1 averages decoded chunk vectors per model id. |
| Is there an evidence-change signal to invalidate cached vectors? | `evidence_revisions` (v141) bumps per source version on chunk/lineage change. | X-1.1 stores the revision it was built from and rebuilds when it moves. |
| Can a group become a search/ask scope the same way a tag does? | `AdvancedSearchCompiler` has a `.tag` field (`tag:`, `label:`) compiled to a subquery on `user_tag_links`. | X-2.4 adds `group:` beside it, compiled to `user_group_members`. |
| Are rich-text notes readable by ingestion? | `RTFStructuralParser` reads `.rtf`; nothing reads `.rtfd` packages. | X-3.1 narrowed to `.rtf`. |
| Can PDF marks be shown without writing the original? | `SourceViewer` hosts a `PDFView` with a fresh `PDFDocument(url:)`; annotations added in memory are not saved unless written. | X-3.2/3.3 keep marks in the ledger and add them on open; X-3.4 writes a copy only. |
| Can a Safari extension hand clips to the app without a network or new Mac entitlement? | Safari web extensions call their native `NSExtensionRequestHandling` handler via `browser.runtime.sendNativeMessage` (nativeMessaging permission); the appex can join the existing App Group; `ShareInbox.drain` already imports App Group inbox items with a SHA-256 check. | X-4.3 reuses the Share inbox format. No Xcode template exists for this target in this toolchain ⇒ the target is added to the project file by hand, mirroring `KalsmritikoshShare`. |
| Is there a proven multi-device folder pattern? | `TeamCase` (W4-4): per-member append-only signed logs, hash-chained, in a shared folder; verify reports tampering per entry. | X-5.1 follows it; adds encryption (TeamCase is signed but plain). |
| Do all user-layer writes go through one place, so sync can capture them? | Writes live in `TagsRepository`, `AnnotationsRepository`, `PlanFeatureRepositories` — **and directly in `SmartCollectionsView`**. | X-5.4 first moves the smart-collection writes into a repository, then journals all three. |
| Can the iOS app share the sync code? | The viewer target compiles only its own folder; CryptoKit (Ed25519, AES-GCM, HKDF) and CommonCrypto (PBKDF2) exist on iOS; SQLCipher is already linked. | X-6.1 generated copy + CI staleness check. |
| Can the open corpora be used offline in tests? | Downloaded once at development time and committed with licences; tests never fetch. | Fixture size kept small (a few MB). |

Conclusion: every DEVONthink capability listed for the six gaps maps to at least one task
above, every task has a concrete code path, and the two plan changes (RTF-only rich notes,
smart-collection writes moved into a repository) are recorded. The plan can complete all six.
