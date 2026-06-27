//
//  GGUFRegistry.swift
//  Kalsmritikosh
//
//  Persisted list of user-picked .gguf files. The user adds a model
//  via SwiftUI's `.fileImporter` in SettingsView; the entry stored
//  here lets AppState register a LlamaCppProvider for it at next
//  boot WITHOUT re-prompting.
//
//  Stored as a JSON file under
//    ~/Library/Application Support/Kalsmritikosh/gguf-models.json
//  to survive app updates. Each entry remembers the URL, a friendly
//  name, the parsed metadata (context_length, family) and the file
//  size.
//

import Foundation
import OSLog

public actor GGUFRegistry {

    public struct Entry: Codable, Sendable, Equatable {
        public let id: String           // stable id for ModelManifest
        public let displayName: String
        public let filePath: String     // resolved absolute path
        public let sizeBytes: Int64
        public let contextWindow: Int
        public let family: String?
        public let tier: ModelManifest.Tier

        public init(
            id: String,
            displayName: String,
            filePath: String,
            sizeBytes: Int64,
            contextWindow: Int,
            family: String?,
            tier: ModelManifest.Tier
        ) {
            self.id = id
            self.displayName = displayName
            self.filePath = filePath
            self.sizeBytes = sizeBytes
            self.contextWindow = contextWindow
            self.family = family
            self.tier = tier
        }

        public var estimatedRAMBytes: Int64 {
            Int64(Double(sizeBytes) * 1.5)
        }

        public var fileURL: URL { URL(fileURLWithPath: filePath) }
    }

    private let storeURL: URL
    private var entries: [Entry] = []

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = appSupport.appendingPathComponent("Kalsmritikosh", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("gguf-models.json", isDirectory: false)
        }
    }

    public func load() async -> [Entry] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        entries = decoded
        return entries
    }

    public func all() -> [Entry] { entries }

    /// Register a new .gguf file picked by the user via fileImporter.
    /// Reads its header to extract context_length + family when
    /// possible, persists the entry, and returns it.
    public func add(fileURL: URL, friendlyName: String? = nil) async throws -> Entry {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "GGUFRegistry", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "File not found: \(fileURL.path)"])
        }
        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let parsed = GGUFHeader.parse(at: fileURL)
        let baseName = friendlyName ?? fileURL.deletingPathExtension().lastPathComponent
        let tier: ModelManifest.Tier = {
            switch size {
            case ..<(2 * 1_073_741_824): return .small
            case ..<(10 * 1_073_741_824): return .medium
            default: return .large
            }
        }()
        let entry = Entry(
            id: "provider.local.gguf.\(baseName.replacingOccurrences(of: " ", with: "_"))",
            displayName: "GGUF \(baseName)",
            filePath: fileURL.path,
            sizeBytes: size,
            contextWindow: parsed?.contextLength ?? 4_096,
            family: parsed?.family,
            tier: tier
        )
        if let i = entries.firstIndex(where: { $0.filePath == entry.filePath }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        try persist()
        return entry
    }

    public func remove(id: String) async {
        entries.removeAll { $0.id == id }
        try? persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: storeURL, options: .atomic)
    }
}

/// Minimal GGUF v3 header parser. Reads enough of the metadata
/// to surface (a) the model's family / architecture and (b) its
/// context window. Returns nil when the file isn't a GGUF, the
/// header is malformed, or the fields aren't present. This is a
/// best-effort parse — when nil, the registry falls back to a
/// safe default context window.
public enum GGUFHeader {
    public struct Info: Sendable, Equatable {
        public let contextLength: Int?
        public let family: String?
    }

    public static func parse(at url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read first 16 MB — should be plenty for the metadata block.
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 16 * 1_048_576) ?? Data()
        } catch {
            return nil
        }
        guard prefix.count >= 4 else { return nil }
        // GGUF magic: 'G','G','U','F'
        let magic = String(bytes: prefix.prefix(4), encoding: .ascii)
        guard magic == "GGUF" else { return nil }
        // Walk the metadata in a relaxed way — we just scan for known
        // key strings and pull the following uint32. A full parser
        // would respect the typed-value layout; this best-effort
        // scan is enough to extract context_length and architecture.
        let bytes = [UInt8](prefix)
        var contextLength: Int? = nil
        var family: String? = nil
        if let arch = findStringValue(after: "general.architecture", in: bytes) {
            family = arch
        }
        if let ctx = findIntValue(after: "context_length", in: bytes) {
            contextLength = ctx
        }
        return Info(contextLength: contextLength, family: family)
    }

    /// Find the next string value following the named key. Strings
    /// in GGUF are length-prefixed (uint64 le); the scan reads the
    /// length, then that many ASCII bytes.
    private static func findStringValue(after key: String, in bytes: [UInt8]) -> String? {
        guard let range = bytes.firstRange(of: Array(key.utf8)) else { return nil }
        let cursor = range.upperBound + 1 // skip type byte that follows the key
        guard cursor + 8 <= bytes.count else { return nil }
        let lenBytes = bytes[cursor..<(cursor + 8)]
        let len = lenBytes.withUnsafeBufferPointer { ptr -> UInt64 in
            ptr.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: 1) { $0.pointee }
        }
        let strStart = cursor + 8
        let strEnd = strStart + Int(len)
        guard strEnd <= bytes.count, len < 1024 else { return nil }
        return String(bytes: bytes[strStart..<strEnd], encoding: .utf8)
    }

    private static func findIntValue(after key: String, in bytes: [UInt8]) -> Int? {
        guard let range = bytes.firstRange(of: Array(key.utf8)) else { return nil }
        // Look for a uint32 value within the next 32 bytes after the key.
        let cursor = range.upperBound
        let end = min(cursor + 32, bytes.count)
        for i in cursor..<(end - 4) {
            let n = bytes[i..<(i + 4)].withUnsafeBufferPointer { ptr -> UInt32 in
                ptr.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            }
            // Real context windows fall in the (256, 1_048_576) range.
            // Use that as a smell test so we don't return type bytes.
            if n >= 256 && n <= 1_048_576 {
                return Int(n)
            }
        }
        return nil
    }
}

private extension Array where Element == UInt8 {
    /// Linear search for a needle byte sequence. Returns the first
    /// range or nil. Naive — fine for ≤ 16 MB header scans.
    func firstRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        outer: for i in 0...(count - needle.count) {
            for j in 0..<needle.count where self[i + j] != needle[j] {
                continue outer
            }
            return i..<(i + needle.count)
        }
        return nil
    }
}
