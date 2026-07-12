# Kalsmritikosh — Supported Formats (v1)

Honest per-format status. **Advertise only what is here as "advertised".** Support
status is separate from `SourceType.case` existing (A3.1 / spec §8.1). "Structural"
means the format produces typed `EvidenceBlock`s with exact locators (A1);
"legacy" means it still flattens to `KnowledgeObject.content` and will migrate.

Verified against `origin/main`. Structural parsers live in `Ingestion/Structural/`.

## Status legend
- **Structural** — typed evidence blocks + locators (A1 path). Exact citations.
- **Legacy** — flattened text only (pre-A1). Works, but coarse locators.
- **Deferred** — intentionally out of v1 (locked exclusions or not yet built).

| Format | SourceType | v1 status | Parser | Blocks / locators | Notes |
|---|---|---|---|---|---|
| Plain text | `.txt` | Structural | `PlainTextStructuralParser` | paragraph; char range | |
| Markdown | `.markdown` | Structural | `PlainTextStructuralParser` | title/heading/list/quote/code/paragraph; char range + section path | |
| DOCX | `.docx` | Structural | `DocxStructuralParser` | title/heading/list/paragraph/table/tableRow; section path; header/footer boilerplate | native OOXML |
| CSV | `.csv` | Structural | `CSVStructuralParser` | sheet + row (cells as JSON); sheet/row locator | RFC-4180; deterministic table queries |
| EML | `.eml` | Structural | `EmailStructuralParser` | header-per-field / body / attachment; message-id + header-field locator | quote-strip + multipart reused |
| PDF | `.pdf` | Structural | `PDFStructuralParser` | paragraph blocks; page + paragraphIndex locator; OCR pages flagged (method + confidence) | native text + per-page OCR fallback (mojibake-aware); word bboxes are a later refinement |
| XLSX | `.xlsx` | Structural | `XLSXStructuralParser` | sheet + row (cells as JSON) per worksheet; sheet/row locator | OOXML shared-strings; deterministic table queries |
| PPTX | `.pptx` | Structural | `PPTXStructuralParser` | slideTitle / slideBody / slideNotes; slide + shape locator | title-placeholder aware; DrawingML runs; speaker notes |
| EPUB | `.epub` | Structural | `EPUBStructuralParser` | documentTitle / sectionHeading / paragraph / listItem / quote in reading order; sectionPath + chapter member locator | OPF spine order; XHTML reading-order walk |
| RTF | `.rtf` | Structural | `RTFStructuralParser` | paragraph blocks; character-range locator | NSAttributedString decode; heading-from-font-runs is a later refinement |
| ODT | `.odt` | Structural | `ODTStructuralParser` | sectionHeading / paragraph in reading order; sectionPath locator | OpenDocument content.xml; outline-level headings |
| ODS | `.ods` | Structural | `ODSStructuralParser` | sheet + row (cells as JSON); sheet/row locator | OpenDocument content.xml; honors column/row repeat; deterministic table queries |
| MBOX | `.mbox` | Legacy (per-message KOs) | `EmailLoader` | per-message flattened | structural MBOX = follow-up |
| EMLX (Apple Mail) | `.appleMail` | Legacy | `EmailLoader` | flattened | |
| Images | `.png/.jpg/.heic/.tiff/.webp` | Structural | `ImageStructuralParser` | image container + paragraph-per-line + table/tableRow; line/row locator; OCR confidence | Vision OCR; word bboxes are a later refinement |
| ZIP | `.zip` | Structural relations pending | `ArchiveLoader` | members re-ingested | security guards done (zip-bomb/slip); A3.12 member provenance |
| Audio | `.mp3/.wav/.m4a/.aac` | **Deferred/experimental** | `AudioLoader`+ASR | transcript (no timecodes yet) | advertise only after timecoded evidence (A3.13) |
| Video | `.mp4/.mov` | **Deferred/experimental** | `AudioLoader` | audio transcript only | NOT "video understanding" |

## Deferred (locked exclusions — do not advertise)
`DOC` `.doc` · `XLS` `.xls` · `PPT` `.ppt` · `PST/OST` · `MSG` · `NSF` · `RAR`/`7z` ·
Keynote (unless proven) · Publisher · browser/iMessage direct DB loading · cloud OCR/ASR.

## Acceptance per advertised format (A3.14)
normal · empty · corrupt · encrypted (where applicable) · huge · duplicate · renamed ·
nested · interrupted · unusual encoding · exact-citation reopen. Fixtures tracked with the
test target (A0.6).
