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
| pdf | document | PARTIAL (OCR) | pdf-pdfkit | 1 |
| png | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| jpg | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| heic | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| tiff | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| webp | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| mp3, wav, m4a, aac, aiff, caf, flac, 3gp | audio | PARTIAL (ASR) / DEFERRED | apple-speech | 1 |
| mp4, mov | video | PARTIAL (ASR) / DEFERRED | apple-speech | 1 |
| ppt, keynote | presentation | PRESERVED-ONLY | — | — |
| imessage, chatExport | chat | PRESERVED-ONLY | — | — |
| safariHistory, chromeHistory | browserHistory | PRESERVED-ONLY | — | — |
| zip, rar, sevenZip | archive | CONTAINER | — | — |

**Totals (code-generated): 25 FULL · 6 PARTIAL · 10 media · 9 PRESERVED-ONLY/CONTAINER.**

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
- **Host artifacts (HOST-\*)** are machine/OS evidence rather than documents a person wrote, so
  they carry their own `hostArtifact` category. Processing is the same (immediate, text +
  structure); the distinction matters when attributing a fact to a person. A registry hive is
  read whole with each key's last-written time, capped at 20 000 keys per hive with the ceiling
  stated in a warning. Only complete hives are claimed: transaction logs (`.LOG1`/`.LOG2`) and
  backups (`.SAV`) are deliberately NOT treated as hives, because decoding a partial file would
  report corrupt evidence for a file that is simply not a hive. Freed cells are not followed, so
  nothing here reports deleted registry data as live.

## Advertising rule

Marketing may say "works with mixed document collections." It must **not** claim a format is
"Supported" unless this matrix shows FULL **and** it has passed the advertised-format fixture
gate (PAR-010). Never claim understanding of DEFERRED or PRESERVED-ONLY formats.
