//
//  MistralOCREngine.swift
//  Kalsmritikosh
//
//  Cloud OCR via Mistral's /v1/ocr endpoint. Top-tier on 2026
//  benchmarks for complex layouts and mixed scripts — handles
//  rotated text, watermarks, tables, equations, and handwriting
//  in a single forward pass. Costs ~$1 per 1000 pages.
//
//  Drops into the OCREngine protocol. ImageLoader / PDFLoader pick
//  it up via constructor injection:
//      ImageLoader(ocr: MistralOCREngine(apiKey: key))
//
//  Privacy: the image is uploaded to Mistral's API. PrivacyGate
//  callers must verify the user has opted into cloud routing
//  before resolving this engine.
//

import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
#endif

public actor MistralOCREngine: OCREngine {
    public nonisolated let engineID = "mistral-ocr"

    /// Default Mistral OCR endpoint. The user can override if they're
    /// proxying through an internal gateway.
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.mistral.ai/v1")!,
        model: String = "mistral-ocr-latest"
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func recognizePrinted(at url: URL) async -> [String] {
        await recognize(at: url)
    }

    public func recognizeHandwritten(at url: URL) async -> [String] {
        // Mistral OCR is a single end-to-end VLM — no separate
        // handwriting model. Same path as printed.
        await recognize(at: url)
    }

    public func recognizeTable(at url: URL) async -> [[String]] {
        let lines = await recognize(at: url)
        // Mistral returns markdown by default; split a markdown
        // table row "| a | b | c |" into ["a", "b", "c"]. Falls
        // through to tab-split for non-markdown lines.
        return lines.map { line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                return trimmed
                    .dropFirst().dropLast()
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return trimmed.split(separator: "\t").map(String.init)
        }
    }

    /// One OCR call. Encodes the image as base64 data URL and POSTs
    /// to /v1/ocr. Mistral returns one entry per detected page; we
    /// concatenate `markdown` content split by paragraph.
    private func recognize(at url: URL) async -> [String] {
        guard let payload = encodePayload(url: url) else {
            AtlasLog.knowledge.error("MistralOCREngine: failed to encode \(url.lastPathComponent, privacy: .public)")
            return []
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("ocr"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AtlasLog.knowledge.error("MistralOCREngine: HTTP call failed for \(url.lastPathComponent, privacy: .public) — \(String(describing: error), privacy: .public)")
            return []
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            AtlasLog.knowledge.error("MistralOCREngine: HTTP \(http.statusCode, privacy: .public): \(bodyStr.prefix(400), privacy: .public)")
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = root["pages"] as? [[String: Any]]
        else {
            return []
        }
        // Concatenate per-page markdown, split by blank lines.
        var lines: [String] = []
        for page in pages {
            guard let markdown = page["markdown"] as? String else { continue }
            for block in markdown.components(separatedBy: "\n\n") {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        return lines
    }

    private nonisolated func encodePayload(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mimeType: String = {
            switch url.pathExtension.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "tiff", "tif": return "image/tiff"
            case "webp": return "image/webp"
            case "heic": return "image/heic"
            case "pdf": return "application/pdf"
            default: return "application/octet-stream"
            }
        }()
        let base64 = data.base64EncodedString()
        let dataURL = "data:\(mimeType);base64,\(base64)"
        let body: [String: Any] = [
            "model": model,
            "document": [
                "type": "image_url",
                "image_url": dataURL
            ],
            "include_image_base64": false
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }
}
