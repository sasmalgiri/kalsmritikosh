//
//  ClipPayload.swift
//  KalsmritikoshClipper
//
//  X-4 — what one clip becomes. The Safari extension sends the page the browser already has
//  (its HTML, the selection, title and address); this turns that into ONE item in the app
//  group's Inbox/, in exactly the Share extension's hand-over format (payload file +
//  item.json with the SHA-256), so the app imports it unchanged (ShareInbox.drain).
//  Nothing here fetches anything.
//

import Foundation
import CryptoKit

enum ClipperWire {
    static let appGroup = "6TPTCJD42Q.ecosanskritiinnovation.Kalsmritikosh"
    static let inboxFolder = "Inbox"
    static let itemFile = "item.json"
    /// Mirrored by the app from the "Share and capture" module switch.
    static let enabledKey = "kalsmritikosh.share.enabled"
    /// A page larger than this is refused with a sentence rather than cut.
    static let maxBytes = 25 * 1024 * 1024
}

struct ClipRequest: Equatable {
    enum Kind: String { case page, selection, markdown }

    let kind: Kind
    let title: String
    let url: String
    let html: String
    let text: String

    enum Refusal: Error, Equatable, LocalizedError {
        case notAClip, empty, tooLarge(Int), switchedOff, noInbox
        var errorDescription: String? {
            switch self {
            case .notAClip: return "That was not a clip request."
            case .empty: return "There was nothing to clip — select some text, or clip the whole page."
            case .tooLarge(let mb): return "This page is \(mb) MB, more than the 25 MB a clip can be. Save it as PDF and add that instead."
            case .switchedOff: return "Clipping is off. Turn on \u{201C}Share and capture\u{201D} in Kalsmritikosh \u{25B8} Settings \u{25B8} Modules."
            case .noInbox: return "Kalsmritikosh's shared folder could not be opened."
            }
        }
    }

    /// Read the message the extension's JavaScript sent.
    init(message: Any?) throws {
        guard let m = message as? [String: Any], (m["action"] as? String) == "clip",
              let kind = (m["kind"] as? String).flatMap(Kind.init) else { throw Refusal.notAClip }
        self.kind = kind
        self.title = ((m["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = (m["url"] as? String) ?? ""
        self.html = (m["html"] as? String) ?? ""
        self.text = (m["text"] as? String) ?? ""
    }

    init(kind: Kind, title: String, url: String, html: String, text: String) {
        self.kind = kind; self.title = title; self.url = url; self.html = html; self.text = text
    }

    struct Payload: Equatable {
        let name: String
        let data: Data
        /// "page" | "selection" | "markdown" — "markdown" asks the app to add a Markdown rendering.
        let kind: String
    }

    /// A file name from the page title (or its address), safe for any file system.
    static func fileStem(title: String, url: String) -> String {
        let base = title.isEmpty ? (URL(string: url)?.host ?? "Web page") : title
        let cleaned = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(120))
        return short.isEmpty ? "Web page" : (short.hasPrefix(".") ? "-" + short.dropFirst() : short)
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The item to hand over. The page's address is kept inside the file (a comment and a
    /// meta tag) so the archive knows where it came from.
    func payload(clippedAt date: Date = Date()) throws -> Payload {
        let stamp = ISO8601DateFormatter().string(from: date)
        let header = "<!-- Clipped by Kalsmritikosh from \(Self.escaped(url)) at \(stamp) -->\n"
        let meta = "<meta name=\"kalsmritikosh-source\" content=\"\(Self.escaped(url))\">"
        let stem = Self.fileStem(title: title, url: url)
        let body: String
        switch kind {
        case .page, .markdown:
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.empty }
            if let head = html.range(of: "<head>", options: .caseInsensitive) {
                var h = html
                h.insert(contentsOf: meta, at: head.upperBound)
                body = header + h
            } else {
                body = header + "<html><head>\(meta)<title>\(Self.escaped(title))</title></head><body>\(html)</body></html>"
            }
        case .selection:
            let fragment = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "<pre>\(Self.escaped(text))</pre>" : html
            guard !(html + text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.empty }
            body = header + "<html><head>\(meta)<title>\(Self.escaped(title))</title></head><body>"
                + "<p><a href=\"\(Self.escaped(url))\">\(Self.escaped(title.isEmpty ? url : title))</a></p>\(fragment)</body></html>"
        }
        let data = Data(body.utf8)
        guard data.count <= ClipperWire.maxBytes else { throw Refusal.tooLarge(data.count / 1_048_576) }
        let suffix = kind == .selection ? " (selection)" : ""
        return Payload(name: "\(stem)\(suffix).html", data: data, kind: kind.rawValue)
    }

    /// Write one item into the inbox: staged under a hidden name, then moved into place, so
    /// the app never sees a half-written item.
    static func write(_ p: Payload, origin: String, url: String, into inbox: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = inbox.appendingPathComponent(".tmp-\(id)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try p.data.write(to: staging.appendingPathComponent(p.name))
        let sha = SHA256.hash(data: p.data).map { String(format: "%02x", $0) }.joined()
        let meta: [String: String] = ["sharedAt": ISO8601DateFormatter().string(from: Date()), "origin": origin,
                                      "name": p.name, "kind": p.kind, "sha256": sha,
                                      "bytes": String(p.data.count), "url": url]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: staging.appendingPathComponent(ClipperWire.itemFile))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let final = inbox.appendingPathComponent("\(stamp)-\(id)", isDirectory: true)
        try fm.moveItem(at: staging, to: final)
        return final
    }
}
