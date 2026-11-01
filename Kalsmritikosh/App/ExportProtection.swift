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

/// Re-review 2026-11-02 — the protected-identity register held in memory so every synchronous export path
/// can check against it. nil = not known yet (or unreadable): exports refuse until it is (fail closed).
/// Loaded when the ledger opens and refreshed whenever a source-vault or source-map result is saved.
nonisolated enum ProtectedIdentityCache {
    private static let state = OSAllocatedUnfairLock<[String]?>(initialState: nil)
    static func set(_ names: [String]?) { state.withLock { $0 = names } }
    static var names: [String]? {
        #if DEBUG
        if let n = TestOverride.names { return n }
        #endif
        return state.withLock { $0 }
    }
    #if DEBUG
    enum TestOverride { @TaskLocal static var names: [String]? }
    #endif
}

nonisolated enum ProtectedExport {
    /// The text to export, or why not. `refuseIfPresent`: a sealed or signed artefact (a verifiable receipt,
    /// a signed slice, a proof bundle) cannot be altered after sealing, so a protected identity in it
    /// refuses the export instead of being replaced (replacing would break verification, and the hashes of
    /// the original passages would let a guessed name be confirmed).
    static func prepare(_ text: String, refuseIfPresent: Bool = false) -> Result<String, ExportProtectionRefusal> {
        guard let names = ProtectedIdentityCache.names else {
            return .failure(.init(reason: "The register of protected source identities has not been read yet, so this file could not be checked. Nothing was exported; try again in a moment."))
        }
        guard !names.isEmpty else { return .success(text) }
        if refuseIfPresent {
            let found = RedactionVerifier().leaks(in: text, protectedTerms: names, artifact: "export")
            return found.isEmpty ? .success(text)
                : .failure(.init(reason: "Nothing was exported: this sealed file would contain \(found.count) protected source identity(ies), and a sealed file cannot be redacted after sealing. Leave those passages out and export again."))
        }
        let scrubbed = ProtectedIdentities.scrub(text, names: names)
        return scrubbed.leaks.isEmpty ? .success(scrubbed.text)
            : .failure(.init(reason: "Nothing was exported: \(scrubbed.leaks.count) protected source identity(ies) would remain recoverable in the file."))
    }
}
