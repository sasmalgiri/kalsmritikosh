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

    /// S18 (SEC-06) — the protected-identity register read fresh from the ledger, for the second check at write.
    func protectedNamesNow() async throws -> [String] {
        guard let database else { throw ExportProtectionRefusal(reason: "The ledger is not open, so protected source identities could not be checked. Nothing was exported.") }
        return try await JobResultRepository(database: database).protectedIdentityNames()
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
    /// S18 (SEC-06) — the second check, AT WRITE. A save panel stays open as long as the person likes; a source marked
    /// protected meanwhile must still stop the file. `names` reads the register fresh (fail closed: unreadable → nothing
    /// written); `text` is checked against it — replaced, or refused when `refuseIfPresent` (a sealed/signed file) — and
    /// only then written. Returns the text written.
    static func writeRechecked(_ text: String, to url: URL, refuseIfPresent: Bool,
                               names: () async throws -> [String]) async -> Result<String, ExportProtectionRefusal> {
        let out: String
        switch await recheck(text, refuseIfPresent: refuseIfPresent, names: names) {
        case .success(let checked): out = checked
        case .failure(let refusal): return .failure(refusal)
        }
        do { try Data(out.utf8).write(to: url, options: .atomic) } catch {
            // Deep dive batch 4: a FileManager error names the file; only its domain and code are public.
            let ns = error as NSError
            KalsmritikoshLog.app.error("Export: write failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
            return .failure(.init(reason: "The file could not be written: \(error.localizedDescription)"))
        }
        return .success(out)
    }

    /// Deep dive batch 4 — the at-write check on its own, for an export that writes more than one file (a proof
    /// bundle folder): `text` against the register read now. The checked text (replaced), or why not.
    static func recheck(_ text: String, refuseIfPresent: Bool,
                        names: () async throws -> [String]) async -> Result<String, ExportProtectionRefusal> {
        let current: [String]
        do { current = try await names() } catch {
            KalsmritikoshLog.app.error("Export: protected-identity register unreadable at write: \(String(describing: type(of: error)), privacy: .public)")
            return .failure(.init(reason: "The register of protected source identities could not be read when the file was about to be written. Nothing was exported."))
        }
        if current.isEmpty { return .success(text) }
        if refuseIfPresent {
            let found = RedactionVerifier().leaks(in: text, protectedTerms: current, artifact: "export")
            guard found.isEmpty else {
                return .failure(.init(reason: "Nothing was exported: a source was marked protected while the save window was open, and this sealed file would contain \(found.count) protected source identity(ies)."))
            }
            return .success(text)
        }
        let scrubbed = ProtectedIdentities.scrub(text, names: current)
        guard scrubbed.leaks.isEmpty else {
            return .failure(.init(reason: "Nothing was exported: \(scrubbed.leaks.count) protected source identity(ies) would remain recoverable in the file."))
        }
        return .success(scrubbed.text)
    }

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
