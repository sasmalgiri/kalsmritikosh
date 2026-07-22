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
- **DEFERRED** — recognized but processing intentionally postponed (audio/video; ASR is a
  WhisperKit stub, media is skipped by design in v1).

## Coverage matrix (generated 2026-07-22 from `StructuralParserRegistry.standard(ocr:)`)

| Format | Category | Coverage | Parser | Version |
|---|---|---|---|---|
| txt | document | FULL | plaintext | 1 |
| markdown | document | FULL | plaintext | 1 |
| rtf | document | FULL | rtf-attributed | 1 |
| docx | document | FULL | docx-ooxml | 1 |
| doc | document | FULL | DocStructuralParser | 1.0 |
| odt | document | FULL | odt-opendocument | 1 |
| epub | document | FULL | epub-opf | 1 |
| csv | spreadsheet | FULL | csv | 1 |
| xlsx | spreadsheet | FULL | xlsx-ooxml | 1 |
| xls | spreadsheet | FULL | XlsStructuralParser | 1.0 |
| ods | spreadsheet | FULL | ods-opendocument | 1 |
| pptx | presentation | FULL | pptx-ooxml | 1 |
| eml | email | FULL | eml | 1 |
| mbox | email | FULL | mbox | 1 |
| appleMail (emlx) | email | FULL | emlx-apple-mail | 1 |
| pdf | document | PARTIAL (OCR) | pdf-pdfkit | 1 |
| png | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| jpg | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| heic | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| tiff | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| webp | image | PARTIAL (OCR) | image-vision-ocr | 1 |
| mp3, wav, m4a, aac, aiff, caf, flac, 3gp | audio | DEFERRED | — | — |
| mp4, mov | video | DEFERRED | — | — |
| msg, pst, nsf | email | PRESERVED-ONLY | — | — |
| ppt, keynote | presentation | PRESERVED-ONLY | — | — |
| imessage, chatExport | chat | PRESERVED-ONLY | — | — |
| safariHistory, chromeHistory | browserHistory | PRESERVED-ONLY | — | — |
| zip, rar, sevenZip | archive | CONTAINER | — | — |

**Totals (code-generated): 15 FULL · 6 PARTIAL · 10 DEFERRED · 12 PRESERVED-ONLY.**

## Caveats (honest limits)

- **Archives (zip/rar/7z)** are *containers*, not content: the ingest pipeline expands them
  and parses each member by its own type. They are not "preserved-only" in the content sense —
  the manifest lists them without a structural parser because the archive bytes themselves
  carry no evidence blocks. (The manifest's raw output labels these PRESERVED-ONLY; read them
  as CONTAINER per this note.)
- **PARTIAL (OCR)** fidelity depends on image/scan quality; a currency glyph or handwriting
  may be misread. Native-text PDFs extract exactly; scanned pages fall back to Vision OCR.
- **DEFERRED media**: audio/video are recognized and preserved but not transcribed in v1
  (WhisperKit is a stub; media is skipped so ingest never blocks on it).
- **PRESERVED-ONLY** formats need legacy loaders (MSG/PST/NSF/PPT/Keynote) or dedicated
  adapters (iMessage/chat/browser history) — tracked, intentionally not in v1.

## Advertising rule

Marketing may say "works with mixed document collections." It must **not** claim a format is
"Supported" unless this matrix shows FULL **and** it has passed the advertised-format fixture
gate (PAR-010). Never claim understanding of DEFERRED or PRESERVED-ONLY formats.
