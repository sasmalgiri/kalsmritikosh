//
//  IncrementalUpdater.swift
//  Kalsmritikosh
//
//  Subscribes to IngestCoordinator's SubjectInvalidation stream and
//  drives MemoryDistiller for only the affected subjects. Debounces so a
//  burst of file events collapses into one distillation pass per subject.
//

import Foundation
import OSLog

public actor IncrementalUpdater: BackgroundService {
    public let id = "atlas.incremental.updater"
    private let stream: AsyncStream<SubjectInvalidation>
    private let distiller: MemoryDistiller
    private let debounceMs: UInt64
    private var consumerTask: Task<Void, Never>?
    private var pending: [String: (subject: SubjectInvalidation.Subject, trigger: KnowledgeObject.ID)] = [:]
    private var debounceTask: Task<Void, Never>?

    public init(
        stream: AsyncStream<SubjectInvalidation>,
        distiller: MemoryDistiller,
        debounceMilliseconds: UInt64 = 1_500
    ) {
        self.stream = stream
        self.distiller = distiller
        self.debounceMs = debounceMilliseconds
    }

    public func start() async {
        guard consumerTask == nil else { return }
        let stream = self.stream
        consumerTask = Task { [weak self] in
            for await event in stream {
                await self?.enqueue(event)
            }
        }
    }

    public func stop() async {
        consumerTask?.cancel()
        consumerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        pending.removeAll()
    }

    private func enqueue(_ event: SubjectInvalidation) {
        for subject in event.subjects {
            let key = "\(subject.kind.rawValue)|\(subject.identifier)"
            pending[key] = (subject, event.triggeringObjectID)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        debounceTask?.cancel()
        let waitNs = debounceMs * 1_000_000
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            await self?.flush()
        }
    }

    private func flush() async {
        let snapshot = pending
        pending.removeAll()
        for (_, entry) in snapshot {
            do {
                _ = try await distiller.distill(
                    .init(kind: entry.subject.kind, identifier: entry.subject.identifier),
                    triggeredBy: entry.trigger
                )
                AtlasLog.knowledge.info("Distilled memory for \(entry.subject.kind.rawValue, privacy: .public): \(entry.subject.identifier, privacy: .public)")
            } catch {
                AtlasLog.knowledge.error("Memory distillation failed for \(entry.subject.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
