from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.formatting.rule import FormulaRule

OUT = "/Users/shirshendusasmal/Downloads/DEVONthink_vs_Kalsmritikosh_Gap_Matrix.xlsx"

# Status vocabulary
GAP, PAR, AHEAD, DESIGN, PARTIAL = "GAP", "PARITY", "KALSMRITIKOSH AHEAD", "BY DESIGN", "PARTIAL GAP"

# (Area, Capability, DEVONthink, Kalsmritikosh, Status, Priority, Evidence, Recommendation)
rows = [
 # --- Capture & ingestion
 ("Capture", "Import / index files in place", "Import into database or index files in place; folder indexing stays in sync",
  "Ingests archive in place with custody; folder watcher", PAR, "—",
  "Ingestion/Pipeline/FolderWatcher.swift; CLAUDE.md", "—"),
 ("Capture", "Web clipping (browser extension, bookmarklets)", "Browser extensions + Sorter; clip as web archive, PDF, Markdown, bookmark",
  "None — no browser extension or clipper", GAP, "Medium",
  "grep: no WebClip/Safari extension in Kalsmritikosh/", "Safari Web Extension that saves page as HTML/PDF into an intake folder (no network beyond the page itself)"),
 ("Capture", "Share sheet / Services menu", "Share extension + macOS Services to send anything to DEVONthink",
  "None", GAP, "Medium", "grep: no NSServicesProvider/ShareExtension", "Add a Share extension that drops files into the intake queue"),
 ("Capture", "Email archiving from Mail.app / Outlook", "Imports mailboxes from Apple Mail and Outlook; mail plug-in/script",
  "Parses emlx, eml, mbox, msg, pst, nsf (FULL in measured matrix)", AHEAD, "—",
  "CAPABILITY_MATRIX.md (appleMail/eml/mbox/msg/pst/nsf FULL)", "Market it: PST/NSF/MSG parsing is broader than typical DMS import"),
 ("Capture", "Office / iWork formats", "Indexes text of Office, iWork, RTF, PDF, etc. via macOS importers",
  "docx/xlsx/pptx/doc/xls/odt/ods/rtf/epub FULL; Keynote & ppt PRESERVED-ONLY", PARTIAL, "Medium",
  "CAPABILITY_MATRIX.md (keynote, ppt PRESERVED-ONLY)", "Add Keynote (.key) and legacy .ppt structural parsers"),
 ("Capture", "Archives (zip / 7z / rar)", "Stores archives as files; contents not searchable unless expanded",
  "zip expanded member-by-member with safety limits; 7z/rar NOT EXPANDED", PARTIAL, "Low",
  "CAPABILITY_MATRIX.md (zip CONTAINER; sevenZip/rar NOT EXPANDED)", "Optional 7z/rar decoder (licence check required)"),
 ("Capture", "Audio / video transcription", "No built-in transcription (stores media; AI chat may summarise attached text)",
  "Speech transcription module (PARTIAL) when enabled; otherwise DEFERRED", PARTIAL, "Low",
  "CAPABILITY_MATRIX.md (audio/video DEFERRED); UI/TranscriptsView.swift", "Measure transcription on fixtures to promote from DEFERRED"),
 ("Capture", "Forensic / host artifacts", "Not supported",
  "Registry hive, MFT, prefetch, jump lists, KnowledgeC, shell history etc. FULL", AHEAD, "—",
  "CAPABILITY_MATRIX.md (hostArtifact rows)", "Unique for Investigator persona"),
 ("Capture", "Chat exports / iMessage / browser history", "Not parsed structurally",
  "Chat & discussion exports FULL; iMessage, Safari/Chrome history PRESERVED-ONLY", PARTIAL, "Medium",
  "CAPABILITY_MATRIX.md (imessage, safariHistory, chromeHistory PRESERVED-ONLY)", "Structural parsers for chat.db and browser history"),
 ("Capture", "OCR", "OCR built in (Pro/Server editions; commercial OCR engine, many languages)",
  "Apple Vision OCR; images measured PARTIAL; English only measured", PARTIAL, "Medium",
  "Ingestion/OCR/VisionOCR.swift; CAPABILITY_MATRIX.md (images PARTIAL)", "Measure OCR quality on real scans; add searchable-PDF export"),
 ("Capture", "Languages", "Multilingual search and OCR", "English only in v1 (multilingual planned for v2)", GAP, "Medium",
  "SHIP_DECISIONS.md §4; CAPABILITY_MATRIX.md note", "v2 plan: bge-m3 multilingual embedder"),
 # --- Organisation
 ("Organise", "Groups / folders hierarchy", "Groups, nested; replicants (one item in many groups)",
  "Sources, cases and subject/topic tree derived automatically; no user folder tree", PARTIAL, "Medium",
  "Knowledge/ (TopicTree, SubjectSpine); UI/LibraryView.swift", "Let users file items into manual collections alongside the automatic tree"),
 ("Organise", "Tags", "User tags, tag groups, hierarchical tags", "No user tag system", GAP, "High",
  "grep: no Tag model/repository", "Add user tags (new versioned migration) usable as search scope"),
 ("Organise", "Smart groups / saved searches", "Smart groups update live from criteria", "Saved queries view", PARTIAL, "Low",
  "UI/SavedQueriesView.swift", "Make saved queries live-updating, show counts"),
 ("Organise", "Smart rules / automation on events", "Smart rules: trigger on import/schedule, move/tag/rename/OCR/run script",
  "Automatic pipelines (enrichment, idle maintenance) but no user-defined rules", GAP, "Medium",
  "grep: no SmartRule/RuleEngine", "User rules: 'when a document from X arrives, tag/scope it'"),
 ("Organise", "Auto-classify / See Also", "Built-in AI suggests groups (Classify) and related docs (See Also)",
  "Document classifier, related-document insights, entity/topic linking", PAR, "—",
  "Ingestion/Classification/DocumentClassifier.swift; UI/DocumentInsights.swift", "—"),
 ("Organise", "Duplicate detection", "Duplicates highlighted; replicants vs duplicates", "Content-hash dedup at intake; duplicate fact merge", PAR, "—",
  "Ingestion/Intake (digests); memory: topic-ledger dedup", "—"),
 ("Organise", "Entity / people / organisation extraction", "Concordance word list only; no entity ledger",
  "Canonical entities with aliases, mentions, relationships", AHEAD, "—", "CLAUDE.md glossary; Knowledge/", "Core moat"),
 ("Organise", "Dated events & timeline", "No automatic timeline", "Dated event ledger + Timeline view", AHEAD, "—",
  "UI/TimelineView.swift; Knowledge/", "Core moat"),
 # --- Search & AI
 ("Search", "Full-text search", "Fast index; Boolean, NEAR, wildcard, fuzzy, field operators",
  "SQLite FTS5 + hybrid retrieval (memory, timeline, entity, FTS, vector)", PARTIAL, "Medium",
  "Storage/Repositories/EvidenceStore.swift (FTS5); no query-operator parser found", "Expose an advanced search syntax (AND/OR/NOT, phrase, date:, from:)"),
 ("Search", "Semantic / vector search", "Not core (AI chat uses external models)", "Bundled BGE embedder, on-device HNSW/IVF", AHEAD, "—",
  "SHIP_DECISIONS.md §1 (BGE-small)", "—"),
 ("AI", "Generative AI chat / summarise", "DEVONthink 4.x: chat via ChatGPT, Claude, Mistral, OpenRouter or local models (Ollama, LM Studio); AI Library of prompts/skills (4.4); MCP server so Claude/Codex can search the database (4.3)",
  "Apple Foundation Models on-device only (macOS 26+); deterministic engine otherwise", GAP, "High",
  "SHIP_DECISIONS.md §1 (no cloud in release, to be changed by O-1)", "Owner 2026-10-15: Private mode (default) + Online mode with own Claude/OpenAI/Gemini key — see Final TODO Wave O"),
 ("AI", "Cited answers with evidence gate", "Chat can highlight passages in documents (4.2) and Claude can search the database via MCP (4.3), but there is no evidence gate, refusal rule or contradiction check",
  "Claim–evidence contract, evidence gate (ship/downgrade/refuse/conflict), quality strip", AHEAD, "—",
  "CLAUDE.md; UI/QualityStrip.swift; CLAIMS_APP.md", "Lead feature in marketing"),
 ("AI", "Contradiction detection", "None", "Conflicts surfaced with both sources; never averaged", AHEAD, "—",
  "UI/AuditView.swift; Brain/", "—"),
 ("AI", "Works fully offline with zero AI", "Yes (non-AI features)", "Yes — deterministic evidence engine always works", PAR, "—",
  "SHIP_DECISIONS.md §1", "—"),
 # --- Read / edit
 ("View & edit", "Built-in viewers", "PDF, web, images, media, Markdown, RTF, sheets",
  "Source viewer (PDFKit) with exact locators", PARTIAL, "Medium", "UI/Shared/SourceViewer.swift", "Add QuickLook for formats without a native viewer"),
 ("View & edit", "Create & edit documents", "Create/edit Markdown, RTF, plain text, sheets; wiki links",
  "Notebook and report editor only; source documents are read-only evidence", DESIGN, "Low",
  "UI/NotebookView.swift; UI/ReportEditorView.swift", "Keep sources immutable; improve notebook"),
 ("View & edit", "PDF annotation / highlighting", "Highlight, annotate, edit PDFs", "No PDF annotation", GAP, "High",
  "grep: no PDFAnnotation", "Add highlights/notes stored as overlay records (never edit the source)"),
 ("View & edit", "Item links / deep links", "x-devonthink-item:// links usable in any app", "No URL scheme / deep links", GAP, "Medium",
  "grep: no onOpenURL / CFBundleURLSchemes", "kalsmritikosh:// links to documents, citations and answers"),
 # --- Integration
 ("Integration", "AppleScript / JXA scripting", "Extensive scripting dictionary", "None", GAP, "Medium",
  "grep: no scripting definition", "App Intents first (covers Shortcuts); AppleScript later"),
 ("Integration", "Shortcuts / App Intents", "Shortcuts actions", "None", GAP, "High",
  "grep: no AppIntents", "App Intents: Ask, Search, Ingest folder, Open source"),
 ("Integration", "Spotlight integration", "Items searchable from Spotlight", "None", GAP, "Low",
  "grep: no CoreSpotlight", "Optional, privacy-respecting Spotlight index (off by default)"),
 # --- Sync, devices, security
 ("Sync & devices", "Multi-Mac sync", "CloudKit, Dropbox, WebDAV, Bonjour; encrypted sync stores",
  "None — single Mac, no network in release", DESIGN, "Medium",
  "SHIP_DECISIONS.md §1 (no network provider)", "Possible later: user-controlled encrypted export/import between Macs"),
 ("Sync & devices", "iPhone / iPad app", "DEVONthink To Go 4 (included with Pro/Server), with AI chat", "None (out of scope for v1)", GAP, "Low",
  "SHIP_DECISIONS.md §4", "v1.x companion (read-only ledger viewer)"),
 ("Sync & devices", "Web / server access", "Server edition with web interface", "None", DESIGN, "Low",
  "SHIP_DECISIONS.md (App Store, offline)", "Not aligned with privacy positioning"),
 ("Security", "Database encryption", "Encrypted databases", "Relies on FileVault + App Sandbox; no app-level DB encryption", GAP, "High",
  "grep: no SQLCipher/AES-GCM", "Evaluate app-level encryption for the ledger + vault (key in Keychain)"),
 ("Security", "Redaction for export", "Not built in (stamps + Bates numbering exist)", "Redaction view; exports redact citations/manifests (visual redaction still a ship gate)", AHEAD, "—",
  "UI/RedactionView.swift; SHIP_DECISIONS.md §3 (F7 gate)", "Close the visual-redaction gate"),
 ("Security", "Chain of custody / provenance", "Revision-proof databases (4.0): edits restricted, deletions logged, exportable audit log", "Custody manifests, source versions, hashes, receipts", PARTIAL, "Medium",
  "CAPABILITY_MATRIX.md (custodyManifest FULL); Ingestion/Intake", "Our edge must be hash receipts anyone can verify offline (W1-3); DEVONthink now has audit logs too"),
 # --- Data safety & scale
 ("Data safety", "Versioning", "Automatic versions with retention policies; named versions (4.2)", "Source versions tracked; fact/memory change log", PAR, "—",
  "source_versions table; MemoryChange log", "—"),
 ("Data safety", "Backup & restore", "Database archive/backup, Time Machine", "Backup service", PAR, "—", "App/BackupService.swift", "—"),
 ("Scale", "Proven large databases", "Mature product; reviewers run ~18,000 items / 22 GB comfortably",
  "Advertised scale is tested-figure-only; no recorded large run yet", GAP, "High",
  "SHIP_DECISIONS.md §1 + §3 (scale gate)", "Record an owner-hardware run and publish the tested figure"),
 # --- Workflow
 ("Workflow", "Professional work products", "General-purpose; no persona workflows",
  "Five persona lenses: legal, investigator, journalist, researcher, individual; dossiers, matrices, privilege logs", AHEAD, "—",
  "SHIP_DECISIONS.md §1 (personas); UI/*StudioView.swift", "—"),
 ("Workflow", "Platform maturity & documentation", "~20 years, large user community, extensive manual",
  "Early access; in-app guide", GAP, "Medium", "SHIP_DECISIONS.md (launch claim: early access)", "Write a user manual; publish recipes per persona"),
 ("Distribution", "Pricing / editions", "Standard $99 / Pro $199 / Server $499; one year of updates, two seats (vendor site, Oct 2026)",
  "Planned $29–49 one-time, Personal tier; Mac App Store only", PAR, "—", "SHIP_DECISIONS.md §1", "—"),
]

wb = Workbook()
ws = wb.active
ws.title = "Gap Matrix"
headers = ["#", "Area", "Capability", "DEVONthink", "Kalsmritikosh (today)", "Status", "Priority", "Evidence (repo)", "Recommendation"]
ws.append(headers)
for i, r in enumerate(rows, 1):
    ws.append([i, *r])

thin = Side(style="thin", color="BFBFBF")
hdr_fill = PatternFill("solid", fgColor="1F3864")
for c in ws[1]:
    c.font = Font(bold=True, color="FFFFFF")
    c.fill = hdr_fill
    c.alignment = Alignment(vertical="center", wrap_text=True)
widths = [5, 14, 32, 45, 45, 22, 10, 40, 48]
for i, w in enumerate(widths, 1):
    ws.column_dimensions[get_column_letter(i)].width = w
n = len(rows) + 1
for row in ws.iter_rows(min_row=2, max_row=n):
    for c in row:
        c.alignment = Alignment(vertical="top", wrap_text=True)
        c.border = Border(top=thin, bottom=thin, left=thin, right=thin)
ws.freeze_panes = "D2"
ws.auto_filter.ref = f"A1:I{n}"

colors = {GAP: "F8CBAD", PARTIAL: "FFE699", PAR: "DDEBF7", AHEAD: "C6EFCE", DESIGN: "E7E6E6"}
for status, color in colors.items():
    ws.conditional_formatting.add(f"F2:F{n}", FormulaRule(formula=[f'$F2="{status}"'], fill=PatternFill("solid", fgColor=color)))
ws.conditional_formatting.add(f"G2:G{n}", FormulaRule(formula=['$G2="High"'], font=Font(bold=True, color="C00000")))
dv_s = DataValidation(type="list", formula1='"' + ",".join([GAP, PARTIAL, PAR, AHEAD, DESIGN]) + '"', allow_blank=False)
dv_p = DataValidation(type="list", formula1='"High,Medium,Low,—"', allow_blank=True)
ws.add_data_validation(dv_s); ws.add_data_validation(dv_p)
dv_s.add(f"F2:F{n}"); dv_p.add(f"G2:G{n}")

# Summary sheet with live formulas
s = wb.create_sheet("Summary")
s.append(["Status", "Count", "Meaning"])
meaning = {GAP: "DEVONthink has it, Kalsmritikosh does not",
           PARTIAL: "Kalsmritikosh has part of it",
           PAR: "Both have it",
           AHEAD: "Kalsmritikosh has it, DEVONthink does not",
           DESIGN: "Deliberately different (privacy / evidence contract)"}
for st in [GAP, PARTIAL, PAR, AHEAD, DESIGN]:
    s.append([st, f"=COUNTIF('Gap Matrix'!F:F,\"{st}\")", meaning[st]])
s.append(["Total", "=SUM(B2:B6)", ""])
s.append([])
s.append(["Gaps + partial gaps by priority", "Count", ""])
for p in ["High", "Medium", "Low"]:
    s.append([p, f"=COUNTIFS('Gap Matrix'!G:G,\"{p}\",'Gap Matrix'!F:F,\"{GAP}\")+COUNTIFS('Gap Matrix'!G:G,\"{p}\",'Gap Matrix'!F:F,\"{PARTIAL}\")", ""])
for r in (1, 9):
    for c in s[r]:
        c.font = Font(bold=True, color="FFFFFF"); c.fill = hdr_fill
s["A7"].font = Font(bold=True); s["B7"].font = Font(bold=True)
for st, color in colors.items():
    for row in s.iter_rows(min_row=2, max_row=6):
        if row[0].value == st:
            row[0].fill = PatternFill("solid", fgColor=color)
s.column_dimensions["A"].width = 32; s.column_dimensions["B"].width = 10; s.column_dimensions["C"].width = 55

# Sources / caveats
src = wb.create_sheet("Sources & caveats")
notes = [
 "Kalsmritikosh column: taken from the repository at branch review-fixes (CAPABILITY_MATRIX.md is generated by a test; SHIP_DECISIONS.md is the locked contract) and from code searches recorded in the Evidence column.",
 "'grep: no X' means a search of Kalsmritikosh/ source found no implementation. It is evidence of absence in this branch, not proof the idea was never planned.",
 "DEVONthink column: checked 2026-10-15 against devontechnologies.com (product page, release notes 4.0-4.4.1) and the MacStories DEVONthink 4 review. Re-check before external use; DEVONthink ships several updates a year.",
 "Status 'BY DESIGN' marks differences that follow the locked privacy contract (no network, no cloud AI, sources are immutable evidence). They are not defects.",
 "Priority reflects fit with the v1 personas (lawyer, investigator, journalist, researcher, individual) and App Store expectations; it is a judgement, adjust as needed.",
]
src.append(["Note"])
src["A1"].font = Font(bold=True, color="FFFFFF"); src["A1"].fill = hdr_fill
for t in notes:
    src.append([t])
src.column_dimensions["A"].width = 140
for row in src.iter_rows(min_row=2):
    row[0].alignment = Alignment(wrap_text=True, vertical="top")

wb.save(OUT)
from collections import Counter
print(OUT)
print(Counter(r[4] for r in rows))
print("high gaps:", [r[1] for r in rows if r[5] == "High"])
