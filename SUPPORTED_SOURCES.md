# SUPPORTED_SOURCES

> **DOC STATUS: CURRENT** — this matrix is **generated from code** by
> `ParserCapabilityManifest` (PAR-001), not hand-maintained, so it cannot drift from what
> the app actually parses. Regenerate with
> `ParserCapabilityManifest.renderMarkdown(registry:)`. Supersedes the format claims in
> `SUPPORTED_FORMATS_V1.md`.

Coverage states (from the locked product contract):

- **FULL** — a structural parser recovers structure + exact locators. May be *advertised*
  "Supported" only after fixture + release verification (PAR-010).
- **PARTIAL** — content recovered with disclosed limits. Two different limits live here:
  OCR-dependent formats, whose fidelity depends on scan/image quality; and container-only
  formats, where the file's framing is read exactly but its record content is not interpreted
  (currently `evtx`). The limit is always named, never left as a vague "partial".
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
| loginRecord (utmp/wtmp/btmp) | hostArtifact | FULL | linux-login-accounting-utmp | 1 |
| shellHistory (bash/zsh/fish/REPL) | hostArtifact | FULL | shell-history | 1 |
| shellLink (lnk) | hostArtifact | FULL | windows-shell-link | 1 |
| amcache (Amcache.hve) | hostArtifact | FULL | windows-amcache | 1 |
| masterFileTable ($MFT) | hostArtifact | FULL | ntfs-master-file-table | 1 |
| knowledgeC | hostArtifact | FULL | apple-knowledgec | 1 |
| custodyManifest | document | FULL | chain-of-custody | 1 |
| extractionManifest | hostArtifact | FULL | ios-backup-manifest | 1 |
| discussionExport | chat | FULL | discussion-export | 1 |
| eventLog (evtx) | hostArtifact | PARTIAL (container) | windows-eventlog-evtx | 1 |
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

**Totals (code-generated): 34 FULL · 7 PARTIAL · 10 media · 9 PRESERVED-ONLY/CONTAINER.**

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
- **PARTIAL (container) — Windows event logs (`.evtx`, HOST-3).** An EVTX file has two layers.
  The CONTAINER is fixed-offset and is read exactly: every record's id and its written
  FILETIME, so a machine's own account of itself lands on the timeline — when it was on, when
  someone signed in, when a service was installed — each record citable at its byte offset.
  The CONTENT layer is BinXML with a per-chunk TEMPLATE table, and templates are **not
  resolved**, so a record's structured field names (`EventID`, `Provider`, `Channel`, the named
  `Data` elements) are not recovered. The UTF-16 strings a record carries **are** recovered,
  unlabelled. The practical line: this log is searchable and dated ("a record at 09:26:53
  mentioning EVIDENCE-01"), but it cannot yet be filtered by event id, so it will not answer
  "show me every 4624". That gap is emitted as an **evidence block**, not merely a warning, so
  an answer built on a thin event log can quote what the log could not say; the status is
  always PARTIAL and never COMPLETE, and a test pins that. The boundary is deliberate: BinXML
  templates are self-referential, so a fixture writer correct enough to prove a template
  resolver needs the same understanding as the resolver, and a shared misunderstanding would
  pass its own tests. Verifying the template layer needs a real `.evtx` to check against, so
  the container ships verified and the parser SAYS what it could not interpret. Other honest
  states: a log copied from a running machine has its dirty flag reported (the last chunk may
  be mid-write), a truncated log yields what survived and says it is short, records are read
  only up to each chunk's free-space offset so stale bytes from a previous log are never
  reported as current records, and confidence is capped at medium.
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

- **Linux login accounting (`utmp` / `wtmp` / `btmp`, HOST-4)** answers the first question an
  investigation asks about a machine: who was on it, from where, and when. It is read
  COMPLETELY — every field of every record — because the format is a bare array of fixed-size
  records with no templates and no compression; that is why it is FULL where the Windows event
  log is PARTIAL. Boots, shutdowns, logins, logouts and failed attempts all become dated,
  citable evidence, with the terminal, the remote hostname and the remote IP where the record
  carries them. **The one thing that must not go wrong:** these three files share a single
  384-byte record layout and mean three different things, and the meaning exists ONLY in the
  filename — `utmp` is who was logged in at the moment of imaging, `wtmp` is history, and
  `btmp` is FAILED attempts. A btmp record whose type on disk is identical to a successful
  login is therefore never rendered with the words of one; a test pins that, because the
  inversion would turn a rejected break-in into evidence that someone was signed in. A file
  whose name is neither is reported as being of unknown kind rather than assumed to be history.
  Byte order is the host's and nothing in the file declares it, so both readings are scored and
  the winner is recorded (a big-endian machine is itself a fact worth stating). Sessions —
  login paired with logout — are marked **derived**, since the file stores two independent
  records and only the reused terminal name links them; a login with no logout is reported as
  still open rather than given a duration, and a logout stamped before its login is called a
  clock change rather than shown as negative. Detection is by filename, including rotated
  copies (`wtmp.1`); a text report ABOUT the file (`wtmp.txt` from `utmpdump`) stays a text
  document. The format has no magic signature, so a file exported under another name is
  recovered by a deliberately strict structural probe that runs ONLY where the alternative is
  "unknown bytes" — it can never take a file away from a recognized format, and it refuses an
  all-zero file rather than claim it on the strength of its empty slots. Inherent limit: `tv_sec`
  is a signed 32-bit count, so the format itself cannot express a time past 2038.
  **Not yet read:** `journald` binary journals — see the deferred list at the end of this
  section. Shell history is now read; see the next entry.

- **Shell and REPL history (HOST-4b)** is what was actually TYPED on the machine —
  `.bash_history`, `.zsh_history`, `fish_history`, `.python_history`, `.mysql_history` and
  their siblings. These already parsed as plain text, so the commands were searchable; what
  was missing was the part that matters most, WHEN. Three of the four flavours carry
  per-command timestamps that look like nothing to a text reader, and all three are now
  decoded: bash's `#<epoch>` marker lines (HISTTIMEFORMAT), zsh's
  `: <epoch>:<elapsed>;command` prefix (EXTENDED_HISTORY — which also records how long the
  command RAN, a fact nothing else states), and fish's `- cmd:` / `when:` blocks. Multi-line
  commands are kept whole, because cutting at the first newline would report a command nobody
  ran. A `#` line that is not a bare 9-to-12-digit number stays a typed comment, so `# deploy`
  and `#42` are commands rather than invented dates. Unmarked lines are joined into the
  preceding command ONLY after a timestamp has been seen: bash marks every dated command, but
  applying that rule to the undated region at the top of a file — the normal shape, since
  timestamping is usually switched on part-way through — would fuse a whole history into one
  command. An **UNDATED** history states that in the evidence itself, because it otherwise
  looks identical to a dated one whose dates failed to display, and an answer could place
  those commands at a time the file never recorded; what such a file does establish is ORDER,
  preserved by sequence number. A partially dated file reports which half is which. Two
  deliberate refusals: commands are never de-duplicated (running something forty times is
  itself a fact) and never labelled suspicious or dangerous (that is analysis, and a wrong
  label beside real evidence reads as if the file had said it). Detection is by exact
  filename — bare `History` belongs to the browser lane, a `.txt` export is a document about
  the file, and `.lesshst` / `.viminfo` are editor state rather than commands. Non-UTF-8 bytes
  (zsh writes its own escaped encoding for non-ASCII) are read byte-for-byte as Latin-1 with
  the encoding disclosed, rather than guessing at an unescaping that could corrupt a command.

- **Windows shortcuts (`.lnk`, HOST-6a)** are evidence about files that may no longer exist. A
  shortcut in `Recent` records the target's full original path and size, the volume's serial
  number and label, and the DRIVE TYPE — and when that type is REMOVABLE, the shortcut is
  often the only surviving record that a particular file was on a particular USB device and
  was opened from this machine. Also read: the relative path, working directory, description,
  icon location, and the command-line ARGUMENTS (how a program was actually invoked), plus the
  TrackerDataBlock's NetBIOS name of the machine that CREATED the link — which is not
  necessarily the machine it was found on, and is labelled as such. **The misreading this
  parser refuses to enable:** a shortcut's three FILETIMEs belong to the TARGET FILE as it
  stood when the shortcut was last written. They are NOT when the shortcut was used. Every one
  of them carries that disclaimer in its own evidence block — not once at the top of the
  document — because a retrieved answer quotes a block, so a caveat elsewhere would not travel
  with it. **The identifier this parser refuses to manufacture:** the tracker's droid UUIDs can
  contain the creating machine's MAC address, but only when the UUID is version 1 with a
  unicast node; a version-4 UUID's node bytes are random, and reporting those as a hardware
  address would invent an identifier an investigation could attribute to a person. Both
  conditions are checked and no address is reported otherwise. The shell-item id list is
  declared, skipped by its exact size and DISCLOSED rather than decoded: it is a
  loosely-documented per-shell-folder tagged format, and the path information worth having is
  carried in the fixed-offset location block and relative path. A shortcut renamed away from
  `.lnk` is still found by its 20-byte header-plus-class-id signature.

- **Amcache (`Amcache.hve`, HOST-6c)** is Windows's inventory of executables that have been
  PRESENT on the machine. It is a registry hive, so HOST-2's reader already read its bytes
  exactly; what this adds is the schema — and the prize is the executable's **SHA-1**, which
  identifies precisely which binary was there and can be matched against a hash set long after
  the file is deleted, alongside its full path, publisher, product, version, size and PE link
  date. **The misconception this refuses to enable:** an Amcache entry is NOT evidence of
  execution. Windows populates the inventory from a scheduled task that walks the filesystem,
  so an entry proves the file existed at that path when the task ran — nothing more. Reading
  Amcache as a "programs that ran" list is a well-known and consequential error, so the
  distinction is emitted as an evidence block and every record states that it is evidence of
  presence. The key's last-written time is labelled a property of the RECORD, not of the file.
  A `FileId` is reported as a SHA-1 only when it really is a 40-character hex digest (behind
  the format's `0000` prefix), and an all-zero digest is treated as the placeholder it is —
  a hash that gets reported is a hash someone will look up. The LEGACY numbered schema
  (Windows 8: values named `0`, `15`, `101` …) is counted and disclosed but deliberately NOT
  mapped: those field meanings are community-derived rather than documented, and labelling one
  "SHA-1" on that basis would present a guess in the shape of a fact. `Amcache.hve` is routed
  ahead of the generic hive detector, since reading it as an ordinary hive would dump its keys
  without the schema that makes them mean anything.

- **NTFS master file table (`$MFT`, HOST-5)** is the artifact that outlives the files it
  describes, which makes it the strongest thing in an extraction. Every file and folder has a
  record holding its name, size, parent directory and four timestamps, and when a file is
  DELETED the record is only marked not-in-use — the name and the times survive until the slot
  is reused. For small files the entire content is stored inside the record, so a deleted note
  or configuration file comes back in full. Full paths are rebuilt by walking parent
  references. **Three things it states rather than assumes.** (1) Deleted records are labelled
  DELETED, in the evidence and in the searchable text: a filename hit must never read as
  though the file were still on the disk. (2) A path through a directory whose record has been
  REUSED by a different folder is labelled stale — it is what the record says, not where the
  file was — and a parent missing from the extraction makes the path explicitly incomplete.
  (3) NTFS stores the four timestamps TWICE, in `$STANDARD_INFORMATION` and in `$FILE_NAME`.
  Where the two disagree, both values and the field that differs are reported as a factual
  property of the record; it is **not** called timestomping, because installers, archive
  extraction and copying tools all produce differences and naming a cause is analysis rather
  than extraction. **The trap this parser had to survive:** NTFS overwrites the last two bytes
  of every 512-byte sector of a record with an update-sequence number and stores the displaced
  originals in an array. A reader that does not put them back corrupts two bytes per sector,
  and for any field crossing a boundary that yields a plausible-looking WRONG date — silent
  corruption. Fixups are applied before anything is parsed, and a record whose sector
  placeholder does not match its sequence number is refused outright rather than reported with
  corrupt fields, because that means the copy was taken mid-write. Other honest states: the
  record size is read from the file (so 4096-byte-record volumes work), a record NTFS itself
  marked BAD is reported with its fields flagged untrustworthy, DOS 8.3 names are not counted
  as separate files, extension records are not counted as extra files, unused slots are skipped
  silently while data-bearing unsigned slots are counted, resident content that is not text is
  NOT rendered as mojibake that a search would match, and the record ceiling is stated. `$MFT`
  is detected by name (including `mft`, `C.$MFT`, `.mft`) and a renamed export by a structural
  probe that requires the record header's own offsets to be self-consistent, since "FILE" alone
  is a weak signature.

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
  Device identity (HOST-8d) is an `identifierAnchor`, the case
  built for "a real-world subject identified by a canonical identifier" — so a serial, IMEI,
  MEID, UDID or MAC address merges two extractions of one device through the existing gated
  anchor door, with no new entity kind and no schema change. Identity is (field, value), so a
  serial and an IMEI sharing digits stay two devices. A computer name or model is recorded but
  NEVER merges, because two machines are routinely called the same thing; manufacturer
  placeholders ("To Be Filled By O.E.M.", "Unknown", all-zero serials) are refused, since
  anchoring on one would fuse every device that shares it. HOST-8e wires this into every run: the strong device
  fields are registered `.identifier`-shaped, and the pipeline's existing anchor binding
  resolves an anchor for every identifier-shaped fact — so device anchors are created with no
  new call site and no new write path. Identifiers are read only from STRUCTURED key/value
  blocks (plist, registry, custody manifest); a serial appearing in prose is never anchored,
  because that would be a guess.

### Host artifacts NOT yet read (stated, so absence is never mistaken for coverage)

An extraction containing these keeps them with identity, hash and dates, and they stay
searchable by name — they are simply not interpreted yet:

- **Windows event log CONTENT** — records are dated and searchable, but not filterable by
  event id. See the PARTIAL (container) note above.
- **`journald`** binary journals (`*.journal`). The examiner's normal export path
  (`journalctl -o json` / `-o export`) produces JSON or text that IS already ingested, so the
  gap is the binary file rather than the log's content.
- **Program execution** — Prefetch (Win10+ is LZXPRESS-Huffman compressed), jumplists (OLE2
  containers of shell-link streams), Shimcache. Plain `.lnk` shortcuts and Amcache ARE read;
  see the entries above.
- **`lastlog`** — deliberately not claimed with the utmp family: it has a different record
  layout and identifies an account only by the record's POSITION (the numeric uid), so without
  `/etc/passwd` a login would be attributed to a number.

## Advertising rule

Marketing may say "works with mixed document collections." It must **not** claim a format is
"Supported" unless this matrix shows FULL **and** it has passed the advertised-format fixture
gate (PAR-010). Never claim understanding of DEFERRED or PRESERVED-ONLY formats.
