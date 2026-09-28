//
//  AmcacheReader.swift
//  Kalsmritikosh
//
//  HOST-6c — Amcache (`Amcache.hve`): Windows's inventory of the executables
//  that have been PRESENT on the machine.
//
//  Amcache is a registry hive, so HOST-2's `RegistryHiveReader` already reads
//  its bytes exactly. What this adds is the schema: which keys mean what. The
//  prize is `InventoryApplicationFile`, whose entries carry the executable's
//  full path, publisher, product, size, PE link date — and its **SHA-1**. That
//  hash is what lets a binary be matched against a hash set, or identified as a
//  known tool, even after the file itself has been deleted.
//
//  THE MISCONCEPTION THIS READER REFUSES TO ENABLE: an Amcache entry is NOT
//  evidence of execution. `InventoryApplicationFile` is populated by a scheduled
//  inventory task that walks the filesystem, so an entry proves the file EXISTED
//  at a path at some point — nothing more. Treating Amcache as a "programs that
//  ran" list is a well-known and consequential error, and the parser states the
//  distinction in the evidence rather than leaving a reader to assume the
//  stronger claim.
//
//  The LEGACY numbered schema (Windows 8/8.1: `Root\File\{volume}\<ref>` with
//  values named `0`, `15`, `101`, `17` …) is deliberately NOT mapped. The
//  field meanings there are community-derived rather than documented, and
//  labelling a value "SHA-1" or "compile time" on that basis would present a
//  guess in the same shape as a fact. Those keys are counted and reported as
//  present-but-uninterpreted instead.
//

import Foundation

public struct AmcacheReader: Sendable {

    /// One executable Windows recorded as having been present.
    public struct FileEntry: Sendable, Equatable {
        public let keyPath: String
        /// When the registry key was last written — the closest thing this
        /// artifact has to a time, and a property of the RECORD, not the file.
        public let keyLastWritten: Date?
        public let path: String?
        public let name: String?
        public let publisher: String?
        public let productName: String?
        public let version: String?
        /// SHA-1 of the executable, recovered from `FileId` only when it really
        /// is a 40-character hex digest behind the format's `0000` prefix.
        public let sha1: String?
        public let sizeBytes: String?
        /// The PE header's link (compile) date, as Amcache recorded it.
        public let linkDate: String?
        public let programID: String?
        public let binaryType: String?
        public let isOSComponent: Bool?

        /// An entry with neither a path nor a hash identifies nothing.
        public var identifiesAFile: Bool { path != nil || sha1 != nil || name != nil }
    }

    /// One installed application, as distinct from one file on disk.
    public struct ProgramEntry: Sendable, Equatable {
        public let keyPath: String
        public let keyLastWritten: Date?
        public let programID: String?
        public let name: String?
        public let publisher: String?
        public let version: String?
        public let installDate: String?
        public let rootDirectory: String?
        public let source: String?
    }

    public let files: [FileEntry]
    public let programs: [ProgramEntry]
    /// Keys under the legacy numbered schema: present, counted, not interpreted.
    public let legacyFileKeyCount: Int
    public let hiveLastWritten: Date?
    public private(set) var problems: [String] = []

    nonisolated static let fileKeyMarker = #"\inventoryapplicationfile"#
    nonisolated static let programKeyMarker = #"\inventoryapplication"#
    nonisolated static let legacyKeyMarker = #"\file\{"#

    /// Build from an already-read hive. Keeping the registry reading in ONE
    /// place means Amcache inherits its safety properties — freed cells are not
    /// followed, cycles are refused, the key ceiling applies — rather than
    /// re-implementing them.
    public init(keys: [RegistryHiveReader.Key], hiveLastWritten: Date?) {
        self.hiveLastWritten = hiveLastWritten
        var files: [FileEntry] = []
        var programs: [ProgramEntry] = []
        var legacy = 0

        for key in keys {
            let lowered = key.path.lowercased()
            if lowered.contains(Self.fileKeyMarker) {
                // The marker key itself has no values; only its children do.
                guard !key.values.isEmpty else { continue }
                files.append(Self.fileEntry(key))
            } else if lowered.contains(Self.programKeyMarker) {
                guard !key.values.isEmpty else { continue }
                programs.append(Self.programEntry(key))
            } else if lowered.contains(Self.legacyKeyMarker), !key.values.isEmpty {
                legacy += 1
            }
        }

        self.files = files.filter(\.identifiesAFile)
        self.programs = programs
        self.legacyFileKeyCount = legacy
        if files.count != self.files.count {
            problems.append("\(files.count - self.files.count) inventory entr(y/ies) carried "
                            + "neither a path, a name nor a hash, so they identify no file and "
                            + "are not reported.")
        }
        if legacy > 0 {
            problems.append("\(legacy) key(s) use the legacy Windows 8 numbered Amcache schema "
                            + "(values named 0, 15, 101 …). Those field meanings are "
                            + "community-derived rather than documented, so they are reported as "
                            + "present but NOT interpreted: labelling one \"SHA-1\" on that basis "
                            + "would present a guess in the shape of a fact.")
        }
    }

    // MARK: - Mapping

    private nonisolated static func fileEntry(_ key: RegistryHiveReader.Key) -> FileEntry {
        func value(_ name: String) -> String? {
            guard let match = key.values.first(where: {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            }) else { return nil }
            let text = match.rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        func flag(_ name: String) -> Bool? {
            guard let raw = value(name) else { return nil }
            if raw == "1" || raw.lowercased() == "true" { return true }
            if raw == "0" || raw.lowercased() == "false" { return false }
            return nil
        }
        return FileEntry(
            keyPath: key.path,
            keyLastWritten: key.lastWritten,
            path: value("LowerCaseLongPath") ?? value("Path"),
            name: value("Name"),
            publisher: value("Publisher"),
            productName: value("ProductName"),
            version: value("Version") ?? value("ProductVersion"),
            sha1: sha1(fromFileID: value("FileId")),
            sizeBytes: value("Size"),
            linkDate: value("LinkDate"),
            programID: value("ProgramId"),
            binaryType: value("BinaryType"),
            isOSComponent: flag("IsOsComponent"))
    }

    private nonisolated static func programEntry(_ key: RegistryHiveReader.Key) -> ProgramEntry {
        func value(_ name: String) -> String? {
            guard let match = key.values.first(where: {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            }) else { return nil }
            let text = match.rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return ProgramEntry(
            keyPath: key.path,
            keyLastWritten: key.lastWritten,
            programID: value("ProgramId") ?? (key.name.isEmpty ? nil : key.name),
            name: value("Name"),
            publisher: value("Publisher"),
            version: value("Version"),
            installDate: value("InstallDate"),
            rootDirectory: value("RootDirPath"),
            source: value("Source"))
    }

    /// `FileId` is the SHA-1 behind a four-zero prefix. Both the prefix and a
    /// 40-character hex body are required: anything else is some other
    /// identifier, and calling it a SHA-1 would let an answer assert a hash that
    /// could be matched against a hash set and come back wrong.
    nonisolated static func sha1(fromFileID raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body: String
        if trimmed.count == 44, trimmed.hasPrefix("0000") {
            body = String(trimmed.dropFirst(4))
        } else if trimmed.count == 40 {
            body = trimmed
        } else {
            return nil
        }
        guard body.count == 40, body.allSatisfy({ $0.isHexDigit }) else { return nil }
        // An all-zero digest is a placeholder, not a hash of anything.
        guard body.contains(where: { $0 != "0" }) else { return nil }
        return body
    }
}
