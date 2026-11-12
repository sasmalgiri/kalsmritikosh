//
//  CaseMapExport.swift
//  Kalsmritikosh
//
//  Living case map, M8 (plan §9): a map leaves the app only through CaseOutputService (prepareMap → write /
//  release), never as a screenshot of the canvas. What is exported is FROZEN from what the person sees: the
//  view, the items and links shown, the selection, the legend, the case, the moment or recorded state, the
//  scope fingerprint and every source. A picture alone cannot be traced to its sources, so every map export
//  carries a readable relationship and evidence table — in the PDF, and as the CSV that accompanies a PNG, or
//  alone. A historical export says which recorded state it depicts; current restrictions apply to it as to any
//  export (cited sources re-checked against the case's export policy now — a source labelled privileged since
//  refuses it — protected identities scrubbed and verified gone, the case's legal holds stated as they are now).
//
//  Pure rendering (CoreGraphics + CoreText + ImageIO, offline). No AI, no network.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public nonisolated enum CaseMapExportFormat: String, Sendable, CaseIterable {
    /// The map drawn on the first page, then the relationship and evidence table.
    case pdf
    /// The map as an image (always released with the CSV table beside it).
    case png
    /// The relationship and evidence table alone (also the text copied or printed).
    case csv
}

/// What the person is looking at, as it is when they choose Export.
public nonisolated struct CaseMapExportRequest: Sendable {
    public enum State: Sendable {
        /// The case as it is now (the time it was read).
        case current(Date)
        /// A recorded state (read-only history).
        case recorded(CaseCheckpointSummary)
    }
    public var projection: CaseMapProjection
    public var placements: [CaseMapNodeID: CaseMapPlacement]
    /// The items and links shown in the view (only these are exported).
    public var shown: [CaseMapNodeID]
    public var links: [String]
    public var selection: CaseMapNodeID?
    public var viewTitle: String
    public var state: State
    public var scopeFingerprint: String?

    public init(projection: CaseMapProjection, placements: [CaseMapNodeID: CaseMapPlacement], shown: [CaseMapNodeID], links: [String],
                selection: CaseMapNodeID?, viewTitle: String, state: State, scopeFingerprint: String?) {
        self.projection = projection; self.placements = placements; self.shown = shown; self.links = links
        self.selection = selection; self.viewTitle = viewTitle; self.state = state; self.scopeFingerprint = scopeFingerprint
    }
}

/// The frozen text of a map export, before and after protection (every string the bytes are rendered from).
public nonisolated struct CaseMapExportFrozen: Sendable, Equatable {
    public struct Item: Sendable, Equatable { public var ref: String, kind: String, title: String, state: String, review: String, recorded: String, event: String, sources: String }
    public struct Relation: Sendable, Equatable {
        public var from: String, type: String, to: String, why: String, assertedBy: String, state: String, sources: String
        public var fromRef: String, toRef: String
    }
    public var header: [String]
    public var legend: [String]
    public var items: [Item]
    public var relations: [Relation]
    public var citations: [StudioEvidenceRef]

    /// Every text the rendering uses (for the protected-identity check of the bytes).
    public var texts: [String] {
        header + legend + items.flatMap { [$0.ref, $0.kind, $0.title, $0.state, $0.review, $0.recorded, $0.event, $0.sources] }
            + relations.flatMap { [$0.from, $0.type, $0.to, $0.why, $0.assertedBy, $0.state, $0.sources] }
    }

    /// A copy with every string passed through `f` (protection).
    func mapped(_ f: (String) throws -> String) rethrows -> CaseMapExportFrozen {
        var c = self
        c.header = try header.map(f); c.legend = try legend.map(f)
        c.items = try items.map { Item(ref: $0.ref, kind: try f($0.kind), title: try f($0.title), state: try f($0.state), review: try f($0.review),
                                       recorded: $0.recorded, event: $0.event, sources: try f($0.sources)) }
        c.relations = try relations.map { Relation(from: try f($0.from), type: try f($0.type), to: try f($0.to), why: try f($0.why), assertedBy: try f($0.assertedBy),
                                                   state: try f($0.state), sources: try f($0.sources), fromRef: $0.fromRef, toRef: $0.toRef) }
        return c
    }
}

public nonisolated enum CaseMapExportRenderer {

    static func day(_ d: Date?) -> String { d.map { ISO8601DateFormatter.string(from: $0, timeZone: .gmt, formatOptions: [.withFullDate]) } ?? "" }
    static func stamp(_ d: Date) -> String { ISO8601DateFormatter.string(from: d, timeZone: .gmt, formatOptions: [.withInternetDateTime]) }

    static func sourcesText(_ refs: [CaseMapSourceRef]) -> String {
        refs.map { r in
            [r.documentName ?? "document", r.locatorText, r.quote.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " · ")
        }.joined(separator: " | ")
    }

    /// Freeze the request: the shown items, the links among them, the legend and the header naming the case,
    /// the moment or recorded state, the scope and the selection. `restrictions` are lines describing the
    /// restrictions applied now (holds, protection).
    public static func freeze(_ r: CaseMapExportRequest, restrictions: [String]) -> CaseMapExportFrozen {
        let p = r.projection
        let shown = Set(r.shown)
        let nodes = p.nodes.filter { shown.contains($0.id) }
        let links = r.links.compactMap { p.link($0) }.filter { shown.contains($0.from) && shown.contains($0.to) }
        var header = ["Case map — \(p.title)", "View: \(r.viewTitle)"]
        switch r.state {
        case .current(let at): header.append("State: the case as it was read at \(stamp(at)) (current).")
        case .recorded(let cp): header.append(cp.stateLabel)
        }
        if let q = p.question { header.append("Question: \(q)") }
        header.append("Scope fingerprint: \(r.scopeFingerprint ?? "not available")")
        header.append("Shown: \(nodes.count) of \(p.nodes.count) item(s) and \(links.count) of \(p.links.count) link(s) — the rest of the case is not in this export.")
        if let sel = r.selection, let n = p.node(sel) { header.append("Selected: \(n.title)") }
        header += restrictions
        header.append("A map's layout, size or tidiness says nothing about whether anything is proved. Every link is traced to its sources in the table.")
        let legend = CaseMapNodeKind.allCases.filter { $0 != .group }.map { "Item: \($0.label)" }
            + CaseMapLinkType.allCases.map { "Link: \($0.label) (\($0.stroke.rawValue) line)" }
            + CaseMapStatus.Kind.allCases.map { "State: \($0.label)" }
        let items = nodes.map { n in
            CaseMapExportFrozen.Item(ref: n.id.key, kind: n.kind.label, title: n.title, state: "\(n.status.kind.label): \(n.status.text)", review: n.review.label,
                                     recorded: day(n.recordedAt), event: day(n.eventDate), sources: sourcesText(n.sources))
        }
        let relations = links.map { l in
            CaseMapExportFrozen.Relation(from: p.node(l.from)?.title ?? l.from.key, type: l.type.label, to: p.node(l.to)?.title ?? l.to.key, why: l.basis,
                                         assertedBy: l.assertedBy.label, state: "\(l.status.kind.label): \(l.status.text) · \(l.review.label)",
                                         sources: sourcesText(l.sources), fromRef: l.from.key, toRef: l.to.key)
        }
        var cites: [StudioEvidenceRef] = []
        var seen = Set<String>()
        for ref in nodes.flatMap(\.sources) + links.flatMap(\.sources) {
            guard let v = ref.sourceVersionID else { continue }
            let key = "\(v.uuidString)|\(ref.quote ?? "")"
            if seen.insert(key).inserted { cites.append(StudioEvidenceRef(sourceVersionID: v, objectID: ref.objectID, quote: ref.quote)) }
        }
        return CaseMapExportFrozen(header: header, legend: legend, items: items, relations: relations, citations: cites)
    }

    static func csvField(_ s: String) -> String {
        // S14 (SEC-10): a cell a spreadsheet would run as a formula is written as text.
        let t = CSVFormulaGuard.neutralised(s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "))
        return t.contains(",") || t.contains("\"") ? "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : t
    }

    /// The relationship and evidence table (CSV): the header lines as comments, then one row per link and one
    /// row per item, each with its sources.
    public static func csv(_ f: CaseMapExportFrozen) -> String {
        var out = f.header.map { "# " + $0 }.joined(separator: "\n") + "\n"
        out += "row,from,relationship,to,why this link exists,asserted by,state,sources\n"
        for r in f.relations {
            out += ["link", r.from, r.type, r.to, r.why, r.assertedBy, r.state, r.sources].map(csvField).joined(separator: ",") + "\n"
        }
        out += "row,item,kind,title,state,review,recorded,event date,sources\n"
        for i in f.items {
            out += ["item", i.ref, i.kind, i.title, i.state, i.review, i.recorded, i.event, i.sources].map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: Drawing

    private static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        let base = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return bold ? (CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base) : base
    }
    private static func attributed(_ text: String, _ size: CGFloat, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
    }
    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, bold: Bool = false, ctx: CGContext) {
        let fs = CTFramesetterCreateWithAttributedString(attributed(text, size, bold: bold))
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    /// Draw the shown items and links into `area` (y grows upward, as in PDF space).
    static func drawMap(_ f: CaseMapExportFrozen, placements: [String: CaseMapPoint], area: CGRect, ctx: CGContext) {
        let pts = f.items.compactMap { placements[$0.ref] }
        guard !pts.isEmpty else {
            draw("No positioned items to draw; see the table.", in: area, size: 10, ctx: ctx)
            return
        }
        let minX = pts.map(\.x).min() ?? 0, maxX = pts.map(\.x).max() ?? 1, minY = pts.map(\.y).min() ?? 0, maxY = pts.map(\.y).max() ?? 1
        let box = CGSize(width: 120, height: 34)
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let scale = min((area.width - box.width) / w, (area.height - box.height) / h, 1.5)
        func at(_ ref: String) -> CGPoint? {
            guard let p = placements[ref] else { return nil }
            // World y grows downward on screen; PDF y grows upward.
            return CGPoint(x: area.minX + box.width / 2 + (p.x - minX) * scale, y: area.maxY - box.height / 2 - (p.y - minY) * scale)
        }
        ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1)); ctx.setLineWidth(0.8)
        for r in f.relations {
            guard let a = at(r.fromRef), let b = at(r.toRef) else { continue }
            let dashed = CaseMapLinkType.allCases.first { $0.label == r.type }?.stroke
            ctx.setLineDash(phase: 0, lengths: dashed == .dashed ? [5, 3] : dashed == .dotted ? [1.5, 2.5] : [])
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        for i in f.items {
            guard let c = at(i.ref) else { continue }
            let rect = CGRect(x: c.x - box.width / 2, y: c.y - box.height / 2, width: box.width, height: box.height)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1)); ctx.stroke(rect)
            draw("\(i.kind)\n\(String(i.title.prefix(48)))", in: rect.insetBy(dx: 3, dy: 2), size: 6.5, ctx: ctx)
        }
    }

    static func tableText(_ f: CaseMapExportFrozen) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(attributed("Relationships and their evidence\n", 13, bold: true))
        for r in f.relations {
            s.append(attributed("\(r.from) — \(r.type) — \(r.to)\n", 9, bold: true))
            s.append(attributed("Why: \(r.why)\nAsserted: \(r.assertedBy)\nState: \(r.state)\nSources: \(r.sources.isEmpty ? "none recorded" : r.sources)\n\n", 8.5))
        }
        s.append(attributed("Items\n", 13, bold: true))
        for i in f.items {
            s.append(attributed("\(i.kind): \(i.title)\n", 9, bold: true))
            s.append(attributed("State: \(i.state) · \(i.review)" + (i.recorded.isEmpty ? "" : " · recorded \(i.recorded)") + (i.event.isEmpty ? "" : " · event date \(i.event)")
                                + "\nSources: \(i.sources.isEmpty ? "none recorded" : i.sources)\n\n", 8.5))
        }
        s.append(attributed("Legend\n", 13, bold: true))
        s.append(attributed(f.legend.joined(separator: "\n") + "\n", 8.5))
        return s
    }

    /// PDF: the header and the map on page one, then the table on as many pages as it needs.
    public static func pdf(_ f: CaseMapExportFrozen, placements: [String: CaseMapPoint]) -> Data {
        var media = CGRect(x: 0, y: 0, width: 792, height: 612)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        draw(f.header.joined(separator: "\n"), in: CGRect(x: 36, y: 612 - 36 - 120, width: 720, height: 120), size: 8, ctx: ctx)
        drawMap(f, placements: placements, area: CGRect(x: 36, y: 36, width: 720, height: 612 - 36 - 36 - 130), ctx: ctx)
        ctx.endPDFPage()
        let table = tableText(f)
        let fs = CTFramesetterCreateWithAttributedString(table)
        var start = 0
        let path = CGPath(rect: CGRect(x: 36, y: 36, width: 720, height: 540), transform: nil)
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length <= 0 { break }
            start += visible.length
        } while start < table.length
        ctx.closePDF()
        return out as Data
    }

    /// PNG: the header and the map (the table goes beside it as CSV).
    public static func png(_ f: CaseMapExportFrozen, placements: [String: CaseMapPoint]) -> Data {
        let w = 1600, h = 1200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(f.header.joined(separator: "\n"), in: CGRect(x: 40, y: CGFloat(h) - 40 - 220, width: CGFloat(w) - 80, height: 220), size: 15, ctx: ctx)
        drawMap(f, placements: placements, area: CGRect(x: 40, y: 40, width: CGFloat(w) - 80, height: CGFloat(h) - 80 - 240), ctx: ctx)
        guard let image = ctx.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }

    static func points(_ r: CaseMapExportRequest) -> [String: CaseMapPoint] {
        var out: [String: CaseMapPoint] = [:]
        for (id, p) in r.placements { out[id.key] = p.point }
        return out
    }
}
