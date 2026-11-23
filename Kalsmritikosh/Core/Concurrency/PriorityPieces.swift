//
//  PriorityPieces.swift
//  Kalsmritikosh
//
//  Speed PERF-36 torrent (owner 2026-11-23) — not tested yet. "Priority pieces" (a torrent client's streaming mode): the
//  documents the person needs now go to the front of every queue. Two signals:
//
//    • the open case — its authorised documents (source versions, their knowledge objects, their original files);
//    • the current question — the documents its retrieval cited.
//
//  AppState sets them when a case opens or a question is asked; the import queue, the shard batches, the embedding drain,
//  the upgrade drain and WorkStealingQueue read them (priority items first, the rest in their usual order). Only ORDER
//  changes: nothing is skipped, nothing is read that would not be read anyway. A process-wide, lock-protected value.
//

import Foundation
import os

public nonisolated enum PriorityPieces {
    public struct Signal: Sendable, Equatable {
        public var caseID: UUID?
        public var sourceVersions: Set<UUID> = []
        public var objects: Set<UUID> = []
        /// Standardised file paths of the documents' originals (the import queue sees files, not ids).
        public var paths: Set<String> = []
        public var isEmpty: Bool { sourceVersions.isEmpty && objects.isEmpty && paths.isEmpty }
    }

    private static let state = OSAllocatedUnfairLock<(open: Signal, question: Signal)>(initialState: (Signal(), Signal()))

    /// The open case's documents (replaces the previous case's; nil caseID clears).
    public static func setOpenCase(_ caseID: UUID?, sourceVersions: Set<UUID> = [], objects: Set<UUID> = [], files: [URL] = []) {
        let s = Signal(caseID: caseID, sourceVersions: caseID == nil ? [] : sourceVersions, objects: caseID == nil ? [] : objects,
                       paths: caseID == nil ? [] : Set(files.map { $0.standardizedFileURL.path }))
        state.withLock { $0.open = s }
        KalsmritikoshLog.ingestion.info("priority pieces: open case with \(s.sourceVersions.count, privacy: .public) version(s), \(s.objects.count, privacy: .public) object(s) first")
    }

    /// The documents the current question's retrieval cited (replaces the previous question's).
    public static func setQuestion(objects: Set<UUID>, sourceVersions: Set<UUID> = []) {
        state.withLock { $0.question = Signal(caseID: nil, sourceVersions: sourceVersions, objects: objects, paths: []) }
    }

    public static func clear() { state.withLock { $0 = (Signal(), Signal()) } }

    public static var current: Signal {
        state.withLock { s in
            Signal(caseID: s.open.caseID, sourceVersions: s.open.sourceVersions.union(s.question.sourceVersions),
                   objects: s.open.objects.union(s.question.objects), paths: s.open.paths.union(s.question.paths))
        }
    }

    public static func isPriority(sourceVersion id: UUID) -> Bool { state.withLock { $0.open.sourceVersions.contains(id) || $0.question.sourceVersions.contains(id) } }
    public static func isPriority(object id: UUID) -> Bool { state.withLock { $0.open.objects.contains(id) || $0.question.objects.contains(id) } }
    public static func isPriority(file url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return state.withLock { $0.open.paths.contains(p) || $0.question.paths.contains(p) }
    }

    /// `items` with the priority ones first, each group in its original order (a stable partition).
    public static func ordered<T>(_ items: [T], isPriority: (T) -> Bool) -> [T] {
        var first: [T] = [], rest: [T] = []
        for x in items { if isPriority(x) { first.append(x) } else { rest.append(x) } }
        return first + rest
    }

    /// Files: the open case's / question's originals first.
    public static func orderedFiles(_ files: [URL]) -> [URL] {
        let paths = current.paths
        guard !paths.isEmpty else { return files }
        return ordered(files) { paths.contains($0.standardizedFileURL.path) }
    }
}
