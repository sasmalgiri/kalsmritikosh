//
//  IOSBackupManifest.swift
//  Kalsmritikosh
//
//  HOST-8b — reads an iOS backup's `Manifest.db`, the file that makes the rest of
//  the backup meaningful.
//
//  An iTunes/Finder backup stores every file under a SHA-1 name in a two-hex-char
//  subdirectory: `3d/3d0d7e5fb2ce288813306e4d4636395e047a3d28`. Nothing on disk
//  says what that is. Manifest.db's `Files` table maps each hash to its DOMAIN
//  and RELATIVE PATH — so that hash is `HomeDomain/Library/SMS/sms.db`, the
//  message store. Without this mapping an extraction is 40 000 anonymous blobs;
//  with it, it is a filesystem.
//
//      CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT,
//                          relativePath TEXT, flags INTEGER, file BLOB)
//
//  `flags`: 1 = file, 2 = directory, 4 = symlink. The `file` blob is an
//  NSKeyedArchiver plist holding size, mtime and permissions; it is decoded
//  best-effort, and when it cannot be read the size is taken from the actual file
//  on disk rather than guessed.
//
//  Read-only on a private copy. Only Manifest.db is read here — nothing in this
//  file opens the backup's content files.
//

import Foundation

public struct IOSBackupManifest: Sendable {

    public enum EntryKind: String, Sendable {
        case file, directory, symlink, unknown

        nonisolated static func from(flags: Int64?) -> EntryKind {
            switch flags {
            case 1: return .file
            case 2: return .directory
            case 4: return .symlink
            default: return .unknown
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        /// SHA-1 name the file is stored under, and the on-disk filename.
        public let fileID: String
        public let domain: String
        public let relativePath: String
        public let kind: EntryKind
        public let size: Int64?
        public let modified: Date?

        /// The path this file HAD on the device — the only form a human or a
        /// query can use. `HomeDomain/Library/SMS/sms.db`.
        public nonisolated var virtualPath: String {
            relativePath.isEmpty ? domain : "\(domain)/\(relativePath)"
        }

        /// Where the bytes actually sit inside the backup folder:
        /// the first two hex characters of the id, then the id.
        public nonisolated var storedRelativePath: String? {
            guard kind == .file, fileID.count >= 2 else { return nil }
            return "\(fileID.prefix(2))/\(fileID)"
        }

        /// The app or system area this belongs to, which is how an examiner scopes
        /// a search: `AppDomain-net.whatsapp.WhatsApp` → `net.whatsapp.WhatsApp`.
        public nonisolated var appBundleID: String? {
            for prefix in ["AppDomain-", "AppDomainGroup-", "AppDomainPlugin-", "SysContainerDomain-"] {
                if domain.hasPrefix(prefix) { return String(domain.dropFirst(prefix.count)) }
            }
            return nil
        }
    }

    public enum ManifestError: Error, Sendable {
        case notAManifest
        case unreadable(String)
    }

    public let entries: [Entry]
    /// Non-fatal problems, surfaced as parser warnings.
    public let problems: [String]

    /// Entry ceiling. A full backup holds hundreds of thousands of rows; the
    /// inventory is a citation surface, so it stops at a stated number.
    public nonisolated static let entryCap = 200_000

    // MARK: - Reading

    /// Reads a Manifest.db given its bytes. `bundleRoot`, when supplied, is used
    /// ONLY to stat a file whose metadata blob would not decode — never to read
    /// any file's content.
    public nonisolated init(manifestData: Data, bundleRoot: URL? = nil) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-iosmanifest-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try manifestData.write(to: tmp, options: .atomic) }
        catch { throw ManifestError.unreadable("\(error)") }

        let db: ExternalSQLiteSource
        do { db = try ExternalSQLiteSource(originalPath: tmp) }
        catch { throw ManifestError.unreadable("\(error)") }

        let hasFiles = ((try? db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='Files';")) ?? [])
            .isEmpty == false
        guard hasFiles else { throw ManifestError.notAManifest }

        var problems: [String] = []
        var entries: [Entry] = []
        let rows = (try? db.query("""
            SELECT fileID, domain, relativePath, flags, file FROM Files
            ORDER BY domain, relativePath LIMIT \(Self.entryCap);
            """)) ?? []

        for row in rows {
            guard row.cells.count >= 4,
                  let fileID = row.cells[0].string,
                  let domain = row.cells[1].string else { continue }
            let relativePath = row.cells[2].string ?? ""
            let kind = EntryKind.from(flags: row.cells[3].int64)

            var size: Int64?
            var modified: Date?
            if row.cells.count >= 5, let blob = row.cells[4].data {
                let decoded = Self.decodeMetadata(blob)
                size = decoded.size
                modified = decoded.modified
            }
            // A file whose metadata blob would not decode still has bytes on
            // disk; measuring them beats reporting an unknown size.
            if size == nil, kind == .file, let bundleRoot,
               let stored = Entry(fileID: fileID, domain: domain, relativePath: relativePath,
                                  kind: kind, size: nil, modified: nil).storedRelativePath {
                let onDisk = bundleRoot.appendingPathComponent(stored)
                if let attributes = try? FileManager.default
                    .attributesOfItem(atPath: onDisk.path) {
                    size = (attributes[.size] as? NSNumber)?.int64Value
                    modified = modified ?? (attributes[.modificationDate] as? Date)
                }
            }

            entries.append(Entry(fileID: fileID, domain: domain, relativePath: relativePath,
                                 kind: kind, size: size, modified: modified))
        }

        if rows.count >= Self.entryCap {
            problems.append("Stopped after \(Self.entryCap) manifest entries; later files are "
                            + "not individually listed.")
        }
        if entries.isEmpty {
            problems.append("Manifest has a Files table but no readable rows.")
        }
        let undecodable = entries.filter { $0.kind == .file && $0.size == nil }.count
        if undecodable > 0 {
            problems.append("\(undecodable) file(s) had an unreadable metadata blob and no "
                            + "measurable bytes; their size and modification time are unknown.")
        }

        self.entries = entries
        self.problems = problems
    }

    // MARK: - Resolution

    /// The on-disk URL for a device path, e.g.
    /// `HomeDomain/Library/SMS/sms.db` → `<root>/3d/3d0d7e…`. Nil when the backup
    /// does not contain that path, or when it is a directory rather than a file.
    public nonisolated func actualURL(forVirtualPath path: String, in bundleRoot: URL) -> URL? {
        guard let entry = entries.first(where: { $0.virtualPath == path }),
              let stored = entry.storedRelativePath else { return nil }
        return bundleRoot.appendingPathComponent(stored)
    }

    /// Every entry within a domain — how an examiner scopes to one app.
    public nonisolated func entries(inDomain domain: String) -> [Entry] {
        entries.filter { $0.domain == domain }
    }

    /// Domains present, with a count each, most files first. This is the shape of
    /// the extraction: which apps and system areas it actually covers.
    public nonisolated var domainCounts: [(domain: String, count: Int)] {
        Dictionary(grouping: entries, by: \.domain)
            .map { (domain: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.domain < $1.domain }
    }

    public nonisolated var fileCount: Int { entries.filter { $0.kind == .file }.count }

    // MARK: - Metadata blob

    /// Best-effort read of the NSKeyedArchiver plist in `Files.file`. The archive
    /// stores an MBFile object whose Size and LastModified we want; rather than
    /// reimplementing keyed unarchiving, this scans `$objects` for the dictionary
    /// carrying those keys and resolves one level of UID reference. Returns nils
    /// when the shape is not recognized — never a guessed size.
    nonisolated static func decodeMetadata(_ blob: Data) -> (size: Int64?, modified: Date?) {
        guard let plist = try? PropertyListSerialization
                .propertyList(from: blob, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return (nil, nil) }

        func resolve(_ value: Any?) -> Any? {
            // A keyed archive stores references as CFKeyedArchiverUID, which
            // bridges to an integer index into $objects.
            if let index = (value as? NSNumber)?.intValue,
               value is NSNumber, index >= 0, index < objects.count,
               !(value is NSString) {
                return objects[index]
            }
            return value
        }

        for object in objects {
            guard let dictionary = object as? [String: Any],
                  dictionary["Size"] != nil else { continue }

            var size: Int64?
            if let direct = dictionary["Size"] as? NSNumber { size = direct.int64Value }
            // An unrealistically small "size" is a UID reference, not a size.
            if let candidate = size, candidate < objects.count,
               let referenced = resolve(dictionary["Size"]) as? NSNumber,
               referenced.int64Value != candidate {
                size = referenced.int64Value
            }

            var modified: Date?
            if let seconds = (dictionary["LastModified"] as? NSNumber)?.doubleValue,
               seconds > 0 {
                // MBFile timestamps are UNIX seconds, unlike most Apple stores.
                modified = Date(timeIntervalSince1970: seconds)
            }
            return (size, modified)
        }
        return (nil, nil)
    }

    /// The manifest filename, lowercased. `Manifest.mbdb` (iOS 9 and earlier) is
    /// deliberately NOT claimed: it is a different, non-SQLite format, and
    /// treating it as one would report a readable backup as corrupt.
    public nonisolated static let manifestName = "manifest.db"
}
