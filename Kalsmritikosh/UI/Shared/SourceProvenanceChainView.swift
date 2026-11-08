//
//  SourceProvenanceChainView.swift
//  Kalsmritikosh
//
//  Smart-map IN-03 / SRC-05 / SRC-06 / IN-09 — the "Where this came from" panel of the source inspector:
//    • the chain from the passage to its exact source version, every parent that contained it (email,
//      archive member path, embedding document) and the intake receipt of the file actually supplied;
//    • derivation links both ways — the original a derived copy was made from (with the method) and the
//      copies made from this version;
//    • how each page was read, with "Re-read this document" and "Open the original" for uncertain or
//      unread pages — no text is never presented as proof that the page holds nothing;
//    • for a protected original, "Enter password" (ProtectedSourceUnlockSheet).
//  Read-only except for the explicit re-read and unlock actions, which go through the one pipeline.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
import os
#endif

public struct SourceProvenanceChainView: View {
    /// The exact version, when the caller has it; otherwise resolved from the block or `objectID` (the cited document).
    let givenVersionID: UUID?
    let objectID: UUID?
    let blockID: UUID?
    @State private var resolvedVersionID: UUID?
    private var sourceVersionID: UUID { givenVersionID ?? resolvedVersionID ?? UUID() }

    @Environment(AppState.self) private var appState
    @State private var chain: SourceProvenanceChain?
    @State private var reading: SourceReadingReport?
    @State private var protection: ProtectedSourceAttempt?
    @State private var failure: String?
    @State private var status: String?
    @State private var working = false
    @State private var showUnlock = false

    public init(sourceVersionID: UUID, blockID: UUID? = nil) {
        self.givenVersionID = sourceVersionID
        self.objectID = nil
        self.blockID = blockID
    }

    /// For a viewer that knows the cited document (knowledge object) and, optionally, the passage's block.
    public init(knowledgeObjectID: UUID, blockID: UUID? = nil) {
        self.givenVersionID = nil
        self.objectID = knowledgeObjectID
        self.blockID = blockID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where this came from").font(.headline)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Button("Refresh") { Task { await load() } }
            } else if let chain {
                chainSection(chain)
                derivationSection(chain)
                if let reading { readingSection(reading) }
                if let protection, protection.state != .notProtected { protectionSection(protection) }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: givenVersionID ?? blockID ?? objectID) { await load() }
        .sheet(isPresented: $showUnlock) {
            ProtectedSourceUnlockSheet(sourceVersionID: sourceVersionID, filename: chain?.version.filename ?? "this document",
                                       onUnlocked: { _ in Task { await load() } })
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func chainSection(_ chain: SourceProvenanceChain) -> some View {
        if let block = chain.block {
            Text(blockLine(block)).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(chain.pathDescriptions.enumerated()), id: \.offset) { _, line in
            Label(line, systemImage: "arrow.turn.left.up").font(.callout).textSelection(.enabled)
        }
        if chain.truncated {
            Text("The chain is longer than shown or loops back on itself; only the paths listed were followed.")
                .font(.caption).foregroundStyle(.orange)
        }
        ForEach(Array(chain.receipts.enumerated()), id: \.offset) { _, r in
            Text("Received \(r.recordedAt.formatted(date: .abbreviated, time: .shortened)) — \(receiptOutcome(r.outcome)); \(r.custodyMode == "managed" ? "a copy is kept in the library" : "read in place")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func derivationSection(_ chain: SourceProvenanceChain) -> some View {
        ForEach(Array(chain.derivedFrom.enumerated()), id: \.offset) { _, d in
            Label("A copy made from “\(d.originalFilename)”" + (d.method.map { " — \($0)" } ?? ""), systemImage: "doc.on.doc")
                .font(.callout)
        }
        ForEach(Array(chain.derivatives.enumerated()), id: \.offset) { _, d in
            Label("Copy: “\(d.derivedFilename)”" + (d.method.map { " — \($0)" } ?? ""), systemImage: "doc.badge.arrow.up")
                .font(.callout)
        }
    }

    @ViewBuilder
    private func readingSection(_ report: SourceReadingReport) -> some View {
        if let line = report.disclosure {
            Text(line).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        let flagged = report.uncertainOrUnread
        if !flagged.isEmpty {
            ForEach(flagged.prefix(50)) { p in
                Text("Page \(p.page): \(p.state.label)").font(.caption)
            }
            if flagged.count > 50 { Text("…and \(flagged.count - 50) more pages").font(.caption).foregroundStyle(.secondary) }
        }
        if report.needsAttention {
            HStack {
                Button("Re-read this document") { Task { await reread() } }
                    .disabled(working || appState.ingest == nil)
                    .help(appState.ingest == nil ? "The library is not open yet." : "Read the exact original again with the current reader")
                Button("Open the original") { Task { await openOriginal() } }
                    .disabled(working || appState.protectedSourceUnlock == nil)
                    .help("Open a checked copy of the exact original to look at the page yourself")
            }
        }
    }

    @ViewBuilder
    private func protectionSection(_ attempt: ProtectedSourceAttempt) -> some View {
        Label(attempt.state.label, systemImage: "lock").font(.callout).foregroundStyle(.orange)
        Text(attempt.state.remedy).font(.caption).foregroundStyle(.secondary)
        if attempt.state.acceptsPassword {
            Button("Enter password") { showUnlock = true }
                .disabled(appState.protectedSourceUnlock == nil)
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let db = appState.database else { failure = "The library is not open yet."; return }
        do {
            var svid = givenVersionID ?? resolvedVersionID
            if svid == nil {
                // The version the passage was read from: the block's own version, else the document's active one.
                let row: SQLRow?
                if let blockID {
                    row = try await db.query("SELECT source_version_id FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(blockID)]).first
                } else if let objectID {
                    row = try await db.query("""
                        SELECT eb.source_version_id FROM evidence_block_objects ebo JOIN evidence_blocks eb ON eb.id = ebo.evidence_block_id
                         WHERE ebo.knowledge_object_id = ? AND eb.source_version_id IS NOT NULL
                         ORDER BY eb.superseded_by_run IS NOT NULL, eb.ordinal LIMIT 1;
                        """, [.uuid(objectID)]).first
                } else {
                    row = nil
                }
                guard let version = row?.uuid(0) else {
                    failure = "This document has no recorded source version, so where it came from cannot be shown."
                    return
                }
                resolvedVersionID = version
                svid = version
            }
            guard let svid else { return }
            let service = SourceProvenanceChainService(database: db)
            if let blockID {
                chain = try await service.chain(forBlock: blockID)
            } else {
                chain = try await service.chain(forVersion: svid)
            }
            reading = try? await SourcePageReadingService(database: db).report(sourceVersionID: svid)
            if let unlock = appState.protectedSourceUnlock {
                let latest = try? await unlock.latest(sourceVersionID: svid)
                // Check the bytes once when the reading says nothing was read and no check is recorded yet.
                if latest == nil, reading?.limit == .notRead {
                    protection = await unlock.probe(sourceVersionID: svid)
                } else {
                    protection = latest
                }
            }
            failure = nil
        } catch {
            KalsmritikoshLog.ui.error("Provenance chain failed for \(sourceVersionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failure = "Where this came from could not be read: \(error.localizedDescription)"
        }
    }

    private func reread() async {
        guard let ingest = appState.ingest else { return }
        working = true
        defer { working = false }
        do {
            let planned = try await ingest.ensureUpgrade(sourceVersionID: sourceVersionID, goal: .evidenceReady, execution: .foreground)
            let outcome = try await ingest.reprocess(sourceVersionID: sourceVersionID)
            if planned.isEmpty, outcome == .upToDate {
                status = "Already read with the current reader — nothing changed. Open the original to check the pages listed."
            } else {
                status = "Read again."
            }
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Re-read failed for \(sourceVersionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            status = "Could not read it again: \(error.localizedDescription). The original and everything read before are kept."
        }
    }

    private func openOriginal() async {
        guard let unlock = appState.protectedSourceUnlock else { return }
        working = true
        defer { working = false }
        do {
            let url = try await unlock.inspectOriginal(sourceVersionID: sourceVersionID)
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        } catch {
            KalsmritikoshLog.ui.error("Open original failed for \(sourceVersionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            status = "The exact original could not be opened (\(error.localizedDescription)). Nothing else was opened in its place."
        }
    }

    // MARK: - Wording

    private func blockLine(_ b: SourceProvenanceBlock) -> String {
        var parts = ["Passage"]
        if let page = b.page { parts.append("page \(page)") }
        parts.append(b.extractionMethod == "ocr" ? "recognised from an image" : "read from the text")
        if b.supersededByLaterReading { parts.append("from an earlier reading (kept for this citation)") }
        return parts.joined(separator: " · ")
    }

    private func receiptOutcome(_ raw: String) -> String {
        switch raw {
        case "newLogicalSource": return "new document"
        case "newVersion": return "a new version of a document already held"
        case "unchanged": return "already held, unchanged"
        case "moved": return "moved"
        case "aliased": return "an identical copy of a document already held"
        default: return raw
        }
    }
}
