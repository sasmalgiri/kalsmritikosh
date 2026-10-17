//
//  ScriptCommands.swift
//  Kalsmritikosh
//
//  P-4 — AppleScript: `ask`, `search`, `add files` and `open link`, defined in
//  Kalsmritikosh.sdef. They do exactly what the Shortcuts actions do (IntentBridge) and are
//  governed by the same "Shortcuts actions" switch, so a script and a shortcut can never
//  see different answers. Receiving Apple events needs no entitlement and no network.
//
//      tell application "Kalsmritikosh" to ask "When was the patent granted?"
//      tell application "Kalsmritikosh" to search "invoice" limit 5
//

import AppKit
import Foundation

/// Runs `work` without blocking the script, then hands its result (or error) back.
@MainActor
private func finish(_ command: NSScriptCommand, _ work: @escaping @MainActor () async throws -> Any?) {
    command.suspendExecution()
    nonisolated(unsafe) let suspended = command
    Task { @MainActor in
        do {
            let value = try await work()
            suspended.resumeExecution(withResult: value)
        } catch {
            suspended.scriptErrorNumber = -10000   // errAEEventFailed
            suspended.scriptErrorString = ScriptCommandError.message(for: error)
            suspended.resumeExecution(withResult: nil)
        }
    }
}

enum ScriptCommandError {
    static func message(for error: Error) -> String {
        if let intent = error as? KalsmritikoshIntentError {
            return String(localized: intent.localizedStringResource)
        }
        return error.localizedDescription
    }

    static func missing(_ what: String) -> NSError {
        NSError(domain: "Kalsmritikosh.AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "Give \(what)."])
    }
}

@objc(KalsAskCommand)
final class KalsAskCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let question = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        MainActor.assumeIsolated {
            finish(self) {
                guard !question.isEmpty else { throw ScriptCommandError.missing("a question") }
                return try await IntentBridge.ask(question)
            }
        }
        return nil
    }
}

@objc(KalsSearchCommand)
final class KalsSearchCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let query = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = (evaluatedArguments?["limit"] as? NSNumber)?.intValue ?? 10
        MainActor.assumeIsolated {
            finish(self) {
                guard !query.isEmpty else { throw ScriptCommandError.missing("something to search for") }
                return try await IntentBridge.search(query, limit: limit)
            }
        }
        return nil
    }
}

@objc(KalsAddFilesCommand)
final class KalsAddFilesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let urls: [URL]
        switch directParameter {
        case let url as URL: urls = [url]
        case let list as [Any]: urls = list.compactMap { $0 as? URL }
        default: urls = []
        }
        MainActor.assumeIsolated {
            finish(self) {
                let state = try IntentBridge.ready()
                guard !urls.isEmpty else { throw KalsmritikoshIntentError.nothingToAdd }
                await state.ingestFiles(urls)
                return urls.count
            }
        }
        return nil
    }
}

@objc(KalsOpenLinkCommand)
final class KalsOpenLinkCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let text = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        MainActor.assumeIsolated {
            finish(self) {
                let state = try IntentBridge.ready()
                guard let url = URL(string: text), url.scheme == "kalsmritikosh" else {
                    throw ScriptCommandError.missing("a kalsmritikosh:// link")
                }
                await state.handleDeepLink(url)
                return nil
            }
        }
        return nil
    }
}
