//
//  ImportQueue.swift
//  Kalsmritikosh
//
//  W1-9 — a visible queue for files the user adds: pending, running, finished
//  or failed, with pause, resume, skip and reorder (ported in spirit from
//  mailin's ImportQueueView/BulkImportCoordinator). Several workers run files at
//  once (Speed PERF-26); pausing waits between files so nothing is left half-written, and
//  re-adding a file never duplicates it (ingest deduplicates by content hash).
//  Every run ends with an import receipt when receipts are on.
//

import Foundation
import Observation
import os

@MainActor
@Observable
public final class ImportQueue {
    public enum State: String, Sendable { case pending, running, done, failed, skipped }

    public struct Item: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public var state: State = .pending
        public var error: String?
        public var name: String { url.lastPathComponent }
    }

    public private(set) var items: [Item] = []
    public private(set) var paused = false
    private var worker: Task<Void, Never>?

    public var pendingCount: Int { items.filter { $0.state == .pending || $0.state == .running }.count }
    public var isActive: Bool { worker != nil }

    public init() {}

    func enqueue(_ urls: [URL], state: AppState) {
        items.append(contentsOf: urls.map { Item(url: $0) })
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain(state)
            self?.worker = nil
        }
    }

    public func pause() { paused = true }
    /// Speed PERF-26 (owner 2026-11-23) — not tested yet: resuming wakes the waiting workers at once (no polling).
    public func resume() {
        paused = false
        let w = resumeWaiters
        resumeWaiters.removeAll()
        for c in w { c.resume() }
    }
    @ObservationIgnored private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private func waitWhilePaused() async {
        while paused { await withCheckedContinuation { resumeWaiters.append($0) } }
    }

    public func skip(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .pending else { return }
        items[i].state = .skipped
    }

    public func move(_ id: UUID, by offset: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .pending else { return }
        let j = i + offset
        guard items.indices.contains(j), items[j].state == .pending else { return }
        items.swapAt(i, j)
    }

    public func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .skipped }
    }

    private func drain(_ state: AppState) async {
        guard let ingest = state.ingest else { return }
        // Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. Once per queued import: AI or not.
        if ImportAIPermission.scope == nil {
            let grant = await ImportAIConsent.decide(for: items.filter { $0.state == .pending }.map(\.url))
            await ImportAIPermission.$scope.withValue(grant) { await drain(state) }
            return
        }
        let activity = state.beginProcess("Importing…", total: items.count)
        defer { state.finishProcess(activity); state.noteIngestFile(current: nil) }
        var outcomes: [AppState.ImportOutcome] = []
        // Speed PERF-26 (owner 2026-11-23) — not tested yet. Several files at once (the parse stage's live width, at most
        // 4): each worker takes the next pending item in queue order (claims happen on the main actor, so an item is
        // never taken twice); a pause waits between files for `resume()` (event-driven, not a 0.3 s poll).
        let width = max(1, min(4, await PipelineStages.currentWidth(.parse)))
        await withTaskGroup(of: [AppState.ImportOutcome].self) { group in
            for _ in 0..<width {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return [] }
                    var mine: [AppState.ImportOutcome] = []
                    while true {
                        await self.waitWhilePaused()
                        guard let i = self.items.firstIndex(where: { $0.state == .pending }) else { break }
                        self.items[i].state = .running
                        let url = self.items[i].url
                        state.noteIngestFile(current: url.lastPathComponent)
                        let scoped = url.startAccessingSecurityScopedResource()
                        do {
                            _ = try await ingest.ingest(fileAt: url, intent: .fullAvailable)
                            state.noteIngestFile(current: url.lastPathComponent, finished: true)
                            self.markFinished(url, .done, nil)
                            mine.append(.init(url: url, error: nil))
                        } catch {
                            KalsmritikoshLog.app.error("Queued import failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                            self.markFinished(url, .failed, error.localizedDescription)
                            mine.append(.init(url: url, error: error.localizedDescription))
                        }
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        state.updateProcess(activity, done: self.items.filter { $0.state == .done || $0.state == .failed }.count,
                                            total: self.items.count)
                    }
                    return mine
                }
            }
            for await part in group { outcomes += part }
        }
        await state.writeImportReceipt(outcomes)
        await state.runPostIngestChecksSinceLast()   // W3-4 / N-11
    }

    private func markFinished(_ url: URL, _ s: State, _ error: String?) {
        if let i = items.firstIndex(where: { $0.url == url && $0.state == .running }) {
            items[i].state = s
            items[i].error = error
        }
    }
}
