# Storage and key inventory (SEC-03)

Smart-map S16, 2026-11-12. Every place the app writes case-derived data to disk, whether the app encrypts it, and what
removes it. This is the declared model; `SmartMapS16Tests.storageInventory` checks it against the code (every anchor below
must exist in the named file, every temporary prefix the launch sweep removes must be listed here, the vault must seal by
default and an opened copy must never be carried by a ledger move). Where a store is **not** app-encrypted it relies on
**FileVault**, and that is said here, in docs/THREAT_MODEL.md (T2), in docs/DATA_FLOW_INVENTORY.md and in the privacy text —
never advertised as app encryption. Supersedes the "vault copies are not encrypted" wording of K11 (SHIP_DECISIONS IN-02).

Keys: the ledger key is a random 32-byte key in this Mac's Keychain (`LedgerKeychain`, accessible after first unlock, this
device only; a recovery key is shown once). Keys derived from it by HKDF and never stored: `hnsw-cache` (vector cache),
`evidence-vault` (vault copies), `backup-manifest` (backup signature). The sync store key comes from the person's
passphrase. No Keychain item is case-scoped (2026-11-13, SEC-07: every Keychain user is one key per Mac, per AI provider or per
endpoint; `SEC07ErasureReachTests.keychainHoldsNothingCaseScoped` fails if a new one appears unclassified). So a case or
person erasure removes no Keychain item; a full erase keeps the ledger key (the emptied ledger stays encrypted with it) and,
when folder sync was set up, stops syncing and forgets the sync key. Pay as you go (2026-11-15): the **AI account token** is
one random UUID per Mac in the Keychain (`AIAccountToken`, Kalsmritikosh/App/Store/PayAsYouGo.swift, service
`ecosanskritiinnovation.Kalsmritikosh.aiAccountToken`, accessible after first unlock, this device only); it holds no case data
and is not removed by an erasure — it names the relay account of credit packs bought without a subscription and is
recoverable from the App Store purchases on another Mac. The relay's own tables (`relay/schema.sql`: `topups`, `daily` keyed
`token:<uuid>` for pay as you go) are described in docs/DATA_FLOW_INVENTORY.md N6.

| ID | Store | Anchor (file :: symbol) | Location | App-encrypted | Removed by |
|----|-------|-------------------------|----------|---------------|------------|
| ST-01 | Ledger (all case data) | Kalsmritikosh/Storage/Database/LedgerEncryption.swift :: LedgerKeychain | ledger folder `knowledge.sqlite` (+wal/shm) | Yes — SQLCipher AES-256 | full erase empties and vacuums; case erasure deletes rows |
| ST-02 | Vector cache | Kalsmritikosh/Storage/Vector/HNSWVectorIndex.swift :: persist(to | ledger folder `hnsw-index.bin` | Yes — AES-GCM (`hnsw-cache`), 0600, never written without a key | full erase; case erasure drops and rebuilds |
| ST-03 | Evidence vault (copies of originals, on by default) | Kalsmritikosh/Core/Security/EvidenceVault.swift :: sealPurpose | ledger folder `EvidenceVault/` | Yes — AES-GCM 1 MiB chunks (`evidence-vault`), 0700/0400. **Not sealed: copies stored by builds before IN-02 or with no ledger key — FileVault** | full erase; case erasure when no other version uses the copy; "Stop and forget everything from this folder" (LS26) when no remaining source outside the folder and no case uses the copy — its opened copy goes with it, the result says how many copies were removed and how many were kept as shared, and an unfinished step is recorded and retried at launch |
| ST-04 | Opened copy of a sealed original (while viewed) | Kalsmritikosh/Core/Security/EvidenceVault.swift :: removeOpenedCopies | ledger folder `EvidenceVault-open/` | No — plaintext, owner-only — **FileVault** | every launch, full erase, removal of the copy; never carried by a ledger move (S16) |
| ST-05 | Exact-original copy opened from the provenance chain | Kalsmritikosh/Ingestion/Upgrade/ProtectedSourceUnlockService.swift :: inspectOriginal | temporary folder `original-*` | No — plaintext 0444 — **FileVault** | launch sweep of leftovers older than an hour (S16; before S16 never removed) |
| ST-06 | Temporary working copies (capture, unlock, page renders, intake snapshots, archive expansion, backup scratch) | Kalsmritikosh/Core/Security/TemporaryPlaintextSweep.swift :: prefixes | temporary folder: `capture-`, `unlock-`, `kalsmritikosh-pdfpage-`, `usf-intake-snapshot`, `usf-upgrade-reopen`, `usfm2-expand-`, `usfm2-7z-`, `kalsmritikosh-cbackup-`, `kalsmritikosh-backup-`, `kalsnap-` | No (backup scratch holds an encrypted ledger copy) — **FileVault** | removed after use; launch sweep of leftovers older than an hour (S16) |
| ST-07 | DEVONthink hand-off note | Kalsmritikosh/App/SendToDevonthink.swift :: kalsmritikosh-devonthink | temporary folder `kalsmritikosh-devonthink/` | No — after protected-identity masking — **FileVault** | launch sweep older than an hour (S16) |
| ST-08 | Share / Safari clipper inbox | Kalsmritikosh/App/ShareInbox.swift :: ShareInbox | App Group container `Inbox/` | No — **FileVault** | each item after it is saved into Intake |
| ST-09 | Intake (captured items) and custody log | Kalsmritikosh/UI/CaptureView.swift :: static func save | Application Support `Kalsmritikosh/Intake/` | No — **FileVault** | not by erasure (stated in Help) |
| ST-10 | Notes, note versions, note trash | Kalsmritikosh/App/NotesStore.swift :: NotesStore | Application Support `Kalsmritikosh/Notes*` | No — **FileVault** | not by erasure |
| ST-11 | AI transcriptions, web captures, public lists | Kalsmritikosh/App/Online/OnlineTools.swift :: Web captures | Application Support | No — **FileVault** | not by erasure |
| ST-12 | Import receipts | Kalsmritikosh/App/ImportReceiptWriter.swift :: Import receipt written | Application Support `KalsmritikoshChronicaMemora/Receipts/` | No (signed) — **FileVault** | not by erasure |
| ST-13 | Output records waiting to be saved | Kalsmritikosh/Investigate/CaseFile/CaseOutputService.swift :: pendingDirectory | ledger folder `case-output-pending/` | No — **FileVault** | resumed and removed at launch |
| ST-14 | Diagnostics (MetricKit) | Kalsmritikosh/App/Diagnostics/DiagnosticsReporter.swift :: DiagnosticsSanitizer | Application Support `Kalsmritikosh/Diagnostics/` | No — no case data: message text, home-folder paths and credentials removed before saving (S16, SEC-11) | the newest 30 kept |
| ST-15 | Ledger backup / move to a new Mac | Kalsmritikosh/App/BackupService.swift :: createBackup | where the person chooses | Yes — ledger SQLCipher; manifest HMAC (`backup-manifest`) | the person; a case or person erasure names the backups this Mac made before it (ST-24) and deletes them only when the person chooses “Delete backups made before this erasure”; restored on this Mac, the erasure is applied again before the ledger is read |
| ST-16 | Complete backup | Kalsmritikosh/App/BackupService.swift :: createCompleteBackup | where the person chooses | Partly — ledger encrypted, vault copies as stored; **originals and the source map are plaintext** | as ST-15 |
| ST-17 | Companion snapshot | Kalsmritikosh/Storage/Database/LedgerEncryption.swift :: exportCopy | where the person chooses | Ledger re-encrypted with a passphrase; originals plaintext | as ST-15 |
| ST-18 | Ledger kept before a restore | Kalsmritikosh/App/PendingRestore.swift :: keepCurrent | ledger folder `Before restore <time>/` | Yes — SQLCipher copy | the person |
| ST-19 | Ledger moved to another disk | Kalsmritikosh/App/LedgerRelocation.swift :: isOpenedPlaintext | `<disk>/Investigations Made Easy Ledger/` | Ledger and vault as stored; the opened-copies folder is not copied (S16) | the person (the source is kept) |
| ST-20 | Folder sync store | SyncCore/SyncStore.swift :: func write( | the folder the person picks | Yes — AES-GCM from the passphrase, signed; `store.json` and device files plaintext (no case text) | the person |
| ST-21 | Exports (reports, packages, CSV, productions) | Kalsmritikosh/Investigate/CaseFile/CaseOutputService.swift :: authorizeRelease | where the person chooses | No — plaintext by nature | the person; a case or person erasure lists the recorded ones (where written — the folder from schema v191, the file name before — when, SHA-256) and never deletes them |
| ST-22 | Spotlight items (file name and first 240 characters) | Kalsmritikosh/App/SpotlightIndexer.swift :: syncSpotlight | system index | System | module off; a case erasure that erases documents |
| ST-23 | Preferences holding case text (studio stores, workspace state) | Kalsmritikosh/App/AppState.swift :: removeManagedFiles | app preferences | No — **FileVault** | full erase removes the listed keys |
| ST-24 | List of backups this Mac made (name, path, time, folder bookmark; no case content) | Kalsmritikosh/App/BackupLog.swift :: backup-log.json | ledger folder `backup-log.json` (never in a backup) | No — **FileVault** | not by erasure (it is how an erasure names earlier backups); an entry is marked when its backup is deleted |
| ST-25 | This Mac's team signing key (Ed25519; signs what this Mac writes in a shared team folder) | Kalsmritikosh/App/Team/TeamCase.swift :: com.kalsmritikosh.team | Keychain, this device only (`AfterFirstUnlockThisDeviceOnly`; never in a backup, so a restored ledger joins a folder again as a new member) | Yes — **Keychain** | not by case erasure (not case-scoped); removing it means this Mac can no longer write as its old member |
| ST-26 | Shared team folders (requests, inputs, submissions, signed logs; v198) | Kalsmritikosh/App/Team/TeamCaseExchange.swift :: submissionsDir | a folder the people chose (file share, external disk, synced folder) — outside the app; the case keeps only a bookmark (`case_team_links`) | No — protected by the folder's own access; entries are **signed**, not encrypted | not by the app: erasing a case removes its records and link, never the shared folder others use |
| ST-27 | This Mac's team key-agreement key (X25519; opens the pieces of a shared import encrypted for this member) | Kalsmritikosh/App/Team/TeamSwarm.swift :: x25519 | Keychain, this device only (`AfterFirstUnlockThisDeviceOnly`; its public half is published in the team folder, signed with ST-25) | Yes — **Keychain** | not by case erasure (not case-scoped) |
| ST-28 | Shared-import pieces in a team folder (manifest, claims, partial ledgers, wrapped piece keys; PERF-40, v207) | Kalsmritikosh/App/Team/TeamSwarm.swift :: swarmDir | `<team folder>/swarm/` — outside the app | Yes — each partial ledger SQLCipher with its own piece key, wrapped per member (X25519 + HKDF + AES-GCM); manifest and claims signed, not encrypted (paths and fingerprints only) | erasing a case removes the claims, pieces and manifest this Mac wrote for it (signed log entries stay; they hold ids and fingerprints only) |

Previews and thumbnails: the app writes no preview or thumbnail cache of its own (PDF page thumbnails are drawn in
memory; page renders for text recognition are ST-06). Files the person opens in another app through Finder may be
cached by macOS (Quick Look), outside the app's control.

Not verified here: the signed distribution build (the test host uses its own Keychain item and an in-memory key).
