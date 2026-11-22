//
//  PDFPageRanges.swift
//  Kalsmritikosh
//
//  Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet.
//
//  A large PDF is split into PAGE RANGES, and each range is a work item of the parse stage: a range task
//  opens its OWN PDFDocument on the same bytes (PDFKit objects are never shared between tasks), reads the
//  native text of its pages and, for a page that needs it, renders and recognises it (the OCR stage
//  bounds the recognitions process-wide, so ranges of several documents share the Neural Engine fairly).
//  Results come back per page and are put together in page order by the caller, so the text, the block
//  ordinals and the page locators are exactly what the one-page-at-a-time loop produced.
//
//  Small documents (fewer pages than `minimumPagesToSplit`) and a parse width of 1 keep the single loop
//  on the caller's own document.
//

import Foundation
import os
#if canImport(PDFKit)
import PDFKit
#endif

nonisolated enum PDFPageRanges {
    /// Below this many pages one loop is quicker than opening the document again per range.
    static let minimumPagesToSplit = 8
    /// The fewest pages one range takes.
    static let minimumPagesPerRange = 4

    /// Where a range task opens its own copy of the document.
    enum Source: Sendable {
        case url(URL)
        case data(Data)
    }

    /// `0..<pageCount` cut into about `2 × width` ranges (so a slow range does not hold the others up),
    /// each at least `minimumPagesPerRange` pages.
    static func ranges(pageCount: Int, width: Int) -> [Range<Int>] {
        guard pageCount > 0 else { return [] }
        let pieces = max(1, min(pageCount / minimumPagesPerRange, max(1, width) * 2))
        let size = Int((Double(pageCount) / Double(pieces)).rounded(.up))
        return stride(from: 0, to: pageCount, by: max(1, size)).map { $0..<min(pageCount, $0 + max(1, size)) }
    }

    #if canImport(PDFKit)
    /// `work` for every page, by page index. Pages of one range run in order inside its task; ranges run
    /// concurrently up to the parse stage's live width. `document` is the caller's own (used for the
    /// single-loop path only — it never crosses into another task).
    static func mapPages<T: Sendable>(
        document: PDFDocument, source: Source,
        work: @escaping @Sendable (PDFPage, Int) async -> T
    ) async -> [Int: T] {
        let pageCount = document.pageCount
        let width = await PipelineStages.currentWidth(.parse)
        guard pageCount >= minimumPagesToSplit, width > 1 else {
            var out: [Int: T] = [:]
            for i in 0..<pageCount {
                guard let page = document.page(at: i) else { continue }
                out[i] = await work(page, i)
            }
            return out
        }
        let parts = ranges(pageCount: pageCount, width: width)
        KalsmritikoshLog.ingestion.info("PDFPageRanges: \(pageCount, privacy: .public) page(s) in \(parts.count, privacy: .public) range(s), up to \(width, privacy: .public) at a time")
        let perRange: [[Int: T]] = await StagedPipeline.map(parts, stage: .parse) { _, range in
            guard let own = open(source) else {
                KalsmritikoshLog.ingestion.error("PDFPageRanges: range \(range.lowerBound, privacy: .public)–\(range.upperBound, privacy: .public) could not reopen the document; those pages are read by the single loop")
                return [:]
            }
            var out: [Int: T] = [:]
            for i in range {
                if Task.isCancelled { break }
                guard let page = own.page(at: i) else { continue }
                out[i] = await work(page, i)
            }
            return out
        }
        var merged: [Int: T] = [:]
        for part in perRange { merged.merge(part) { a, _ in a } }
        // A range that could not reopen the document: its pages are read here, on the caller's copy.
        if merged.count < pageCount, !Task.isCancelled {
            for i in 0..<pageCount where merged[i] == nil {
                guard let page = document.page(at: i) else { continue }
                merged[i] = await work(page, i)
            }
        }
        return merged
    }

    /// A fresh PDFDocument on the source's bytes, unlocked with the empty password when it opens locked
    /// (the caller has already established that the empty password opens it).
    private static func open(_ source: Source) -> PDFDocument? {
        let doc: PDFDocument?
        switch source {
        case .url(let u): doc = PDFDocument(url: u)
        case .data(let d): doc = PDFDocument(data: d)
        }
        guard let doc else { return nil }
        if doc.isLocked, !doc.unlock(withPassword: "") { return nil }
        return doc
    }
    #endif
}
