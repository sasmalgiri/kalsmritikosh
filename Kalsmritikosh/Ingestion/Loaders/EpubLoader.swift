//
//  EpubLoader.swift
//  Kalsmritikosh
//
//  EPUB is a ZIP archive containing META-INF/container.xml (locates the
//  package OPF), an OPF manifest (lists every resource + a `spine` that
//  defines reading order), and a tree of XHTML chapter files. Inspired
//  by Python's ebooklib + EbookConverter: walk the spine in order,
//  strip HTML to readable plaintext, and emit each chapter as a markdown
//  section so the chunker can split per chapter.
//

import Foundation

public struct EpubLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.epub]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        guard type == .epub else { throw IngestorError.unsupportedType(type) }
        let zip = try ZIPReader(url: url)

        // 1. Locate the OPF via META-INF/container.xml.
        let containerData: Data
        do { containerData = try zip.read("META-INF/container.xml") }
        catch { throw IngestorError.parseFailure(url, reason: "missing META-INF/container.xml") }
        guard let opfPath = Self.opfPath(from: containerData) else {
            throw IngestorError.parseFailure(url, reason: "container.xml has no rootfile path")
        }

        // 2. Read the OPF and pull spine items in reading order.
        let opfData: Data
        do { opfData = try zip.read(opfPath) }
        catch { throw IngestorError.parseFailure(url, reason: "missing OPF \(opfPath)") }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let (manifest, spine, title) = Self.parseOPF(opfData)
        guard !spine.isEmpty else {
            throw IngestorError.parseFailure(url, reason: "OPF spine is empty")
        }

        // 3. For each spine item, hydrate the chapter file and convert
        //    its XHTML body to plain text. Chapters land under markdown
        //    headings so the chunker treats them as natural splits.
        var pieces: [String] = []
        if let title, !title.isEmpty {
            pieces.append("# \(title)")
            pieces.append("")
        }
        var chapterCount = 0
        for idref in spine {
            guard let manifestPath = manifest[idref] else { continue }
            let chapterPath = opfDir.isEmpty
                ? manifestPath
                : "\(opfDir)/\(manifestPath)"
            guard let data = try? zip.read(chapterPath) else { continue }
            let text = Self.xhtmlToPlain(data)
            if text.isEmpty { continue }
            chapterCount += 1
            pieces.append("## Chapter \(chapterCount)")
            pieces.append("")
            pieces.append(text)
            pieces.append("")
        }
        let content = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw IngestorError.empty(url) }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .epub,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("epub-opf")),
                "chapterCount": AnyCodable(.int(Int64(chapterCount))),
                "binarySize": AnyCodable(.int(size)),
                "title": AnyCodable(.string(title ?? ""))
            ]
        )
    }

    // MARK: - OPF / container parsing

    static func opfPath(from container: Data) -> String? {
        let xml = String(decoding: container, as: UTF8.self)
        // <rootfile full-path="..." ...
        guard let r = xml.range(of: "full-path=\"") else { return nil }
        let valueStart = r.upperBound
        guard let valueEnd = xml.range(of: "\"", range: valueStart..<xml.endIndex) else { return nil }
        return String(xml[valueStart..<valueEnd.lowerBound])
    }

    /// Returns (manifest mapping id → href, spine ordered idrefs, dc:title).
    static func parseOPF(_ opf: Data) -> ([String: String], [String], String?) {
        let xml = String(decoding: opf, as: UTF8.self)
        var manifest: [String: String] = [:]
        var spine: [String] = []
        var title: String? = nil

        // dc:title
        if let tOpen = xml.range(of: "<dc:title"),
           let tHead = xml.range(of: ">", range: tOpen.upperBound..<xml.endIndex),
           let tClose = xml.range(of: "</dc:title>", range: tHead.upperBound..<xml.endIndex) {
            title = String(xml[tHead.upperBound..<tClose.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // manifest items
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let mOpen = xml.range(of: "<item ", range: cursor..<xml.endIndex),
                  let mClose = xml.range(of: "/>", range: mOpen.upperBound..<xml.endIndex)
            else { break }
            let attrs = String(xml[mOpen.upperBound..<mClose.lowerBound])
            if let id = Self.attr(attrs, "id"),
               let href = Self.attr(attrs, "href") {
                manifest[id] = href
            }
            cursor = mClose.upperBound
        }

        // spine — only `<itemref idref="..."/>` matters; ignore guide/nav.
        cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let sOpen = xml.range(of: "<itemref ", range: cursor..<xml.endIndex),
                  let sClose = xml.range(of: "/>", range: sOpen.upperBound..<xml.endIndex)
            else { break }
            let attrs = String(xml[sOpen.upperBound..<sClose.lowerBound])
            if let idref = Self.attr(attrs, "idref") {
                spine.append(idref)
            }
            cursor = sClose.upperBound
        }

        return (manifest, spine, title)
    }

    private static func attr(_ attrs: String, _ name: String) -> String? {
        guard let range = attrs.range(of: "\(name)=\"") else { return nil }
        let start = range.upperBound
        guard let end = attrs.range(of: "\"", range: start..<attrs.endIndex) else { return nil }
        return String(attrs[start..<end.lowerBound])
    }

    /// XHTML chapter → readable plaintext. Walks the body and emits
    /// paragraphs (`<p>`) and list items (`<li>`) on their own lines so
    /// the chunker sees structural breaks. Falls back to DocxLoader's
    /// blob tag-stripper when the tree can't be walked.
    static func xhtmlToPlain(_ data: Data) -> String {
        let html = String(decoding: data, as: UTF8.self)
        var pieces: [String] = []
        var cursor = html.startIndex
        // Only consider what's inside <body> if present — gets rid of
        // <head> noise like script/style.
        var scope = html
        if let bodyOpen = html.range(of: "<body"),
           let bodyHead = html.range(of: ">", range: bodyOpen.upperBound..<html.endIndex),
           let bodyClose = html.range(of: "</body>", range: bodyHead.upperBound..<html.endIndex) {
            scope = String(html[bodyHead.upperBound..<bodyClose.lowerBound])
            cursor = scope.startIndex
        } else {
            cursor = scope.startIndex
        }
        // Block-level tags whose text contents become their own paragraph.
        let blockTags = ["h1","h2","h3","h4","h5","h6","p","li","blockquote"]
        for tag in blockTags {
            let openPattern = "<\(tag)"
            let closePattern = "</\(tag)>"
            var c = scope.startIndex
            while c < scope.endIndex {
                guard let o = scope.range(of: openPattern, range: c..<scope.endIndex),
                      let oHead = scope.range(of: ">", range: o.upperBound..<scope.endIndex),
                      let close = scope.range(of: closePattern, range: oHead.upperBound..<scope.endIndex)
                else { break }
                let body = String(scope[oHead.upperBound..<close.lowerBound])
                let plain = DocxLoader.stripTags(body)
                if !plain.isEmpty {
                    let prefix: String
                    switch tag {
                    case "h1": prefix = "# "
                    case "h2": prefix = "## "
                    case "h3": prefix = "### "
                    case "h4": prefix = "#### "
                    case "h5": prefix = "##### "
                    case "h6": prefix = "###### "
                    case "li": prefix = "- "
                    case "blockquote": prefix = "> "
                    default: prefix = ""
                    }
                    pieces.append(prefix + plain)
                }
                c = close.upperBound
            }
        }
        _ = cursor // silence unused warning
        if pieces.isEmpty {
            // Last resort — strip every tag.
            return DocxLoader.stripTags(scope)
        }
        return pieces.joined(separator: "\n\n")
    }
}
