//
//  NetworkObservation.swift
//  Kalsmritikosh
//
//  Unified path R2-E (SEC-09, owner 2026-11-22 round 2) — not tested yet. Observation of every app-originated
//  transmission ATTEMPT at the one door to the network (NetworkHelperClient.send): host, method, purpose, the mode the
//  app was in, and what happened (refused before leaving, handed to the helper, failed). Content-free: no URL path,
//  no header, no body. Off unless a recording session is started (the simulated privacy-mode run in
//  KalsmritikoshTests/SimulatedReleaseTests.swift and scripts/sim/network-observation.sh, which also captures the
//  process's sockets with nettop for the same run). A mode label is never accepted as proof of zero traffic; the record is.
//

import Foundation
import os

public nonisolated struct NetworkObservationEntry: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable { case refusedBeforeLeaving, handedToHelper, failed }
    public let at: Double
    public let host: String
    public let method: String
    public let purpose: String
    public let mode: String
    public let outcome: Outcome
}

public nonisolated enum NetworkObservation {
    private static let state = OSAllocatedUnfairLock(initialState: (recording: false, mode: "unlabelled", entries: [NetworkObservationEntry]()))

    /// Start a recording session; `mode` names the privacy mode under observation (e.g. "private", "online-consented").
    public static func start(mode: String) { state.withLock { $0 = (true, mode, []) } }
    public static func relabel(mode: String) { state.withLock { $0.mode = mode } }
    /// Stop and return everything recorded since `start`.
    @discardableResult
    public static func stop() -> [NetworkObservationEntry] {
        state.withLock { s in let e = s.entries; s = (false, "unlabelled", []); return e }
    }
    public static var entries: [NetworkObservationEntry] { state.withLock { $0.entries } }

    static func note(url: String, method: String?, purpose: String?, outcome: NetworkObservationEntry.Outcome) {
        state.withLock { s in
            guard s.recording else { return }
            s.entries.append(NetworkObservationEntry(at: Date().timeIntervalSince1970, host: URL(string: url)?.host ?? "(unparseable)",
                                                     method: method ?? "POST", purpose: purpose ?? "ai", mode: s.mode, outcome: outcome))
        }
    }

    /// A labelled, content-free report of a recording.
    public static func report(_ entries: [NetworkObservationEntry]) -> String {
        var s = "# SIMULATED network observation (app-side door record)\n\nEvery attempt the app made to send, by mode. Content-free: host, method, purpose and outcome only.\n\n"
        s += "| Mode | Host | Method | Purpose | Outcome |\n|---|---|---|---|---|\n"
        for e in entries { s += "| \(e.mode) | \(e.host) | \(e.method) | \(e.purpose) | \(e.outcome.rawValue) |\n" }
        if entries.isEmpty { s += "| (none) | | | | no attempt recorded |\n" }
        return s
    }
}
