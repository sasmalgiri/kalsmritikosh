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
        // The note leaves the app for another app's database: the same protected-identity gate as every export
        // (candidate re-review P-B1).
        let note: String
        switch ProtectedExport.prepare(await devonthinkNote(question: question, answer: answer)) {
        case .success(let safe): note = safe
        case .failure(let refusal): return .failed(refusal.reason)
        }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kalsmritikosh-devonthink", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // S16 (SEC-10) — the question becomes ONE safe file-name component: before, only "/" was replaced, so a question
            // starting with "." made a hidden file and control or bidi-override characters reached the name shown in Finder.
            let safe = SafeFilename.sanitize(String(question.prefix(60)), fallback: "Answer")
            let file = dir.appendingPathComponent("\(safe).md")
            // Deep dive batch 4: written through the at-write check, against the register read now.
            if case .failure(let refusal) = await ProtectedExport.writeRechecked(note, to: file, refuseIfPresent: false,
                                                                                names: { try await self.protectedNamesNow() }) {
                KalsmritikoshLog.app.error("Send to DEVONthink refused at write")
                return .failed(refusal.reason)
            }
            #if canImport(AppKit)
            if let app = Self.devonthinkBundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                do {
                    _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    return .sentToDevonthink
                } catch {
                    KalsmritikoshLog.app.error("Send to DEVONthink failed: \(error.localizedDescription, privacy: .private)")
                    return .failed(error.localizedDescription)
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
            #endif
            return .shownInFinder(file.path)
        } catch {
            KalsmritikoshLog.app.error("Send to DEVONthink note write failed: \(error.localizedDescription, privacy: .private)")
            return .failed(error.localizedDescription)
        }
    }
}
