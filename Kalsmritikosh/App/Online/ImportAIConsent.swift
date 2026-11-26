//
//  ImportAIConsent.swift
//  Kalsmritikosh
//
//  Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. The once-per-import AI permission: when
//  the one online AI is set up, an import first asks whether its AI steps (chunk context labels, the first-
//  passage card, memory distillation, AI extraction, AI re-ranking, recording transcription, the enrichment
//  drain and background upkeep that follow it) may send the imported documents' text to the AI, with the
//  estimated cost. "Import without AI" imports with the app's own rules only. The decision covers this import
//  (ImportAIPermission.scope) and the background work that follows it; nothing is stored across launches.
//  Same pattern as CaseReadConsent (one sheet, one continuation).
//

import Foundation
import PDFKit
import Observation
import os

public nonisolated struct ImportAIConsentRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let provider: String
    public let files: Int
    public let bytes: Int64
    public let estimatedTokens: Int
    public let estimate: String
    /// The file count stopped at `ImportAIConsent.scanCap` (the import may hold more).
    public let countCapped: Bool
}

@MainActor
@Observable
public final class ImportAIConsent {
    public static let shared = ImportAIConsent()

    public private(set) var pending: ImportAIConsentRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// A test host answers for the person; nil in the app.
    public var scriptedAnswer: Bool?

    /// The most files counted for the estimate (the count is a guide, not the import plan).
    public nonisolated static let scanCap = 200_000
    /// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. The import-time AI reads each passage
    /// about once and a half (context label + card / distillation share), and writes about this much per file.
    nonisolated static let inputPasses = 1.5
    nonisolated static let replyTokensPerFile = 400

    public func request(_ request: ImportAIConsentRequest) async -> Bool {
        if let scriptedAnswer { return scriptedAnswer }
        while pending != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        return await withCheckedContinuation { c in
            continuation = c
            pending = request
        }
    }

    public func resolve(allow: Bool) {
        pending = nil
        continuation?.resume(returning: allow)
        continuation = nil
    }

    /// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. Ask once for an import of `urls`
    /// (files or folders). Not set up, or the import levers are off: the import runs without AI and nothing
    /// is asked. Returns the decision, already recorded for the background work that follows.
    public static func decide(for urls: [URL]) async -> ImportAIPermission.Grant {
        guard OneAI.isSetUp, ReleaseCapabilityProfile.current().ingestGenerativeLLMEnabled else {
            let g = ImportAIPermission.Grant(allowed: false)
            ImportAIPermission.record(g)
            return g
        }
        let (files, bytes, capped) = await Task.detached(priority: .utility) { size(of: urls) }.value
        // Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. The cost is estimated from the TEXT the files
        // hold (PDFs sampled and read, text files counted whole, packaged office files and images by kind), not file bytes.
        let textBytes = await Task.detached(priority: .utility) { estimatedTextBytes(of: urls) }.value
        let request = makeRequest(files: files, bytes: textBytes, capped: capped)
        let allowed = await shared.request(request)
        let g = ImportAIPermission.Grant(allowed: allowed)
        ImportAIPermission.record(g)
        KalsmritikoshLog.app.info("import AI permission: \(allowed ? "allowed" : "declined", privacy: .public) for \(files, privacy: .public) file(s)")
        return g
    }

    nonisolated static func makeRequest(files: Int, bytes: Int64, capped: Bool) -> ImportAIConsentRequest {
        let kind = OnlineSettings.kind
        let tokens = Int(Double(AIPricing.approximateTokens(characters: Int(min(bytes, Int64(Int.max / 2))))) * inputPasses)
        let replies = max(1, files) * replyTokensPerFile
        let estimate: String
        switch kind {
        case .included:
            estimate = "Estimated: up to \(AIPricing.estimateCredits(inputTokens: tokens, maxOutputTokens: replies).formatted()) credits (only the actual cost is charged; a file that holds little text costs little)."
        default:
            estimate = OwnKeyBudget.estimateLine(model: OnlineSettings.model, inputTokens: tokens, maxOutputTokens: replies)
                ?? "About \(tokens.formatted()) tokens of document text would be read."
        }
        return ImportAIConsentRequest(provider: kind.displayName, files: files, bytes: bytes, estimatedTokens: tokens,
                                      estimate: estimate, countCapped: capped)
    }

    /// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. How many PDFs are actually opened to count their
    /// text; the rest use the sampled PDFs' text-to-bytes ratio.
    nonisolated static let pdfSampleLimit = 40
    /// Characters of text counted per image (what OCR typically finds on a page-sized image).
    nonisolated static let charactersPerImage: Int64 = 1_500

    /// Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. The text the import's AI steps would read, estimated
    /// per kind: plain-text formats count whole (markup about half), PDFs are opened (up to `pdfSampleLimit`) and their text
    /// counted, the rest of the PDFs scaled by the sampled ratio, packaged office files a quarter of their bytes, images
    /// `charactersPerImage` each, audio/video/other binaries nothing (recordings are previewed per send). Stops at `scanCap`.
    nonisolated static func estimatedTextBytes(of urls: [URL]) -> Int64 {
        let textKinds: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "log", "eml", "emlx", "mbox", "rtf", "srt", "vtt", "ics", "vcf", "yaml", "yml"]
        let markupKinds: Set<String> = ["html", "htm", "xml", "xhtml"]
        let packagedKinds: Set<String> = ["docx", "xlsx", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "epub", "doc", "xls", "ppt", "msg", "pst"]
        let imageKinds: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "webp"]
        var total: Int64 = 0, pdfSampledBytes: Int64 = 0, pdfSampledText: Int64 = 0, pdfUnsampledBytes: Int64 = 0
        var pdfSampled = 0, seen = 0
        func add(_ f: URL, _ size: Int64) {
            let ext = f.pathExtension.lowercased()
            if textKinds.contains(ext) { total += size }
            else if markupKinds.contains(ext) { total += size / 2 }
            else if packagedKinds.contains(ext) { total += size / 4 }
            else if imageKinds.contains(ext) { total += charactersPerImage }
            else if ext == "pdf" {
                if pdfSampled < pdfSampleLimit, let doc = PDFDocument(url: f) {
                    pdfSampled += 1
                    let n = Int64(doc.string?.utf8.count ?? 0)
                    total += n; pdfSampledText += n; pdfSampledBytes += size
                } else { pdfUnsampledBytes += size }
            }
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        outer: for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: Set(keys + [.isDirectoryKey]))
            if values?.isDirectory != true { add(url, Int64(values?.fileSize ?? 0)); seen += 1; continue }
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                add(f, Int64(v.fileSize ?? 0)); seen += 1
                if seen >= scanCap { break outer }
            }
        }
        if pdfUnsampledBytes > 0 {
            // No sampled PDF had any bytes: assume a tenth of the bytes is text (a typical text PDF).
            let ratio = pdfSampledBytes > 0 ? Double(pdfSampledText) / Double(pdfSampledBytes) : 0.1
            total += Int64(Double(pdfUnsampledBytes) * ratio)
        }
        return total
    }

    /// Files and bytes under `urls` (regular files; folders walked; stops at `scanCap`).
    nonisolated static func size(of urls: [URL]) -> (files: Int, bytes: Int64, capped: Bool) {
        var files = 0, bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: Set(keys + [.isDirectoryKey]))
            if values?.isDirectory != true {
                files += 1; bytes += Int64(values?.fileSize ?? 0)
                continue
            }
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files += 1; bytes += Int64(v.fileSize ?? 0)
                if files >= scanCap { return (files, bytes, true) }
            }
        }
        return (files, bytes, false)
    }
}
