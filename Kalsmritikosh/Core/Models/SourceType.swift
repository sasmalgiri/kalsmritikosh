//
//  SourceType.swift
//  Kalsmritikosh
//
//  The kinds of source files the system can ingest. Used by every
//  KnowledgeObject so downstream layers never need to inspect the
//  raw file to know what they're dealing with.
//

import Foundation
import UniformTypeIdentifiers

public enum SourceType: String, Codable, CaseIterable, Sendable {
    // Documents
    case pdf, docx, doc, txt, markdown, rtf, odt, epub

    // PAR-008 — structured text: web/data/config/log formats with a
    // deterministic structure we can parse into typed blocks.
    case html, json, xml, log
    /// HOST-1 — Apple property list (binary `bplist00`, XML, or legacy OpenStep).
    /// Its own type, not `.xml`: a binary plist is not XML at all, and the key-path
    /// structure is what makes a host artifact citable.
    case plist
    /// HOST-8 — the examiner's chain-of-custody sidecar for an extraction. A
    /// document a person authored, not machine evidence, so it carries the
    /// document category; what makes it special is that it is the ONE artifact
    /// describing where all the others came from.
    case custodyManifest
    /// HOST-7 — Apple's CoreDuet activity store (`knowledgeC.db`): app focus with
    /// durations, device lock/unlock, screen, media, battery. Its own type rather
    /// than plain `.sqlite` because its timestamps are APPLE EPOCH and its rows
    /// only become dated events once a schema-aware parser reads them.
    case knowledgeC
    /// HOST-2 — Windows registry hive (REGF): NTUSER.DAT, UsrClass.dat, SOFTWARE,
    /// SYSTEM, SAM, SECURITY. Usually EXTENSIONLESS, so recognized by filename
    /// pattern and by the "regf" signature.
    case registryHive
    /// DISC-1 — a discussion-platform data export (YouTube Takeout comments,
    /// Discord package, Reddit CSVs, X archive, Telegram JSON, Twitch chat,
    /// saved forum threads). One type for all of them: the platform is decided by
    /// a mapper reading the CONTENT, because export filenames like `comments.csv`
    /// are not unique to any platform.
    case discussionExport

    // PAR-009 — a generic read-only SQLite database (rows cite db/table/key).
    case sqlite

    // Spreadsheets
    case xlsx, xls, csv, ods

    // Presentations
    case pptx, ppt, keynote

    // Email
    case mbox, pst, eml, msg, appleMail, nsf

    // Images
    case png, jpg, heic, tiff, webp

    // Audio — mp3/wav/m4a/aac plus mobile/voice-note containers that
    // AVFoundation decodes natively (aiff, caf, flac, AAC-in-3GP).
    case mp3, wav, m4a, aac, aiff, caf, flac, threegp

    // Video
    case mp4, mov

    // Archives
    case zip, rar, sevenZip

    // Phase K — chat + browser ingest. Each maps to a dedicated
    // loader that knows how to read the source's schema (SQLite for
    // imessage / browser history; structured text for chat exports).
    case imessage
    case safariHistory
    case chromeHistory
    case chatExport

    // Fallback
    case unknown

    /// Best-effort detection from a file URL.
    /// USF-001.1 — the canonical filename / path PATTERN detector (Phase K), separated so a
    /// single authoritative detector can order pattern → magic bytes → declared extension →
    /// unknown. Returns nil when no meaningful pattern matches (chat.db lives at
    /// ~/Library/Messages/chat.db; History.db is Safari; bare "History" is Chrome's profile DB).
    public nonisolated static func detectPathPattern(from url: URL) -> SourceType? {
        let name = url.lastPathComponent.lowercased()
        let path = url.path.lowercased()
        if name == "chat.db" || path.contains("/library/messages/") { return .imessage }
        if name == "history.db" || path.contains("/library/safari/history") { return .safariHistory }
        if name == "history"
            && (path.contains("/google/chrome/") || path.contains("/brave-browser/")
                || path.contains("/microsoft/edge/") || path.contains("/arc/user data/")) {
            return .chromeHistory
        }
        if name.hasPrefix("whatsapp chat ") || name.hasPrefix("_chat ")
            || name.contains("signal-") || name.contains("slack-export") {
            return .chatExport
        }
        // HOST-2 — Windows registry hives are extensionless with fixed names, so
        // the filename IS the signal. `.dat` would otherwise fall through to
        // `.unknown` and `SOFTWARE`/`SYSTEM`/`SAM` have no extension at all.
        // Transaction logs (.LOG1/.LOG2) and backups (.SAV) are deliberately not
        // claimed here: they are not whole hives and would decode as corrupt.
        if Self.registryHiveNames.contains(name) { return .registryHive }
        // HOST-7 — must precede the `.db` extension mapping, or the activity store
        // reads as a generic SQLite file and its Apple-epoch dates stay numbers.
        if name == "knowledgec.db" || path.contains("/coreduet/knowledge/") { return .knowledgeC }
        // HOST-8 — must precede the `.json` extension mapping, or the chain of
        // custody reads as an ordinary JSON document and never reaches the ledger
        // as custody.
        if CustodyRecord.manifestNames.contains(name) { return .custodyManifest }
        // DISC-1 — discussion exports. Ambiguous names (comments.csv, messages.json)
        // are claimed ONLY inside a recognizable export tree, so an ordinary
        // spreadsheet named comments.csv stays a CSV. Unambiguous names stand alone.
        if Self.discussionExportPathMarkers.contains(where: { path.contains($0) }),
           Self.discussionExportNames.contains(name) {
            return .discussionExport
        }
        if Self.unambiguousDiscussionExportNames.contains(name) { return .discussionExport }
        return nil
    }

    /// The canonical Windows hive filenames, lowercased. NTUSER.DAT is per-user
    /// (desktop/Explorer activity); UsrClass.dat holds shell bags; the rest are
    /// machine-wide under %SystemRoot%\System32\config.
    nonisolated static let registryHiveNames: Set<String> = [
        "ntuser.dat", "usrclass.dat", "software", "system", "sam", "security",
        "default", "components", "bcd-template", "drivers", "elam"
    ]

    /// Directory markers that identify an export tree. Present in the paths the
    /// platforms themselves produce.
    nonisolated static let discussionExportPathMarkers: [String] = [
        "/takeout/", "/youtube and youtube music/", "/my activity/",
        "/messages/", "/discord/", "/reddit/", "/twitch/",
        "/your_instagram_activity/", "/your_facebook_activity/", "/live chats/", "/comments/"
    ]
    /// Generic names that are only a discussion export inside such a tree.
    nonisolated static let discussionExportNames: Set<String> = [
        "comments.csv", "live-chats.csv", "posts.csv", "messages.csv",
        "watch-history.json", "search-history.json", "messages.json",
        "my-comments.html", "my-live-chat-messages.html",
        // Reddit writes these at the export root; Discord writes messages.json /
        // messages.csv under messages/c<channel id>/.
        "statistics.csv", "chat_history.json"
    ]
    /// Names no other artifact uses, so path context is unnecessary.
    nonisolated static let unambiguousDiscussionExportNames: Set<String> = [
        "tweets.js", "direct-messages.js", "note-tweet.js"
    ]

    public nonisolated static func detect(from url: URL) -> SourceType {
        // Phase K path/filename patterns take priority over the extension.
        if let pattern = detectPathPattern(from: url) { return pattern }
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "doc": return .doc
        case "txt": return .txt
        case "md", "markdown": return .markdown
        case "rtf": return .rtf
        case "odt": return .odt
        case "epub": return .epub
        case "html", "htm", "xhtml": return .html
        case "json", "jsonl", "ndjson": return .json
        case "xml": return .xml
        case "plist": return .plist
        case "log": return .log
        case "sqlite", "sqlite3", "db": return .sqlite
        case "xlsx": return .xlsx
        case "xls": return .xls
        case "csv": return .csv
        case "ods": return .ods
        case "pptx": return .pptx
        case "ppt": return .ppt
        case "key": return .keynote
        case "mbox": return .mbox
        case "pst": return .pst
        case "eml": return .eml
        case "msg": return .msg
        case "emlx": return .appleMail
        case "nsf": return .nsf
        case "png": return .png
        case "jpg", "jpeg": return .jpg
        case "heic": return .heic
        case "tiff", "tif": return .tiff
        case "webp": return .webp
        case "mp3": return .mp3
        case "wav": return .wav
        case "m4a": return .m4a
        case "aac": return .aac
        case "aiff", "aif", "aifc": return .aiff
        case "caf": return .caf
        case "flac": return .flac
        case "3gp", "3gpp": return .threegp
        case "mp4": return .mp4
        case "mov": return .mov
        case "zip": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        default: return .unknown
        }
    }

    /// Content-based fallback for when the filename has no (or an unknown)
    /// extension — reads leading magic bytes. Used by the ingest path only when
    /// `detect(from:)` returns `.unknown` (e.g. an email attachment named as a
    /// bare hash). OLE2 (.doc/.xls/.ppt) is intentionally NOT sniffed here —
    /// magic bytes can't tell those apart without parsing the CFB directory, so
    /// we leave them to the MIME-type mapping rather than risk mis-routing.
    public nonisolated static func sniffMagicBytes(_ data: Data) -> SourceType? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return nil }
        func has(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        if has([0xFF, 0xD8, 0xFF]) { return .jpg }
        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if has([0x25, 0x50, 0x44, 0x46]) { return .pdf }                       // %PDF
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has([0x52, 0x49, 0x46, 0x46]), b.count >= 12,
           Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return .webp }        // RIFF....WEBP
        // USF-M2 — unambiguous archive signatures precede the ZIP check. An extensionless RAR/7z is
        // classified correctly even though USF-M2 cannot yet DECODE its contents (honest unsupported).
        if has([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }           // "Rar!\x1A\x07" (RAR4 + RAR5)
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }      // "7z\xBC\xAF\x27\x1C"
        // ZIP container (also docx/xlsx/pptx/odt/ods/epub). USF-M2 disambiguates the compound-container
        // subtype at intake via `zipSubtype(forDeclaredExtension:)` (magic stays the detection basis).
        if has([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        // "SQLite format 3\0" — a generic SQLite database (PAR-009).
        if has([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]) { return .sqlite }   // "SQLite"
        // HOST-1 — "bplist00": a binary property list. Host artifacts are routinely
        // extensionless or oddly named, so magic bytes are the reliable signal.
        if has([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) { return .plist }    // "bplist"
        // HOST-2 — "regf": a Windows registry hive, whatever the examiner named it.
        if has([0x72, 0x65, 0x67, 0x66]) { return .registryHive }         // "regf"
        return nil
    }

    /// USF-M2 §1 — compound-container disambiguation. A DOCX/XLSX/PPTX/ODT/ODS/EPUB is itself a ZIP,
    /// so `sniffMagicBytes` reports `.zip` for all of them. The declared extension selects the logical
    /// container SUBTYPE (it is NOT proof the package will parse — the parser still validates it).
    /// A `.zip`/unknown extension on ZIP magic stays `.zip`. Detection basis remains `.magicBytes`.
    public nonisolated static func zipSubtype(forDeclaredExtension ext: String) -> SourceType {
        switch ext.lowercased() {
        case "docx": return .docx
        case "xlsx": return .xlsx
        case "pptx": return .pptx
        case "odt":  return .odt
        case "ods":  return .ods
        case "epub": return .epub
        default:     return .zip
        }
    }

    public nonisolated var category: Category {
        switch self {
        case .pdf, .docx, .doc, .txt, .markdown, .rtf, .odt, .epub,
             .html, .json, .xml, .log, .sqlite, .plist, .custodyManifest: return .document
        case .registryHive, .knowledgeC: return .hostArtifact
        // People talking — the same ontological shape as a chat thread, which is
        // what FactTypeClassifier already treats as a conversation between people.
        case .discussionExport: return .chat
        case .xlsx, .xls, .csv, .ods: return .spreadsheet
        case .pptx, .ppt, .keynote: return .presentation
        case .mbox, .pst, .eml, .msg, .appleMail, .nsf: return .email
        case .png, .jpg, .heic, .tiff, .webp: return .image
        case .mp3, .wav, .m4a, .aac, .aiff, .caf, .flac, .threegp: return .audio
        case .mp4, .mov: return .video
        case .zip, .rar, .sevenZip: return .archive
        case .imessage, .chatExport: return .chat
        case .safariHistory, .chromeHistory: return .browserHistory
        case .unknown: return .unknown
        }
    }

    public enum Category: String, Codable, Sendable {
        case document, spreadsheet, presentation, email, image, audio, video,
             archive, chat, browserHistory, unknown
        /// HOST-* — machine/OS evidence rather than a document a person wrote:
        /// registry hives, event logs, filesystem metadata. Processed like a
        /// document (immediate, text + structure), but semantically it is a record
        /// OF the machine, which matters when attributing a fact to a person.
        case hostArtifact
    }
}

// MARK: - Attachable formats (user-initiated attach → ingest → answer)

public extension SourceType {
    /// The file extensions a user may ATTACH for on-demand ingest — every format
    /// the app extracts content from. Legacy-binary Office (.doc/.xls/.ppt) and
    /// Outlook mail (.msg/.pst) are INCLUDED (owner decision 2026-08-20): their
    /// loaders do extract real content, though the legacy-binary ones can be
    /// partial. Still excluded are the true no-read stubs — .nsf, .rar, .7z and
    /// Keynote (decoder pending) — and the path-pattern chat/browser DBs, which
    /// aren't hand-picked documents.
    nonisolated static let attachableExtensions: [String] = [
        // Documents (incl. legacy .doc — partial OLE2 extraction)
        "pdf", "docx", "doc", "txt", "md", "markdown", "rtf", "odt", "epub",
        "html", "htm", "xhtml", "json", "jsonl", "ndjson", "xml", "plist", "log",
        "sqlite", "sqlite3", "db",
        // Spreadsheets (incl. legacy .xls — partial OLE2 extraction)
        "xlsx", "xls", "csv", "ods",
        // Presentations (incl. legacy .ppt — partial; Keynote omitted, stub)
        "pptx", "ppt",
        // Email (incl. Outlook .msg / .pst)
        "mbox", "eml", "emlx", "msg", "pst",
        // Images
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "webp",
        // Audio
        "mp3", "wav", "m4a", "aac", "aiff", "aif", "aifc", "caf", "flac", "3gp", "3gpp",
        // Video
        "mp4", "mov",
        // Archives
        "zip",
    ]

    /// The attachable set as `UTType`s for SwiftUI `.fileImporter` /
    /// `NSOpenPanel.allowedContentTypes` (unknown extensions are dropped).
    nonisolated static var attachableContentTypes: [UTType] {
        attachableExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// One-line, human-readable summary of the supported formats for tooltips.
    nonisolated static let attachableSummary =
        "PDF, Word (.doc/.docx), Excel (.xls/.xlsx), CSV, PowerPoint (.ppt/.pptx), RTF, ODT, EPUB, HTML, JSON, XML, text & logs, SQLite, email (.mbox/.eml/.msg/.pst), images, audio and video."
}
