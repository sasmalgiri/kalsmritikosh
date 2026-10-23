//
//  KalsmritikoshShare.swift
//  KalsmritikoshShare (Share extension, com.apple.share-services)
//
//  W3-6 — "Save to Kalsmritikosh" in the Share menu of Finder, Safari, Mail, Preview
//  and any app that shares files, text or a web address. The extension has no
//  network entitlement and does not read the shared items' sources: it copies
//  exactly what the sharing app hands over into the app group's Inbox/, one folder
//  per item (written under a hidden name, then renamed, so the app never sees a
//  half-written item), with an item.json recording when, from where, and the
//  SHA-256 of the bytes. The app moves each item into its capture intake with a
//  custody line and reads it (Kalsmritikosh/App/ShareInbox.swift — keep the two
//  layouts identical).
//
//  A web address is saved as a .webloc (the address only): the page itself is not
//  downloaded, because nothing here may connect. To keep a page, share its text,
//  or save it as PDF / web archive in Safari and share that file.
//

import AppKit
import CryptoKit
import UniformTypeIdentifiers

enum ShareInboxWire {
    static let appGroup = "6TPTCJD42Q.ecosanskritiinnovation.Kalsmritikosh"
    static let inboxFolder = "Inbox"
    static let itemFile = "item.json"
    /// Mirrored by the app from the "Share and capture" module switch.
    static let enabledKey = "kalsmritikosh.share.enabled"
}

final class ShareViewController: NSViewController {
    private let label = NSTextField(labelWithString: "Saving to Investigations Made Easy…")

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))
        label.frame = NSRect(x: 20, y: 35, width: 320, height: 40)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        v.addSubview(label)
        view = v
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await run() }
    }

    private func finish(_ message: String, error: Bool) async {
        label.stringValue = message
        try? await Task.sleep(for: .seconds(error ? 2.5 : 0.8))
        if error {
            extensionContext?.cancelRequest(withError: NSError(domain: "Kalsmritikosh", code: 1,
                                                               userInfo: [NSLocalizedDescriptionKey: message]))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func run() async {
        let defaults = UserDefaults(suiteName: ShareInboxWire.appGroup)
        guard defaults?.bool(forKey: ShareInboxWire.enabledKey) == true else {
            await finish("“Share and capture” is switched off. Turn it on in Investigations Made Easy ▸ Settings ▸ Modules.", error: true)
            return
        }
        guard let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInboxWire.appGroup)?
            .appendingPathComponent(ShareInboxWire.inboxFolder, isDirectory: true) else {
            await finish("Investigations Made Easy's shared folder is not available.", error: true)
            return
        }
        let source = (extensionContext?.inputItems.first as? NSExtensionItem)?.attributedContentText?.string
        var saved = 0, failed = 0
        for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
            for provider in item.attachments ?? [] {
                if let payload = await Self.payload(from: provider) {
                    do { try Self.write(payload, origin: "Share menu" + (source.map { ": \($0.prefix(200))" } ?? ""), into: inbox); saved += 1 }
                    catch { failed += 1 }
                } else {
                    failed += 1
                }
            }
        }
        if saved == 0 {
            await finish("Nothing could be saved from this item.", error: true)
        } else {
            await finish("Saved \(saved) item\(saved == 1 ? "" : "s") for Investigations Made Easy" + (failed > 0 ? " (\(failed) could not be read)." : "."), error: false)
        }
    }

    struct Payload { let data: Data; let name: String; let kind: String }

    /// Files first (their own bytes and name), then a web address (as .webloc), then text.
    static func payload(from provider: NSItemProvider) async -> Payload? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url, let data = try? Data(contentsOf: url) {
                return Payload(data: data, name: url.lastPathComponent, kind: "file")
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL,
           let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0) {
            let host = url.host ?? "link"
            return Payload(data: plist, name: "\(host).webloc", kind: "web address (not downloaded)")
        }
        for type in [UTType.html, UTType.rtf, UTType.plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let value = try? await provider.loadItem(forTypeIdentifier: type.identifier)
            let data = (value as? Data) ?? (value as? String).map { Data($0.utf8) } ?? (value as? NSAttributedString).map { Data($0.string.utf8) }
            if let data, !data.isEmpty {
                let ext = type == .html ? "html" : type == .rtf ? "rtf" : "txt"
                return Payload(data: data, name: "Shared text.\(ext)", kind: type == .plainText ? "text" : ext)
            }
        }
        return nil
    }

    static func write(_ p: Payload, origin: String, into inbox: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = inbox.appendingPathComponent(".tmp-\(id)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let safe = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try p.data.write(to: staging.appendingPathComponent(safe.isEmpty ? "Shared item" : safe))
        let sha = SHA256.hash(data: p.data).map { String(format: "%02x", $0) }.joined()
        let meta: [String: String] = ["sharedAt": ISO8601DateFormatter().string(from: Date()), "origin": origin,
                                      "name": safe.isEmpty ? "Shared item" : safe, "kind": p.kind,
                                      "sha256": sha, "bytes": String(p.data.count)]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: staging.appendingPathComponent(ShareInboxWire.itemFile))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try fm.moveItem(at: staging, to: inbox.appendingPathComponent("\(stamp)-\(id)", isDirectory: true))
    }
}
