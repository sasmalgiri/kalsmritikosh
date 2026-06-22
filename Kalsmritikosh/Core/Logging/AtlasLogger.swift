//
//  AtlasLogger.swift
//  Kalsmritikosh
//
//  Privacy-respecting structured logger over OSLog. Local-only; no
//  remote telemetry by default. Subsystems mirror the module names.
//

import Foundation
import OSLog

public enum AtlasLog {
    // G2-SWIFT6 — nonisolated so every module's actor / nonisolated
    // context can log without the "main-actor-isolated static property
    // cannot be referenced" warning. Logger is Sendable; multi-actor
    // logging is safe.
    public nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    public nonisolated static let ingestion = Logger(subsystem: subsystem, category: "ingestion")
    public nonisolated static let storage = Logger(subsystem: subsystem, category: "storage")
    public nonisolated static let knowledge = Logger(subsystem: subsystem, category: "knowledge")
    public nonisolated static let routing = Logger(subsystem: subsystem, category: "routing")
    public nonisolated static let brain = Logger(subsystem: subsystem, category: "brain")
    public nonisolated static let ui = Logger(subsystem: subsystem, category: "ui")

    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.atlas.chronica.memora"
}
