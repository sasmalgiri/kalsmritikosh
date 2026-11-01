//
//  ExportProtection.swift
//  Kalsmritikosh
//
//  Practitioner review 2026-11-02 (Journalist blocker): every file export carries protected source
//  identities through the same check — replaced, verified gone, or nothing is written. Fails closed: a
//  register that cannot be read, or a name that would survive, stops the export with the reason.
//

import Foundation
import AppKit
import os

extension AppState {
    /// `text` with every protected source identity replaced, or the reason it may not be exported.
    func protectedExportText(_ text: String) async -> Result<String, ExportProtectionRefusal> {
        guard let database else { return .failure(.init(reason: "The ledger is not open, so protected source identities could not be checked. Nothing was exported.")) }
        let names: [String]
        do { names = try await JobResultRepository(database: database).protectedIdentityNames() } catch {
            KalsmritikoshLog.app.error("Export: protected-identity register unreadable: \(String(describing: error), privacy: .public)")
            return .failure(.init(reason: "The register of protected source identities could not be read, so this file could not be checked. Nothing was exported."))
        }
        let scrubbed = ProtectedIdentities.scrub(text, names: names)
        guard scrubbed.leaks.isEmpty else {
            return .failure(.init(reason: "Nothing was exported: \(scrubbed.leaks.count) protected source identity(ies) would remain recoverable in the file."))
        }
        return .success(scrubbed.text)
    }
}

struct ExportProtectionRefusal: Error, Equatable {
    let reason: String

    /// Tell the person why nothing was written.
    @MainActor func present() {
        let alert = NSAlert()
        alert.messageText = "Not exported"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.runModal()
    }
}
