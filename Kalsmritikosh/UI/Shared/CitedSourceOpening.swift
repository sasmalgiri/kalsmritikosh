//
//  CitedSourceOpening.swift
//  Kalsmritikosh
//
//  SRC-01 / SRC-08 (smart-map S2, 2026-11-08) — the ONE way a surface opens a citation. Ask citation chips, the
//  case file (chronology, return to source), contradictions, history, fund flow, drafts, case search and the map
//  all call `resolve`, which goes through CitedSourceResolver: the cited version opens (its kept copy, or the
//  file only when its bytes are the cited ones), or the cited passage is shown from the ledger with the reason
//  the version is unavailable. A surface never opens "the object's current file" on its own.
//

import SwiftUI
import os

enum CitedSourceOpening {

    enum Result {
        /// Open the source viewer on this file (its `versionNote` labels a kept older version).
        case viewer(CitationOpenTarget)
        /// Show the cited passage from the ledger, with why the cited version itself cannot be opened.
        case passage(OpenedSource)
    }

    @MainActor
    static func resolve(_ appState: AppState, objectID: UUID, sourceVersionID: UUID? = nil,
                        quote: String?, focus: String? = nil, blockID: UUID? = nil) async -> Result {
        let trimmed = quote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = (trimmed?.isEmpty ?? true) ? nil : trimmed
        var note = CitedSourceResolver.Unavailable.missingOriginal.label
        if let db = appState.database {
            // S14 (SRC-08): a cited place the viewer cannot go to (a cell, an image region, a time in a recording) is said.
            var placeNote: String?
            if let blockID {
                do { placeNote = try await CitedSourceResolver.locator(blockID: blockID, database: db).flatMap(CitedSourceResolver.unsupportedLocatorNote) } catch {
                    KalsmritikoshLog.ui.error("Cited source: locator not read: \(error.localizedDescription, privacy: .public)")
                }
            }
            do {
                switch try await CitedSourceResolver.resolve(sourceVersionID: sourceVersionID, objectID: objectID, database: db,
                                                             ledgerURL: db.url, vault: appState.evidenceVault) {
                case .open(let url, let versionNote):
                    let label = [placeNote, versionNote].compactMap { $0 }.joined(separator: " ")
                    return .viewer(CitationOpenTarget(url: url, objectID: objectID, quote: q, focus: focus, versionNote: label.isEmpty ? nil : label))
                case .unavailable(let why):
                    note = [why.label, placeNote].compactMap { $0 }.joined(separator: " ")
                }
            } catch {
                KalsmritikoshLog.ui.error("Cited source open failed: \(error.localizedDescription, privacy: .public)")
                note = "The cited version could not be checked (\(error.localizedDescription)); the cited passage is shown from the ledger."
            }
        }
        return .passage(OpenedSource(citation: VerifiedAnswer.Citation(objectID: objectID, snippet: q ?? ""), note: note))
    }
}

/// The cited passage from the ledger, under the reason its version cannot be opened (SRC-08).
struct CitedPassageSheet: View {
    let opened: OpenedSource
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let note = opened.note {
                Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("citation.source.unavailable")
            }
            EvidenceViewer(citation: opened.citation)
            HStack { Spacer(); Button("Close", action: onDone).keyboardShortcut(.cancelAction) }.padding(10)
        }
    }
}

/// S14 (SRC-01) — a cited source opened through the pinned path inside a navigation link or a sheet that used to show
/// the object's current file: the version the document was read from (checked), labelled when older, or the passage
/// from the ledger with the reason the version cannot be opened.
struct PinnedSourceView: View {
    @Environment(AppState.self) private var appState
    let objectID: UUID
    var sourceVersionID: UUID? = nil
    let quote: String?
    var focus: String? = nil
    var blockID: UUID? = nil
    @State private var result: CitedSourceOpening.Result?

    var body: some View {
        Group {
            switch result {
            case .viewer(let target)?:
                VStack(spacing: 0) {
                    if let note = target.versionNote {
                        Label(note, systemImage: "clock.arrow.circlepath").font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("citation.source.versionNote")
                    }
                    SourceViewer(url: target.url, koID: target.objectID, quote: target.quote, focus: target.focus)
                }
            case .passage(let opened)?:
                VStack(spacing: 0) {
                    if let note = opened.note {
                        Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("citation.source.unavailable")
                    }
                    EvidenceViewer(citation: opened.citation)
                }
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: objectID) {
            result = await CitedSourceOpening.resolve(appState, objectID: objectID, sourceVersionID: sourceVersionID,
                                                      quote: quote, focus: focus, blockID: blockID)
        }
    }
}
