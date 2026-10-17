//
//  DeviceImport.swift
//  Kalsmritikosh
//
//  P-3 — File ▸ Import from iPhone or iPad (Continuity Camera): Take Photo, Scan Documents,
//  Add Sketch. macOS hands the result to the focused window as item providers; each one is
//  saved into the capture intake (same custody line as a dropped file) and read with text
//  recognition like any image or PDF. The phone and the Mac talk to each other through the
//  system; this app makes no connection. Part of the "Share and capture" module.
//

import Foundation
import UniformTypeIdentifiers
import os

nonisolated enum DeviceImport {
    /// What the import menu may hand over, in order of preference: a scan arrives as a PDF,
    /// a photo as HEIC or JPEG.
    static let acceptedTypes: [UTType] = [.pdf, .heic, .jpeg, .png, .tiff, .image]

    /// The best type a provider offers among the accepted ones.
    static func preferredType(among identifiers: [String]) -> UTType? {
        let offered = identifiers.compactMap(UTType.init)
        for wanted in acceptedTypes where offered.contains(where: { $0.conforms(to: wanted) }) {
            return offered.first { $0.conforms(to: wanted) }
        }
        return nil
    }

    /// A file name for an imported item: what it is, when it arrived, the right extension.
    static func fileName(for type: UTType, at date: Date = Date()) -> String {
        let kind = type.conforms(to: .pdf) ? "Scan" : "Photo"
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "\(kind) from iPhone or iPad \(stamp).\(type.preferredFilenameExtension ?? "dat")"
    }

    static func loadData(_ provider: NSItemProvider, as type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error {
                    KalsmritikoshLog.app.error("Device import could not read an item: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: data)
            }
        }
    }
}

extension AppState {
    /// Save every item the import menu handed over, then read the intake. Returns how many
    /// items were saved.
    @discardableResult
    func importFromDevice(_ providers: [NSItemProvider]) async -> Int {
        guard ProductModuleFlags.isEnabled(.captureExtensions) else { return 0 }
        var saved = 0
        for provider in providers {
            guard let type = DeviceImport.preferredType(among: provider.registeredTypeIdentifiers),
                  let data = await DeviceImport.loadData(provider, as: type) else { continue }
            do {
                _ = try CaptureIntake.save(data, name: DeviceImport.fileName(for: type),
                                           origin: "Import from iPhone or iPad (Continuity Camera)")
                saved += 1
            } catch {
                KalsmritikoshLog.app.error("Device import save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if saved > 0 { _ = await readCaptureIntake() }
        return saved
    }
}
