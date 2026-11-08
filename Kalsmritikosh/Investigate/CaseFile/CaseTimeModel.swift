//
//  CaseTimeModel.swift
//  Kalsmritikosh
//
//  Smart-map S5 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §12 TIME; schema v181): what happened, kept
//  apart from when the case learned of it and who did what in the investigation.
//
//  • Typed times (TIME-01): occurrence, creation, signing, collection, receipt, import, assignment, performance,
//    submission, review, correction and supersession are separate kinds; none is folded into a generic timestamp.
//  • Time values (TIME-02): a value has its precision, a range or a one-sided bound, "approximately", a relative wording,
//    its time zone and the source's own words — or it is unknown. A day is never shown with a time.
//  • Competing times (TIME-03): source assertions stay as they are; the investigator's interpretation is a separate
//    decision listing the assertions it considered.
//  • Per-object timelines (TIME-04): each record's events and work history; the case timeline is their union — the same
//    entries, never a second copy.
//  • Chronology uncertainty (TIME-05): items whose ranges overlap are marked "order cannot be determined", and the time
//    zone assumed for zone-less dates is stated. A sorted list is not evidence of sequence.
//  • Attribution and order (TIME-06 / TIME-08): the recorded name, this Mac's signed-in account (not an identity check),
//    the reported performer, the software actor and its trigger are separate; this device's own recording sequence and
//    causal parent are kept, and wall-clock order is never presented as trusted.
//  • Audit sources (TIME-07) for investigator-drawn links, review decisions and outputs, and the chain's trust statement.
//  • History access (TIME-10): a recorded state opened today is shown under today's scope; sources no longer in it are
//    withheld.
//  Nothing here calls a model or the network.
//

import Foundation
import os

// MARK: - Kinds and values

public nonisolated enum CaseTypedTimeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case occurrence, creation, signing, collection, receipt, `import`, assignment, performance, submission, review, correction, supersession
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .occurrence: return "When it happened"
        case .creation: return "When the document was created"
        case .signing: return "When it was signed"
        case .collection: return "When it was collected"
        case .receipt: return "When the case received it"
        case .import: return "When it was imported into the app"
        case .assignment: return "When the work was assigned"
        case .performance: return "When the work was done"
        case .submission: return "When the result was submitted"
        case .review: return "When it was reviewed"
        case .correction: return "When it was corrected"
        case .supersession: return "When it was superseded"
        }
    }
    /// Event times describe the matter investigated; the rest describe the investigation's own handling.
    public var isEventTime: Bool { [.occurrence, .creation, .signing].contains(self) }
}

public nonisolated enum CaseTimeQualifier: String, Sendable, Codable, CaseIterable {
    case stated, approximate, notBefore, notAfter, between, relative, unknown
    public var label: String {
        switch self {
        case .stated: return "as stated"
        case .approximate: return "approximately"
        case .notBefore: return "not before"
        case .notAfter: return "not after"
        case .between: return "between"
        case .relative: return "relative to another event"
        case .unknown: return "time not known"
        }
    }
}

public nonisolated enum CaseTimeAssertor: String, Sendable, Codable, CaseIterable {
    case source, investigator, app
    public var label: String {
        switch self {
        case .source: return "stated by a source"
        case .investigator: return "entered by the investigator"
        case .app: return "recorded by the app"
        }
    }
}

/// A time as it is known: never more precise than it was given.
public nonisolated struct CaseTimeValue: Sendable, Equatable, Hashable, Codable {
    public var start: Date?
    public var end: Date?
    public var precision: DatePrecision
    public var qualifier: CaseTimeQualifier
    public var relativeText: String?
    public var timeZoneID: String?
    public var originalText: String?

    public init(start: Date?, end: Date? = nil, precision: DatePrecision, qualifier: CaseTimeQualifier = .stated, relativeText: String? = nil,
                timeZoneID: String? = nil, originalText: String? = nil) {
        self.start = start; self.end = end; self.precision = precision; self.qualifier = qualifier; self.relativeText = relativeText
        self.timeZoneID = timeZoneID; self.originalText = originalText
    }

    public static let unknown = CaseTimeValue(start: nil, precision: .unknown, qualifier: .unknown)

    public var timeZone: TimeZone? { timeZoneID.flatMap(TimeZone.init(identifier:)) }

    func calendar(_ assumed: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone ?? assumed
        return c
    }

    /// One date at the value's precision (a day never gets a time; a time names its zone when one was recorded).
    func render(_ d: Date, _ assumed: TimeZone) -> String {
        let cal = calendar(assumed)
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_GB")
        switch precision {
        case .decade: return "the \(cal.component(.year, from: d) / 10 * 10)s"
        case .year: f.dateFormat = "yyyy"
        case .quarter: return "Q\((cal.component(.month, from: d) - 1) / 3 + 1) \(cal.component(.year, from: d))"
        case .month: f.dateFormat = "MMMM yyyy"
        case .day, .unknown: f.dateFormat = "d MMM yyyy"
        case .minute: f.dateFormat = "d MMM yyyy HH:mm"
        case .instant: f.dateFormat = "d MMM yyyy HH:mm:ss"
        }
        var s = f.string(from: d)
        if precision == .minute || precision == .instant { s += " " + (timeZoneID ?? "(\(cal.timeZone.identifier), assumed)") }
        return s
    }

    /// The value in words: "approximately March 2024", "between 3 Mar 2024 and 5 Mar 2024", "not after 4 Mar 2024",
    /// "two days after the meeting (relative)", "time not known" — with the source's wording after it.
    public func label(assuming assumed: TimeZone = .current) -> String {
        var s: String
        switch qualifier {
        case .unknown: s = "time not known"
        case .relative: s = (relativeText ?? "relative") + (start.map { " (≈ \(render($0, assumed)))" } ?? " (relative — not placed on a date)")
        case .between: s = "between \(start.map { render($0, assumed) } ?? "?") and \(end.map { render($0, assumed) } ?? "?")"
        case .notBefore: s = "not before \(start.map { render($0, assumed) } ?? "?")"
        case .notAfter: s = "not after \(start.map { render($0, assumed) } ?? "?")"
        case .approximate: s = "approximately \(start.map { render($0, assumed) } ?? "?")" + (end.map { " – \(render($0, assumed))" } ?? "")
        case .stated: s = (start.map { render($0, assumed) } ?? "?") + (end.map { " – \(render($0, assumed))" } ?? "")
        }
        if precision == .unknown, qualifier != .unknown, qualifier != .relative { s += " (precision not recorded)" }
        if let t = originalText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { s += " — “\(t)”" }
        return s
    }

    /// The earliest and latest instant the value allows (nil: it cannot be placed). A day spans the whole day in its zone;
    /// "approximately" widens by one unit of its precision either side; "not before"/"not after" are open on one side.
    public func bounds(assuming assumed: TimeZone = .current) -> (earliest: Date, latest: Date)? {
        guard let start, qualifier != .unknown else { return nil }
        if qualifier == .relative, precision == .unknown { return nil }
        let cal = calendar(assumed)
        func span(_ d: Date) -> (Date, Date) {
            let comp: Calendar.Component
            switch precision {
            case .decade: let y = cal.component(.year, from: d) / 10 * 10
                let a = cal.date(from: DateComponents(year: y)) ?? d
                return (a, cal.date(byAdding: .year, value: 10, to: a) ?? a)
            case .year: comp = .year
            case .quarter:
                let m = (cal.component(.month, from: d) - 1) / 3 * 3 + 1
                let a = cal.date(from: DateComponents(year: cal.component(.year, from: d), month: m)) ?? d
                return (a, cal.date(byAdding: .month, value: 3, to: a) ?? a)
            case .month: comp = .month
            case .day, .unknown: comp = .day
            case .minute: comp = .minute
            case .instant: return (d, d)
            }
            guard let iv = cal.dateInterval(of: comp, for: d) else { return (d, d) }
            return (iv.start, iv.end)
        }
        var lo = span(start).0
        var hi = span(end ?? start).1
        if qualifier == .approximate {
            let unit: Calendar.Component = [.decade, .year].contains(precision) ? .year : precision == .quarter || precision == .month ? .month
                : precision == .day || precision == .unknown ? .day : .hour
            lo = cal.date(byAdding: unit, value: -1, to: lo) ?? lo
            hi = cal.date(byAdding: unit, value: 1, to: hi) ?? hi
        }
        switch qualifier {
        case .notBefore: return (lo, .distantFuture)
        case .notAfter: return (.distantPast, hi)
        default: return (lo, hi)
        }
    }
}

// MARK: - Assertions and interpretations (TIME-01 / TIME-03)

public nonisolated struct CaseTypedTime: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let recordKind: String
    public let recordID: String
    public let kind: CaseTypedTimeKind
    public let value: CaseTimeValue
    public let assertor: CaseTimeAssertor
    public let assertedBy: String?
    public let sourceVersionID: UUID?
    public let locator: String?
    /// When the app recorded the assertion — never the time it asserts.
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    /// Derived from a stored column of another record (not a row of case_time_assertions).
    public var derived: Bool = false
    public var isActive: Bool { withdrawnAt == nil }
    public var line: String {
        "\(kind.label): \(value.label()) — \(assertor.label)" + (assertedBy.map { " (\($0))" } ?? "") + (locator.map { ", \($0)" } ?? "")
            + "; recorded \(recordedAt.formatted(date: .abbreviated, time: .shortened)) by \(recordedBy)"
    }
}

public nonisolated struct CaseTimeInterpretation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let recordKind: String
    public let recordID: String
    public let kind: CaseTypedTimeKind
    public let chosenAssertionID: UUID?
    public let value: CaseTimeValue
    public let rationale: String
    public let considered: [UUID]
    public let decidedBy: String
    public let decidedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
}

/// A record's times: every assertion kept as it was, by kind, and the investigator's current interpretation of each.
public nonisolated struct CaseRecordTimes: Sendable, Equatable {
    public let assertions: [CaseTypedTime]
    public let interpretations: [CaseTimeInterpretation]
    public func assertions(_ k: CaseTypedTimeKind) -> [CaseTypedTime] { assertions.filter { $0.kind == k && $0.isActive } }
    public func interpretation(_ k: CaseTypedTimeKind) -> CaseTimeInterpretation? { interpretations.last { $0.kind == k && $0.isActive } }
    /// Kinds with more than one distinct value asserted and no interpretation recorded.
    public var competing: [CaseTypedTimeKind] {
        CaseTypedTimeKind.allCases.filter { k in Set(assertions(k).map(\.value)).count > 1 && interpretation(k) == nil }
    }
}

public nonisolated enum CaseTimeError: Error, Equatable, LocalizedError {
    case unknownMustHaveNoValue
    case valueNeeded
    case endBeforeStart
    case relativeNeedsWording
    case sourceNeedsReference
    case nothingConsidered
    case assertionNotForRecord
    public var errorDescription: String? {
        switch self {
        case .unknownMustHaveNoValue: return "A time recorded as not known has no date."
        case .valueNeeded: return "Give the date, or record the time as not known or relative."
        case .endBeforeStart: return "The end of the range is before its start."
        case .relativeNeedsWording: return "Say what it is relative to, in the source's words."
        case .sourceNeedsReference: return "A time stated by a source names the source (a document in the case, or who stated it)."
        case .nothingConsidered: return "An interpretation lists the time assertions it chose between."
        case .assertionNotForRecord: return "That time assertion is not about this record and kind."
        }
    }
}

// MARK: - Chronology ordering (TIME-05)

public nonisolated struct CaseChronologyItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let time: CaseTimeValue
    public init(id: String, title: String, time: CaseTimeValue) { self.id = id; self.title = title; self.time = time }
}

public nonisolated struct CaseChronologyArrangement: Sendable, Equatable {
    /// Groups in date order; a group of more than one is a set whose order the recorded dates cannot settle.
    public let groups: [[CaseChronologyItem]]
    /// Items with no placeable time (unknown, or relative with no date).
    public let unplaced: [CaseChronologyItem]
    public let timeZoneNote: String
    public var undetermined: [[CaseChronologyItem]] { groups.filter { $0.count > 1 } }
    public var notes: [String] {
        var out = [timeZoneNote, "The list is in order of each entry's earliest possible time. That is a reading aid, not evidence of the sequence."]
        for g in undetermined {
            out.append("Order cannot be determined from the recorded dates between: " + g.map { "“\($0.title)” (\($0.time.label()))" }.joined(separator: "; ") + ".")
        }
        if !unplaced.isEmpty { out.append("Not placed (no usable date): " + unplaced.map { "“\($0.title)”" }.joined(separator: "; ") + ".") }
        return out
    }
}

public nonisolated enum CaseChronologyOrder {
    public static func arrange(_ items: [CaseChronologyItem], assuming tz: TimeZone = .current) -> CaseChronologyArrangement {
        var placed: [(CaseChronologyItem, Date, Date)] = []
        var unplaced: [CaseChronologyItem] = []
        for i in items {
            if let b = i.time.bounds(assuming: tz) { placed.append((i, b.earliest, b.latest)) } else { unplaced.append(i) }
        }
        placed.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
        var groups: [[CaseChronologyItem]] = []
        var groupEnd: Date?
        for (item, lo, hi) in placed {
            // Overlapping ranges cannot be put in order (a shared instant included: two entries of the same day).
            if let end = groupEnd, lo < end || (lo == end && hi == lo) {
                groups[groups.count - 1].append(item)
                groupEnd = max(end, hi)
            } else {
                groups.append([item])
                groupEnd = hi
            }
        }
        let zoneless = items.contains { $0.time.timeZoneID == nil && $0.time.bounds(assuming: tz) != nil }
        let note = zoneless ? "Dates without a recorded time zone are read in \(tz.identifier) (this Mac's time zone); entries with their own zone keep it."
                            : "Every dated entry carries its own time zone."
        return CaseChronologyArrangement(groups: groups, unplaced: unplaced, timeZoneNote: note)
    }
}

// MARK: - Per-object timelines (TIME-04)

public nonisolated struct CaseTimelineEntry: Sendable, Equatable, Identifiable, Hashable {
    public enum Lane: String, Sendable, Hashable { case event, work }
    /// Stable: the canonical record it comes from ("revision:<id>", "time:<id>", "journal:<id>", "action:<id>").
    public let id: String
    public let lane: Lane
    public let recordKind: String
    public let recordID: String
    public let text: String
    /// For an event: the time it happened, as recorded. Nil for work.
    public let eventTime: CaseTimeValue?
    /// When the app recorded it — always kept apart from the event time.
    public let recordedAt: Date
    public let actor: String?
}

public nonisolated enum CaseTimeline {
    /// One record's entries, from the records that hold them: its time assertions (event lane, at their precision), its
    /// before/after revisions and the case actions they were written with (work lane).
    static func entries(times: [CaseTypedTime], revisions: [CaseRecordRevision], journal: [CaseJournalEntry]) -> [CaseTimelineEntry] {
        var out: [CaseTimelineEntry] = []
        for t in times where t.isActive {
            out.append(CaseTimelineEntry(id: "time:\(t.id.uuidString.lowercased())", lane: t.kind.isEventTime ? .event : .work, recordKind: t.recordKind,
                                         recordID: t.recordID.lowercased(), text: t.kind.label + " — " + t.assertor.label, eventTime: t.value,
                                         recordedAt: t.recordedAt, actor: t.recordedBy))
        }
        for j in journal where j.kind == .chronology {
            out.append(CaseTimelineEntry(id: "journal:\(j.id.uuidString.lowercased())", lane: .event, recordKind: "journal", recordID: j.id.uuidString.lowercased(),
                                         text: j.text, eventTime: j.timeValue, recordedAt: j.createdAt, actor: j.author))
        }
        for r in revisions {
            let fields = r.changedFields.filter { !["updated_at"].contains($0) }
            out.append(CaseTimelineEntry(id: "revision:\(r.id.uuidString.lowercased())", lane: .work, recordKind: r.recordKind, recordID: r.recordID.lowercased(),
                                         text: r.change + (fields.isEmpty ? "" : " — changed: " + fields.joined(separator: ", ")),
                                         eventTime: nil, recordedAt: r.recordedAt, actor: r.actor))
        }
        return out.sorted { $0.recordedAt != $1.recordedAt ? $0.recordedAt < $1.recordedAt : $0.id < $1.id }
    }
}

// MARK: - Action attribution and device order (TIME-06 / TIME-08)

/// Who and what is behind a case action, beyond the name it is recorded under. Set around a write with `withValue`.
public nonisolated struct CaseActionContext: Sendable, Equatable {
    /// The person who reported doing the work (external work entered by someone else).
    public var performedBy: String?
    /// The software that acted ("rule: point suggester v1", "daily record"), when the action was automatic.
    public var softwareActor: String?
    /// What triggered it ("opened the case map", "re-read the report").
    public var trigger: String?
    /// The case action this one was caused by.
    public var causedBy: UUID?
    public init(performedBy: String? = nil, softwareActor: String? = nil, trigger: String? = nil, causedBy: UUID? = nil) {
        self.performedBy = performedBy; self.softwareActor = softwareActor; self.trigger = trigger; self.causedBy = causedBy
    }
    @TaskLocal public static var current: CaseActionContext? = nil
}

public nonisolated enum CaseActionStamp {
    /// This Mac's signed-in account name. It is the session the app runs in, not a verified identity.
    public static var sessionAccount: String { NSUserName() }

    /// The ledger's recording-device id (created once). A ledger restored elsewhere keeps it; it is not a hardware id.
    static func deviceID(_ db: isolated Database, at date: Date) throws -> String {
        if let d = try db.query("SELECT device_id FROM ledger_recording_device WHERE id = 1;", []).first?.string(0) { return d }
        let d = UUID().uuidString.lowercased()
        try db.exec("INSERT OR IGNORE INTO ledger_recording_device (id, device_id, created_at) VALUES (1, ?, ?);", [.text(d), .date(date)])
        return try db.query("SELECT device_id FROM ledger_recording_device WHERE id = 1;", []).first?.string(0) ?? d
    }

    /// Insert one case action with its attribution parts and its place in this device's own sequence.
    static func insert(_ db: isolated Database, id: UUID, caseID: UUID, sequence: Int64, actor: String, action: String, detail: String?, at date: Date) throws {
        // A ledger not yet at v181 (a partial migration in a test, or a migration step) keeps the earlier row shape.
        guard try !db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ledger_recording_device';", []).isEmpty else {
            try db.exec("INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .integer(sequence), .text(actor), .text(action), .optionalText(detail), .date(date)])
            return
        }
        let ctx = CaseActionContext.current
        let device = try deviceID(db, at: date)
        let seq = (try db.query("SELECT COALESCE(MAX(device_seq), 0) FROM case_actions WHERE device_id = ?;", [.text(device)]).first?.int(0) ?? 0) + 1
        try db.exec("""
            INSERT INTO case_actions (id, case_id, sequence, actor, action, detail, at, session_account, performed_by, software_actor, trigger_context,
                                      device_id, device_seq, caused_by)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(caseID), .integer(sequence), .text(actor), .text(action), .optionalText(detail), .date(date),
                  .text(sessionAccount), .optionalText(CaseFileRepository.blankToNil(ctx?.performedBy)), .optionalText(CaseFileRepository.blankToNil(ctx?.softwareActor)),
                  .optionalText(CaseFileRepository.blankToNil(ctx?.trigger)), .text(device), .integer(seq), ctx?.causedBy.map { .uuid($0) } ?? .null])
    }
}

/// A case action in display order, with what can and cannot be said about its time.
public nonisolated struct CaseOrderedAction: Sendable, Equatable {
    public let action: CaseAction
    /// The recorded clock time is earlier than an action this device recorded before it: the clock moved back (or was
    /// wrong). The device order stands; the clock time is not trusted.
    public let clockOutOfOrder: Bool
    /// Not recorded on this device (an action received from elsewhere), or recorded before v181 with no device sequence.
    public let outsideDeviceOrder: Bool
}

public nonisolated enum CaseAuditOrdering {
    public static let statement = "Actions are listed in the order this device recorded them (its own sequence). Times are this Mac's clock as it was then and are not verified; an action recorded before sequencing began, or received from another device, is listed by its recorded time and marked, and its order relative to the others is not established."

    /// Order by this device's sequence; mark clock times that run backwards and actions outside the device order.
    public static func arrange(_ actions: [CaseAction], device: String?) -> [CaseOrderedAction] {
        let mine = actions.filter { $0.deviceID != nil && $0.deviceID == device && $0.deviceSeq != nil }.sorted { ($0.deviceSeq ?? 0) < ($1.deviceSeq ?? 0) }
        let others = actions.filter { !($0.deviceID != nil && $0.deviceID == device && $0.deviceSeq != nil) }.sorted { $0.at < $1.at }
        var out: [CaseOrderedAction] = []
        var latest: Date?
        for a in mine {
            let back = latest.map { a.at < $0 } ?? false
            latest = max(latest ?? a.at, a.at)
            out.append(CaseOrderedAction(action: a, clockOutOfOrder: back, outsideDeviceOrder: false))
        }
        out += others.map { CaseOrderedAction(action: $0, clockOutOfOrder: false, outsideDeviceOrder: true) }
        return out
    }
}

// MARK: - Audit sources and trust statement (TIME-07)

public nonisolated enum CaseAuditSources {
    /// What the chain can and cannot show — printed with every verification result.
    public static let trustStatement = "Tamper-evident, not tamper-proof: each sealed event is linked to the one before it with a key kept in this Mac's Keychain for this ledger. The check shows whether sealed records changed since they were sealed; it cannot show that what was recorded is true, and anyone holding this Mac's key and ledger could rebuild the chain. Events recorded before sealing began are not covered."

    /// Investigator-drawn map links (as drawn), review decisions and produced outputs, as audit-chain events. Only fields
    /// that never change after the row is written enter the payload; free text enters as a digest.
    public static func events(_ database: Database) async throws -> [AuditChainEvent] {
        var out: [AuditChainEvent] = []
        for r in try await database.query("""
            SELECT id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at, certainty, valid_from, valid_to, valid_text, revises_link_id
            FROM case_map_links ORDER BY created_at, id;
            """, []) {
            guard let id = r.uuid(0), let c = r.string(1), let t = r.string(2), let by = r.string(8), let at = r.date(9) else { continue }
            let payload = "caseID=\(c.lowercased());certainty=\(r.string(10) ?? "");createdAt=\(at.timeIntervalSince1970);createdBy=\(by);"
                + "from=\(r.string(3) ?? ""):\(r.string(4) ?? "");rationaleDigest=\(CaseFileHash.sha256(r.string(7) ?? ""));revises=\(r.string(14) ?? "");"
                + "to=\(r.string(5) ?? ""):\(r.string(6) ?? "");type=\(t);valid=\(r.double(11).map { "\($0)" } ?? "")..\(r.double(12).map { "\($0)" } ?? ""):\(CaseFileHash.sha256(r.string(13) ?? ""))"
            out.append(AuditChainEvent(source: .mapLink, eventID: id, occurredAt: at, canonicalPayload: payload))
        }
        for r in try await database.query("""
            SELECT id, case_id, item_kind, item_id, decision, reason, note, source_versions_json, actor, decided_at, passages_json
            FROM investigation_review_decisions ORDER BY decided_at, id;
            """, []) {
            guard let id = r.uuid(0), let c = r.string(1), let k = r.string(2), let item = r.string(3), let d = r.string(4), let by = r.string(8), let at = r.date(9) else { continue }
            let payload = "actor=\(by);at=\(at.timeIntervalSince1970);caseID=\(c.lowercased());decision=\(d);item=\(k):\(item);"
                + "noteDigest=\(CaseFileHash.sha256(r.string(6) ?? ""));passagesDigest=\(CaseFileHash.sha256(r.string(10) ?? ""));reason=\(r.string(5) ?? "");"
                + "versionsDigest=\(CaseFileHash.sha256(r.string(7) ?? ""))"
            out.append(AuditChainEvent(source: .reviewDecision, eventID: id, occurredAt: at, canonicalPayload: payload))
        }
        for r in try await database.query("""
            SELECT id, case_id, kind, route, snapshot_sha256, file_name, file_sha256, status, detail, released_by, released_at
            FROM case_document_outputs ORDER BY released_at, id;
            """, []) {
            guard let id = r.uuid(0), let c = r.string(1), let by = r.string(9), let at = r.date(10) else { continue }
            let payload = "caseID=\(c.lowercased());detailDigest=\(CaseFileHash.sha256(r.string(8) ?? ""));fileName=\(CaseFileHash.sha256(r.string(5) ?? ""));"
                + "fileSHA256=\(r.string(6) ?? "");kind=\(r.string(2) ?? "");releasedAt=\(at.timeIntervalSince1970);releasedBy=\(by);route=\(r.string(3) ?? "");"
                + "snapshot=\(r.string(4) ?? "");status=\(r.string(7) ?? "")"
            out.append(AuditChainEvent(source: .caseOutput, eventID: id, occurredAt: at, canonicalPayload: payload))
        }
        return out
    }
}

// MARK: - History detail under today's restrictions (TIME-10)

public nonisolated enum CaseHistoryAccess {
    /// A free-text audit or history detail as it may be shown now: every name protected today is replaced, so older
    /// detail is not a way round a protection added since.
    public static func visibleDetail(_ detail: String?, protectedNames: [String]) -> String? {
        guard let detail else { return nil }
        guard !protectedNames.isEmpty else { return detail }
        return ProtectedIdentities.scrub(detail, names: protectedNames).text
    }
}

// MARK: - Persistence

extension CaseFileRepository {

    @discardableResult
    public func recordTime(caseID: UUID, recordKind: String, recordID: String, kind: CaseTypedTimeKind, value: CaseTimeValue, assertor: CaseTimeAssertor,
                           assertedBy: String? = nil, sourceVersionID: UUID? = nil, locator: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let rk = try Self.clean(recordKind, "The record"), rid = try Self.clean(recordID, "The record")
        switch value.qualifier {
        case .unknown: guard value.start == nil, value.end == nil else { throw CaseTimeError.unknownMustHaveNoValue }
        case .relative: guard Self.blankToNil(value.relativeText) != nil else { throw CaseTimeError.relativeNeedsWording }
        default: guard value.start != nil else { throw CaseTimeError.valueNeeded }
        }
        if value.qualifier == .between, value.end == nil { throw CaseTimeError.valueNeeded }
        if let a = value.start, let b = value.end, b < a { throw CaseTimeError.endBeforeStart }
        if assertor == .source, sourceVersionID == nil, Self.blankToNil(assertedBy) == nil { throw CaseTimeError.sourceNeedsReference }
        let id = UUID()
        try await write("cf_time", caseID: caseID, actor: who, action: "timeAsserted", detail: "\(rk) \(kind.rawValue): \(value.label())", at: date) { db in
            if let v = sourceVersionID, !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_time_assertions (id, case_id, record_kind, record_id, time_kind, start_at, end_at, precision, qualifier, relative_text, time_zone,
                    original_text, asserted_by_kind, asserted_by, source_version_id, locator, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(rk), .text(rid.lowercased()), .text(kind.rawValue), .optionalDate(value.start), .optionalDate(value.end),
                      .text(value.precision.displayName), .text(value.qualifier.rawValue), .optionalText(Self.blankToNil(value.relativeText)),
                      .optionalText(Self.blankToNil(value.timeZoneID)), .optionalText(Self.blankToNil(value.originalText)), .text(assertor.rawValue),
                      .optionalText(Self.blankToNil(assertedBy)), sourceVersionID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(locator)),
                      .text(who), .date(date)])
        }
        return id
    }

    public func withdrawTime(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = try Self.clean(reason, "The reason"), who = try Self.clean(actor, "Actor")
        try await write("cf_timew", caseID: caseID, actor: who, action: "timeWithdrawn", detail: why, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_time_assertions WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(id), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("time assertion")
            }
            try db.exec("UPDATE case_time_assertions SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    static func timeValue(start: Date?, end: Date?, precision: String?, qualifier: String?, relative: String?, zone: String?, text: String?) -> CaseTimeValue {
        CaseTimeValue(start: start, end: end, precision: precision.flatMap(Self.precision(named:)) ?? .unknown,
                      qualifier: qualifier.flatMap(CaseTimeQualifier.init(rawValue:)) ?? (start == nil ? .unknown : .stated),
                      relativeText: relative, timeZoneID: zone, originalText: text)
    }

    /// A record's times: the stored assertions, the times other records hold about it (derived, labelled as such), and the
    /// investigator's interpretations. Nothing is merged across kinds.
    public func times(caseID: UUID, recordKind: String, recordID: String) async throws -> CaseRecordTimes {
        let rid = recordID.lowercased()
        var a: [CaseTypedTime] = try await database.query("""
            SELECT id, case_id, record_kind, record_id, time_kind, start_at, end_at, precision, qualifier, relative_text, time_zone, original_text,
                   asserted_by_kind, asserted_by, source_version_id, locator, recorded_by, recorded_at, withdrawn_at
            FROM case_time_assertions WHERE case_id = ? AND record_kind = ? AND lower(record_id) = ? ORDER BY recorded_at, rowid;
            """, [.uuid(caseID), .text(recordKind), .text(rid)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let rk = r.string(2), let ri = r.string(3), let k = r.string(4).flatMap(CaseTypedTimeKind.init(rawValue:)),
                  let who = r.string(12).flatMap(CaseTimeAssertor.init(rawValue:)), let by = r.string(16), let at = r.date(17) else { return nil }
            return CaseTypedTime(id: id, caseID: c, recordKind: rk, recordID: ri, kind: k,
                                     value: Self.timeValue(start: r.date(5), end: r.date(6), precision: r.string(7), qualifier: r.string(8), relative: r.string(9), zone: r.string(10), text: r.string(11)),
                                     assertor: who, assertedBy: r.string(13), sourceVersionID: r.uuid(14), locator: r.string(15), recordedBy: by, recordedAt: at, withdrawnAt: r.date(18))
        }
        a += try await derivedTimes(caseID: caseID, recordKind: recordKind, recordID: rid)
        let i: [CaseTimeInterpretation] = try await database.query("""
            SELECT id, case_id, record_kind, record_id, time_kind, chosen_assertion_id, start_at, end_at, precision, time_zone, rationale, considered_json, decided_by, decided_at, withdrawn_at
            FROM case_time_interpretations WHERE case_id = ? AND record_kind = ? AND lower(record_id) = ? ORDER BY decided_at, rowid;
            """, [.uuid(caseID), .text(recordKind), .text(rid)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let rk = r.string(2), let ri = r.string(3), let k = r.string(4).flatMap(CaseTypedTimeKind.init(rawValue:)),
                  let why = r.string(10), let by = r.string(12), let at = r.date(13) else { return nil }
            let considered = ((try? JSONDecoder().decode([String].self, from: Data((r.string(11) ?? "[]").utf8))) ?? []).compactMap(UUID.init(uuidString:))
            return CaseTimeInterpretation(id: id, caseID: c, recordKind: rk, recordID: ri, kind: k, chosenAssertionID: r.uuid(5),
                                          value: Self.timeValue(start: r.date(6), end: r.date(7), precision: r.string(8), qualifier: nil, relative: nil, zone: r.string(9), text: nil),
                                          rationale: why, considered: considered, decidedBy: by, decidedAt: at, withdrawnAt: r.date(14))
        }
        return CaseRecordTimes(assertions: a, interpretations: i)
    }

    /// Times other records already hold about this one (the app's own record of import, receipt, submission and
    /// assignment, and a chronology entry's own date). Labelled derived; never stored twice.
    func derivedTimes(caseID: UUID, recordKind: String, recordID rid: String) async throws -> [CaseTypedTime] {
        var out: [CaseTypedTime] = []
        func add(_ k: CaseTypedTimeKind, _ v: CaseTimeValue, _ who: CaseTimeAssertor, _ by: String?, _ recorded: Date, _ recordedBy: String) {
            var t = CaseTypedTime(id: UUID(), caseID: caseID, recordKind: recordKind, recordID: rid, kind: k, value: v, assertor: who, assertedBy: by,
                                      sourceVersionID: nil, locator: nil, recordedBy: recordedBy, recordedAt: recorded, withdrawnAt: nil)
            t.derived = true
            out.append(t)
        }
        switch recordKind {
        case "journal":
            if let r = try await database.query("SELECT event_date, date_end, date_precision, date_qualifier, date_time_zone, date_text, author, created_at FROM case_journal WHERE case_id = ? AND lower(id) = ? AND entry_kind = 'chronology';",
                                                [.uuid(caseID), .text(rid)]).first, let at = r.date(7) {
                let v = Self.timeValue(start: r.date(0), end: r.date(1), precision: r.string(2), qualifier: r.string(3), relative: nil, zone: r.string(4), text: r.string(5))
                add(.occurrence, v, .investigator, r.string(6), at, r.string(6) ?? "")
            }
        case "document":
            if let r = try await database.query("SELECT intake_recorded_at, created_at FROM source_versions WHERE lower(id) = ?;", [.text(rid)]).first, let at = r.date(0) ?? r.date(1) {
                add(.import, CaseTimeValue(start: at, precision: .instant), .app, nil, at, "the app")
            }
        case "report":
            if let r = try await database.query("SELECT received_at, recorded_by, recorded_at FROM case_reports WHERE case_id = ? AND lower(id) = ?;", [.uuid(caseID), .text(rid)]).first,
               let at = r.date(2) {
                if let rec = r.date(0) { add(.receipt, CaseTimeValue(start: rec, precision: .day), .investigator, r.string(1), at, r.string(1) ?? "") }
            }
        case "task":
            if let r = try await database.query("SELECT submitted_at, submitted_by FROM case_action_contracts WHERE case_id = ? AND lower(task_id) = ?;", [.uuid(caseID), .text(rid)]).first,
               let at = r.date(0) {
                add(.submission, CaseTimeValue(start: at, precision: .instant), .app, r.string(1), at, r.string(1) ?? "the app")
            }
            for r in try await database.query("""
                SELECT r.recorded_at, r.actor, r.after_json FROM case_record_revisions r WHERE r.case_id = ? AND r.record_kind = 'task' AND r.record_id = ? AND r.change = 'taskAssigned' ORDER BY r.recorded_at;
                """, [.uuid(caseID), .text(rid)]) {
                guard let at = r.date(0) else { continue }
                add(.assignment, CaseTimeValue(start: at, precision: .instant), .app, r.string(1), at, r.string(1) ?? "")
            }
        default: break
        }
        return out
    }

    /// The investigator's interpretation of a competing time. The assertions are kept exactly; an earlier interpretation of
    /// the same record and kind is withdrawn (kept) in the same write.
    @discardableResult
    public func interpretTime(caseID: UUID, recordKind: String, recordID: String, kind: CaseTypedTimeKind, choosing chosen: UUID?, value: CaseTimeValue?,
                              considered: [UUID], rationale: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let why = try Self.clean(rationale, "The reason for the interpretation")
        let who = try Self.clean(actor, "Actor")
        guard !considered.isEmpty else { throw CaseTimeError.nothingConsidered }
        let rid = recordID.lowercased()
        let id = UUID()
        let consideredJSON = String(decoding: try JSONEncoder().encode(considered.map { $0.uuidString.lowercased() }.sorted()), as: UTF8.self)
        try await write("cf_timei", caseID: caseID, actor: who, action: "timeInterpreted", detail: "\(recordKind) \(kind.rawValue): \(why)", at: date) { db in
            var v = value
            for a in considered + (chosen.map { [$0] } ?? []) {
                guard let r = try db.query("SELECT start_at, end_at, precision, time_zone FROM case_time_assertions WHERE id = ? AND case_id = ? AND record_kind = ? AND lower(record_id) = ? AND time_kind = ? AND withdrawn_at IS NULL;",
                                           [.uuid(a), .uuid(caseID), .text(recordKind), .text(rid), .text(kind.rawValue)]).first else { throw CaseTimeError.assertionNotForRecord }
                if a == chosen, v == nil { v = Self.timeValue(start: r.date(0), end: r.date(1), precision: r.string(2), qualifier: nil, relative: nil, zone: r.string(3), text: nil) }
            }
            guard let v else { throw CaseTimeError.valueNeeded }
            try db.exec("""
                UPDATE case_time_interpretations SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = 'replaced by a later interpretation'
                WHERE case_id = ? AND record_kind = ? AND lower(record_id) = ? AND time_kind = ? AND withdrawn_at IS NULL;
                """, [.text(who), .date(date), .uuid(caseID), .text(recordKind), .text(rid), .text(kind.rawValue)])
            try db.exec("""
                INSERT INTO case_time_interpretations (id, case_id, record_kind, record_id, time_kind, chosen_assertion_id, start_at, end_at, precision, time_zone,
                    rationale, considered_json, decided_by, decided_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(recordKind), .text(rid), .text(kind.rawValue), chosen.map { .uuid($0) } ?? .null,
                      .optionalDate(v.start), .optionalDate(v.end), .text(v.precision.displayName), .optionalText(v.timeZoneID),
                      .text(why), .text(consideredJSON), .text(who), .date(date)])
        }
        return id
    }

    // MARK: Timelines (TIME-04)

    /// One record's timeline: its event times and its work history, from the canonical records.
    public func timeline(caseID: UUID, recordKind: String, recordID: String) async throws -> [CaseTimelineEntry] {
        let rid = recordID.lowercased()
        let t = try await times(caseID: caseID, recordKind: recordKind, recordID: rid).assertions.filter { !$0.derived }
        let revs = try await CaseRecordRevisions.revisions(database, caseID: caseID).filter { $0.recordKind == recordKind && $0.recordID.lowercased() == rid }
        let journal = recordKind == "journal" ? try await self.journal(caseID: caseID).filter { $0.id.uuidString.lowercased() == rid } : []
        return CaseTimeline.entries(times: t, revisions: revs, journal: journal)
    }

    /// The case timeline: the union of every record's timeline — the same entries, by the same ids.
    public func caseTimeline(caseID: UUID) async throws -> [CaseTimelineEntry] {
        let t: [CaseTypedTime] = try await database.query("SELECT DISTINCT record_kind, record_id FROM case_time_assertions WHERE case_id = ?;", [.uuid(caseID)])
            .compactMap { r -> (String, String)? in r.string(0).flatMap { k in r.string(1).map { (k, $0) } } }
            .asyncFlatMap { try await self.times(caseID: caseID, recordKind: $0.0, recordID: $0.1).assertions.filter { !$0.derived } }
        let revs = try await CaseRecordRevisions.revisions(database, caseID: caseID)
        return CaseTimeline.entries(times: t, revisions: revs, journal: try await journal(caseID: caseID))
    }

    // MARK: Assignment (TIME-01 / TIME-04 / TIME-07)

    /// Assign (or unassign) a case task. The task's before/after copy and the case action are written together, so the
    /// assignment is in the record's work history and in the sealed action log.
    public func reassignTask(caseID: UUID, taskID: UUID, to owner: String?, reason: String?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        let to = Self.blankToNil(owner)
        try await write("cf_assign", caseID: caseID, actor: who, action: "taskAssigned", detail: (to ?? "unassigned") + (Self.blankToNil(reason).map { " — \($0)" } ?? ""), at: date,
                        capture: .task(taskID)) { db in
            guard try !db.query("SELECT 1 FROM case_task_links WHERE case_id = ? AND task_id = ?;", [.uuid(caseID), .uuid(taskID)]).isEmpty else { throw CaseWorkError.notInCase("task") }
            try db.exec("UPDATE professional_tasks SET owner = ?, updated_at = ? WHERE id = ?;", [.optionalText(to), .date(date), .uuid(taskID)])
        }
    }

    // MARK: Ordering (TIME-08)

    public func recordingDeviceID() async throws -> String? {
        try await database.query("SELECT device_id FROM ledger_recording_device WHERE id = 1;", []).first?.string(0)
    }
}

extension Array {
    func asyncFlatMap<T>(_ f: (Element) async throws -> [T]) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out += try await f(e) }
        return out
    }
}

// MARK: - The journal entry's time value (TIME-02)

extension CaseJournalEntry {
    /// The entry's date as a time value: its precision, range or bound, time zone and the source's wording.
    public var timeValue: CaseTimeValue? {
        guard eventDate != nil || dateQualifier == .unknown else { return nil }
        return CaseTimeValue(start: eventDate, end: dateEnd, precision: datePrecision ?? .unknown,
                             qualifier: dateQualifier ?? (eventDate == nil ? .unknown : (dateEnd != nil ? .between : .stated)),
                             timeZoneID: dateTimeZone, originalText: dateText)
    }
}
