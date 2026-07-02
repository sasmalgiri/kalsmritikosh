//
//  Chunker.swift
//  Kalsmritikosh
//
//  Boundary-aware chunker. Splits a KnowledgeObject's content into
//  bounded Chunks for embeddings + LLM context, but respects STRUCTURAL
//  boundaries first (headings, paragraphs) and only falls back to
//  sentence-level splits when a single block exceeds the budget. The
//  prior implementation was sentence-only with a hard char budget,
//  which meant a 2000-char paragraph could end up split mid-paragraph
//  into two chunks that lost their topical coherence — bad for both
//  embedding similarity AND citation snippets.
//
//  Strategy (in order):
//
//    1. Split content into BLOCKS:
//       - lines starting with `#` (markdown heading) → standalone block,
//         and ALWAYS terminate the running chunk before emitting them
//       - lines matching `Subject:` / `From:` / `To:` / `Date:`
//         (email headers) → standalone short blocks
//       - paragraphs separated by blank lines
//
//    2. Pack blocks into chunks up to `targetCharacterCount`:
//       - if a single block exceeds the budget, fall back to sentence
//         splits within just that block
//       - otherwise group small adjacent blocks until the budget fills
//
//  Output Chunk model is unchanged — same char-range, ordinal, page
//  number contract so SourceViewer + citation highlighting still work.
//

import Foundation
import NaturalLanguage

public struct Chunker: Sendable {
    public let targetCharacterCount: Int
    /// Below this size, an emitted chunk gets merged into the next
    /// block instead of standing alone. Prevents micro-chunks
    /// (single-line headings) from being treated as standalone
    /// retrieval candidates.
    public let minChunkCharacterCount: Int
    /// Sentence-level overlap (in characters) carried between
    /// consecutive sub-chunks when a large block is split by sentence.
    /// Standard RAG practice: ~10-15% overlap so an answer that
    /// straddles a chunk boundary isn't severed across two unrelated
    /// vectors. Only applies inside `sentenceSplit` — the block-packing
    /// path is already boundary-aware (paragraphs / headings), so no
    /// overlap is needed there. 0 disables overlap.
    public let overlapCharacterCount: Int

    public nonisolated init(
        targetCharacterCount: Int = 1200,
        minChunkCharacterCount: Int = 80,
        overlapCharacterCount: Int = 160
    ) {
        self.targetCharacterCount = targetCharacterCount
        self.minChunkCharacterCount = minChunkCharacterCount
        self.overlapCharacterCount = overlapCharacterCount
    }

    // MARK: - Adaptive sizing for ANY model / device / context

    /// Hard floor / ceiling on chunk size in characters.
    ///
    /// `minTargetCharacterCount` — under this, a single chunk no
    /// longer carries enough semantic content for an embedding to be
    /// distinguishable in vector space. Lookup recall collapses.
    ///
    /// `maxTargetCharacterCount` — over this, embeddings dilute (one
    /// vector represents too many topics) and Gate-1 L1 precision
    /// drops. The cap is a quality decision, not a memory one.
    public static let minTargetCharacterCount: Int = 800
    public static let maxTargetCharacterCount: Int = 2400

    /// Diagnostic output of `Chunker.diagnose(...)` — the computed
    /// target plus warnings about mismatches between the chosen
    /// model and the user's device. AppState logs the warnings on
    /// boot so misconfigurations are visible up front.
    public struct SizingDiagnostic: Sendable, Equatable {
        public let target: Int
        public let warnings: [String]

        public init(target: Int, warnings: [String]) {
            self.target = target
            self.warnings = warnings
        }
    }

    /// Primary sizing API — adaptive to ANY context window and ANY
    /// device RAM. The discrete-tier overloads below delegate here.
    ///
    /// Formula:
    ///   chars  = max(1024, tokens) × 4 / 12   (English ≈ 4 chars/token)
    ///   chars *= ramFactor                    (≤ 1.0; floor 0.3 — see below)
    ///   chars  = clamp(chars, 800, 2400)
    ///
    /// RAM factor: `min(1.0, totalRAMBytes / 16 GB)` with a floor of
    /// 0.3. Why 16 GB as the unit? It's the modern Mac baseline where
    /// a typical 8B Q4 reasoning model fits comfortably alongside the
    /// OS and app. The floor of 0.3 means even a 2 GB device gets a
    /// usable chunk (800 chars after clamping) rather than crashing
    /// to zero. Devices smaller than that won't run any local LLM
    /// reasoning meaningfully anyway.
    ///
    /// Worked examples (16 GB RAM = factor 1.0):
    ///   llama3 8B,    8K tokens  → 2400  (clamped)
    ///   qwen2.5 14B, 32K tokens  → 2400  (clamped)
    ///   tiny 1B,     1K tokens   →  800  (floored — too small to be useful)
    ///   tokens = 0 (missing)     →  800  (defaulted to safe min)
    ///
    /// Worked examples (8 GB RAM = factor 0.5):
    ///   llama3 8B,    8K tokens  → 1365  (scaled down for RAM)
    ///   qwen2.5 14B, 32K tokens  → 2400  (clamped)
    ///
    /// Worked examples (4 GB RAM = factor 0.30 floor):
    ///   any model                →  800  (effectively forced to floor)
    public static func targetForContextWindow(
        tokens: Int,
        totalRAMBytes: Int
    ) -> Int {
        // Default to 4K tokens if the manifest is missing or
        // nonsense — a safe middle ground for unknown models.
        let safeTokens = tokens >= 1024 ? tokens : (tokens > 0 ? 1024 : 4_096)
        let charsByContext = safeTokens * 4 / 12
        let safeBytes = max(0, totalRAMBytes)
        let ramGB = Double(safeBytes) / 1_073_741_824
        let ramFactor = max(0.3, min(1.0, ramGB / 16.0))
        let scaled = Int(Double(charsByContext) * ramFactor)
        return max(minTargetCharacterCount, min(scaled, maxTargetCharacterCount))
    }

    /// Tier-based overload — used by call sites that only have the
    /// coarse hardware tier. Each tier maps to a representative RAM
    /// size (small=8 GB / medium=16 GB / large=32 GB) which is then
    /// fed through the primary RAM-bytes API. Preferring this tier
    /// API over the RAM API costs a small accuracy loss but lets
    /// callers without HardwareProbe access still call in.
    public static func targetForContextWindow(
        tokens: Int,
        hardwareTier: ModelManifest.Tier = .large
    ) -> Int {
        let representativeRAM: Int = {
            switch hardwareTier {
            case .small: return 8 * 1_073_741_824
            case .medium: return 16 * 1_073_741_824
            case .large: return 32 * 1_073_741_824
            }
        }()
        return targetForContextWindow(
            tokens: tokens,
            totalRAMBytes: representativeRAM
        )
    }

    /// Produce a sizing target PLUS warnings for any device/model
    /// mismatch. Use this at boot to log a clear up-front signal
    /// when the user has chosen a combo that won't behave well —
    /// rather than silently sizing badly and hoping nobody notices.
    ///
    /// Warnings surfaced (any combination):
    ///   - Model context window is missing / zero
    ///   - Model context window < 1K (chunks forced to floor; LLM
    ///     context-prefix prompts will struggle to fit prompt + answer)
    ///   - Model's required RAM > total device RAM (model will OOM or
    ///     swap heavily; ingest will be unusable)
    ///   - Model RAM > 70% of device RAM (ingest will compete with
    ///     everything else on the machine)
    public static func diagnose(
        modelContextTokens: Int,
        modelRequiredRAMBytes: Int,
        totalRAMBytes: Int
    ) -> SizingDiagnostic {
        var warnings: [String] = []

        if modelContextTokens <= 0 {
            warnings.append("model context window is 0 or missing; defaulting chunk sizing to a safe 4K-token assumption")
        } else if modelContextTokens < 1_024 {
            warnings.append("model context window=\(modelContextTokens) is below 1K — per-chunk LLM prompts may not fit prompt+answer+buffer")
        }

        let safeDeviceBytes = max(0, totalRAMBytes)
        let safeModelBytes = max(0, modelRequiredRAMBytes)
        if safeDeviceBytes > 0 && safeModelBytes > safeDeviceBytes {
            let modelGB = String(format: "%.1f", Double(safeModelBytes) / 1_073_741_824)
            let deviceGB = String(format: "%.1f", Double(safeDeviceBytes) / 1_073_741_824)
            warnings.append("model needs \(modelGB) GB RAM but device has only \(deviceGB) GB — model will OOM or swap heavily; choose a smaller model")
        } else if safeDeviceBytes > 0 && Double(safeModelBytes) > Double(safeDeviceBytes) * 0.7 {
            let pct = Int((Double(safeModelBytes) / Double(safeDeviceBytes)) * 100)
            warnings.append("model uses \(pct)% of device RAM — ingest will compete with other apps and likely thrash the cache")
        }

        let target = targetForContextWindow(
            tokens: modelContextTokens,
            totalRAMBytes: totalRAMBytes
        )
        return SizingDiagnostic(target: target, warnings: warnings)
    }

    public nonisolated func chunk(
        objectID: KnowledgeObject.ID,
        content: String,
        pageBreaks: [Int] = []
    ) -> [Chunk] {
        guard !content.isEmpty else { return [] }

        let blocks = splitIntoBlocks(content)
        var chunks: [Chunk] = []
        var ordinal = 0

        var bufferStart: Int?
        var bufferEnd: Int = 0
        var bufferText: String = ""

        func flush() {
            guard let start = bufferStart, bufferEnd > start, !bufferText.isEmpty else {
                bufferStart = nil
                bufferEnd = 0
                bufferText = ""
                return
            }
            chunks.append(Chunk(
                objectID: objectID,
                ordinal: ordinal,
                text: bufferText,
                characterRange: start..<bufferEnd,
                pageNumber: nearestPage(for: start, breaks: pageBreaks)
            ))
            ordinal += 1
            bufferStart = nil
            bufferEnd = 0
            bufferText = ""
        }

        for block in blocks {
            // Strong-boundary block (heading) — always flush before
            // emitting so a heading starts its own chunk group.
            if block.isStrongBoundary {
                flush()
            }

            // Block exceeds the budget on its own — split by
            // sentences and emit each sub-chunk separately.
            if block.length > targetCharacterCount {
                flush()
                for sub in sentenceSplit(content, range: block.start..<block.end) {
                    chunks.append(Chunk(
                        objectID: objectID,
                        ordinal: ordinal,
                        text: sub.text,
                        characterRange: sub.start..<sub.end,
                        pageNumber: nearestPage(for: sub.start, breaks: pageBreaks)
                    ))
                    ordinal += 1
                }
                continue
            }

            // Would adding this block overflow? Flush first.
            let currentLen = bufferStart != nil ? (bufferEnd - bufferStart!) : 0
            if currentLen + block.length > targetCharacterCount && currentLen >= minChunkCharacterCount {
                flush()
            }

            // Append the block.
            if bufferStart == nil {
                bufferStart = block.start
            }
            bufferEnd = block.end
            if !bufferText.isEmpty { bufferText += "\n\n" }
            bufferText += block.text
        }

        flush()
        return chunks
    }

    // MARK: - Block detection

    private nonisolated struct Block {
        let start: Int
        let end: Int
        let text: String
        let isStrongBoundary: Bool
        var length: Int { end - start }
    }

    private nonisolated func splitIntoBlocks(_ content: String) -> [Block] {
        var blocks: [Block] = []
        let index = content.startIndex
        let utf16Start = content.utf16.startIndex
        var paragraphStartUTF16: Int? = nil
        var paragraphLines: [String] = []

        // Split on lines so we can detect heading + blank-line
        // structure without paying for a full regex pass.
        let lines = content.components(separatedBy: "\n")
        var cursor = 0 // utf16 offset

        func flushParagraph() {
            guard let start = paragraphStartUTF16, !paragraphLines.isEmpty else {
                paragraphStartUTF16 = nil
                paragraphLines.removeAll()
                return
            }
            let joined = paragraphLines.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let end = start + joined.utf16.count
                blocks.append(Block(start: start, end: end, text: joined, isStrongBoundary: false))
            }
            paragraphStartUTF16 = nil
            paragraphLines.removeAll()
        }

        for (i, line) in lines.enumerated() {
            let lineUTF16Count = line.utf16.count
            let lineStart = cursor
            // +1 for the "\n" we split on, except last line
            let next = i < lines.count - 1 ? cursor + lineUTF16Count + 1 : cursor + lineUTF16Count
            defer { cursor = next; _ = utf16Start; _ = index }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line — paragraph boundary
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Markdown heading — always its own block, marked as strong
            if isHeading(trimmed) || isEmailHeader(trimmed) {
                flushParagraph()
                blocks.append(Block(
                    start: lineStart,
                    end: lineStart + lineUTF16Count,
                    text: line,
                    isStrongBoundary: true
                ))
                continue
            }

            // Regular content line — accumulate into the running paragraph
            if paragraphStartUTF16 == nil {
                paragraphStartUTF16 = lineStart
            }
            paragraphLines.append(line)
        }

        flushParagraph()
        return blocks
    }

    private nonisolated func isHeading(_ line: String) -> Bool {
        // Markdown ATX heading
        if line.hasPrefix("#") {
            // Must have content after the hashes
            return line.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil
        }
        return false
    }

    private nonisolated func isEmailHeader(_ line: String) -> Bool {
        // Common email-style header lines
        return line.range(
            of: #"^(Subject|From|To|Cc|Bcc|Date|Reply-To|Message-Id):\s"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Sentence fallback

    private struct SentenceChunk {
        let text: String
        let start: Int
        let end: Int
    }

    /// Sentence-aware split inside a block that's too big for the
    /// budget. Uses NLTokenizer for the sentence boundaries; packs
    /// sentences into char-budget chunks.
    private nonisolated func sentenceSplit(
        _ content: String,
        range: Range<Int>
    ) -> [SentenceChunk] {
        // Resolve UTF-16 range to String indices for the tokenizer.
        let utf16 = content.utf16
        guard let from = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
              let to = utf16.index(utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex),
              let stringFrom = from.samePosition(in: content),
              let stringTo = to.samePosition(in: content),
              stringFrom < stringTo else {
            return []
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = content

        // Collect sentence spans (UTF-16 offsets) so we can pack them
        // with overlap in a second pass — the enumerate closure is
        // forward-only, which can't look back to carry overlap.
        var sentences: [(lower: Int, upper: Int)] = []
        tokenizer.enumerateTokens(in: stringFrom..<stringTo) { tokenRange, _ in
            let lower = utf16.distance(from: utf16.startIndex, to: tokenRange.lowerBound)
            let upper = utf16.distance(from: utf16.startIndex, to: tokenRange.upperBound)
            if upper > lower { sentences.append((lower, upper)) }
            return true
        }
        guard !sentences.isEmpty else { return [] }

        func sentLen(_ i: Int) -> Int { sentences[i].upper - sentences[i].lower }

        var out: [SentenceChunk] = []
        var i = 0
        while i < sentences.count {
            // Greedily fill a chunk from sentence i up to the budget
            // (always take at least one sentence, even if oversized).
            var j = i
            var len = 0
            while j < sentences.count {
                let next = sentLen(j)
                if j > i && len + next > targetCharacterCount { break }
                len += next
                j += 1
            }
            let start = sentences[i].lower
            let end = sentences[j - 1].upper
            out.append(SentenceChunk(
                text: substring(content, lower: start, upper: end),
                start: start,
                end: end
            ))

            if j >= sentences.count { break }

            // Overlap: rewind the next chunk's start by trailing
            // sentences totalling ≤ overlapCharacterCount, while always
            // guaranteeing forward progress (i strictly increases).
            var back = j - 1
            var acc = 0
            while back > i && acc + sentLen(back) <= overlapCharacterCount {
                acc += sentLen(back)
                back -= 1
            }
            i = max(i + 1, back + 1)
        }

        return out
    }

    // MARK: - Helpers

    private nonisolated func substring(_ s: String, lower: Int, upper: Int) -> String {
        let from = s.utf16.index(s.utf16.startIndex, offsetBy: max(0, lower))
        let to = s.utf16.index(s.utf16.startIndex, offsetBy: min(s.utf16.count, upper))
        return String(String.UnicodeScalarView(s.utf16[from..<to].compactMap(Unicode.Scalar.init)))
    }

    private nonisolated func nearestPage(for offset: Int, breaks: [Int]) -> Int? {
        guard !breaks.isEmpty else { return nil }
        var page = 1
        for b in breaks { if offset >= b { page += 1 } else { break } }
        return page
    }
}
