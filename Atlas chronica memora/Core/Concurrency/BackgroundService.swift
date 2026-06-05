//
//  BackgroundService.swift
//  Atlas chronica memora
//
//  Long-running background jobs (indexing, compression, ASR queues) all
//  conform to this so the app shell can start / stop them uniformly.
//

import Foundation

public protocol BackgroundService: Sendable {
    var id: String { get }
    func start() async
    func stop() async
}
