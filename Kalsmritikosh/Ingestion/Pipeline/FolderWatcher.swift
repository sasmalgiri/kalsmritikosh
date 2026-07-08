//
//  FolderWatcher.swift
//  Kalsmritikosh
//
//  FSEvents-backed file system watcher. Resolves a BookmarkStore root,
//  starts an FSEventStream, emits debounced URL batches into an
//  AsyncStream the IngestCoordinator drains. macOS-only; on iOS the
//  watcher returns nothing so the rest of the pipeline still compiles.
//

import Foundation
#if canImport(CoreServices) && os(macOS)
import CoreServices
#endif

public actor FolderWatcher {
    public struct Event: Sendable, Hashable {
        public let urls: [URL]
    }

    #if canImport(CoreServices) && os(macOS)
    private var streams: [BookmarkStore.Root.ID: WatchHandle] = [:]
    #endif
    private(set) var continuation: AsyncStream<Event>.Continuation?
    public let events: AsyncStream<Event>

    public init() {
        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func watch(root: BookmarkStore.Root, url: URL) {
        #if canImport(CoreServices) && os(macOS)
        guard streams[root.id] == nil else { return }
        let handle = WatchHandle(url: url) { [weak self] urls in
            Task { await self?.send(urls) }
        }
        handle.start()
        streams[root.id] = handle
        #else
        _ = (root, url)
        #endif
    }

    public func stop(root: BookmarkStore.Root) {
        #if canImport(CoreServices) && os(macOS)
        streams[root.id]?.stop()
        streams.removeValue(forKey: root.id)
        #else
        _ = root
        #endif
    }

    public func stopAll() {
        #if canImport(CoreServices) && os(macOS)
        for handle in streams.values { handle.stop() }
        streams.removeAll()
        #endif
        continuation?.finish()
    }

    private func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        continuation?.yield(Event(urls: urls))
    }
}

#if canImport(CoreServices) && os(macOS)
private nonisolated final class WatchHandle {
    let url: URL
    let onEvents: @Sendable ([URL]) -> Void
    var stream: FSEventStreamRef?

    init(url: URL, onEvents: @Sendable @escaping ([URL]) -> Void) {
        self.url = url
        self.onEvents = onEvents
    }

    func start() {
        // passRetained pairs with takeRetainedValue in the callback's
        // release shim so the handle outlives the FSEvents stream even if
        // every Swift-side reference drops.
        let unmanaged = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil,
            release: { ptr in
                if let ptr {
                    Unmanaged<WatchHandle>.fromOpaque(ptr).release()
                }
            },
            copyDescription: nil
        )
        let paths = [url.path] as CFArray
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let handle = Unmanaged<WatchHandle>.fromOpaque(info).takeUnretainedValue()
            let pathsArray = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            let urls = pathsArray.prefix(count).map { URL(fileURLWithPath: $0) }
            handle.onEvents(Array(urls))
        }
        let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        if s == nil {
            // Stream wasn't created — release the retain we just took so
            // we don't leak this handle.
            unmanaged.release()
        }
        self.stream = s
        if let s {
            FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "kalsmritikosh.fsevents"))
            FSEventStreamStart(s)
        }
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            // FSEventStreamInvalidate triggers our release shim, which
            // balances the passRetained from start().
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    deinit { stop() }
}
#endif
