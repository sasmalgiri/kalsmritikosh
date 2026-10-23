//
//  SendToDevonthink.swift
//  Kalsmritikosh
//
//  W3-2 — work alongside DEVONthink (as mailin plans in its E2): an answer is
//  written as a Markdown note with a kalsmritikosh:// link back to each quoted
//  passage, then handed to DEVONthink with NSWorkspace.open(_:withApplicationAt:)
//  — sandbox-safe, no Apple Events entitlement. When DEVONthink is not installed
//  the note is shown in Finder instead. The outcome is reported, never assumed.
//

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

public enum SendToDevonthinkOutcome: Sendable, Equatable {
    case sentToDevonthink, shownInFinder(String), failed(String)

    public var message: String {
        switch self {
        case .sentToDevonthink: return "Sent to DEVONthink."
        case .shownInFinder(let p): return "DEVONthink is not installed; the note was saved and shown in Finder (\(p))."
        case .failed(let m): return "Could not send: \(m)"
        }
    }
}

extension AppState {

    static let devonthinkBundleIDs = ["com.devon-technologies.think", "com.devon-technologies.think3",
                                      "com.devon-technologies.thinkpro2"]

    /// Build the Markdown note for an answer: text, then each source with its link.
    public func devonthinkNote(question: String, answer: VerifiedAnswer) async -> String {
        let names = (try? await objects?.sourceFilenames(for: Set(answer.citations.map(\.objectID)))) ?? [:]
        var md = ["# \(question.isEmpty ? "Answer" : question)", "", answer.answerText ?? answer.body, "", "## Sources", ""]
        for (i, c) in answer.citations.enumerated() {
            let link = DeepLink.document(id: c.objectID, quote: c.snippet).url?.absoluteString ?? ""
            md.append("\(i + 1). **\(names[c.objectID] ?? "Source")** — “\(c.snippet.prefix(240))” [Open in Investigations Made Easy](\(link))")
        }
        md.append(""); md.append("_From Investigations Made Easy, \(Date().formatted(date: .abbreviated, time: .shortened))._")
        return md.joined(separator: "\n")
    }

    @MainActor
    public func sendToDevonthink(question: String, answer: VerifiedAnswer) async -> SendToDevonthinkOutcome {
        guard ProductModuleFlags.isEnabled(.sendToDevonthink) else { return .failed("Send to DEVONthink is switched off.") }
        let note = await devonthinkNote(question: question, answer: answer)
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kalsmritikosh-devonthink", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = String(question.prefix(60)).replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            let file = dir.appendingPathComponent("\(safe.isEmpty ? "Answer" : safe).md")
            try Data(note.utf8).write(to: file, options: .atomic)
            #if canImport(AppKit)
            if let app = Self.devonthinkBundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                do {
                    _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    return .sentToDevonthink
                } catch {
                    KalsmritikoshLog.app.error("Send to DEVONthink failed: \(error.localizedDescription, privacy: .public)")
                    return .failed(error.localizedDescription)
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
            #endif
            return .shownInFinder(file.path)
        } catch {
            KalsmritikoshLog.app.error("Send to DEVONthink note write failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
