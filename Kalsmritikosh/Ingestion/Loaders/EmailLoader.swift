//
//  EmailLoader.swift
//  Kalsmritikosh
//
//  EML (single message) is fully parsed. MBOX is split into messages
//  by "From " separator lines and emitted as a single concatenated
//  KnowledgeObject (each message later becomes its own KO once we
//  split the pipeline in M5).
//  PST / MSG / Apple Mail .emlx land in M5 — they require third-party
//  decoders or AppKit-level Mail.app access.
//

import Foundation

public struct EmailLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.eml, .mbox, .pst, .msg, .appleMail]

    public init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .eml:
            return try ingestEML(at: url)
        case .mbox:
            return try ingestMBOX(at: url)
        case .appleMail:
            return try ingestAppleEMLX(at: url)
        default:
            return try binaryStub(at: url, type: type)
        }
    }

    /// Apple Mail's `.emlx` is "<decimal byte length>\n<RFC822 message>\n
    /// <optional Apple plist trailer>". We peel the length prefix and the
    /// trailer, then delegate to the EML path.
    private func ingestAppleEMLX(at url: URL) throws -> KnowledgeObject {
        let raw: Data
        do { raw = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        // Scan up to the first newline for the byte-count prefix.
        guard let newlineIdx = raw.firstIndex(of: 0x0A) else {
            throw IngestorError.parseFailure(url, reason: "emlx: missing length prefix")
        }
        let prefix = raw[raw.startIndex..<newlineIdx]
        let prefixString = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let length = Int(prefixString), length > 0 else {
            throw IngestorError.parseFailure(url, reason: "emlx: invalid length prefix '\(prefixString)'")
        }
        let messageStart = raw.index(after: newlineIdx)
        let messageEnd = raw.index(messageStart, offsetBy: length, limitedBy: raw.endIndex) ?? raw.endIndex
        let messageData = raw[messageStart..<messageEnd]
        let messageString = String(decoding: messageData, as: UTF8.self)
        let (headers, body) = splitEMLHeaders(messageString)

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("emlx-apple-mail"))
        ]
        for (key, value) in headers { meta[key] = AnyCodable(.string(value)) }

        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? body
            : headerLines.joined(separator: "\n") + "\n\n" + body

        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .appleMail,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    private func ingestEML(at url: URL) throws -> KnowledgeObject {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // EMLs sometimes ship as latin1; fall back.
            do {
                raw = try String(contentsOf: url, encoding: .isoLatin1)
            } catch {
                throw IngestorError.unreadable(url, underlying: error)
            }
        }
        let (headers, body) = splitEMLHeaders(raw)
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("eml"))
        ]
        for (key, value) in headers {
            meta[key] = AnyCodable(.string(value))
        }
        // Prepend the human-relevant headers (From / To / Cc / Subject / Date)
        // so the entity extractor + summarizer see the participants and topic.
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        let merged = headerLines.isEmpty
            ? body
            : headerLines.joined(separator: "\n") + "\n\n" + body
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .eml,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    private func ingestMBOX(at url: URL) throws -> KnowledgeObject {
        let raw: String
        do { raw = try String(contentsOf: url, encoding: .utf8) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        var combined = ""
        var messageCount = 0
        for chunk in raw.components(separatedBy: "\nFrom ") {
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            messageCount += 1
            let (_, body) = splitEMLHeaders(chunk)
            combined.append(body)
            combined.append("\n\n---\n\n")
        }
        if combined.isEmpty { throw IngestorError.empty(url) }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .mbox,
            content: combined,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "messageCount": AnyCodable(.int(Int64(messageCount))),
                "loader": AnyCodable(.string("mbox"))
            ],
            confidence: .medium
        )
    }

    private func binaryStub(at url: URL, type: SourceType) throws -> KnowledgeObject {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: "Binary email archive; native parsing lands in a later milestone.",
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "binarySize": AnyCodable(.int(size)),
                "loaderStub": AnyCodable(.string("email-binary"))
            ],
            confidence: .low
        )
    }

    private func splitEMLHeaders(_ raw: String) -> ([String: String], String) {
        guard let blankLine = raw.range(of: "\n\n") else {
            return ([:], raw)
        }
        let headerBlock = String(raw[..<blankLine.lowerBound])
        let body = String(raw[blankLine.upperBound...])

        var headers: [String: String] = [:]
        var current: (String, String)?
        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                if let (k, v) = current {
                    current = (k, v + " " + line.trimmingCharacters(in: .whitespaces))
                }
            } else if let colon = line.firstIndex(of: ":") {
                if let (k, v) = current { headers[k] = v }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = (key, value)
            }
        }
        if let (k, v) = current { headers[k] = v }
        return (headers, body)
    }
}
