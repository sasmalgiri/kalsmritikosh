//
//  AppState+KeyRotation.swift
//  Kalsmritikosh
//
//  ALCOA ALC-21 (owner 2026-11-24) — "Rotate keys" from Settings: the rotation is requested, the ledger closed, rotated
//  (KeyRotation, while closed) and opened again under the new key; the new chain key seals the rotation record at once.
//

import Foundation
import os

extension AppState {
    /// Rotate the ledger key, re-seal the vault and start a new audit-chain key. Returns the line to show.
    func rotateKeys(actor: String) async -> String {
        guard let db = database else { return "The ledger is not open." }
        let url = db.url
        do { try KeyRotation.request(ledgerURL: url, by: actor) } catch {
            KalsmritikoshLog.storage.error("Key rotation not requested: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
        await shutdown()
        prepareReopen()
        await boot(databaseURL: url)
        if let failure = KeyRotation.lastFailure, KeyRotation.lastReport == nil { return failure }
        guard case .ready = phase else { return "The ledger did not open again after the rotation; quit and reopen the app to finish it." }
        if let chain = auditChain {
            do { _ = try await chain.seal() } catch {
                KalsmritikoshLog.storage.error("Audit chain not sealed after rotation: \(String(describing: error), privacy: .public)")
            }
        }
        return KeyRotation.lastReport?.line ?? "The keys were rotated."
    }
}
