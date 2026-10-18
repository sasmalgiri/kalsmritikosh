//
//  SafariWebExtensionHandler.swift
//  KalsmritikoshClipper
//
//  X-4 — the native side of the Safari clipper. The extension's JavaScript calls
//  browser.runtime.sendNativeMessage with the page it already has; this writes it into the
//  app group's inbox (ClipPayload) and answers with what happened. No network.
//

import Foundation
import SafariServices
import os

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh.KalsmritikoshClipper", category: "clip")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        let reply: [String: Any]
        do {
            reply = ["ok": true, "saved": try Self.handle(message)]
        } catch {
            log.error("Clip refused: \(error.localizedDescription, privacy: .public)")
            reply = ["ok": false, "error": error.localizedDescription]
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Returns the saved file's name.
    static func handle(_ message: Any?) throws -> String {
        if let m = message as? [String: Any], (m["action"] as? String) == "status" {
            return UserDefaults(suiteName: ClipperWire.appGroup)?.bool(forKey: ClipperWire.enabledKey) == true ? "on" : "off"
        }
        let request = try ClipRequest(message: message)
        guard UserDefaults(suiteName: ClipperWire.appGroup)?.bool(forKey: ClipperWire.enabledKey) == true else {
            throw ClipRequest.Refusal.switchedOff
        }
        guard let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ClipperWire.appGroup)?
            .appendingPathComponent(ClipperWire.inboxFolder, isDirectory: true) else { throw ClipRequest.Refusal.noInbox }
        let payload = try request.payload()
        _ = try ClipRequest.write(payload, origin: "Safari clipper", url: request.url, into: inbox)
        return payload.name
    }
}
