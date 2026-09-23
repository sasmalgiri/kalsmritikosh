# SUPPORTED_SOURCES

> **DOC STATUS: CURRENT** — this matrix is **generated from code** by
> `ParserCapabilityManifest` (PAR-001), not hand-maintained, so it cannot drift from what
> the app actually parses. Regenerate with
> `ParserCapabilityManifest.renderMarkdown(registry:)`. Supersedes the format claims in
> `SUPPORTED_FORMATS_V1.md`.

Coverage states (from the locked product contract):

- **FULL** — a structural parser recovers structure + exact locators. May be *advertised*
  "Supported" only after fixture + release verification (PAR-010).
- **PARTIAL** — content recovered with disclosed limits. Here: OCR-dependent formats, whose
  fidelity depends on scan/image quality.
- **PRESERVED-ONLY** — no structural parser yet; identity/metadata/hash retained, content not
  interpretable. Never silently dropped.
- **DEFERRED** — recognized but processing intentionally postponed. Applies to audio/video only
  when the "Transcribe audio & video" module is turned OFF.

## Coverage matrix (generated 2026-09-23 from `StructuralParserRegistry.standard(ocr:)`)

| Format | Category | Coverage | Parser | Version |
|---|---|---|---|---|
| txt | document | FULL | plaintext | 1 |
| markdown | document | FULL | plaintext | 1 |
| rtf | document | FULL | rtf-attributed | 1 |
| docx | document | FULL | docx-ooxml | 1 |
| doc | document | FULL | DocStructuralParser | 1.0 |
| odt | document | FULL | odt-opendocument | 1 |
| epub | document | FULL | epub-opf | 1 |
| html | document | FULL | structured-text | 1 |
| json | document | FULL | structured-text | 1 |
| xml | document | FULL | structured-text | 1 |
| log | document | FULL | structured-text | 1 |
| sqlite | document | FULL | sqlite | 1 |
| csv | spreadsheet | FULL | csv | 1 |
| xlsx | spreadsheet | FULL | xlsx-ooxml | 1 |
| xls | spreadsheet | FULL | XlsStructuralParser | 1.0 |
| ods | spreadsheet | FULL | ods-opendocument | 1 |
| pptx | presentation | FULL | pptx-ooxml | 1 |
| eml | email | FULL | eml | 1 |
| mbox | email | FULL | mbox | 1 |
| appleMail (emlx) | email | FULL | emlx-apple-mail | 1 |
| msg | email | FULL | msg | 1 |
| pst | email | FULL | pst | 1 |
| nsf | email | FULL | nsf | 1 |
| plist | document | FULL | plist | 1 |
| registryHive | hostArtifact | FULL | windows-registry-regf | 1 |
| knowledgeC | hostArtifact | FULL | apple-knowledgec | 1 |
| custodyManifest | document | FULL | chain-of-custody | 1 |
| extractionManifest | hostArtifact | FULL | ios-backup-manifest | 1 |
| discussionExport | chat | FULL | discussion-export | 1 |
| pdf | document | PARTIAL (OCR) | pdf-pdfkit | 1 |
| png | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| jpg | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| heic | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| tiff | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| webp | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| mp3, wav, m4a, aac, aiff, caf, flac, 3gp | audio | PARTIAL (ASR) / DEFERRED | apple-speech | 1 |
| mp4, mov | video | PARTIAL (ASR) / DEFERRED | apple-speech | 1 |
| ppt, keynote | presentation | PRESERVED-ONLY | — | — |
| chatExport (WhatsApp/Signal/Slack) | chat | FULL when opted in, else PRESERVED-ONLY | discussion-export | 1 |
| imessage | chat | PRESERVED-ONLY | — | — |
| safariHistory, chromeHistory | browserHistory | PRESERVED-ONLY | — | — |
| zip, rar, sevenZip | archive | CONTAINER | — | — |

**Totals (code-generated): 29 FULL · 6 PARTIAL · 10 media · 9 PRESERVED-ONLY/CONTAINER.**

The media row is the one entry whose coverage depends on a user setting, so it is stated as a
pair. The 10 audio/video types are PARTIAL (ASR) with the default-ON "Transcribe audio & video"
module, and DEFERRED when it is switched off. Everything else is fixed at build time. The
routing truth is the `UniversalParserRegistry`; `ParserCapabilityManifest.generate(registry:)`
derives this table from it so the matrix cannot drift from what actually runs.

## Caveats (honest limits)

- **Archives (zip/rar/7z)** are *containers*, not content: the ingest pipeline expands them
  and parses each member by its own type. They are not "preserved-only" in the content sense —
  the manifest lists them without a structural parser because the archive bytes themselves
  carry no evidence blocks. (The manifest's raw output labels these PRESERVED-ONLY; read them
  as CONTAINER per this note.)
- **PARTIAL (OCR)** fidelity depends on image/scan quality; a currency glyph or handwriting
  may be misread. Native-text PDFs extract exactly; scanned pages fall back to Vision OCR.
- **Media (ASR)**: with the default-ON "Transcribe audio & video" module, speech is transcribed
  on-device by Apple Speech (`requiresOnDeviceRecognition` is forced — nothing leaves the Mac)
  and the transcript carries inline timecodes, so an answer can cite "the call at 12:04".
  It is PARTIAL, never FULL: ASR is approximate and a recording has no document structure.
  A recording whose speech cannot be recognized is recorded as such, not silently dropped.
  Transcription is the slowest step in ingest; turning the module off returns media to
  DEFERRED (kept, hashed, searchable by name and date, not transcribed).
- **PRESERVED-ONLY** formats need dedicated work (PPT/Keynote) or opt-in adapters
  (iMessage/chat/browser history, which are feature-gated and off by default).
- **Discussion platforms (DISC-\*)** are read from the platform's own data export — the file
  set the account holder, or a lawful order, produced. Kalsmritikosh makes **no network calls**
  (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO` in both build configurations and
  `network.client = false`), so there is no API client and no credentialed scraper anywhere in
  the app; collection is always someone else's step. Every platform maps into one
  `DiscussionRecord` (author, time, thread, reply target), so adding a platform adds a mapper,
  not a parser. Mappers claim a file by its CONTENT, not its name or extension, because
  evidence is routinely renamed. Currently mapped: **YouTube** (Takeout comments, live chat,
  watch/search history), **Discord** (package messages.json and messages.csv), **Reddit**
  (comments, posts, private messages), **X** (tweets.js, direct-messages.js), **Meta**
  (Messenger and Instagram threads) **Telegram** (Desktop result.json, full or single-chat) and
  **WhatsApp / Signal / Slack** text exports. That last one is behind the "Chat exports"
  opt-in flag: with the flag off the type stays PRESERVED-ONLY, and no path — including the
  generic text fallback — may activate it. Meta threads are the only artifact here that names
  every participant per message; the other platforms' exports contain only the requesting
  account's own content, so those are attributed to a stated account-holder marker rather
  than to a name the export never contained. An export from an unmapped platform is reported by name with the
  supported list, never guessed at. Watching and searching are kept a distinct `activity` kind
  so "what did they say" cannot return a search box.
- **Host artifacts (HOST-\*)** are machine/OS evidence rather than documents a person wrote, so
  they carry their own `hostArtifact` category. Processing is the same (immediate, text +
  structure); the distinction matters when attributing a fact to a person. A registry hive is
  read whole with each key's last-written time, capped at 20 000 keys per hive with the ceiling
  stated in a warning. Only complete hives are claimed: transaction logs (`.LOG1`/`.LOG2`) and
  backups (`.SAV`) are deliberately NOT treated as hives, because decoding a partial file would
  report corrupt evidence for a file that is simply not a hive. Freed cells are not followed, so
  nothing here reports deleted registry data as live. Apple's activity store
  (`knowledgeC.db`) gets both lanes: every row is indexed by the record loader, and a
  schema-aware parser turns ZOBJECT rows into dated events with durations. Its timestamps
  are APPLE EPOCH (seconds since 2001-01-01); read as Unix time a 2026 event would date to
  1994, so the conversion lives in one shared `AppleEpoch` helper. `ZSECONDSFROMGMT` is
  kept because it states the time zone the DEVICE was in, which no absolute timestamp can.

- **Chain of custody (HOST-8)** is read from an examiner-authored JSON sidecar at the
  extraction root (`kalsmritikosh-custody.json`, `custody.json` or `chain-of-custody.json`):
  case and evidence numbers, examiner, agency, legal authority, acquisition tool and date,
  source device and its time zone, image hash with its algorithm, and whether the records are
  live / recovered / deleted. Each fact becomes its OWN evidence block, so an answer cannot
  quote the examiner while dropping the authority. **Nothing is inferred** — custody is a human
  attestation, and a guessed value shown beside real ones would be worse than a gap because it
  would look identical. Absence is a disclosed state, not a default: evidence with no recorded
  custody never renders the same as documented evidence. "Complete chain of custody" is
  all-or-nothing and a partial chain names exactly which fields are missing. An UNREADABLE
  manifest is reported more loudly than a missing one, because it means someone intended to
  document the chain and the documentation cannot be read.

- **Extraction inventory (HOST-8b)** reads an iOS backup's `Manifest.db`, the file that makes
  the rest of the backup meaningful: every file is stored under a SHA-1 name in a two-hex
  subdirectory, and only this manifest maps that hash back to its device path
  (`HomeDomain/Library/SMS/sms.db`). The inventory is a DISTINCT forensic fact from the file
  contents — it answers what the extraction covered, **including what it did not**, which is a
  finding rather than something to stay silent about. Zero-byte files are flagged because they
  can mean a truncated extraction; an unknown size is stated as unknown rather than shown as
  zero. `Manifest.mbdb` (iOS 9 and earlier) is deliberately NOT claimed — it is a different,
  non-SQLite format, and treating it as one would report a readable backup as corrupt. Reading
  the manifest never opens any content file. The pipeline now WALKS that tree (HOST-8c): each file inside
  a backup is ingested under its device path, through the same pipeline, with an
  `archiveMember` relation and a per-member disposition recorded, so every member stays
  visible as admitted / blocked / failed. A file listed in the manifest but absent on disk is
  recorded as failed, because that is what a truncated extraction looks like. The safety
  guards are the archive lane's own — path-escape containment, the per-member byte ceiling and
  the shared root budget — so a backup is not a route around limits that apply to archives.
  **Still open:** there is no device entity yet, so two extractions from the same device do
  not merge.

## Advertising rule

Marketing may say "works with mixed document collections." It must **not** claim a format is
"Supported" unless this matrix shows FULL **and** it has passed the advertised-format fixture
gate (PAR-010). Never claim understanding of DEFERRED or PRESERVED-ONLY formats.
