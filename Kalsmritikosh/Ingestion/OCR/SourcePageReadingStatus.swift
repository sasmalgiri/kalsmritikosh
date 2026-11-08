//
//  SourcePageReadingStatus.swift
//  Kalsmritikosh
//
//  Smart-map SRC-05 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05): how each page of a source
//  version was read, so uncertain or unread pages lead to a retry and to the original instead of passing as
//  "read". Measured from the ledger: the ACTIVE evidence blocks of the version (their page locator, extraction
//  method and confidence), the page count the reader recorded, and the structural readiness dimension.
//
//  A page with no text is NEVER evidence that the original holds nothing relevant: it may be a photograph, a
//  stamp, handwriting or a recognition failure. Every unread or uncertain page says so and names the two
//  remedies — re-read the document, or open the original and look.
//

import Foundation

public nonisolated enum PageReadingState: String, Sendable, Equatable, CaseIterable {
    /// Text read from the document's own text layer.
    case read
    /// Text recognised from an image of the page (OCR) — may contain misread characters.
    case recognizedUncertain
    /// A text layer exists but looked garbled and recognition did not replace it — low confidence.
    case garbledText
    /// Nothing was read from this page (blank, a picture, handwriting, or a failed recognition).
    case noTextFound

    public var label: String {
        switch self {
        case .read: return "Read"
        case .recognizedUncertain: return "Recognised from an image — check against the original"
        case .garbledText: return "Text looked garbled — check against the original"
        case .noTextFound: return "No text found — not proof the page is blank"
        }
    }

    /// Whether the page may hold material the text does not show.
    public var mayHoldUnreadMaterial: Bool { self != .read }
}

public nonisolated struct PageReadingStatus: Sendable, Equatable, Identifiable {
    public let page: Int
    public let state: PageReadingState
    public let blockCount: Int
    /// The lowest extraction confidence among the page's blocks (nil when it has none).
    public let lowestConfidence: Double?
    public var id: Int { page }
}

/// Why a version has no page-level account at all.
public nonisolated enum SourceReadingLimit: String, Sendable, Equatable {
    /// The version was never read into structure (failed, protected, unsupported or still pending).
    case notRead
    /// The reader did not record a page count, so unread pages cannot be listed one by one.
    case pageCountUnknown
}

public nonisolated struct SourceReadingReport: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let filename: String
    /// Pages the reader recorded (nil when unknown).
    public let pageCount: Int?
    public let pages: [PageReadingStatus]
    public let limit: SourceReadingLimit?
    /// The structural readiness state + condition as recorded ("failed", "blocked/encrypted", …), for the
    /// not-read explanation.
    public let structuralState: String?

    /// The pages that may hold unread material.
    public var uncertainOrUnread: [PageReadingStatus] { pages.filter(\.state.mayHoldUnreadMaterial) }

    /// Whether the investigator should re-read or inspect the original.
    public var needsAttention: Bool { limit != nil || !uncertainOrUnread.isEmpty }

    /// The one sentence a search receipt, the map or the inspector shows. Never claims absence.
    public var disclosure: String? {
        if limit == .notRead {
            return "\(filename) was not read (\(structuralState ?? "no text recorded")). Its contents are unknown — finding nothing in it proves nothing. Re-read it or open the original."
        }
        let none = pages.filter { $0.state == .noTextFound }.map(\.page)
        let unsure = pages.filter { $0.state == .recognizedUncertain || $0.state == .garbledText }.map(\.page)
        var parts: [String] = []
        if !none.isEmpty { parts.append("no text was found on \(Self.pageList(none))") }
        if !unsure.isEmpty { parts.append("\(Self.pageList(unsure)) \(unsure.count == 1 ? "was" : "were") read with low certainty (recognised from an image, or garbled) and may contain misread words") }
        if parts.isEmpty {
            return limit == .pageCountUnknown
                ? "\(filename): the reader did not record its page count, so a page with no text would not be listed. Open the original to be sure."
                : nil
        }
        return "\(filename): " + parts.joined(separator: "; ") + ". That is not proof the original holds nothing relevant — re-read the document or open the original to check."
    }

    static func pageList(_ pages: [Int]) -> String {
        let shown = pages.prefix(12).map(String.init).joined(separator: ", ")
        let more = pages.count > 12 ? " and \(pages.count - 12) more" : ""
        return (pages.count == 1 ? "page " : "pages ") + shown + more
    }
}

public nonisolated struct SourcePageReadingService: Sendable {
    private let database: Database
    /// OCR text at or above this confidence is still OCR (recognised, not native) — it is always reported as
    /// recognised; native text below `garbledBelow` is the reader's "kept but garbled" marker.
    public static let garbledBelow = 0.5

    public init(database: Database) { self.database = database }

    public func report(sourceVersionID: UUID) async throws -> SourceReadingReport {
        guard let v = try await database.query("""
            SELECT sv.filename, sv.detected_type, sd.metadata,
                   (SELECT state || COALESCE('/' || condition, '') FROM source_readiness_dimensions
                     WHERE source_version_id = sv.id AND dimension = 'structuralExtraction' LIMIT 1)
              FROM source_versions sv LEFT JOIN source_documents sd ON sd.id = sv.document_id
             WHERE sv.id = ? LIMIT 1;
            """, [.uuid(sourceVersionID)]).first else {
            throw SourceProvenanceError.versionNotFound(sourceVersionID)
        }
        let filename = v.string(0) ?? "source"
        let type = SourceType(rawValue: v.string(1) ?? "") ?? .unknown
        let structural = v.string(3)
        var pageCount = Self.pageCount(fromMetadata: v.string(2))
        if pageCount == nil, type.category == .image { pageCount = 1 }   // an image is one page

        let rows = try await database.query("""
            SELECT locator, extraction_method, extraction_confidence, raw_text FROM evidence_blocks
             WHERE source_version_id = ? AND superseded_by_run IS NULL ORDER BY ordinal;
            """, [.uuid(sourceVersionID)])
        guard !rows.isEmpty else {
            return SourceReadingReport(sourceVersionID: sourceVersionID, filename: filename, pageCount: pageCount,
                                       pages: pageCount.map { n in (1...max(1, n)).map { PageReadingStatus(page: $0, state: .noTextFound, blockCount: 0, lowestConfidence: nil) } } ?? [],
                                       limit: .notRead, structuralState: structural)
        }
        // Per page: block count, whether any block is native-and-confident, OCR, or garbled.
        nonisolated struct Tally { var count = 0; var native = 0; var ocr = 0; var garbled = 0; var lowest: Double? = nil }
        var byPage: [Int: Tally] = [:]
        var unpaged = 0
        for r in rows {
            // A block with no text (an image's container block, an empty table cell row) reads nothing.
            guard !(r.string(3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let confidence = r.double(2) ?? 0
            // A one-page source (a photo, a single scanned page) owns blocks that carry no page locator.
            guard let page = SourceProvenanceChainService.page(fromLocator: r.string(0)) ?? (pageCount == 1 ? 1 : nil) else {
                unpaged += 1; continue
            }
            var t = byPage[page] ?? Tally()
            t.count += 1
            t.lowest = min(t.lowest ?? confidence, confidence)
            switch r.string(1) ?? "" {
            case "ocr": t.ocr += 1
            default: if confidence < Self.garbledBelow { t.garbled += 1 } else { t.native += 1 }
            }
            byPage[page] = t
        }
        // A document whose blocks carry no page locator (a text file, an email) has no page account to give.
        if byPage.isEmpty, pageCount == nil {
            return SourceReadingReport(sourceVersionID: sourceVersionID, filename: filename, pageCount: nil, pages: [],
                                       limit: unpaged > 0 ? nil : .pageCountUnknown, structuralState: structural)
        }
        let lastPage = max(pageCount ?? 0, byPage.keys.max() ?? 0)
        let pages: [PageReadingStatus] = (1...max(1, lastPage)).map { p in
            guard let t = byPage[p] else { return PageReadingStatus(page: p, state: .noTextFound, blockCount: 0, lowestConfidence: nil) }
            let state: PageReadingState = t.ocr > 0 ? .recognizedUncertain : (t.garbled > 0 ? .garbledText : .read)
            return PageReadingStatus(page: p, state: state, blockCount: t.count, lowestConfidence: t.lowest)
        }
        return SourceReadingReport(sourceVersionID: sourceVersionID, filename: filename, pageCount: pageCount, pages: pages,
                                   limit: pageCount == nil ? .pageCountUnknown : nil, structuralState: structural)
    }

    /// The reader's recorded page count in the source document metadata (`{"pageCount": …}`), when present.
    nonisolated static func pageCount(fromMetadata json: String?) -> Int? {
        guard let json, let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let value = meta["pageCount"]?.value else { return nil }
        switch value {
        case .int(let n): return Int(n)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
}
