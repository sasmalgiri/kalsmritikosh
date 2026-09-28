//
//  IMessageLoader.swift
//  Kalsmritikosh
//
//  Phase K — reads macOS Messages (~/Library/Messages/chat.db) and
//  emits one KnowledgeObject per conversation, with full message
//  text concatenated chronologically. Downstream entity / event /
//  causal extraction then runs as if the conversation were an email
//  thread.
//
//  Requires Full Disk Access in System Settings → Privacy &
//  Security. When the user grants it, the system can reconstruct
//  the iMessage slice of personal history that no other Mac-native
//  product touches.
//
//  Apple date handling: Messages stores dates as nanoseconds since
//  the macOS Mach epoch (2001-01-01). We convert to UNIX time on
//  read; everything downstream then handles event.date as Date()
//  in the usual way.
//
//  MESSAGE TEXT — FIXED SILENT DATA LOSS. From macOS Ventura / iOS 16
//  onward Messages often leaves `message.text` NULL and puts the body in
//  `message.attributedBody`, a legacy typedstream archive. This reader used
//  to filter `WHERE message.text IS NOT NULL`, so those messages were not
//  rendered badly — they were DROPPED, with nothing saying so. A modern
//  conversation could arrive nearly empty and look complete.
//
//  Now: every message row is read. Text comes from `message.text` when
//  present, else from `attributedBody` via AttributedBodyText, and when
//  NEITHER yields text the message is STILL emitted with its timestamp,
//  sender and direction plus a stated note. A message never vanishes, and
//  the recovery counts are recorded in the object's metadata so a thin
//  conversation can be told apart from a quiet one.
//

import Foundation

public struct IMessageLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.imessage]

    /// Maximum messages to ingest per conversation. Caps the KO
    /// content size so a 10-year power-user iMessage thread stays
    /// in the chunker's sweet spot; older messages still land via
    /// per-conversation thread splits when chronological cuts apply
    /// later.
    public static let maxMessagesPerConversation: Int = 5_000

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let src: ExternalSQLiteSource
        do {
            src = try ExternalSQLiteSource(originalPath: url)
        } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }
        // Pull every message joined with its conversation handle and
        // chat (chat_id is the conversation; handle is the
        // counterparty). Ordered by date so the rendered transcript
        // reads top-to-bottom oldest → newest.
        //
        // Apple's `message.date` is nanoseconds since 2001-01-01.
        // `message.is_from_me = 1` means the local user sent it.
        // NO `WHERE message.text IS NOT NULL` filter: that is what dropped
        // every modern message. Rows with neither text nor a decodable body are
        // reported, not skipped.
        func sql(includeAttributedBody: Bool) -> String {
            """
            SELECT
                chat.guid AS chat_guid,
                chat.display_name AS chat_display,
                handle.id AS counterparty,
                message.text AS body,
                message.date AS apple_date,
                message.is_from_me AS from_me,
                \(includeAttributedBody ? "message.attributedBody" : "NULL") AS attributed_body
            FROM message
            LEFT JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
            LEFT JOIN chat ON chat.ROWID = chat_message_join.chat_id
            LEFT JOIN handle ON handle.ROWID = message.handle_id
            ORDER BY chat.ROWID, message.date ASC;
            """
        }
        // `attributedBody` does not exist in older chat.db schemas, where
        // selecting it would fail the whole query and take the entire iMessage
        // lane down with it. Try the modern shape, fall back to the legacy one.
        let rows: [ExternalSQLiteSource.Row]
        var readsAttributedBody = true
        do {
            rows = try src.query(sql(includeAttributedBody: true))
        } catch {
            readsAttributedBody = false
            do {
                rows = try src.query(sql(includeAttributedBody: false))
            } catch {
                throw IngestorError.unreadable(url, underlying: error)
            }
        }
        guard !rows.isEmpty else {
            throw IngestorError.empty(url)
        }

        // Group by chat_guid; render each conversation as a single
        // transcript. We then concatenate transcripts in the KO's
        // content with `=== <conversation> ===` separators so the
        // chunker boundaries land on conversation breaks.
        var conversations: [(label: String, text: String)] = []
        // Counted so a conversation that reads thin can be told apart from one
        // that genuinely was.
        var recoveredFromAttributedBody = 0
        var unrecoverableText = 0
        var current: (label: String, parts: [String])? = nil
        var messageCount = 0
        for row in rows {
            let chatGuid = row.string(0) ?? "unknown"
            let chatDisplay = row.string(1)?.trimmingCharacters(in: .whitespaces) ?? ""
            let counterparty = row.string(2) ?? "unknown"
            let plainText = row.string(3)
            let recovered = Self.messageText(plainText: plainText,
                                             attributedBody: row.data(6))
            switch recovered.origin {
            case .plainText: break
            case .attributedBody: recoveredFromAttributedBody += 1
            case .unrecoverable: unrecoverableText += 1
            }
            let body = recovered.text
            let appleDate = row.int(4) ?? 0
            let fromMe = (row.int(5) ?? 0) != 0
            let label: String = chatDisplay.isEmpty
                ? "\(chatGuid) [\(counterparty)]"
                : "\(chatDisplay) [\(chatGuid)]"
            if current?.label != label {
                if let cur = current {
                    conversations.append((cur.label, cur.parts.joined(separator: "\n")))
                }
                current = (label, [])
                messageCount = 0
            }
            if messageCount >= Self.maxMessagesPerConversation {
                continue
            }
            let date = Self.dateFromAppleNanoseconds(Int64(appleDate))
            let stamp = Self.timestampFormatter.string(from: date)
            let sender = fromMe ? "me" : counterparty
            current?.parts.append("[\(stamp)] \(sender): \(body)")
            messageCount += 1
        }
        if let cur = current {
            conversations.append((cur.label, cur.parts.joined(separator: "\n")))
        }
        let content = conversations.map { conv in
            "=== \(conv.label) ===\n\(conv.text)"
        }.joined(separator: "\n\n")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestorError.empty(url)
        }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "channel": AnyCodable(.string("iMessage")),
                "conversation_count": AnyCodable(.int(Int64(conversations.count))),
                "message_count": AnyCodable(.int(Int64(rows.count))),
                // Visible accounting, so "few messages" and "few messages READ"
                // are never the same-looking result.
                "text_recovered_from_attributed_body": AnyCodable(.int(Int64(recoveredFromAttributedBody))),
                "text_unrecoverable": AnyCodable(.int(Int64(unrecoverableText))),
                "reads_attributed_body": AnyCodable(.bool(readsAttributedBody))
            ]
        )
    }

    // MARK: - Message text

    enum TextOrigin: Sendable, Equatable {
        case plainText
        case attributedBody
        /// Neither column yielded text. The message is still emitted.
        case unrecoverable
    }

    /// Text for one message row, and where it came from.
    ///
    /// The order matters: `message.text` is Apple's own plain copy and is
    /// preferred whenever it exists, so the archive decoder is only ever a
    /// fallback for rows Apple left empty.
    nonisolated static func messageText(plainText: String?, attributedBody: Data?)
    -> (text: String, origin: TextOrigin) {
        if let plainText, !plainText.trimmingCharacters(in: .whitespaces).isEmpty {
            return (plainText, .plainText)
        }
        if let attributedBody, let recovered = AttributedBodyText.decode(attributedBody),
           !recovered.text.trimmingCharacters(in: .whitespaces).isEmpty {
            return (recovered.text, .attributedBody)
        }
        // The message existed, was sent at a time, by someone, in a direction.
        // Saying so is evidence; dropping the row is not.
        return ("[message text not recoverable from this database]", .unrecoverable)
    }

    // MARK: - Helpers

    /// macOS Messages stores message dates as nanoseconds since
    /// the macOS Mach epoch (2001-01-01 00:00:00 UTC). Older
    /// versions used seconds; we detect by magnitude. Apple's
    /// reference: `kCFAbsoluteTimeIntervalSince1970 == 978307200`.
    static func dateFromAppleNanoseconds(_ raw: Int64) -> Date {
        let appleEpoch: TimeInterval = 978_307_200
        // Modern column is nanoseconds; legacy is seconds. Threshold
        // 1e12 separates them safely.
        let seconds: TimeInterval = raw > 1_000_000_000_000
            ? Double(raw) / 1_000_000_000.0
            : Double(raw)
        return Date(timeIntervalSince1970: appleEpoch + seconds)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
