//
//  ReferenceShelfReader.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-17 (owner 2026-11-22) — not tested yet.
//
//  Reads a reference-shelf folder (acts, rules, manuals the person adds) into the shelf's own tables.
//  It uses the same loaders as ingestion to get the text, but writes NOTHING to the archive ledger:
//  no knowledge objects, chunks, entities, events, facts or embeddings — only shelf documents and
//  passages (ReferenceShelfRepository). So a reference document can never be counted as evidence,
//  enter a case's scope, or feed a story. Only document-shaped files are taken (documents,
//  spreadsheets, presentations); an unchanged file (same content hash) is not read again; a file that
//  cannot be read is recorded as unreadable with the reason, never skipped silently.
//

import Foundation
import CryptoKit
import os

public nonisolated struct ReferenceShelfReader: Sendable {

    public struct Report: Sendable {
        public var read = 0
        public var unchanged = 0
        public var unreadable = 0
        public var skippedNotDocuments = 0
        public var stoppedAtLimit = false
    }

    public static let fileLimit = 2_000
    public static let passageCharacters = 1_200

    private let registry: LoaderRegistry
    private let repository: ReferenceShelfRepository

    public init(registry: LoaderRegistry, repository: ReferenceShelfRepository) {
        self.registry = registry
        self.repository = repository
    }

    public func read(folderID: UUID, folderURL: URL) async -> Report {
        var report = Report()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            KalsmritikoshLog.ingestion.error("Reference shelf: the folder could not be opened")
            return report
        }
        var files: [URL] = []
        while let next = walker.nextObject() as? URL {
            guard (try? next.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            if files.count >= Self.fileLimit { report.stoppedAtLimit = true; break }
            files.append(next)
        }
        for url in files {
            let type = SourceType.detect(from: url)
            switch type.category {
            case .document, .spreadsheet, .presentation: break
            default: report.skippedNotDocuments += 1; continue
            }
            let path = url.path
            let title = url.deletingPathExtension().lastPathComponent
            do {
                let ko = try await registry.loader(for: type).ingest(fileAt: url, type: type)
                let text = ko.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                if try await repository.contentHash(folderID: folderID, path: path) == hash {
                    report.unchanged += 1; continue
                }
                guard !text.isEmpty else {
                    try await repository.putDocument(folderID: folderID, path: path, title: title, contentHash: hash,
                                                     status: "unreadable", detail: "No text could be read from this file.", passages: [])
                    report.unreadable += 1; continue
                }
                try await repository.putDocument(folderID: folderID, path: path, title: title, contentHash: hash,
                                                 status: "read", detail: nil, passages: Self.passages(of: text))
                report.read += 1
            } catch {
                KalsmritikoshLog.ingestion.error("Reference shelf: a file could not be read: \(String(describing: error), privacy: .public)")
                do {
                    try await repository.putDocument(folderID: folderID, path: path, title: title, contentHash: "unreadable",
                                                     status: "unreadable", detail: "This file could not be read.", passages: [])
                } catch {
                    KalsmritikoshLog.storage.error("Reference shelf: could not record an unreadable file: \(String(describing: error), privacy: .public)")
                }
                report.unreadable += 1
            }
        }
        return report
    }

    /// Paragraph-respecting passages of about `passageCharacters`, each with the nearest heading-like
    /// line above it ("Section 12", "Rule 4 — Notice", "CHAPTER III") as its section label.
    static func passages(of text: String) -> [(section: String?, text: String)] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [(String?, String)] = []
        var current = ""
        var section: String?
        var currentSection: String?
        for p in paragraphs {
            if isHeading(p) { section = String(p.prefix(80)) }
            if current.isEmpty { currentSection = section }
            if !current.isEmpty, current.count + p.count > passageCharacters {
                out.append((currentSection, current))
                current = ""
                currentSection = section
            }
            current += (current.isEmpty ? "" : "\n\n") + p
            while current.count > passageCharacters * 2 {
                let head = String(current.prefix(passageCharacters))
                out.append((currentSection, head))
                current = String(current.dropFirst(passageCharacters))
            }
        }
        if !current.isEmpty { out.append((currentSection, current)) }
        return out.map { (section: $0.0, text: $0.1) }
    }

    static func isHeading(_ p: String) -> Bool {
        guard p.count <= 80, !p.contains("\n") else { return false }
        let lower = p.lowercased()
        let starts = ["section ", "rule ", "article ", "chapter ", "part ", "schedule ", "clause ", "regulation "]
        if starts.contains(where: { lower.hasPrefix($0) }) { return true }
        let letters = p.filter(\.isLetter)
        return letters.count >= 4 && letters.allSatisfy(\.isUppercase)
    }
}
