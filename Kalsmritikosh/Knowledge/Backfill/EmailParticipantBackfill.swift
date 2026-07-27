//
//  EmailParticipantBackfill.swift
//  Kalsmritikosh
//
//  OPS-005 — backfill email_participant_occurrences for email KOs that
//  were ingested before OPS-005 shipped. Idempotent and paginated:
//  KOs that already have at least one occurrence row are skipped.
//
//  Resolution strategy for old KOs (no seeds metadata):
//    1. Read from/to/cc/bcc/sender/reply-to header values from
//       knowledge_objects.metadata (stored as flat JSON keys by all
//       email loaders since T13).
//    2. Parse each with EmailAddressListParser.
//    3. Look up the canonical entity for each address via EntitiesRepository.
//    4. Write EmailParticipantOccurrence rows.
//
//  If an address has no canonical entity row (e.g. bcc addresses
//  ingested before OPS-005 added them to structuredEntities) the
//  seed is silently skipped — the occurrence ledger only references
//  canonicalised entities.
//

import Foundation
import OSLog

public actor EmailParticipantBackfill {
    private let occurrences: EmailParticipantRepository
    private let entities: EntitiesRepository
    private let database: Database

    public init(
        occurrences: EmailParticipantRepository,
        entities: EntitiesRepository,
        database: Database
    ) {
        self.occurrences = occurrences
        self.entities    = entities
        self.database    = database
    }

    /// Process up to `pageSize` un-backfilled email KOs.
    /// Returns the count of occurrence rows written.
    @discardableResult
    public func run(pageSize: Int = 500) async -> Int {
        let emailTypes: [String] = ["eml", "mbox", "appleMail", "msg", "nsf", "pst"]
        let placeholders = emailTypes.map { _ in "?" }.joined(separator: ",")
        let bindings: [SQLValue] = emailTypes.map { .text($0) }

        let koRows: [SQLRow]
        do {
            koRows = try await database.query("""
            SELECT ko.id, ko.metadata
              FROM knowledge_objects ko
             WHERE ko.source_type IN (\(placeholders))
               AND NOT EXISTS (
                     SELECT 1 FROM email_participant_occurrences epo
                      WHERE epo.source_ko_id = ko.id
                   )
             LIMIT ?;
            """, bindings + [.integer(Int64(pageSize))])
        } catch {
            KalsmritikoshLog.knowledge.error(
                "EmailParticipantBackfill: query failed: \(String(describing: error), privacy: .public)"
            )
            return 0
        }

        var totalWritten = 0
        for row in koRows {
            guard let koID = row.uuid(0) else { continue }
            let metaJSON = row.string(1) ?? ""
            let headers = headersFrom(metaJSON: metaJSON)
            let built = await buildOccurrences(koID: koID, headers: headers)
            guard !built.isEmpty else { continue }
            do {
                let n = try await occurrences.insertBatch(built)
                totalWritten += n
            } catch {
                KalsmritikoshLog.knowledge.error(
                    "EmailParticipantBackfill: insert failed for \(koID.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        KalsmritikoshLog.knowledge.info(
            "EmailParticipantBackfill: wrote \(totalWritten, privacy: .public) occurrence rows for \(koRows.count, privacy: .public) KOs"
        )
        return totalWritten
    }

    // MARK: - Internals

    private func buildOccurrences(
        koID: UUID,
        headers: [String: String]
    ) async -> [EmailParticipantOccurrence] {
        var out: [EmailParticipantOccurrence] = []
        let now = Date()
        let roleHeaderPairs: [(EmailParticipantRole, String)] = [
            (.from,    headers["from"]     ?? ""),
            (.sender,  headers["sender"]   ?? ""),
            (.replyTo, headers["reply-to"] ?? ""),
            (.to,      headers["to"]       ?? ""),
            (.cc,      headers["cc"]       ?? ""),
            (.bcc,     headers["bcc"]      ?? "")
        ]
        for (role, headerValue) in roleHeaderPairs {
            guard !headerValue.isEmpty else { continue }
            let parsed = EmailAddressListParser.parse(headerValue)
            for entry in parsed {
                guard let entityID = await resolveEntity(address: entry.address) else { continue }
                out.append(EmailParticipantOccurrence(
                    sourceObjectID: koID,
                    entityID:       entityID,
                    role:           role,
                    rawAddress:     entry.address,
                    displayName:    entry.displayName,
                    createdAt:      now
                ))
            }
        }
        return out
    }

    /// Extract lowercase header-key → value map from a flat JSON dict
    /// as stored in knowledge_objects.metadata.
    private func headersFrom(metaJSON: String) -> [String: String] {
        guard !metaJSON.isEmpty,
              let data = metaJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k.lowercased()] = s }
            // AnyCodable wraps values; try {"type":"string","value":"..."}
            if let dict = v as? [String: Any],
               let s = dict["value"] as? String {
                out[k.lowercased()] = s
            }
        }
        return out
    }

    private func resolveEntity(address: String) async -> Entity.ID? {
        guard let found = try? await entities.find(byValue: address, limit: 1).first else {
            return nil
        }
        return found.id
    }
}
