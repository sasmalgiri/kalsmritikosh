//
//  TextLoader.swift
//  Atlas chronica memora
//
//  Plain-text, Markdown, and RTF. RTF uses NSAttributedString to peel
//  formatting; the others read as UTF-8 with replacement fallback.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct TextLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.txt, .markdown, .rtf]

    public init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }

        let content: String
        switch type {
        case .rtf:
            #if canImport(AppKit)
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                content = attr.string
            } else {
                content = String(decoding: data, as: UTF8.self)
            }
            #else
            content = String(decoding: data, as: UTF8.self)
            #endif
        default:
            content = String(decoding: data, as: UTF8.self)
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent))
            ]
        )
    }
}
