//
//  DeepLink.swift
//  Kalsmritikosh
//
//  W1-5 — links to passages that work from any app:
//    kalsmritikosh://document/<uuid>                 open the document
//    kalsmritikosh://document/<uuid>?quote=<text>    open it at that passage
//  Opening a link that points at something no longer in this archive says so;
//  links never reveal content by themselves (they carry the id and the quote
//  the user copied, nothing else).
//
//  The `kalsmritikosh` URL scheme must be registered in the target's Info
//  (URL Types) for macOS to route links here — an owner step in Xcode.
//

import Foundation
import os

public nonisolated enum DeepLink: Equatable, Sendable {
    case document(id: UUID, quote: String?)

    public static let scheme = "kalsmritikosh"

    public var url: URL? {
        switch self {
        case .document(let id, let quote):
            var c = URLComponents()
            c.scheme = Self.scheme
            c.host = "document"
            c.path = "/" + id.uuidString
            if let q = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                c.queryItems = [URLQueryItem(name: "quote", value: String(q.prefix(500)))]
            }
            return c.url
        }
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch c.host?.lowercased() {
        case "document":
            let raw = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let id = UUID(uuidString: raw) else { return nil }
            self = .document(id: id, quote: c.queryItems?.first(where: { $0.name == "quote" })?.value)
        default:
            return nil
        }
    }
}

extension AppState {

    /// Handle a `kalsmritikosh://` link: open the source at the passage, or explain why not.
    public func handleDeepLink(_ url: URL) async {
        guard ProductModuleFlags.isEnabled(.deepLinks) else {
            deepLinkMessage = "Links to passages are switched off. Turn on “Links to passages” in Settings ▸ Modules."
            return
        }
        guard let link = DeepLink(url: url) else {
            deepLinkMessage = "This link is not a Kalsmritikosh link this version understands."
            return
        }
        switch link {
        case .document(let id, let quote):
            guard let objects, let source = try? await objects.fetchSourceURL(id: id) else {
                deepLinkMessage = "This document is not in this archive. It may have been removed, or the link came from another Mac."
                KalsmritikoshLog.app.info("Deep link to missing document \(id.uuidString, privacy: .public)")
                return
            }
            deepLinkTarget = CitationOpenTarget(url: source, objectID: id, quote: quote)
        }
    }

    /// Put a link to a passage on the pasteboard.
    public func copyLink(objectID: UUID, quote: String?) {
        guard ProductModuleFlags.isEnabled(.deepLinks),
              let url = DeepLink.document(id: objectID, quote: quote).url else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
