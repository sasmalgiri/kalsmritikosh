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
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let ingestion = Logger(subsystem: subsystem, category: "ingestion")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let knowledge = Logger(subsystem: subsystem, category: "knowledge")
    public static let routing = Logger(subsystem: subsystem, category: "routing")
    public static let brain = Logger(subsystem: subsystem, category: "brain")
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.atlas.chronica.memora"
}
