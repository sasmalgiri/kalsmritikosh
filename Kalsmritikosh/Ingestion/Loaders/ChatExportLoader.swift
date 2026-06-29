//
//  ChatExportLoader.swift
//  Kalsmritikosh
//
//  Phase K — handles structured text exports from chat apps where
//  direct DB access isn't possible (WhatsApp via "Export Chat",
//  Signal via the desktop export, Slack via workspace export → the
//  per-channel .txt files inside the ZIP).
//
//  Common WhatsApp format (one message per line, possibly multi-line
//  for replies):
//      [3/14/25, 9:12:34 AM] Alice: Did you sign the contract?
//      [3/14/25, 9:13:01 AM] Bob: Yes — uploaded.
//
//  Common Signal Desktop format:
//      2025-03-14 09:12:34 - Alice: Did you sign the contract?
//
//  Slack export format (TXT):
//      [2025-03-14, 09:12 AM] alice: Did you sign the contract?
//
//  We try the three regex shapes in order; the first that matches
//  the file's opening lines wins. Falls back to plain-text ingest
//  when none match (lets the user drop arbitrary chat-shaped logs
//  into the watcher and still get something useful).
//

import Foundation

public struct ChatExportLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.chatExport]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }
        let raw = String(decoding: data, as: UTF8.self)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestorError.empty(url)
        }
        // Try WhatsApp, then Signal, then Slack. Whichever matches
        // the most lines in the first 50 lines wins.
        let probeLines = raw.split(separator: "\n").prefix(50).map(String.init)
        let scoreWA = probeLines.filter { Self.whatsappRegex.firstMatch(in: $0) != nil }.count
        let scoreSignal = probeLines.filter { Self.signalRegex.firstMatch(in: $0) != nil }.count
        let scoreSlack = probeLines.filter { Self.slackRegex.firstMatch(in: $0) != nil }.count

        let (channel, normalized) = Self.bestParse(
            raw: raw,
            scores: (whatsapp: scoreWA, signal: scoreSignal, slack: scoreSlack)
        )
        let content = normalized.isEmpty ? raw : normalized
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "channel": AnyCodable(.string(channel)),
                "parser": AnyCodable(.string(channel.lowercased()))
            ]
        )
    }

    // MARK: - Format selection

    private static func bestParse(
        raw: String,
        scores: (whatsapp: Int, signal: Int, slack: Int)
    ) -> (channel: String, normalized: String) {
        // Need at least 3 matches in the first 50 lines to commit
        // to a format. Otherwise we fall back to "ChatExport" with
        // the raw content so the chunker still indexes it.
        let max = Swift.max(scores.whatsapp, scores.signal, scores.slack)
        guard max >= 3 else {
            return ("ChatExport", raw)
        }
        if scores.whatsapp == max {
            return ("WhatsApp", normalize(raw, regex: whatsappRegex,
                                         template: "[$1] $2: $3"))
        }
        if scores.signal == max {
            return ("Signal", normalize(raw, regex: signalRegex,
                                       template: "[$1] $2: $3"))
        }
        return ("Slack", normalize(raw, regex: slackRegex,
                                   template: "[$1] $2: $3"))
    }

    /// Normalize each line to `[timestamp] sender: body`. Lines
    /// that don't match get attached to the prior message (chat
    /// apps commonly split multi-line messages with internal `\n`).
    private static func normalize(_ raw: String, regex: NSRegularExpression, template: String) -> String {
        var out: [String] = []
        var pending: String? = nil
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            if regex.firstMatch(in: s, options: [], range: range) != nil {
                if let pend = pending { out.append(pend) }
                let normalized = regex.stringByReplacingMatches(
                    in: s, options: [], range: range, withTemplate: template
                )
                pending = normalized
            } else {
                pending = (pending ?? "") + "\n" + s
            }
        }
        if let pend = pending { out.append(pend) }
        return out.joined(separator: "\n")
    }

    // MARK: - Regex shapes

    /// WhatsApp: `[3/14/25, 9:12:34 AM] Alice: body`
    nonisolated static let whatsappRegex: NSRegularExpression = {
        let pattern = #"^\[(\d{1,2}/\d{1,2}/\d{2,4},\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:[AaPp][Mm])?)\]\s*([^:]+?):\s*(.*)$"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Signal Desktop: `2025-03-14 09:12:34 - Alice: body`
    nonisolated static let signalRegex: NSRegularExpression = {
        let pattern = #"^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)\s*-\s*([^:]+?):\s*(.*)$"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Slack TXT export: `[2025-03-14, 09:12 AM] alice: body`
    nonisolated static let slackRegex: NSRegularExpression = {
        let pattern = #"^\[(\d{4}-\d{2}-\d{2},?\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:[AaPp][Mm])?)\]\s*([^:]+?):\s*(.*)$"#
        return try! NSRegularExpression(pattern: pattern)
    }()
}

private extension NSRegularExpression {
    func firstMatch(in s: String) -> NSTextCheckingResult? {
        firstMatch(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s))
    }
}
