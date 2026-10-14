//
//  ImportQueue.swift
//  Kalsmritikosh
//
//  W1-9 — a visible queue for files the user adds: pending, running, finished
//  or failed, with pause, resume, skip and reorder (ported in spirit from
//  mailin's ImportQueueView/BulkImportCoordinator). One worker runs one file at
//  a time; pausing waits between files so nothing is left half-written, and
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
    public func resume() { paused = false }

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
        let activity = state.beginProcess("Importing…", total: items.count)
        defer { state.finishProcess(activity); state.noteIngestFile(current: nil) }
        var outcomes: [AppState.ImportOutcome] = []
        while true {
            while paused { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard let i = items.firstIndex(where: { $0.state == .pending }) else { break }
            items[i].state = .running
            let url = items[i].url
            state.noteIngestFile(current: url.lastPathComponent)
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                _ = try await ingest.ingest(fileAt: url, intent: .fullAvailable)
                state.noteIngestFile(current: url.lastPathComponent, finished: true)
                markFinished(url, .done, nil)
                outcomes.append(.init(url: url, error: nil))
            } catch {
                KalsmritikoshLog.app.error("Queued import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                markFinished(url, .failed, error.localizedDescription)
                outcomes.append(.init(url: url, error: error.localizedDescription))
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            state.updateProcess(activity, done: items.filter { $0.state == .done || $0.state == .failed }.count,
                                total: items.count)
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
