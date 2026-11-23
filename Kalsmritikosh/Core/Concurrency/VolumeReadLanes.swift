//
//  VolumeReadLanes.swift
//  Kalsmritikosh
//
//  Speed PERF-38 torrent (owner 2026-11-23) — not tested yet. "Choking: favour the fastest peers": reading is paced PER
//  DISK. Every file read by the folder import, the shard import, backup / restore copies and archive expansion goes
//  through the lane of the volume it lives on. Each volume has its own throughput-tuned limit (the AIMD of
//  AdaptiveConcurrency, measured in BYTES per second instead of requests): the internal SSD starts wide, an external
//  disk at 2, a USB stick / SD card, a network share or an optical disc at 1–2. After each window of finished reads
//  (one window = as many reads as the current limit) the lane widens by one while bytes/s still rises (≥ 5 %), and
//  narrows by one when bytes/s fell by a quarter (a spinning disk seeking between too many files). Every volume has
//  its own lane, so all volumes are read at the same time; `interleaved` deals the files of a run round-robin over
//  the volumes so the workers keep every disk busy instead of queueing behind the slowest one.
//
//  The lane works from synchronous copy workers (blocking wait) and from async import tasks (suspending wait).
//  No network: the volume facts come from the file system (URLResourceValues) and stat(2).
//

import Foundation
import Darwin
import os

/// What kind of disk a file is on, from the file system's own facts.
public nonisolated enum VolumeKind: String, Sendable, Codable, CaseIterable {
    case internalDisk, externalDisk, removable, network, optical, offline, unknown

    /// Lower is faster (used to choose between two copies of the same bytes, PERF-39).
    public var speedRank: Int {
        switch self {
        case .internalDisk: return 0
        case .externalDisk: return 1
        case .unknown: return 2
        case .removable: return 3
        case .network: return 4
        case .optical: return 5
        case .offline: return 9
        }
    }

    /// Slower than an external disk, or not there at all.
    public var isSlowOrOffline: Bool { speedRank >= VolumeKind.removable.speedRank }

    /// First limit and the most reads at once for a lane of this kind.
    func startAndCap(cores: Int) -> (start: Int, cap: Int) {
        switch self {
        case .internalDisk:
            let cap = max(4, min(16, cores))
            return (min(cap, max(4, cores / 2)), cap)
        case .externalDisk, .unknown: return (2, 8)
        case .removable: return (2, 4)
        case .network: return (2, 6)
        case .optical: return (1, 2)
        case .offline: return (1, 1)
        }
    }
}

/// One volume as the lanes see it.
public nonisolated struct VolumeProfile: Sendable, Hashable {
    /// A stable key for the volume in this process (its device number, or its identifier when there is one).
    public let key: String
    public let kind: VolumeKind
    public let name: String
}

/// One volume's read lane: a counting gate whose width follows the measured bytes/s.
public nonisolated final class VolumeLane: @unchecked Sendable {
    public let profile: VolumeProfile
    public let cap: Int
    private let floor = 1
    // Every field below is guarded by `cond`.
    private let cond = NSCondition()
    private var limitValue: Int
    private var inFlight = 0
    private var asyncWaiters: [CheckedContinuation<Void, Never>] = []
    private var windowDone = 0
    private var windowBytes: Int64 = 0
    private var windowStart = ContinuousClock.now
    private var lastThroughput: Double = 0
    private var bestThroughput: Double = 0

    init(profile: VolumeProfile, cores: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.profile = profile
        let sc = profile.kind.startAndCap(cores: cores)
        self.cap = max(1, sc.cap)
        self.limitValue = max(1, min(sc.start, self.cap))
    }

    /// The width now.
    public var limit: Int { cond.withLock { limitValue } }
    /// The best bytes/s one window measured (0 until a window finished).
    public var measuredBytesPerSecond: Double { cond.withLock { bestThroughput } }

    /// Wait (blocking this thread) for a read slot — synchronous copy workers.
    public func acquireBlocking() {
        cond.withLock {
            while inFlight >= limitValue { cond.wait() }
            inFlight += 1
        }
    }

    /// Wait (suspending) for a read slot — async import tasks.
    public func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now: Bool = cond.withLock {
                if inFlight < limitValue { inFlight += 1; return true }
                asyncWaiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }

    /// Give the slot back with how many bytes the read moved (nil / 0: not counted, e.g. a failure).
    public func release(bytes: Int64?) {
        let wake: [CheckedContinuation<Void, Never>] = cond.withLock {
            inFlight = max(0, inFlight - 1)
            if let bytes, bytes > 0 {
                windowDone += 1
                windowBytes += bytes
                if windowDone >= limitValue {
                    let d = ContinuousClock.now - windowStart
                    let elapsed = max(0.001, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                    let throughput = Double(windowBytes) / elapsed
                    if lastThroughput == 0 || throughput >= lastThroughput * 1.05 {
                        if limitValue < cap { limitValue += 1 }
                    } else if throughput < lastThroughput * 0.75, limitValue > floor {
                        limitValue -= 1   // choke: more reads at once made this disk slower
                    }
                    lastThroughput = throughput
                    bestThroughput = max(bestThroughput, throughput)
                    windowDone = 0
                    windowBytes = 0
                    windowStart = .now
                }
            }
            var out: [CheckedContinuation<Void, Never>] = []
            while inFlight < limitValue, !asyncWaiters.isEmpty {
                out.append(asyncWaiters.removeFirst())
                inFlight += 1
            }
            cond.broadcast()
            return out
        }
        for c in wake { c.resume() }
    }
}

public nonisolated enum VolumeReadLanes {
    private static let lanes = OSAllocatedUnfairLock(initialState: [String: VolumeLane]())
    private static let profiles = OSAllocatedUnfairLock(initialState: [Int32: VolumeProfile]())

    /// The volume `url` is on. A path that cannot be reached (an unplugged disk, an unmounted share) is `.offline`.
    public static func profile(for url: URL) -> VolumeProfile {
        var st = stat()
        var probe = url.standardizedFileURL
        // A file not there (a copy target not written yet, or a source on an unplugged disk): its nearest existing
        // folder decides the volume — but never `/Volumes` itself, which would make an unplugged disk look internal.
        while stat(probe.path, &st) != 0 {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path || parent.path.isEmpty || parent.path == "/Volumes" || probe.pathComponents.count <= 2 {
                return VolumeProfile(key: "offline", kind: .offline, name: "")
            }
            probe = parent
        }
        let dev = Int32(st.st_dev)
        if let known = profiles.withLock({ $0[dev] }) { return known }
        let made = classify(probe, device: dev)
        profiles.withLock { $0[dev] = made }
        return made
    }

    /// Whether the volume of `url` is mounted right now (the original of a source may sit on an unplugged disk).
    public static func isReachable(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.standardizedFileURL.path, &st) == 0
    }

    static func classify(_ url: URL, device: Int32) -> VolumeProfile {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey,
                                         .volumeIsEjectableKey, .volumeTypeNameKey, .volumeNameKey]
        let v: URLResourceValues
        do { v = try url.resourceValues(forKeys: keys) } catch {
            KalsmritikoshLog.ingestion.debug("VolumeReadLanes: volume facts unreadable: \(error.localizedDescription, privacy: .private)")
            return VolumeProfile(key: "dev-\(device)", kind: .unknown, name: "")
        }
        let type = (v.volumeTypeName ?? "").lowercased()
        let kind: VolumeKind
        if v.volumeIsLocal == false || ["smbfs", "afpfs", "nfs", "webdav", "ftp"].contains(type) {
            kind = .network
        } else if ["cd9660", "udf", "cddafs"].contains(type) {
            kind = .optical
        } else if v.volumeIsInternal == true, v.volumeIsRemovable != true {
            kind = .internalDisk
        } else if v.volumeIsRemovable == true || v.volumeIsEjectable == true {
            // An external drive the system can eject is treated as removable until its bytes/s says otherwise.
            kind = v.volumeIsInternal == false && v.volumeIsRemovable != true ? .externalDisk : .removable
        } else if v.volumeIsInternal == false {
            kind = .externalDisk
        } else {
            kind = .unknown
        }
        return VolumeProfile(key: "dev-\(device)", kind: kind, name: v.volumeName ?? "")
    }

    /// The lane of the volume `url` is on (made on first use).
    public static func lane(for url: URL) -> VolumeLane {
        let p = profile(for: url)
        return lanes.withLock { all in
            if let l = all[p.key] { return l }
            let l = VolumeLane(profile: p)
            all[p.key] = l
            return l
        }
    }

    /// The lanes made so far (Settings / diagnostics).
    public static func snapshot() -> [(profile: VolumeProfile, limit: Int, bytesPerSecond: Double)] {
        lanes.withLock { Array($0.values) }.map { ($0.profile, $0.limit, $0.measuredBytesPerSecond) }
    }

    static func size(of url: URL) -> Int64 {
        var st = stat()
        return stat(url.standardizedFileURL.path, &st) == 0 ? Int64(st.st_size) : 0
    }

    /// The lanes this task tree already holds a slot of: a nested read on the SAME volume (an archive's members read
    /// while the archive's own read holds the slot) runs on the held slot, so a full lane can never deadlock.
    @TaskLocal static var held: Set<String> = []

    /// Run an async read of `url` in its volume's lane. `bytes` defaults to the file's size (taken before the read).
    public static func withRead<T>(_ url: URL, bytes: Int64? = nil, _ body: () async throws -> T) async rethrows -> T {
        let lane = lane(for: url)
        let key = lane.profile.key
        if held.contains(key) { return try await body() }
        let counted = bytes ?? size(of: url)
        await lane.acquire()
        do {
            let r = try await $held.withValue(held.union([key])) { try await body() }
            lane.release(bytes: counted)
            return r
        } catch {
            lane.release(bytes: nil)
            throw error
        }
    }

    /// Run a synchronous read of `url` in its volume's lane (copy workers; blocks this thread while the lane is full).
    /// Never call it from an async task (use `withRead`); copy workers run on their own threads.
    public static func withReadBlocking<T>(_ url: URL, bytes: Int64? = nil, _ body: () throws -> T) rethrows -> T {
        let lane = lane(for: url)
        let key = lane.profile.key
        if held.contains(key) { return try body() }
        let counted = bytes ?? size(of: url)
        lane.acquireBlocking()
        do {
            let r = try $held.withValue(held.union([key])) { try body() }
            lane.release(bytes: counted)
            return r
        } catch {
            lane.release(bytes: nil)
            throw error
        }
    }

    /// `items` dealt round-robin over their volumes (fastest volume first in each round), keeping each volume's own
    /// order, so the workers of one run keep every disk busy at the same time.
    public static func interleaved<T>(_ items: [T], url: (T) -> URL) -> [T] {
        guard items.count > 1 else { return items }
        var groups: [String: [T]] = [:]
        var rank: [String: Int] = [:]
        var firstSeen: [String] = []
        for item in items {
            let p = profile(for: url(item))
            if groups[p.key] == nil { firstSeen.append(p.key); rank[p.key] = p.kind.speedRank }
            groups[p.key, default: []].append(item)
        }
        guard groups.count > 1 else { return items }
        let order = firstSeen.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? 9, rb = rank[b.element] ?? 9
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        var out: [T] = []
        out.reserveCapacity(items.count)
        var cursor = [String: Int]()
        var left = items.count
        while left > 0 {
            for key in order {
                let i = cursor[key, default: 0]
                guard let g = groups[key], i < g.count else { continue }
                out.append(g[i])
                cursor[key] = i + 1
                left -= 1
            }
        }
        return out
    }

    public static func interleaved(_ urls: [URL]) -> [URL] { interleaved(urls) { $0 } }
}
