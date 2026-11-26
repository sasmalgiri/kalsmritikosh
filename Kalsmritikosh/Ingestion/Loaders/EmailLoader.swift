//
//  EmailLoader.swift
//  Kalsmritikosh
//
//  EML / .emlx → one KO per file. MBOX → one KO per message (T13.1
//  paid off the M5 debt). PST / MSG land in Gate 3 via GS-MAIL —
//  they require third-party decoders or AppKit-level Mail.app access.
//
//  Header parsing pulls From / To / Cc / Date out of structured fields
//  and emits them as high-confidence Entity rows on the KO (T13.2);
//  routing headers (Received, Message-ID, Return-Path, DKIM, SPF, X-*,
//  server names) never reach NER because the loader only prepends the
//  human-relevant headers (From / To / Cc / Subject / Date) to the
//  body that gets chunked.
//

import Foundation
import CryptoKit
import os

public struct EmailLoader: StreamingIngestor {
    public let supportedTypes: Set<SourceType> = [.eml, .mbox, .pst, .msg, .appleMail, .nsf]
    // .eml + .msg = cheap CPU MIME parsing. .pst / .nsf are rare and
    // big but still single-file workloads — they don't benefit from
    // parallel scheduling against themselves. Pick .cpu since that's
    // the heavy hitter on real corpora (Gmail Takeout = thousands of
    // .eml files, no PST/NSF).
    public let primaryLane: ResourceLane = .cpu

    /// Move-A feature flag. When `true`, mbox ingest emits one KO per
    /// reply-chain thread via ThreadCoalescer. When `false` (default),
    /// mbox ingest emits one KO per message — the pre-Move-A path that
    /// the 435 MB production DB was built with.
    ///
    /// Held at `false` until the per-message extraction fanout lands
    /// in `IngestCoordinator.processKnowledgeObject` so events,
    /// mentions, and memory subjects don't degrade on thread KOs.
    /// Flip to `true` only when the fanout is in place AND a fresh
    /// re-ingest is acceptable. ThreadCoalescer.swift stays in the
    /// tree either way — the helper is ready when we are.
    /// Move A — collapse a reply chain into one KO per thread.
    /// Defaults ON since IN-22 (2026-11-22; was OFF, the pre-Move-A behavior). The
    /// user can flip via UserDefaults key
    /// `"kalsmritikosh.moveA.threadCoalescing"` (Settings → Privacy
    /// & ingestion → Coalesce email threads), no rebuild required.
    ///
    /// Pre-flip checklist (documented for reuse):
    ///   1. ThreadCoalescer's 14-day subject-fallback window is
    ///      validated against the user's real archive (over-merge
    ///      bug from prior 180-day window is fixed)
    ///   2. A fresh re-ingest of the affected mailbox is acceptable
    ///      — Move A changes the KO shape, so the file-hash dedup
    ///      will re-extract messages even though file rows already
    ///      exist
    ///   3. Downstream IngestCoordinator.processKnowledgeObject
    ///      fanout (entity / event / mention extraction over the
    ///      thread KO body, not per-message) is healthy — currently
    ///      tested by smoke; the per-thread KOs produce richer
    ///      memory_objects at the cost of slightly larger chunks.
    public nonisolated static var threadCoalescingEnabled: Bool {
        // Unified path IN-22 (owner 2026-11-22) — not tested yet. ON by default (reply chains merged into one
        // document per thread); a person's explicit OFF is kept.
        (AppDefaults.store.object(forKey: "kalsmritikosh.moveA.threadCoalescing") as? Bool) ?? true
    }

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .eml:
            return try ingestEML(at: url)
        case .mbox:
            // For a single-KO entry point, keep the legacy concatenated
            // KO so any caller that doesn't use `ingestMany` still gets
            // something coherent. The modern path (IngestCoordinator)
            // uses `ingestMany` so it gets per-message KOs.
            return try ingestMBOX(at: url)
        case .appleMail:
            return try ingestAppleEMLX(at: url)
        case .msg:
            // G4.9 — native Outlook .msg parsing via OLE2 + MAPI.
            // Previously fell through to the binary stub.
            return try ingestMSG(at: url)
        case .pst:
            // G4.9 — PST is many-messages-per-file. The single-KO
            // entry point only used by callers that don't iterate
            // via ingestMany; collapse all messages into one KO so
            // they still get something coherent.
            return try ingestPSTConcatenated(at: url)
        case .nsf:
            // G4.9 — Lotus Notes NSF: same many-per-file shape as PST,
            // same legacy single-KO fallback strategy.
            return try ingestNSFConcatenated(at: url)
        default:
            return try binaryStub(at: url, type: type)
        }
    }

    /// T13.1 — mbox produces one KO per message; other formats fall
    /// through to the single-KO path. G4.9 — PST and NSF are also
    /// per-message.
    public func ingestMany(fileAt url: URL, type: SourceType) async throws -> [KnowledgeObject] {
        if type == .mbox {
            // Speed PERF-35 (owner 2026-11-23): a mapped mailbox (big enough for a piece map) reuses the previous
            // version's decodes of the messages inside unchanged pieces; only messages touching changed pieces are parsed.
            if let pieces = PieceMaps.reading, pieces.isMapped {
                return try await ingestMBOXAsMessagesReusingPieces(at: url, coalesce: Self.threadCoalescingEnabled, context: pieces)
            }
            return try ingestMBOXAsMessages(at: url)
        }
        if type == .pst {
            return try ingestPSTAsMessages(at: url)
        }
        if type == .nsf {
            return try ingestNSFAsMessages(at: url)
        }
        return [try await ingest(fileAt: url, type: type)]
    }

    /// F01 — every many-record mail format streams: per-message mbox, thread-coalesced mbox (a
    /// header-only grouping pass, then one thread's bodies at a time), PST and NSF (one message /
    /// note parsed at a time from the mapped file).
    public nonisolated func streamsRecords(type: SourceType) -> Bool {
        type == .mbox || type == .pst || type == .nsf
    }

    /// F01 — the per-message mbox path, one message at a time: the file stays memory-mapped,
    /// only boundary offsets are held, and each message is decoded, built and batched in turn.
    /// Emits exactly what `ingestMany` returns (same order, same `messageIndex`).
    public func streamRecords(fileAt url: URL, type: SourceType, budget: StreamBatchBudget,
                              emit: ([KnowledgeObject]) async throws -> Void) async throws {
        guard streamsRecords(type: type) else {
            let all = try await ingestMany(fileAt: url, type: type)
            var batcher = KnowledgeObjectBatcher(budget: budget)
            for ko in all { if let batch = batcher.add(ko) { try await emit(batch) } }
            if let rest = batcher.drain() { try await emit(rest) }
            return
        }
        var batcher = KnowledgeObjectBatcher(budget: budget)
        switch type {
        case .pst:
            // W0-1 — one autorelease pool per record (see streamMbox: the loop is one job).
            for msg in try pstMessageIterator(at: url) {
                let ko = autoreleasepool { buildKO(fromPSTMessage: msg, source: url) }
                if let ko, let batch = batcher.add(ko) { try await emit(batch) }
            }
            if let rest = batcher.drain() { try await emit(rest) }
            return
        case .nsf:
            for note in try nsfNoteIterator(at: url) where note.isMailNote {
                let ko = autoreleasepool { buildKO(fromNSFNote: note, source: url) }
                if let ko, let batch = batcher.add(ko) { try await emit(batch) }
            }
            if let rest = batcher.drain() { try await emit(rest) }
            return
        default:
            break
        }
        try await streamMbox(at: url, budget: budget, coalesce: Self.threadCoalescingEnabled, emit: emit)
    }

    /// F01 — the mbox stream, either mode. Emits exactly what `ingestMBOXAsMessages(at:coalesce:)`
    /// returns, in the same order.
    func streamMbox(at url: URL, budget: StreamBatchBudget, coalesce: Bool,
                    emit: ([KnowledgeObject]) async throws -> Void) async throws {
        var batcher = KnowledgeObjectBatcher(budget: budget)
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // F12 — thread coalescing groups across the whole mailbox, so its plan (headers + byte range
        // per message, never bodies) is held in memory; above `maxCoalescedPlanMessages` that plan is
        // not built and the mailbox streams per message instead — every message is still committed.
        // Speed PERF-26 (owner 2026-11-23) — not tested yet: the mailbox is scanned for boundaries ONCE (was a counting
        // pass and then a boundary pass); the count is the boundary list's length.
        let coalesceBoundaries: [Int]? = coalesce ? Self.mboxBoundaries(data) : nil
        // Speed PERF-35 torrent (owner 2026-11-23) — not tested yet. The message starts this version has are kept with its
        // piece map; message ranges inside pieces unchanged since the previous version are taken from that version's
        // index instead of being scanned for again.
        let pieceContext = PieceMaps.reading
        let proven = pieceContext?.delta.map(PieceMap.provenRecords) ?? [:]
        if let coalesceBoundaries { pieceContext?.noteRecordStarts(Array(coalesceBoundaries.dropLast())) }
        if let coalesceBoundaries, coalesceBoundaries.count - 1 <= Self.maxCoalescedPlanMessages {
            let plan = mboxThreadPlan(data: data, boundaries: coalesceBoundaries, url: url)
            for thread in plan.threads {
                let ko = autoreleasepool { threadKO(thread, plan: plan, data: data, url: url) }
                if let ko, let batch = batcher.add(ko) { try await emit(batch) }
            }
            if let rest = batcher.drain() { try await emit(rest) }
            return
        } else if coalesce {
            KalsmritikoshLog.ingestion.notice("mbox \(url.lastPathComponent, privacy: .private): more than \(Self.maxCoalescedPlanMessages, privacy: .public) messages — streamed per message (thread plan not built)")
        }
        // Per message: boundaries are walked one at a time (O(1) bookkeeping), never collected beyond one window.
        // Speed PERF-26 (owner 2026-11-23) — not tested yet. Message ranges are processed in parallel: the boundary walk
        // stays one single pass, gathering a window of up to 256 messages; the window's messages are decoded on several
        // cores at once (work stealing — long and short messages balance), then numbered in mailbox order, then built
        // into records on several cores, and emitted in order. Same records, same order, same `messageIndex`.
        let width = max(1, await PipelineStages.currentWidth(.parse))
        var pieceIndex = 0
        var start = 0
        let window = 256
        struct Slice { let start: Int; let end: Int; let cutEnd: Int; let oversized: Bool }
        while start < data.count {
            var slices: [Slice] = []
            slices.reserveCapacity(window)
            var reused = 0
            while start < data.count, slices.count < window {
                let end: Int
                if let known = proven[start], known <= data.count { end = known; reused += 1 } else { end = Self.nextMboxBoundary(data, after: start) }
                // W2-8 — a message larger than the per-record budget is read by byte range: only its
                // leading part (cut at a line end) is ever decoded, so memory stays flat; the record says
                // exactly which bytes it holds. One record per message either way (positions unchanged).
                var cutEnd = end
                let oversized = end - start > budget.maxRecordBytes && ProductModuleFlags.isEnabled(.byteRangeItems)
                if oversized { cutEnd = Self.lineCut(data, from: start, maxBytes: budget.maxRecordBytes) }
                slices.append(Slice(start: start, end: end, cutEnd: cutEnd, oversized: oversized))
                start = end
            }
            pieceContext?.noteRecordStarts(slices.map(\.start))
            if reused > 0 { KalsmritikoshLog.ingestion.debug("mbox: \(reused, privacy: .public) message range(s) from the previous version's index (unchanged pieces)") }
            // 1. Decode every slice (W0-1 — each inside its own autorelease pool).
            let pieces = Self.parallelMap(count: slices.count, width: width) { i -> String? in
                autoreleasepool { Self.mboxPiece(data, from: slices[i].start, to: slices[i].cutEnd) }
            }
            // 2. Number the pieces in mailbox order (a blank slice is not a message).
            var indexOf = [Int?](repeating: nil, count: slices.count)
            for i in slices.indices where pieces[i] != nil { indexOf[i] = pieceIndex; pieceIndex += 1 }
            // 3. Build the records.
            let builder = self
            let built = Self.parallelMap(count: slices.count, width: width) { i -> KnowledgeObject? in
                guard let piece = pieces[i], let idx = indexOf[i] else { return nil }
                return autoreleasepool { builder.perMessageKO(from: piece, index: idx, url: url) }
            }
            for (i, sl) in slices.enumerated() {
                guard var ko = built[i] else { continue }
                if sl.oversized {
                    var meta = ko.metadata
                    meta["byteRangeStart"] = AnyCodable(.int(Int64(sl.start)))
                    meta["byteRangeEnd"] = AnyCodable(.int(Int64(sl.cutEnd)))
                    meta["recordTotalBytes"] = AnyCodable(.int(Int64(sl.end - sl.start)))
                    meta["partialReason"] = AnyCodable(.string(
                        "Only bytes \(sl.start)–\(sl.cutEnd) of this message (\(sl.end - sl.start) bytes) are read; the whole message is kept with custody."))
                    ko = KnowledgeObject(id: ko.id, sourceFile: ko.sourceFile, sourceType: ko.sourceType,
                                         content: String(ko.content.utf8.prefix(budget.maxRecordBytes)) ?? ko.content,
                                         metadata: meta, entities: ko.entities, events: ko.events,
                                         relationships: ko.relationships, summaries: ko.summaries,
                                         confidence: ko.confidence, createdAt: ko.createdAt, updatedAt: ko.updatedAt)
                }
                if let batch = batcher.add(ko) { try await emit(batch) }
            }
        }
        if let rest = batcher.drain() { try await emit(rest) }
    }

    /// Speed PERF-26 (owner 2026-11-23) — not tested yet. `body(i)` for i in 0..<count on `width` threads with work
    /// stealing; results in index order.
    nonisolated static func parallelMap<R>(count: Int, width: Int, _ body: (Int) -> R) -> [R] {
        guard count > 0 else { return [] }
        if width <= 1 || count == 1 { return (0..<count).map(body) }
        let results = OSAllocatedUnfairLock(uncheckedState: [R?](repeating: nil, count: count))
        do {
            try WorkStealingQueue.perform(count: count, workers: width) { i in
                let r = body(i)
                results.withLockUnchecked { $0[i] = r }
            }
        } catch {
            KalsmritikoshLog.ingestion.error("EmailLoader: parallel decode stopped: \(error.localizedDescription, privacy: .public)")
        }
        let all = results.withLockUnchecked { $0 }
        // Every index is claimed exactly once while no error stops the workers (`body` cannot throw).
        return all.indices.map { all[$0] ?? body($0) }
    }

    /// F12 — above this many messages a thread-coalesced stream falls back to per-message records
    /// (the thread plan is the one cross-message structure the stream must hold).
    nonisolated static let maxCoalescedPlanMessages = 250_000

    /// The next message start strictly after `start` (a "\nFrom " line), or `data.count` — the same
    /// boundaries `mboxBoundaries` returns, found one at a time.
    nonisolated static func nextMboxBoundary(_ data: Data, after start: Int) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return raw.count }
            let count = raw.count
            var i = start
            while i + 6 <= count {
                if base[i] == 0x0A, base[i+1] == 0x46, base[i+2] == 0x72, base[i+3] == 0x6F, base[i+4] == 0x6D, base[i+5] == 0x20 {
                    return i + 1
                }
                i += 1
            }
            return count
        }
    }

    /// How many message slices the mailbox holds, counted without storing their offsets.
    nonisolated static func countMboxMessages(_ data: Data) -> Int {
        var n = 0, start = 0
        while start < data.count { start = nextMboxBoundary(data, after: start); n += 1 }
        return n
    }

    /// Byte offsets of every mbox message start, plus a final `data.count` sentinel.
    /// Byte-level scan for "\nFrom " — see `ingestMBOXAsMessages` for why not `components`.
    nonisolated static func mboxBoundaries(_ data: Data) -> [Int] {
        let separator: [UInt8] = [0x0A, 0x46, 0x72, 0x6F, 0x6D, 0x20]
        var boundaries: [Int] = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var i = 0
            // Treat the leading "From " (no preceding \n) as a synthetic boundary.
            if count >= 5 && base[0] == 0x46 && base[1] == 0x72 && base[2] == 0x6F && base[3] == 0x6D && base[4] == 0x20 {
                // boundaries already includes 0.
                i = 5
            }
            while i + separator.count <= count {
                if base[i] == 0x0A &&
                   base[i+1] == 0x46 && base[i+2] == 0x72 && base[i+3] == 0x6F &&
                   base[i+4] == 0x6D && base[i+5] == 0x20 {
                    // Message body for the NEXT piece starts at i+1 (skip the \n).
                    boundaries.append(i + 1)
                    i += separator.count
                } else {
                    i += 1
                }
            }
        }
        boundaries.append(data.count)
        return boundaries
    }

    /// One mbox message's trimmed text, or nil when the slice is blank.
    /// W2-8 — the last line end at or before `start + maxBytes` (never splits a line or a UTF-8 sequence).
    nonisolated static func lineCut(_ data: Data, from start: Int, maxBytes: Int) -> Int {
        let limit = min(data.count, start + maxBytes)
        var i = limit
        while i > start + maxBytes / 2 {
            if data[data.startIndex + i - 1] == 0x0A { return i }
            i -= 1
        }
        // No line end in the second half: back off to a UTF-8 character boundary.
        var j = limit
        while j > start, (data[data.startIndex + j - 1] & 0xC0) == 0x80 { j -= 1 }
        if j > start, data[data.startIndex + j - 1] >= 0xC0 { j -= 1 }
        return j
    }

    nonisolated static func mboxPiece(_ data: Data, from start: Int, to end: Int) -> String? {
        let slice = data[(data.startIndex + start)..<(data.startIndex + end)]
        let messageString = String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
        let trimmed = messageString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Apple Mail's `.emlx` is "<decimal byte length>\n<RFC822 message>\n
    /// <optional Apple plist trailer>". We peel the length prefix and the
    /// trailer, then delegate to the EML path.
    private func ingestAppleEMLX(at url: URL) throws -> KnowledgeObject {
        let raw: Data
        // Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet: C-6 size cap.
        try PlainTextSizeCap.check(url, kind: "emlx")
        // Speed PERF-24 (owner 2026-11-23) — not tested yet: a memory-mapped read (pages in on demand), not a heap copy.
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
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
        let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
            headers: headers,
            body: body,
            for: url
        )
        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(textBody)
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))
        if let json = Self.encodeAttachmentURLs(attachmentURLs) {
            meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
        }

        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        headerLines += Self.exportNameLines(headers)
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody

        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }
        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .appleMail,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// Exchange-style exports keep the people's names only in X-From / X-To ("From:
    /// pete.davis@enron.com", "X-From: Schedule Crawler"): kept as lines of their own, so a question
    /// that names the person finds the message.
    nonisolated static func exportNameLines(_ headers: [String: String]) -> [String] {
        [("x-from", "X-From", "from"), ("x-to", "X-To", "to")].compactMap { key, label, plain in
            guard let value = headers[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != headers[plain] else { return nil }
            return "\(label): \(String(value.prefix(600)))"
        }
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

        // T13.7 — If the message is multipart, hand only the decoded
        // text part to the chunker and stage attachments for recursive
        // ingest. Raw base64 / MIME bytes NEVER reach NER or chunking.
        let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
            headers: headers,
            body: body,
            for: url
        )

        // T7 — Strip quoted regions before chunking. Stored bytes-removed
        // metric flows into the completeness report.
        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(textBody)
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))
        if let json = Self.encodeAttachmentURLs(attachmentURLs) {
            meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
        }

        // Prepend the human-relevant headers (From / To / Cc / Subject / Date)
        // so the entity extractor + summarizer see the participants and topic.
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        headerLines += Self.exportNameLines(headers)
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody
        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .eml,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// T13.1 — split an mbox file by `From ` separators and return one
    /// fully-populated KnowledgeObject per message. Each per-message KO
    /// carries its own structured From/To/Cc/Date entities (T13.2) and
    /// goes through the standard chunker / NER / event-extraction
    /// pipeline from IngestCoordinator independently.
    /// `coalesce` defaults to the user's Move-A setting; tests pass it explicitly rather than
    /// flipping a real preference.
    /// Speed PERF-35 (owner 2026-11-23): the whole-file mbox parse (both modes) with the piece map paying off. The
    /// previous version's decodes of the messages proven unchanged (both ends inside the unchanged prefix, fingerprint
    /// kept with its map) are fetched in one query and used instead of decoding those messages again; every other message
    /// is decoded, and its decode kept under the SHA-256 of its bytes for the next version. Gives exactly the documents a
    /// plain parse gives.
    func ingestMBOXAsMessagesReusingPieces(at url: URL, coalesce: Bool, context: PieceMaps.Context) async throws -> [KnowledgeObject] {
        let cache = ContentResults.current
        let origin = ContentResults.origin
        var proven: [Int: Int] = [:]
        var known: [Int: String] = [:]
        var kept: [Int: MboxDecodeReuse.Decoded] = [:]
        if let delta = context.delta {
            proven = PieceMap.provenRecords(delta)
            for start in proven.keys { if let d = delta.previousRecordDigests[Int64(start)] { known[start] = d } }
            if let cache, !known.isEmpty {
                let payloads = await cache.lookupMany(digests: Array(Set(known.values)), kind: .mailMessage,
                                                      producer: MboxDecodeReuse.producer, origin: origin)
                for (start, digest) in known {
                    if let p = payloads[digest], let d = MboxDecodeReuse.decode(p) { kept[start] = d }
                }
            }
        }
        let reuse = MboxDecodeReuse(proven: proven, kept: kept, knownDigests: known)
        let objects = try ingestMBOXAsMessages(at: url, coalesce: coalesce, reuse: reuse)
        context.noteRecordStarts(reuse.starts)
        context.noteRecordDigests(reuse.digests)
        context.noteMessages(parsed: reuse.parsed, reused: reuse.reused)
        if let cache {
            await cache.storeMany(reuse.fresh, kind: .mailMessage, producer: MboxDecodeReuse.producer, origin: origin)
        }
        KalsmritikoshLog.ingestion.info("mbox: \(reuse.reused, privacy: .public) message decode(s) reused from the previous version (unchanged pieces), \(reuse.parsed, privacy: .public) parsed")
        return objects
    }

    func ingestMBOXAsMessages(at url: URL, coalesce: Bool = EmailLoader.threadCoalescingEnabled,
                              reuse: MboxDecodeReuse? = nil) throws -> [KnowledgeObject] {
        // Byte-level scan for "\nFrom " message boundaries. Avoids the
        // String.components(separatedBy:) path that silently flattens
        // very large mbox files (~94MB observed: 525 boundaries seen by
        // /bin/grep, but `components` returned a 1-element array,
        // melting the whole archive into one giant KO). Reading as Data
        // keeps the file out of Swift String's bridging-heavy
        // representation while we look for the 6-byte separator
        // 0x0A 'F' 'r' 'o' 'm' ' '.
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        let boundaries = Self.mboxBoundaries(data)
        // Move-A switch — when the flag is OFF (default), emit one KO
        // per message (the pre-Move-A path that the 435 MB production
        // DB was built with). When ON, fall through to the thread
        // coalescer below.
        reuse?.noteStarts(Array(boundaries.dropLast()))
        if !coalesce {
            if let reuse {
                // Speed PERF-35: the same records as below, each message decoded once or taken from the kept decode.
                var out: [KnowledgeObject] = []
                var index = 0
                for k in 0..<(boundaries.count - 1) {
                    guard let d = decodeMboxRange(data, start: boundaries[k], end: boundaries[k + 1], url: url,
                                                  stageAttachments: true, reuse: reuse, counts: true) else { continue }
                    if let ko = perMessageKO(decoded: d, index: index, url: url) { out.append(ko) }
                    index += 1
                }
                return out
            }
            var pieces: [String] = []
            for k in 0..<(boundaries.count - 1) {
                if let piece = Self.mboxPiece(data, from: boundaries[k], to: boundaries[k + 1]) { pieces.append(piece) }
            }
            return emitPerMessageKOs(from: pieces, url: url)
        }
        let plan = mboxThreadPlan(data: data, boundaries: boundaries, url: url, reuse: reuse)
        return plan.threads.compactMap { threadKO($0, plan: plan, data: data, url: url, reuse: reuse) }
    }

    typealias DecodedMboxMessage = (headers: [String: String], cleanedBody: String, quoted: Int, attachments: [URL])

    /// Speed PERF-35 (owner 2026-11-23): one message's decode — the kept decode of the previous version when the message
    /// is proven unchanged, otherwise decoded from its bytes (and kept, when `counts`, for the next version). nil = blank.
    private func decodeMboxRange(_ data: Data, start: Int, end: Int, url: URL, stageAttachments: Bool,
                                 reuse: MboxDecodeReuse?, counts: Bool) -> DecodedMboxMessage? {
        if let reuse, let hit = reuse.hit(start: start, end: end, counts: counts) {
            return (hit.h, hit.b, hit.q, [])
        }
        guard let piece = Self.mboxPiece(data, from: start, to: end) else { return nil }
        let d = decodeMboxMessage(piece, url: url, stageAttachments: stageAttachments)
        if counts, let reuse { reuse.keep(start: start, end: end, data: data, decoded: d) }
        return d
    }

    /// One mbox message decoded for the thread path: envelope line dropped, headers split,
    /// multipart decoded (attachments staged only when asked), quoted regions stripped.
    private func decodeMboxMessage(_ message: String, url: URL, stageAttachments: Bool)
        -> (headers: [String: String], cleanedBody: String, quoted: Int, attachments: [URL]) {
        // Drop the "From <sender> <date>" envelope line — not a
        // real header, leaks into the parser. `.isNewline` (not
        // `$0 == "\n"`) catches CRLF-terminated mbox from Gmail
        // Takeout where Swift treats "\r\n" as ONE grapheme.
        let messageBody: String
        if let firstLineEnd = message.firstIndex(where: { $0.isNewline }) {
            messageBody = String(message[message.index(after: firstLineEnd)...])
        } else {
            messageBody = message
        }
        let (headers, body) = splitEMLHeaders(messageBody)
        // T13.7 — decode multipart, T7 — strip quoted regions.
        let (textBody, attachmentURLs) = Self.applyMultipartIfNeeded(
            headers: headers, body: body, for: url, stageAttachments: stageAttachments
        )
        let (cleanedBody, quoted) = Self.stripQuotedRegions(textBody)
        return (headers, cleanedBody, quoted, attachmentURLs)
    }

    /// F01 — the thread path's first pass, bodies NOT kept: per message only its headers, date,
    /// quoted-byte count, staged attachments and byte range, then the coalesced threads. Grouping
    /// reads headers + dates only, so this holds the archive's headers, never its bodies.
    struct MboxThreadPlan {
        struct Record { let index: Int; let start: Int; let end: Int; let quoted: Int; let attachments: [URL] }
        let records: [Int: Record]
        let threads: [ThreadCoalescer.Thread]
    }

    private func mboxThreadPlan(data: Data, boundaries: [Int], url: URL, reuse: MboxDecodeReuse? = nil) -> MboxThreadPlan {
        var records: [Int: MboxThreadPlan.Record] = [:]
        var parsedMessages: [ThreadCoalescer.ParsedMessage] = []
        var index = 0
        for k in 0..<(boundaries.count - 1) {
            // CI fix (ScaleRunTests, run 45056172194): one autorelease pool per message, as in the per-message stream
            // (W0-1). The plan pass runs as one job, so without it every message's bridged Foundation temporaries piled
            // up until the whole mailbox was planned (+1.4 GiB on a 93 MiB mbox once thread merge became the default).
            let start = boundaries[k], end = boundaries[k + 1], i = index
            let planned: (MboxThreadPlan.Record, ThreadCoalescer.ParsedMessage)?? = autoreleasepool {
                guard let d = decodeMboxRange(data, start: start, end: end, url: url, stageAttachments: true,
                                              reuse: reuse, counts: true) else { return .none }
                if d.cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && d.headers["subject"] == nil { return .some(nil) }
                return .some((.init(index: i, start: start, end: end, quoted: d.quoted, attachments: d.attachments),
                              ThreadCoalescer.ParsedMessage(index: i, headers: d.headers, body: "",
                                                            date: Self.parseRFC2822Date(d.headers["date"]))))
            }
            guard case .some(let kept) = planned else { continue }
            defer { index += 1 }
            guard let (record, parsed) = kept else { continue }
            records[i] = record
            parsedMessages.append(parsed)
        }
        return MboxThreadPlan(records: records, threads: ThreadCoalescer.coalesce(parsedMessages))
    }

    /// One thread → its KO. Bodies are re-decoded from the mapped bytes here (text only, nothing
    /// staged), so a thread's bodies are resident only while its KO is built.
    private func threadKO(_ thread: ThreadCoalescer.Thread, plan: MboxThreadPlan, data: Data, url: URL,
                          reuse: MboxDecodeReuse? = nil) -> KnowledgeObject? {
        let isoDate = ISO8601DateFormatter()
        let koID = UUID()

        // Build the concatenated thread content + structured
        // per-message offsets so the Evidence gate can still cite
        // an individual message.
        var content = ""
        var perMessage: [[String: AnyCodable]] = []
        var attachmentsAccum: [URL] = []
        var totalQuotedRemoved = 0
        for (n, m) in thread.messages.enumerated() {
            guard let rec = plan.records[m.index],
                  let body = decodeMboxRange(data, start: rec.start, end: rec.end, url: url, stageAttachments: false,
                                             reuse: reuse, counts: false)?.cleanedBody else { continue }
            let from = m.headers["from"] ?? ""
            let dateText = m.date.map { isoDate.string(from: $0) }
                ?? (m.headers["date"] ?? "")
            let banner = "--- MSG \(n + 1) sent \(dateText) by \(from) ---"
            if !content.isEmpty {
                content += "\n\n"
            }
            let messageStart = content.utf8.count
            content += banner + "\n"
            // Header lines first so NER / chunker see participants.
            var headerLines: [String] = []
            for key in ["from", "to", "cc", "subject", "date"] {
                if let value = m.headers[key], !value.isEmpty {
                    headerLines.append("\(key.capitalized): \(value)")
                }
            }
            if !headerLines.isEmpty {
                content += headerLines.joined(separator: "\n") + "\n\n"
            }
            content += body
            let messageEnd = content.utf8.count

            // Per-message structured record. Keys mirror the EML
            // path so the dossier / completeness panels read the
            // same shape.
            var msgRec: [String: AnyCodable] = [
                "messageIndex": AnyCodable(.int(Int64(m.index))),
                "byteStart": AnyCodable(.int(Int64(messageStart))),
                "byteEnd": AnyCodable(.int(Int64(messageEnd))),
            ]
            for (k, v) in m.headers {
                msgRec[k] = AnyCodable(.string(v))
            }
            perMessage.append(msgRec)
            attachmentsAccum.append(contentsOf: rec.attachments)
            totalQuotedRemoved += rec.quoted
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        // Pick representative headers for the KO's flat metadata
        // bag (first message wins) so existing consumers that
        // look up "from"/"subject"/"date" still get a value
        // without needing to walk the per-message array.
        let rep = thread.messages.first?.headers ?? [:]
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("mbox-thread")),
            "threadMessageCount": AnyCodable(.int(Int64(thread.messages.count))),
            "threadSubject": AnyCodable(.string(thread.canonicalSubject)),
            "quotedBytesRemoved": AnyCodable(.int(Int64(totalQuotedRemoved)))
        ]
        for (k, v) in rep {
            meta[k] = AnyCodable(.string(v))
        }
        if let thrid = rep["x-gm-thrid"] {
            meta["threadID"] = AnyCodable(.string(thrid))
        }
        // Smuggle the per-message array as JSON so the schema
        // stays untouched but downstream code can de-serialize.
        if let bag = Self.encodeMessagesBag(perMessage) {
            meta[Self.threadMessagesMetaKey] = AnyCodable(.string(bag))
        }
        if let json = Self.encodeAttachmentURLs(attachmentsAccum) {
            meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
        }
        // Structured From/To/Cc/Date entities computed over the
        // FIRST message so the entity extractor sees a single
        // sender/recipient set per thread KO. Per-message entity
        // mentions still emerge from the chunker's NER pass over
        // the concatenated content.
        let structuredEntities = Self.structuredEntities(from: rep, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structuredEntities) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .mbox,
            content: content,
            metadata: meta,
            confidence: .high
        )
    }

    /// Metadata key carrying the JSON-encoded per-message array
    /// (`[[String: AnyCodable]]`) for a thread KO. The Dossier /
    /// SourceViewer / Evidence gate read this to extract per-message
    /// citation offsets.
    nonisolated static let threadMessagesMetaKey = "t_threadMessages"

    /// The `messageIndex` of every message a thread KO carries, read back from
    /// its `t_threadMessages` bag. Empty when the bag is absent or unreadable.
    nonisolated static func threadMessageIndices(fromBag json: String) -> Set<Int> {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out = Set<Int>()
        for row in rows {
            if let n = row["messageIndex"] as? Int { out.insert(n) }
            else if let n = row["messageIndex"] as? NSNumber { out.insert(n.intValue) }
        }
        return out
    }

    /// Pre-Move-A path. One KO per mbox message. Active when
    /// `threadCoalescingEnabled == false`. Preserved verbatim from
    /// commit dd93c9e so the production DB shape (526 per-message
    /// KOs from Sent.mbox) is reproducible on a fresh re-ingest.
    private func emitPerMessageKOs(from pieces: [String], url: URL) -> [KnowledgeObject] {
        pieces.enumerated().compactMap { perMessageKO(from: $0.element, index: $0.offset, url: url) }
    }

    /// One mbox message → its KO (nil when it carries no text). `index` is the message's position
    /// among the archive's non-blank pieces — the `messageIndex` both paths stamp. F01.
    private func perMessageKO(from message: String, index: Int, url: URL) -> KnowledgeObject? {
        // Envelope line dropped, headers split, multipart decoded (attachments staged), quoted regions stripped — the
        // same decode the thread path uses (Speed PERF-35: one decode, so a kept decode builds the same record).
        perMessageKO(decoded: decodeMboxMessage(message, url: url, stageAttachments: true), index: index, url: url)
    }

    private func perMessageKO(decoded: DecodedMboxMessage, index: Int, url: URL) -> KnowledgeObject? {
        let headers = decoded.headers

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("mbox-per-message")),
            "messageIndex": AnyCodable(.int(Int64(index)))
        ]
        for (key, value) in headers { meta[key] = AnyCodable(.string(value)) }

        // T13.6 — Gmail Takeout: surface X-GM-THRID + X-Gmail-Labels
        // as first-class metadata.
        if let thrid = headers["x-gm-thrid"] {
            meta["threadID"] = AnyCodable(.string(thrid))
        }
        if let labels = headers["x-gmail-labels"] {
            meta["gmailLabels"] = AnyCodable(.string(labels))
        }

        // T13.7 (multipart decoded so chunking sees text only) and T7 (quoted regions stripped) — done by the decode.
        let cleanedBody = decoded.cleanedBody
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(decoded.quoted)))
        if let json = Self.encodeAttachmentURLs(decoded.attachments) {
            meta[Self.attachmentURLsMetaKey] = AnyCodable(.string(json))
        }

        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        headerLines += Self.exportNameLines(headers)
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody
        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }

        let koID = UUID()
        let structuredEntities = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structuredEntities) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .mbox,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    private static func encodeMessagesBag(_ bag: [[String: AnyCodable]]) -> String? {
        let encoded = bag.map { AnyCodable(.array($0.mapValues { $0.value }.map { _ in
            AnyCodable.AnySendable.null  // not used; see below
        })) }
        _ = encoded
        // The simplest faithful encoding is to wrap the per-message
        // dicts in AnyCodable's array/object case and JSON-serialize.
        let asAnyCodable = AnyCodable(
            .array(bag.map { dict in
                AnyCodable.AnySendable.object(dict.mapValues { $0.value })
            })
        )
        let encoder = JSONEncoder()
        // Stable bytes: dictionaries otherwise serialize in per-process hash order, so the same
        // thread produced different stored metadata on every run (and every re-parse looked changed).
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(asAnyCodable) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parse an RFC 2822 / 5322 Date header. Tries the strict format
    /// first then a small handful of timezone-name variants seen on
    /// real mbox archives. Returns nil on unparseable input — the
    /// coalescer treats nil dates as "merge if subject matches".
    nonisolated static func parseRFC2822Date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formats: [String] = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        for fmt in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// Metadata key under which T13.2's structured From/To/Cc/Date
    /// entities are smuggled to IngestCoordinator as a JSON-encoded
    /// [Entity] string. KnowledgeObject.entities holds IDs only, so we
    /// piggyback on metadata instead of changing the schema.
    nonisolated static let structuredEntitiesMetaKey = "t13_structuredEntities"

    /// OPS-005 — reserved metadata key for pre-parsed EmailParticipantSeed
    /// JSON (role + rawAddress + displayName). Not written today because
    /// IngestCoordinator reads raw header strings directly and calls
    /// EmailAddressListParser itself; the key is declared here so future
    /// code or tests can reference it without a magic string.
    nonisolated static let emailParticipantSeedsMetaKey = "ops005_emailParticipantSeeds"

    /// Metadata key under which T13.7's attachment file URLs are
    /// surfaced — a JSON-encoded [String] of file:// paths. After the
    /// parent email KO finishes ingestion, IngestCoordinator recursively
    /// calls `ingest(fileAt:)` on each URL so attachments become their
    /// own KnowledgeObjects (and T7's content-hash dedup folds recurring
    /// attachments onto a single canonical KO with alias file rows).
    nonisolated static let attachmentURLsMetaKey = "t13_attachmentURLs"

    /// Top-level helper called from each ingest path. If the message
    /// is multipart, replaces the body with the decoded text and returns
    /// the staged attachment URLs; otherwise passes the body through
    /// unchanged with no attachments.
    static func applyMultipartIfNeeded(
        headers: [String: String],
        body: String,
        for sourceURL: URL,
        stageAttachments: Bool = true
    ) -> (textBody: String, attachmentURLs: [URL]) {
        guard let ct = headers["content-type"],
              ct.lowercased().hasPrefix("multipart/") else {
            // Single-part: transfer-decode quoted-printable / base64 bodies so a
            // QP soft break can never leave a split email address (or any split
            // token) in the stored text. All email paths (eml, emlx, mbox)
            // funnel through here, so this one branch fixes the whole lane.
            if let decoded = MIMEParser.decodeSinglePartBody(body, headers: headers) {
                return (decoded, [])
            }
            return (body, [])
        }
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-email-attachments", isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        // F01 — a text-only re-decode (streamed coalescing, pass 2) writes nothing to disk.
        guard let decoded = decodeMultipart(body: body, contentType: ct, attachmentDir: stageAttachments ? baseDir : nil) else {
            return (body, [])
        }
        return (decoded.text, decoded.attachmentURLs)
    }

    /// Decode a multipart body into (textBody, attachmentURLs) — the
    /// text replaces the email body that gets handed to extraction,
    /// and the attachment URLs go into KO metadata for recursive
    /// ingest. Returns `nil` when the part can't be parsed; the caller
    /// then falls back to the raw body so we never block ingestion on
    /// a parsing edge case.
    static func decodeMultipart(
        body: String,
        contentType: String,
        attachmentDir: URL?
    ) -> (text: String, attachmentURLs: [URL])? {
        guard contentType.lowercased().hasPrefix("multipart/"),
              let boundary = MIMEPart.extractParam(contentType, key: "boundary") else {
            return nil
        }
        let parts = MIMEParser.parseMultipart(body: body, boundary: boundary)
        var textPieces: [String] = []
        var attachmentURLs: [URL] = []
        var didWriteAttachmentDir = false
        for part in parts {
            // A text part marked as an attachment is a FILE (staged, ingested as its own source with its name and
            // its parent link) when attachments are staged — folding it into the body lost the attachment entirely.
            if part.isText && !(part.isAttachment && attachmentDir != nil) {
                // Prefer text/plain; fall back to text/html with the
                // tags stripped (cheap). Multiple text parts get
                // concatenated so we never lose body content.
                // Charset-aware: windows-1252 / ISO-8859-1 bodies would
                // otherwise be read as UTF-8 and come out as mojibake.
                let text = part.decodedText()
                if part.contentType == "text/html" {
                    textPieces.append(stripHTML(text))
                } else {
                    textPieces.append(text)
                }
            } else if let attachmentDir {
                // Real attachment. Write to disk and record the URL.
                // 2026-06-30 fix — prepend a short content-hash to the
                // filename so two messages in the same mbox that
                // attach files with identical filenames but DIFFERENT
                // bytes don't overwrite each other's staged file.
                // Identical bytes across multiple emails still produce
                // the same on-disk filename (correct — T7's hash-first
                // dedup folds them into one canonical KO downstream).
                let raw = part.filename ?? "attachment-\(UUID().uuidString.prefix(8))"
                var safe = sanitizeFilename(raw)
                // If the attachment filename carries NO extension, derive one from
                // the MIME Content-Type. Downstream routing (SourceType.detect) is
                // extension-based, so an extensionless "image/jpeg" was falling to
                // TextLoader and getting refused as binary. Giving it ".jpg" here
                // routes it to the image parser (+ OCR) like any other image.
                if (safe as NSString).pathExtension.isEmpty,
                   let mimeExt = Self.fileExtension(forMIME: part.contentType) {
                    safe += ".\(mimeExt)"
                }
                let hashTag = Self.shortContentHash(part.body)
                let uniqueName: String = {
                    if let dot = safe.lastIndex(of: ".") {
                        return safe[safe.startIndex..<dot] + "-" + hashTag + safe[dot...]
                    }
                    return safe + "-" + hashTag
                }()
                if !didWriteAttachmentDir {
                    try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
                    didWriteAttachmentDir = true
                }
                let url = attachmentDir.appendingPathComponent(uniqueName)
                do {
                    try part.body.write(to: url, options: .atomic)
                    attachmentURLs.append(url)
                } catch {
                    KalsmritikoshLog.ingestion.error("Attachment could not be staged (\(part.body.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return (textPieces.joined(separator: "\n\n"), attachmentURLs)
    }

    private static func stripHTML(_ s: String) -> String {
        // Very naive — good enough to remove `<tag>` chrome without
        // pulling in a full HTML parser. Anything richer is Gate 3.
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        let ns = s as NSString
        let stripped = re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " "
        )
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Map a MIME Content-Type to a file extension so an attachment whose
    /// filename lacks one still routes to the right parser. Only the formats the
    /// pipeline actually parses are listed; anything else stays extensionless
    /// (and the ingest-time magic-byte sniff is the final safety net).
    static func fileExtension(forMIME contentType: String) -> String? {
        let mime = contentType.lowercased()
            .split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        switch mime {
        case "image/jpeg", "image/jpg":                                                     return "jpg"
        case "image/png":                                                                   return "png"
        case "image/heic", "image/heif":                                                    return "heic"
        case "image/tiff":                                                                  return "tiff"
        case "image/webp":                                                                  return "webp"
        case "application/pdf":                                                             return "pdf"
        case "application/msword":                                                          return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":     return "docx"
        case "application/vnd.ms-excel":                                                    return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":           return "xlsx"
        case "application/vnd.ms-powerpoint":                                               return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":   return "pptx"
        case "application/vnd.oasis.opendocument.text":                                     return "odt"
        case "application/vnd.oasis.opendocument.spreadsheet":                              return "ods"
        case "application/rtf", "text/rtf":                                                 return "rtf"
        case "application/epub+zip":                                                        return "epub"
        case "application/zip":                                                             return "zip"
        case "text/csv":                                                                    return "csv"
        case "text/plain":                                                                  return "txt"
        case "text/html":                                                                   return "html"
        default:                                                                            return nil
        }
    }

    /// IN-10 — one safe path component (no separators, NUL, control or bidi-override characters, no leading
    /// dot, within the file-name byte limit) so a hostile declared filename can neither escape the staging
    /// directory nor make the write fail and the attachment silently vanish.
    private static func sanitizeFilename(_ name: String) -> String {
        SafeFilename.sanitize(name)
    }

    /// 8-char SHA-256 prefix used to disambiguate two attachments
    /// with the same filename but different bytes (Bug fix
    /// 2026-06-30 — without this, two messages in one mbox attaching
    /// "receipt.pdf" with different contents would overwrite each
    /// other on disk before recursive ingest reads either).
    private static func shortContentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    static func encodeAttachmentURLs(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let strings = urls.map(\.absoluteString)
        guard let data = try? JSONEncoder().encode(strings) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeAttachmentURLs(from json: String) -> [URL] {
        guard let data = json.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return strings.compactMap { URL(string: $0) }
    }

    static func encodeStructuredEntities(_ entities: [Entity]) -> String? {
        guard !entities.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(entities) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeStructuredEntities(from json: String) -> [Entity] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([Entity].self, from: data) else {
            return []
        }
        return arr
    }

    /// T13.2 — pull structured emailAddress / person / date entities out
    /// of the parsed RFC 5322 headers so downstream extractors don't
    /// have to re-discover them via NER.
    static func structuredEntities(
        from headers: [String: String],
        sourceObjectID: KnowledgeObject.ID
    ) -> [Entity] {
        var out: [Entity] = []
        let emailRegex = try? NSRegularExpression(
            pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}",
            options: []
        )
        // (The old name-in-angle-brackets regex lived here; replaced by
        // EmailAddressListParser in U0-b — it could not see list commas.)

        func addEmailsAndNames(from header: String?) {
            guard let header, !header.isEmpty else { return }
            let ns = header as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let emailRegex {
                for match in emailRegex.matches(in: header, range: range) {
                    let addr = ns.substring(with: match.range).lowercased()
                    out.append(Entity(
                        kind: .emailAddress,
                        value: addr,
                        normalizedValue: addr,
                        sourceObjectID: sourceObjectID,
                        confidence: .high
                    ))
                }
            }
            // U0-b: display names via the RFC 2822 address-list parser — the
            // old angle-bracket regex was blind to list commas, so the second
            // and later entries of a To: list became ", Name" person entities
            // and quoted names kept their quotes ('Arindam Das'); witnessed
            // live on the owner's archive. The parser understands quoting and
            // list separators; edge punctuation is stripped before the value
            // is ever constructed (the 3c write-time strip stays as belt).
            for parsed in EmailAddressListParser.parse(header) {
                guard let name = parsed.displayName else { continue }
                let raw = EntitiesRepository.stripEdgePunctuation(name)
                // Skip empty / obviously non-name values; let
                // EntityQualityGate decide on edge cases.
                if raw.count >= 2, raw.contains(where: \.isLetter) {
                    out.append(Entity(
                        kind: .person,
                        value: raw,
                        sourceObjectID: sourceObjectID,
                        confidence: .high
                    ))
                }
            }
        }

        addEmailsAndNames(from: headers["from"])
        addEmailsAndNames(from: headers["sender"])
        addEmailsAndNames(from: headers["reply-to"])
        addEmailsAndNames(from: headers["to"])
        addEmailsAndNames(from: headers["cc"])
        // OPS-005 — Bcc addresses enter the canonical entity table
        // so occurrence rows can reference them by entity ID. They
        // MUST NOT appear in chunk text or embeddings (enforced by
        // the headerLines prepend logic that only includes from/to/cc).
        addEmailsAndNames(from: headers["bcc"])

        // Date header → date entity (best-effort RFC 2822 / 5322 parsing).
        if let dateString = headers["date"], !dateString.isEmpty {
            if let date = parseRFC2822DateOrNil(dateString) {
                let iso = ISO8601DateFormatter().string(from: date)
                out.append(Entity(
                    kind: .date,
                    value: dateString,
                    normalizedValue: iso,
                    sourceObjectID: sourceObjectID,
                    confidence: .high
                ))
            }
        }
        return out
    }

    private static func parseRFC2822DateOrNil(_ s: String) -> Date? {
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            formatter.dateFormat = f
            if let date = formatter.date(from: s) { return date }
        }
        return nil
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

    /// G4.9 — parse an Outlook `.msg` (OLE2 compound file w/ MAPI
    /// properties) and emit a KO shaped exactly like the EML path:
    /// human-relevant headers prepended to the plain-text body, the
    /// full header map in `metadata`, and structured From/To/Cc/Date
    /// entities pre-built. Ported from the sibling mailin/MSGParser.
    private func ingestMSG(at url: URL) throws -> KnowledgeObject {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // Sanity cap — the OLE2 reader is robust but mapping a 4 GB blob
        // and walking its FAT chains is not a workload we want at ingest
        // time. The historical .msg corpora cap out well under 100 MB.
        if raw.count > 500_000_000 {
            throw IngestorError.parseFailure(
                url,
                reason: "msg: file too large (\(raw.count / 1_000_000) MB; limit 500 MB)"
            )
        }
        let ole2: OLE2Reader
        do { ole2 = try OLE2Reader(data: raw) }
        catch { throw IngestorError.parseFailure(url, reason: "msg: \(error)") }

        let props = ole2.readMAPIProperties()

        // MAPI property → RFC822-ish header. Sender SMTP wins over the
        // legacy `senderEmailAddress` because the latter often carries
        // Exchange-internal LDAP DNs (e.g. /O=ORG/OU=.../CN=user) that
        // the entity layer can't ground to a real address.
        let senderAddr = props.stringProperty(.senderSmtpAddress)
            ?? props.stringProperty(.senderEmailAddress)
            ?? ""
        let senderName = props.stringProperty(.senderName) ?? ""
        let from: String
        if !senderAddr.isEmpty && !senderName.isEmpty {
            from = "\(senderName) <\(senderAddr)>"
        } else if !senderAddr.isEmpty {
            from = senderAddr
        } else {
            from = senderName
        }
        let to = props.stringProperty(.displayTo) ?? ""
        let cc = props.stringProperty(.displayCc) ?? ""
        let bcc = props.stringProperty(.displayBcc) ?? ""
        let subject = props.stringProperty(.subject) ?? ""

        // Date precedence: delivery time > client-submit > creation. All
        // are FILETIME → Date in the OLE2 reader.
        let date = props.dateProperty(.messageDeliveryTime)
            ?? props.dateProperty(.clientSubmitTime)
            ?? props.dateProperty(.creationTime)
        let dateString = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""

        // Body precedence: plain → HTML stripped → decompressed RTF.
        // Some Outlook senders ship only the RTF stream.
        let plainBody = props.stringProperty(.body) ?? ""
        let htmlBody: String
        if let bytes = props.binaryProperty(.htmlBody) {
            htmlBody = String(data: bytes, encoding: .utf8) ?? ""
        } else {
            htmlBody = ""
        }
        let rtfBody: String
        if let rtfBytes = props.binaryProperty(.rtfCompressed) {
            rtfBody = decompressRTFLZFu(rtfBytes) ?? ""
        } else {
            rtfBody = ""
        }
        let body: String
        if !plainBody.isEmpty {
            body = plainBody
        } else if !htmlBody.isEmpty {
            // Reuse the existing tag stripper from the EML path.
            body = DocxLoader.stripTags(htmlBody)
        } else {
            body = rtfBody
        }

        // Build a lower-cased header dict that mirrors what
        // `splitEMLHeaders` produces, so structuredEntities() and
        // downstream metadata callers see the same shape as EML.
        var headers: [String: String] = [:]
        if !from.isEmpty { headers["from"] = from }
        if !to.isEmpty { headers["to"] = to }
        if !cc.isEmpty { headers["cc"] = cc }
        if !bcc.isEmpty { headers["bcc"] = bcc }
        if !subject.isEmpty { headers["subject"] = subject }
        if !dateString.isEmpty { headers["date"] = dateString }
        if let msgID = props.stringProperty(.internetMessageId) {
            headers["message-id"] = msgID
        }
        if let inReplyTo = props.stringProperty(.inReplyToId) {
            headers["in-reply-to"] = inReplyTo
        }
        if let references = props.stringProperty(.references) {
            headers["references"] = references
        }
        if let replyTo = props.stringProperty(.replyToAddress) {
            headers["reply-to"] = replyTo
        }
        if let topic = props.stringProperty(.conversationTopic) {
            headers["thread-topic"] = topic
        }

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("msg-ole2-mapi"))
        ]
        for (key, value) in headers {
            meta[key] = AnyCodable(.string(value))
        }

        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(body)
        meta["quotedBytesRemoved"] = AnyCodable(.int(Int64(quotedBytesRemoved)))

        // Prepend human-relevant headers to the body so NER + summarizer
        // see participants and topic, matching the EML path exactly.
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        headerLines += Self.exportNameLines(headers)
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody
        if merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }
        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .msg,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// G4.9 — read a PST/OST and emit one KO per message. The KO
    /// shape mirrors the EML path: human headers prepended to body,
    /// structured From/To/Cc/Date entities, full header dictionary
    /// stored in metadata. Errors on individual messages are skipped
    /// inside PSTReader; here we just adapt each surviving PSTMessage
    /// into a KnowledgeObject.
    private func ingestPSTAsMessages(at url: URL) throws -> [KnowledgeObject] {
        let messages = try loadPSTMessages(at: url)
        var out: [KnowledgeObject] = []
        out.reserveCapacity(messages.count)
        for msg in messages {
            guard let ko = buildKO(fromPSTMessage: msg, source: url) else { continue }
            out.append(ko)
        }
        return out
    }

    /// G4.9 — single-KO legacy path: every PST message concatenated
    /// in chronological-ish order (whatever ordering the NDB walk
    /// produces, which is approximately insertion order). Used only
    /// by callers that don't iterate via ingestMany.
    private func ingestPSTConcatenated(at url: URL) throws -> KnowledgeObject {
        let messages = try loadPSTMessages(at: url)
        guard !messages.isEmpty else { throw IngestorError.empty(url) }

        var blocks: [String] = []
        for msg in messages {
            blocks.append(pstMessageMarkdown(msg))
        }
        let content = blocks.joined(separator: "\n\n---\n\n")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .pst,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("pst-ole-ndb")),
                "messageCount": AnyCodable(.int(Int64(messages.count))),
                "binarySize": AnyCodable(.int(size))
            ],
            confidence: .medium
        )
    }

    private func loadPSTMessages(at url: URL) throws -> [PSTReader.PSTMessage] {
        Array(try pstMessageIterator(at: url))
    }

    /// F01 — PST messages parsed one at a time from the memory-mapped file.
    private func pstMessageIterator(at url: URL) throws -> AnyIterator<PSTReader.PSTMessage> {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // Same sanity cap as MSG — PSTs in the wild routinely run into
        // multi-GB territory but mapping them at ingest time is
        // expensive. Bigger archives should be split externally.
        if raw.count > 2_000_000_000 {
            throw IngestorError.parseFailure(
                url,
                reason: "pst: file too large (\(raw.count / 1_000_000) MB; limit 2 GB)"
            )
        }
        let reader: PSTReader
        do { reader = try PSTReader(data: raw) }
        catch { throw IngestorError.parseFailure(url, reason: "pst: \(error)") }
        return reader.messageIterator()
    }

    /// Adapt one PSTMessage into a KnowledgeObject. Returns nil when
    /// the message has no displayable body and no headers worth
    /// keeping (which happens for placeholder NDB rows).
    private func buildKO(fromPSTMessage msg: PSTReader.PSTMessage, source url: URL) -> KnowledgeObject? {
        let from: String
        if !msg.senderEmail.isEmpty && !msg.senderName.isEmpty {
            from = "\(msg.senderName) <\(msg.senderEmail)>"
        } else if !msg.senderEmail.isEmpty {
            from = msg.senderEmail
        } else {
            from = msg.senderName
        }
        let date = msg.deliveryTime ?? msg.creationTime
        let dateString = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""

        var headers: [String: String] = [:]
        if !from.isEmpty { headers["from"] = from }
        if !msg.displayTo.isEmpty { headers["to"] = msg.displayTo }
        if !msg.displayCc.isEmpty { headers["cc"] = msg.displayCc }
        if !msg.displayBcc.isEmpty { headers["bcc"] = msg.displayBcc }
        if !msg.subject.isEmpty { headers["subject"] = msg.subject }
        if !dateString.isEmpty { headers["date"] = dateString }
        if let mid = msg.internetMessageId { headers["message-id"] = mid }
        if let irt = msg.inReplyToId { headers["in-reply-to"] = irt }
        if let refs = msg.references { headers["references"] = refs }
        if let rt = msg.replyToAddress, !rt.isEmpty { headers["reply-to"] = rt }
        if let topic = msg.conversationTopic { headers["thread-topic"] = topic }
        if let ct = msg.contentType { headers["content-type"] = ct }

        // Body precedence: plain text → tag-stripped HTML.
        let body: String
        if !msg.bodyText.isEmpty {
            body = msg.bodyText
        } else if !msg.bodyHTML.isEmpty {
            body = DocxLoader.stripTags(msg.bodyHTML)
        } else {
            body = ""
        }

        // If there's no usable signal at all, drop it — these are
        // empty NDB rows that would only waste downstream cycles.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && headers.count <= 1 {
            return nil
        }

        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(body)

        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        headerLines += Self.exportNameLines(headers)
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("pst-message")),
            "quotedBytesRemoved": AnyCodable(.int(Int64(quotedBytesRemoved)))
        ]
        for (k, v) in headers {
            meta[k] = AnyCodable(.string(v))
        }

        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .pst,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    /// Stringify a PSTMessage as a markdown block for the concatenated
    /// fallback path. Used only when a caller can't iterate the
    /// per-message KO stream.
    private func pstMessageMarkdown(_ msg: PSTReader.PSTMessage) -> String {
        var lines: [String] = []
        if !msg.senderName.isEmpty || !msg.senderEmail.isEmpty {
            let from = msg.senderEmail.isEmpty
                ? msg.senderName
                : (msg.senderName.isEmpty ? msg.senderEmail : "\(msg.senderName) <\(msg.senderEmail)>")
            lines.append("From: \(from)")
        }
        if !msg.displayTo.isEmpty { lines.append("To: \(msg.displayTo)") }
        if !msg.displayCc.isEmpty { lines.append("Cc: \(msg.displayCc)") }
        if !msg.subject.isEmpty { lines.append("Subject: \(msg.subject)") }
        if let d = msg.deliveryTime ?? msg.creationTime {
            lines.append("Date: \(ISO8601DateFormatter().string(from: d))")
        }
        let body: String
        if !msg.bodyText.isEmpty {
            body = msg.bodyText
        } else if !msg.bodyHTML.isEmpty {
            body = DocxLoader.stripTags(msg.bodyHTML)
        } else {
            body = ""
        }
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    /// G4.9 — Lotus Notes NSF database → one KO per mail-shaped note.
    private func ingestNSFAsMessages(at url: URL) throws -> [KnowledgeObject] {
        let notes = try loadNSFNotes(at: url)
        var out: [KnowledgeObject] = []
        out.reserveCapacity(notes.count)
        for note in notes where note.isMailNote {
            guard let ko = buildKO(fromNSFNote: note, source: url) else { continue }
            out.append(ko)
        }
        return out
    }

    /// G4.9 — concatenated NSF KO: every mail note as a markdown block.
    private func ingestNSFConcatenated(at url: URL) throws -> KnowledgeObject {
        let notes = try loadNSFNotes(at: url)
        let mailNotes = notes.filter(\.isMailNote)
        guard !mailNotes.isEmpty else { throw IngestorError.empty(url) }
        let content = mailNotes
            .map { nsfNoteMarkdown($0) }
            .joined(separator: "\n\n---\n\n")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .nsf,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("nsf-domino")),
                "messageCount": AnyCodable(.int(Int64(mailNotes.count))),
                "binarySize": AnyCodable(.int(size))
            ],
            confidence: .medium
        )
    }

    private func loadNSFNotes(at url: URL) throws -> [NSFReader.NSFNote] {
        Array(try nsfNoteIterator(at: url))
    }

    /// F01 — NSF notes parsed one at a time from the memory-mapped file.
    private func nsfNoteIterator(at url: URL) throws -> AnyIterator<NSFReader.NSFNote> {
        let raw: Data
        do { raw = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw IngestorError.unreadable(url, underlying: error) }
        // NSF can run very large; cap at 4 GB like the original mailin
        // parser to keep mapping cost predictable.
        if raw.count > 4_000_000_000 {
            throw IngestorError.parseFailure(
                url,
                reason: "nsf: file too large (\(raw.count / 1_000_000) MB; limit 4 GB)"
            )
        }
        let reader = NSFReader(data: raw)
        do { return try reader.noteIterator() }
        catch { throw IngestorError.parseFailure(url, reason: "nsf: \(error)") }
    }

    private func buildKO(fromNSFNote note: NSFReader.NSFNote, source url: URL) -> KnowledgeObject? {
        // NSF stores SMTP-shaped addresses under multiple field names
        // depending on the form variant.
        let from = note.items["From"]
            ?? note.items["$From"]
            ?? note.items["SMTPOriginator"]
            ?? ""
        let to = note.items["SendTo"] ?? note.items["EnterSendTo"] ?? ""
        let cc = note.items["CopyTo"] ?? note.items["EnterCopyTo"] ?? ""
        let bcc = note.items["BlindCopyTo"] ?? ""
        let subject = note.items["Subject"] ?? ""
        let dateRaw = note.items["DeliveredDate"] ?? note.items["PostedDate"] ?? ""
        let messageID = note.items["$MessageID"] ?? note.items["UNID"]

        // Body precedence: plain Body → $HtmlBody/Body_HTML (stripped).
        let plainBody = note.items["Body"] ?? ""
        let htmlBody = note.items["$HtmlBody"] ?? note.items["Body_HTML"] ?? ""
        let body: String
        if !plainBody.isEmpty {
            body = plainBody
        } else if !htmlBody.isEmpty {
            body = DocxLoader.stripTags(htmlBody)
        } else {
            body = ""
        }

        // Normalize the delivered-date string into ISO8601 when we can
        // recognize the format. Notes ships in several locale-specific
        // shapes — keep the raw string as a fallback when none parse.
        let dateString = Self.normalizeNotesDate(dateRaw)

        var headers: [String: String] = [:]
        if !from.isEmpty { headers["from"] = from }
        if !to.isEmpty { headers["to"] = to }
        if !cc.isEmpty { headers["cc"] = cc }
        if !bcc.isEmpty { headers["bcc"] = bcc }
        if !subject.isEmpty { headers["subject"] = subject }
        if !dateString.isEmpty { headers["date"] = dateString }
        if let mid = messageID, !mid.isEmpty { headers["message-id"] = mid }
        if let irt = note.items["$Ref"], !irt.isEmpty { headers["in-reply-to"] = irt }
        if let form = note.items["Form"], !form.isEmpty { headers["x-notes-form"] = form }
        headers["x-source-format"] = "NSF"

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && headers.count <= 2 {
            return nil
        }

        let (cleanedBody, quotedBytesRemoved) = Self.stripQuotedRegions(body)
        var headerLines: [String] = []
        for key in ["from", "to", "cc", "subject", "date"] {
            if let value = headers[key], !value.isEmpty {
                headerLines.append("\(key.capitalized): \(value)")
            }
        }
        headerLines += Self.exportNameLines(headers)
        let merged = headerLines.isEmpty
            ? cleanedBody
            : headerLines.joined(separator: "\n") + "\n\n" + cleanedBody

        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("nsf-note")),
            "quotedBytesRemoved": AnyCodable(.int(Int64(quotedBytesRemoved)))
        ]
        for (k, v) in headers { meta[k] = AnyCodable(.string(v)) }
        if !note.categories.isEmpty {
            meta["nsfCategories"] = AnyCodable(.string(note.categories.joined(separator: ",")))
        }

        let koID = UUID()
        let structured = Self.structuredEntities(from: headers, sourceObjectID: koID)
        if let json = Self.encodeStructuredEntities(structured) {
            meta[Self.structuredEntitiesMetaKey] = AnyCodable(.string(json))
        }
        return KnowledgeObject(
            id: koID,
            sourceFile: url,
            sourceType: .nsf,
            content: merged,
            metadata: meta,
            confidence: .high
        )
    }

    private func nsfNoteMarkdown(_ note: NSFReader.NSFNote) -> String {
        var lines: [String] = []
        let from = note.items["From"]
            ?? note.items["$From"]
            ?? note.items["SMTPOriginator"]
            ?? ""
        if !from.isEmpty { lines.append("From: \(from)") }
        if let to = note.items["SendTo"] ?? note.items["EnterSendTo"], !to.isEmpty {
            lines.append("To: \(to)")
        }
        if let cc = note.items["CopyTo"], !cc.isEmpty { lines.append("Cc: \(cc)") }
        if let subject = note.items["Subject"], !subject.isEmpty {
            lines.append("Subject: \(subject)")
        }
        if let d = note.items["DeliveredDate"] ?? note.items["PostedDate"], !d.isEmpty {
            lines.append("Date: \(d)")
        }
        let body = note.items["Body"]
            ?? (note.items["$HtmlBody"].map(DocxLoader.stripTags))
            ?? ""
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    /// Lotus Notes ships dates in a small handful of locale-specific
    /// shapes. Walk the candidates in order and return the first
    /// that parses; otherwise pass the raw string through so callers
    /// can still see something in the `date` header.
    private static func normalizeNotesDate(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        let candidates = [
            "MM/dd/yyyy hh:mm:ss a",
            "yyyy-MM-dd'T'HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "EEE, dd MMM yyyy HH:mm:ss Z"
        ]
        for format in candidates {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: raw) {
                return ISO8601DateFormatter().string(from: date)
            }
        }
        return raw
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

    /// Strip quoted regions from an email body and report the bytes
    /// removed for the completeness report.
    /// Removed:
    ///   - lines prefixed with `>`
    ///   - blocks following `On <when> <who> wrote:` headers
    ///   - HTML `gmail_quote` / `<blockquote>` containers
    ///   - `-----Original Message-----` / `_____` separator blocks
    static func stripQuotedRegions(_ body: String) -> (stripped: String, bytesRemoved: Int) {
        let originalBytes = body.utf8.count
        var working = body

        // 1. HTML quote containers — drop the entire region (greedy by tag).
        let htmlPatterns = [
            "<div[^>]*class=\"gmail_quote\"[\\s\\S]*?</div>",
            "<blockquote[\\s\\S]*?</blockquote>"
        ]
        for pattern in htmlPatterns {
            if let re = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) {
                let ns = working as NSString
                working = re.stringByReplacingMatches(
                    in: working,
                    options: [],
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
        }

        // 2. "-----Original Message-----" and similar separators —
        //    everything from the marker to EOF is the quoted history.
        let separators = [
            "-----Original Message-----",
            "________________________________",
            "----- Forwarded message -----"
        ]
        for marker in separators {
            if let range = working.range(of: marker) {
                working = String(working[..<range.lowerBound])
            }
        }

        // 3. "On <when>, <who> wrote:" — header before the quote block.
        //    Drop the header line and everything that follows.
        if let onWroteRe = try? NSRegularExpression(
            pattern: "^On .{5,200} wrote:$",
            options: [.anchorsMatchLines]
        ) {
            let ns = working as NSString
            let matches = onWroteRe.matches(in: working, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first {
                let cutoff = first.range.location
                working = ns.substring(to: cutoff)
            }
        }

        // 4. Lines prefixed with `>` (and `> > `, etc.) — drop them outright.
        let lines = working.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix(">")
        }
        working = kept.joined(separator: "\n")

        let stripped = working.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = max(0, originalBytes - stripped.utf8.count)
        return (stripped, removed)
    }

    /// RFC 2047 encoded-word decoder. Real-world Subject / From / To
    /// headers often arrive as
    ///   `Subject: =?UTF-8?B?5pel5pys6Kqe?=`
    /// or
    ///   `From: =?ISO-8859-1?Q?Andr=E9?= <andre@example.com>`
    /// without decoding, the strings poison NER and the UI.
    ///
    /// Format: `=?charset?encoding?encoded-text?=` where encoding is
    /// `B` (base64) or `Q` (quoted-printable, with `_` standing in
    /// for space). Multiple encoded words back-to-back are concatenated
    /// without intervening whitespace per the spec.
    static func decodeRFC2047(_ raw: String) -> String {
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        guard let re = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return raw }

        var out = ""
        var lastEnd = 0
        var lastWasEncoded = false
        for match in matches {
            let r = match.range
            let inBetween = ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))
            // Per RFC 2047 §6.2: whitespace between two encoded words is dropped.
            let trimmedBetween = lastWasEncoded
                ? inBetween.trimmingCharacters(in: .whitespacesAndNewlines)
                : inBetween
            out += trimmedBetween
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            if let decoded = decodeEncodedWord(payload, encoding: encoding, charset: charset) {
                out += decoded
            } else {
                out += ns.substring(with: r)
            }
            lastEnd = r.location + r.length
            lastWasEncoded = true
        }
        if lastEnd < ns.length {
            out += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        }
        return out
    }

    private static func decodeEncodedWord(_ payload: String, encoding: String, charset: String) -> String? {
        let cf = stringEncoding(for: charset) ?? .utf8
        let data: Data?
        switch encoding {
        case "B":
            data = Data(base64Encoded: payload.filter { !$0.isWhitespace })
        case "Q":
            // Q-encoding: `_` → space, `=XX` → byte XX (hex).
            var bytes: [UInt8] = []
            let chars = Array(payload)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "_" {
                    bytes.append(0x20)
                    i += 1
                    continue
                }
                if c == "=", i + 2 < chars.count {
                    let hex = String([chars[i + 1], chars[i + 2]])
                    if let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        i += 3
                        continue
                    }
                }
                for u in String(c).utf8 { bytes.append(u) }
                i += 1
            }
            data = Data(bytes)
        default:
            data = nil
        }
        guard let data else { return nil }
        return String(data: data, encoding: cf)
    }

    private static func stringEncoding(for charset: String) -> String.Encoding? {
        switch charset.uppercased() {
        case "UTF-8", "UTF8": return .utf8
        case "US-ASCII", "ASCII": return .ascii
        case "ISO-8859-1", "LATIN1": return .isoLatin1
        case "ISO-8859-2", "LATIN2": return .isoLatin2
        case "WINDOWS-1252", "CP1252": return .windowsCP1252
        case "SHIFT_JIS", "SHIFT-JIS", "SJIS": return .shiftJIS
        case "EUC-JP": return .japaneseEUC
        case "ISO-2022-JP": return .iso2022JP
        case "GB2312", "GBK", "GB18030": return .init(rawValue: 0x80000632) // GB18030 superset
        case "BIG5": return .init(rawValue: 0x80000A03)
        case "KOI8-R": return .init(rawValue: 0x80000A02)
        default: return nil
        }
    }

    private func splitEMLHeaders(_ raw: String) -> ([String: String], String) {
        // Accept both LF (Unix) and CRLF (Windows / Gmail Takeout) blank-line
        // boundaries. The original \n\n-only path silently dropped every
        // header on CRLF-terminated mbox files (Gmail Takeout), turning
        // From/To/Subject/Date into wall-of-text body content the rest of
        // the pipeline could only NER-recover, not structure-recover.
        let crlfBoundary = raw.range(of: "\r\n\r\n")
        let lfBoundary = raw.range(of: "\n\n")
        let blankLine: Range<String.Index>?
        switch (crlfBoundary, lfBoundary) {
        case (let crlf?, let lf?):
            blankLine = crlf.lowerBound <= lf.lowerBound ? crlf : lf
        case (let crlf?, nil):
            blankLine = crlf
        case (nil, let lf?):
            blankLine = lf
        default:
            blankLine = nil
        }
        guard let boundary = blankLine else {
            return ([:], raw)
        }
        let headerBlock = String(raw[..<boundary.lowerBound])
        let body = String(raw[boundary.upperBound...])

        var headers: [String: String] = [:]
        var current: (String, String)?
        // Normalize CRLF→LF before splitting. `headerBlock.split(separator: "\n")`
        // operates on Character (grapheme cluster), and Swift treats "\r\n" as
        // a SINGLE cluster distinct from "\n", so the bare Character split
        // collapses the whole CRLF header block to one "line" — every header
        // value would inherit every subsequent header as a continuation.
        let normalized = headerBlock.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
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
        // RFC 2047 — decode encoded-words in every header value so the
        // downstream pipeline (NER, KO metadata, UI) sees real text
        // instead of `=?UTF-8?B?...?=` strings.
        var decoded: [String: String] = [:]
        for (k, v) in headers {
            decoded[k] = Self.decodeRFC2047(v)
        }
        return (decoded, body)
    }
}

/// Speed PERF-35 (owner 2026-11-23): what one mailbox read reuses from the previous version and keeps for the next. A
/// message is taken from the previous version's kept decode only when its range is proven unchanged by the piece map
/// (both ends and the next separator inside the unchanged prefix) AND that version kept its fingerprint and decode;
/// every other message is decoded from its bytes, fingerprinted (SHA-256 of its bytes) and its decode kept. A message
/// with attachments is never kept (its attachments are staged files of that read): it is decoded every time.
/// One read runs synchronously on one task; the lock only makes the type Sendable.
nonisolated final class MboxDecodeReuse: Sendable {
    /// The decoder's version: a change of how messages are decoded makes every kept decode a miss.
    static let producer = "mbox.message-decode.v1"

    struct Decoded: Codable, Sendable { let h: [String: String]; let b: String; let q: Int }

    private struct State {
        var starts: [Int] = []
        var digests: [Int: String] = [:]
        var fresh: [(digest: String, payload: String)] = []
        var parsed = 0
        var reused = 0
    }
    private let proven: [Int: Int]
    private let kept: [Int: Decoded]
    private let state: OSAllocatedUnfairLock<State>

    init(proven: [Int: Int], kept: [Int: Decoded], knownDigests: [Int: String]) {
        self.proven = proven
        self.kept = kept
        self.state = OSAllocatedUnfairLock(initialState: State(digests: knownDigests.filter { kept[$0.key] != nil }))
    }

    /// The kept decode of the message at `start`..<`end`, when it is proven unchanged.
    func hit(start: Int, end: Int, counts: Bool) -> Decoded? {
        guard proven[start] == end, let d = kept[start] else { return nil }
        if counts { state.withLock { $0.reused += 1 } }
        return d
    }

    /// A message decoded from its bytes: its fingerprint, and its decode kept when it has no attachments.
    func keep(start: Int, end: Int, data: Data, decoded: EmailLoader.DecodedMboxMessage) {
        let digest = ContentFingerprint.bytes(data[(data.startIndex + start)..<(data.startIndex + end)])
        var payload: String?
        if decoded.attachments.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                payload = String(data: try encoder.encode(Decoded(h: decoded.headers, b: decoded.cleanedBody, q: decoded.quoted)), encoding: .utf8)
            } catch {
                KalsmritikoshLog.ingestion.error("mbox: a message decode not kept (decoded again next time): \(String(describing: error), privacy: .private)")
            }
        }
        state.withLock { s in
            s.parsed += 1
            if let payload { s.digests[start] = digest; s.fresh.append((digest, payload)) }
        }
    }

    static func decode(_ payload: String) -> Decoded? {
        do { return try JSONDecoder().decode(Decoded.self, from: Data(payload.utf8)) } catch {
            KalsmritikoshLog.ingestion.error("mbox: a kept message decode unreadable (decoded again): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    func noteStarts(_ s: [Int]) { state.withLock { $0.starts.append(contentsOf: s) } }
    var starts: [Int] { state.withLock { $0.starts } }
    var digests: [Int: String] { state.withLock { $0.digests } }
    var fresh: [(digest: String, payload: String)] { state.withLock { $0.fresh } }
    var parsed: Int { state.withLock { $0.parsed } }
    var reused: Int { state.withLock { $0.reused } }
}
