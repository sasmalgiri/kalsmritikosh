//
//  KeysetCursor.swift
//  Kalsmritikosh
//
//  Speed PERF-23 (owner 2026-11-23) — not tested yet. The position after the last row of a page
//  that is ordered by a REAL sort column (a date stored as seconds) with the row's id as the
//  tiebreak. A pager reads `WHERE (sort, id) > (?, ?)` (or `<` for a descending order) instead
//  of `LIMIT ? OFFSET ?`, so page N costs the same as page 1 and rows written between pages
//  never shift the window.
//

import Foundation

public nonisolated struct KeysetCursor: Sendable, Hashable {
    /// The sort column's stored value (seconds since 1970 for dates).
    public let sortKey: Double
    /// The row's id, the tiebreak inside one sort value.
    public let id: UUID
    /// Speed test phase (PERF-23, 2026-11-23): the id exactly as the row stores it. The tiebreak compares stored TEXT, so
    /// a row written with a lower-case id must be compared in that form: re-binding `id.uuidString` (upper case) made
    /// every lower-case id inside the same sort value compare greater again, so the next page repeated them (an
    /// endless walk when a whole page shared one date). nil = the canonical upper-case form.
    public let storedID: String?

    public init(sortKey: Double, id: UUID, storedID: String? = nil) {
        self.sortKey = sortKey
        self.id = id
        self.storedID = storedID
    }

    public init(date: Date, id: UUID) {
        self.init(sortKey: date.timeIntervalSince1970, id: id)
    }
}

extension KeysetCursor {
    /// The cursor after `row`, read from its RAW stored values (never a decoded `Date`, whose
    /// round trip through the reference-date epoch can move the value by an ulp and skip a tie).
    nonisolated static func after(_ row: SQLRow?, sortColumn: Int, idColumn: Int) -> KeysetCursor? {
        guard let row, let id = row.uuid(idColumn) else { return nil }
        let key: Double
        if let d = row.double(sortColumn) { key = d } else if let i = row.int(sortColumn) { key = Double(i) } else { return nil }
        return KeysetCursor(sortKey: key, id: id, storedID: row.string(idColumn))
    }

    /// Binds for `(sort, id) > (?, ?)` / `< (?, ?)` — the id in its stored form.
    nonisolated var binds: [SQLValue] { [.real(sortKey), .text(storedID ?? id.uuidString)] }
}

/// Speed PERF-23 (owner 2026-11-23) — not tested yet. One keyset page: the decoded rows, the cursor
/// after the last RAW row (so an undecodable tail row never stalls the walk) and how many raw rows
/// the query returned (a full page means "there may be more").
public nonisolated struct KeysetPage<Row: Sendable>: Sendable {
    public let rows: [Row]
    public let next: KeysetCursor?
    public let rawCount: Int

    public init(rows: [Row], next: KeysetCursor?, rawCount: Int) {
        self.rows = rows
        self.next = next
        self.rawCount = rawCount
    }

    /// True when the query filled the page (another page may follow).
    public func isFull(_ pageSize: Int) -> Bool { rawCount >= pageSize && next != nil }
}
