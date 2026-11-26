//
//  PhoneCommunicationAnalysis.swift
//  Kalsmritikosh
//
//  G3 — call & message analysis for phone extractions (the Pathfinder / Penlink /
//  i2 "who called whom" view), next to N-2's email analysis. Reads the message
//  blocks the discussion lane already wrote: each `.discussionMessage` block's
//  attributes carry the sender (authorID / authorHandle) and, from parser "2" on,
//  the recipients, direction, call duration and call status the report stated.
//
//  Honesty rules:
//    • A party is the number / handle AS RECORDED. Phone numbers are only
//      stripped of spaces, dashes and parentheses — never given or robbed of a
//      country code, so two spellings of one line may stay two parties.
//    • A record read before parser "2" has no party facts. It is COUNTED and the
//      screen says to re-read it, never silently dropped from the totals.
//    • A record that names only one side yields no pair; it is counted as such.
//

import Foundation
import os

/// One phone / chat message block, as read from the ledger.
public nonisolated struct PhoneRecordRow: Sendable, Hashable {
    public let blockID: UUID
    public let platform: String
    public let recordID: String
    public let authorID: String?
    public let authorHandle: String?
    public let recipients: [String]
    public let direction: String?
    public let durationSeconds: Int?
    public let callStatus: String?
    /// ISO-8601 as the parser wrote it (UTC).
    public let timestamp: String?

    public init(blockID: UUID, platform: String, recordID: String, authorID: String? = nil,
                authorHandle: String? = nil, recipients: [String] = [], direction: String? = nil,
                durationSeconds: Int? = nil, callStatus: String? = nil, timestamp: String? = nil) {
        self.blockID = blockID; self.platform = platform; self.recordID = recordID
        self.authorID = authorID; self.authorHandle = authorHandle; self.recipients = recipients
        self.direction = direction; self.durationSeconds = durationSeconds
        self.callStatus = callStatus; self.timestamp = timestamp
    }

    /// A call-log entry (the UFDR call thread), or anything carrying call facts.
    public var isCall: Bool {
        recordID.hasPrefix("calls#") || durationSeconds != nil || callStatus != nil
    }

    /// Whether the block was written with party facts at all (parser "2").
    public var hasPartyFacts: Bool {
        !recipients.isEmpty || direction != nil || durationSeconds != nil || callStatus != nil
    }

    public var isMissedCall: Bool {
        isCall && (callStatus?.lowercased().contains("miss") ?? false)
    }
}

public nonisolated struct PhoneContactPair: Sendable, Identifiable, Hashable {
    public var id: String { partyA + "↔" + partyB }
    public let partyA: String
    public let partyB: String
    public let calls: Int
    public let messages: Int
    public let callSeconds: Int
    public let firstContact: Date?
    public let lastContact: Date?
    /// A block to open as the pair's source (the earliest dated one).
    public let sampleBlockID: UUID
    public var contacts: Int { calls + messages }
}

public nonisolated struct PhonePartyTotal: Sendable, Identifiable, Hashable {
    public var id: String { party }
    public let party: String
    public let calls: Int
    public let missedCalls: Int
    public let messages: Int
    public let callSeconds: Int
}

public nonisolated struct PhoneMonthVolume: Sendable, Identifiable, Hashable {
    public var id: String { month }
    public let month: String
    public let calls: Int
    public let messages: Int
}

public nonisolated struct PhoneCommunicationReport: Sendable {
    public let pairs: [PhoneContactPair]
    public let parties: [PhonePartyTotal]
    public let monthly: [PhoneMonthVolume]
    /// Display name per party key, when the report gave one alongside the number.
    public let names: [String: String]
    public let totalRecords: Int
    /// Records that produced at least one pair.
    public let pairedRecords: Int
    /// Records read before party facts were recorded (re-read to analyse).
    public let withoutPartyData: Int
    /// Records with party facts that name only one side.
    public let oneSided: Int

    public var coverageLine: String {
        var parts = ["\(pairedRecords) of \(totalRecords) phone/chat record(s) name both sides and are analysed here."]
        if withoutPartyData > 0 {
            parts.append("\(withoutPartyData) record(s) were read before call and message parties were recorded — "
                         + "re-read the phone reports to analyse these.")
        }
        if oneSided > 0 {
            parts.append("\(oneSided) record(s) name only one party; the report does not say who was on the other end.")
        }
        return parts.joined(separator: " ")
    }
}

public nonisolated enum PhoneCommunicationAnalysis {

    /// Conservative party identity: trimmed; a value made only of digits, '+',
    /// spaces, dashes and parentheses loses the spaces, dashes and parentheses.
    /// Nothing else changes — no country code is added or removed.
    public static func normalizeParty(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("+0123456789 -()")
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }.count
        guard digits >= 3, trimmed.allSatisfy({ allowed.contains($0) }) else { return trimmed }
        return trimmed.filter { !" -()".contains($0) }
    }

    /// The pure analysis: no database, no clock.
    public static func analyse(_ input: [PhoneRecordRow]) -> PhoneCommunicationReport {
        // The same record reached twice (e.g. a .ufdr and its unzipped folder) counts once.
        var seen = Set<String>()
        let rows = input.filter {
            seen.insert([$0.platform, $0.recordID, $0.timestamp ?? "", $0.authorID ?? $0.authorHandle ?? ""]
                .joined(separator: "\u{1F}")).inserted
        }

        struct PairAcc { var calls = 0, messages = 0, seconds = 0; var first: Date?; var last: Date?; var sample: UUID; var sampleDate: Date? }
        struct PartyAcc { var calls = 0, missed = 0, messages = 0, seconds = 0 }
        var pairs: [String: (a: String, b: String, acc: PairAcc)] = [:]
        var parties: [String: PartyAcc] = [:]
        var months: [String: (calls: Int, messages: Int)] = [:]
        var names: [String: String] = [:]
        var paired = 0, withoutData = 0, oneSided = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone

        for row in rows {
            let date = row.timestamp.flatMap(parseTimestamp)
            if let date {
                let c = calendar.dateComponents([.year, .month], from: date)
                let key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
                var m = months[key] ?? (0, 0)
                if row.isCall { m.calls += 1 } else { m.messages += 1 }
                months[key] = m
            }
            guard row.hasPartyFacts else { withoutData += 1; continue }

            let sender = (row.authorID ?? row.authorHandle).map(normalizeParty).flatMap { $0.isEmpty ? nil : $0 }
            if let sender, let handle = row.authorHandle, handle != sender, names[sender] == nil {
                names[sender] = handle
            }
            var named: [String] = []
            for p in ([sender].compactMap { $0 } + row.recipients.map(normalizeParty)) where !p.isEmpty && !named.contains(p) {
                named.append(p)
            }
            let seconds = row.isCall ? (row.durationSeconds ?? 0) : 0
            for p in named {
                var acc = parties[p] ?? PartyAcc()
                if row.isCall { acc.calls += 1; acc.seconds += seconds; if row.isMissedCall { acc.missed += 1 } }
                else { acc.messages += 1 }
                parties[p] = acc
            }

            let recipients = named.filter { $0 != sender }
            guard let sender, !recipients.isEmpty else { oneSided += 1; continue }
            paired += 1
            for r in recipients {
                let (a, b) = sender < r ? (sender, r) : (r, sender)
                let key = a + "\u{1F}" + b
                var entry = pairs[key] ?? (a: a, b: b, acc: PairAcc(sample: row.blockID, sampleDate: date))
                if row.isCall { entry.acc.calls += 1; entry.acc.seconds += seconds } else { entry.acc.messages += 1 }
                if let date {
                    entry.acc.first = min(entry.acc.first ?? date, date)
                    entry.acc.last = max(entry.acc.last ?? date, date)
                    if entry.acc.sampleDate == nil || date < (entry.acc.sampleDate ?? date) {
                        entry.acc.sample = row.blockID; entry.acc.sampleDate = date
                    }
                }
                pairs[key] = entry
            }
        }

        let pairList = pairs.values.map {
            PhoneContactPair(partyA: $0.a, partyB: $0.b, calls: $0.acc.calls, messages: $0.acc.messages,
                             callSeconds: $0.acc.seconds, firstContact: $0.acc.first, lastContact: $0.acc.last,
                             sampleBlockID: $0.acc.sample)
        }.sorted { ($0.contacts, $1.id) > ($1.contacts, $0.id) }
        let partyList = parties.map {
            PhonePartyTotal(party: $0.key, calls: $0.value.calls, missedCalls: $0.value.missed,
                            messages: $0.value.messages, callSeconds: $0.value.seconds)
        }.sorted { ($0.calls + $0.messages, $1.party) > ($1.calls + $1.messages, $0.party) }
        let monthList = months.sorted { $0.key < $1.key }
            .map { PhoneMonthVolume(month: $0.key, calls: $0.value.calls, messages: $0.value.messages) }

        return PhoneCommunicationReport(pairs: pairList, parties: partyList, monthly: monthList, names: names,
                                        totalRecords: rows.count, pairedRecords: paired,
                                        withoutPartyData: withoutData, oneSided: oneSided)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw)
    }

    /// Duration as "1:02:03" / "2:03".
    public static func formatSeconds(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension AppState {

    /// G3 — phone / chat message blocks of the CURRENT structure: the UFDR
    /// platform (so records read before party facts existed are counted), plus
    /// any message block that carries party facts.
    public func phoneCommunicationReport() async -> PhoneCommunicationReport? {
        guard ProductModuleFlags.isEnabled(.communicationAnalysis), let database else { return nil }
        do {
            let rows = try await database.query("""
                SELECT b.id,
                       json_extract(b.attributes, '$.platform'), json_extract(b.attributes, '$.recordID'),
                       json_extract(b.attributes, '$.authorID'), json_extract(b.attributes, '$.authorHandle'),
                       json_extract(b.attributes, '$.recipients'), json_extract(b.attributes, '$.direction'),
                       json_extract(b.attributes, '$.durationSeconds'), json_extract(b.attributes, '$.callStatus'),
                       json_extract(b.attributes, '$.timestamp')
                FROM evidence_blocks b
                LEFT JOIN source_versions sv ON sv.id = b.source_version_id
                WHERE b.kind = ? AND b.superseded_by_run IS NULL AND COALESCE(sv.is_current, 1) = 1
                  AND json_valid(b.attributes)
                  AND COALESCE(json_extract(b.attributes, '$.recordID'), '') NOT LIKE 'contacts#%'
                  AND (json_extract(b.attributes, '$.platform') = ?
                       OR json_extract(b.attributes, '$.recipients') IS NOT NULL
                       OR json_extract(b.attributes, '$.direction') IS NOT NULL
                       OR json_extract(b.attributes, '$.durationSeconds') IS NOT NULL
                       OR json_extract(b.attributes, '$.callStatus') IS NOT NULL);
                """, [.text(EvidenceBlockKind.discussionMessage.rawValue), .text(CellebriteReportMapper().platform)])
            let records = rows.compactMap { r -> PhoneRecordRow? in
                guard let id = r.uuid(0), let recordID = r.string(2) else { return nil }
                var recipients: [String] = []
                if let json = r.string(5), let data = json.data(using: .utf8) {
                    do {
                        recipients = try JSONDecoder().decode([String].self, from: data)
                    } catch {
                        KalsmritikoshLog.app.error("Phone analysis: unreadable recipients on a block: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return PhoneRecordRow(blockID: id, platform: r.string(1) ?? "", recordID: recordID,
                                      authorID: r.string(3), authorHandle: r.string(4), recipients: recipients,
                                      direction: r.string(6), durationSeconds: r.int(7).map { Int($0) },
                                      callStatus: r.string(8), timestamp: r.string(9))
            }
            return PhoneCommunicationAnalysis.analyse(records)
        } catch {
            KalsmritikoshLog.app.error("Phone communication report failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// G3 — the cited block for a pair's "Open source": its document and text.
    public func phoneRecordCitation(blockID: UUID) async -> VerifiedAnswer.Citation? {
        guard let database else { return nil }
        do {
            let row = try await database.query("""
                SELECT COALESCE(
                         (SELECT o.knowledge_object_id FROM evidence_block_objects o WHERE o.evidence_block_id = b.id LIMIT 1),
                         (SELECT c.object_id FROM chunks c WHERE c.evidence_block_id = b.id LIMIT 1)),
                       b.raw_text
                FROM evidence_blocks b WHERE b.id = ? LIMIT 1;
                """, [.uuid(blockID)]).first
            guard let objectID = row?.uuid(0) else { return nil }
            return VerifiedAnswer.Citation(objectID: objectID, snippet: row?.string(1) ?? "")
        } catch {
            KalsmritikoshLog.app.error("Phone record source lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// G3 — re-read every phone/chat export whose structure came from an older
    /// discussion parser, so its messages gain party facts. Exact bytes are
    /// re-verified first; a source whose new reading is worse keeps the old one.
    func rereadPhoneReports() async -> (reprocessed: Int, upToDate: Int, failed: Int) {
        guard let database, let ingest else { return (0, 0, 0) }
        let ids: [UUID]
        do {
            ids = try await database.query("""
                SELECT id FROM source_versions WHERE detected_type IN (?, ?) AND is_current = 1;
                """, [.text(SourceType.discussionExport.rawValue), .text(SourceType.chatExport.rawValue)])
                .compactMap { $0.uuid(0) }
        } catch {
            KalsmritikoshLog.app.error("Phone report re-read: listing failed: \(error.localizedDescription, privacy: .public)")
            return (0, 0, 0)
        }
        var done = 0, fresh = 0, failed = 0
        for id in ids {
            do {
                switch try await ingest.reprocess(sourceVersionID: id) {
                case .upToDate: fresh += 1
                case .changedOutputRejected: failed += 1
                default: done += 1
                }
            } catch {
                failed += 1
                KalsmritikoshLog.app.error("Phone report re-read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (done, fresh, failed)
    }
}
