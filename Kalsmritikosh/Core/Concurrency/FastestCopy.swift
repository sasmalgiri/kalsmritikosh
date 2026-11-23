//
//  FastestCopy.swift
//  Kalsmritikosh
//
//  Speed PERF-39 torrent (owner 2026-11-23) — not tested yet. "Many peers at once": the same bytes often exist twice —
//  the kept copy in the evidence vault (beside the ledger, normally the internal SSD) and the original on whatever disk
//  it was read from (a USB stick, a network share, an unplugged drive). A re-read takes the FASTER available copy: the
//  vault first when the original's disk is slower than the vault's (removable, network, optical) or not mounted; the
//  original first when it is at least as fast and the vault copy is sealed (opening a sealed copy decrypts it first).
//  Whichever copy is used, its bytes are hashed and must equal the recorded SHA-256 before anything uses them; a copy
//  that does not match is skipped (logged) and the next one is tried. Nothing is ever substituted unverified.
//

import Foundation
import os

public nonisolated enum FastestCopy {
    public enum Origin: String, Sendable { case vault, original }

    /// Try the vault copy before the original? `vaultSealed`: opening it costs a decrypt; `preferOriginalOnTie`: the
    /// original is the canonical copy (a referenced source) when both disks are as fast.
    public static func vaultFirst(original: URL?, vaultRoot: URL, vaultSealed: Bool, preferOriginalOnTie: Bool) -> Bool {
        guard let original, original.isFileURL else { return true }
        let o = VolumeReadLanes.profile(for: original).kind
        let v = VolumeReadLanes.profile(for: vaultRoot).kind
        if o == .offline || o.speedRank > v.speedRank { return true }
        if o.speedRank < v.speedRank { return false }
        return !(vaultSealed || preferOriginalOnTie)
    }

    /// The candidate order for these bytes: each origin at most once.
    public static func order(original: URL?, vault: EvidenceVault?, address: String?,
                             preferOriginalOnTie: Bool) async -> [Origin] {
        var vaultHas = false
        var sealed = false
        if let vault, let address, !address.isEmpty {
            vaultHas = await vault.contains(address.lowercased())
            if vaultHas { sealed = await vault.isSealed(address.lowercased()) }
        }
        let originalUsable = original.map { $0.isFileURL && VolumeReadLanes.isReachable($0) } ?? false
        switch (vaultHas, originalUsable) {
        case (false, false): return []
        case (true, false): return [.vault]
        case (false, true): return [.original]
        case (true, true):
            let first = vaultFirst(original: original, vaultRoot: vault?.rootURL ?? URL(fileURLWithPath: NSTemporaryDirectory()),
                                   vaultSealed: sealed, preferOriginalOnTie: preferOriginalOnTie)
            return first ? [.vault, .original] : [.original, .vault]
        }
    }

    /// A file URL holding exactly the bytes whose SHA-256 is `expectedSHA256`, from the fastest copy that verifies;
    /// nil when neither copy is there or neither matches. `filename` names an opened vault copy (so it keeps the
    /// original's name and type). The hash read is paced by the copy's disk lane (PERF-38).
    public static func verifiedURL(expectedSHA256: String, original: URL?, vault: EvidenceVault?, address: String?,
                                   filename: String?, preferOriginalOnTie: Bool) async -> (url: URL, origin: Origin)? {
        let want = expectedSHA256.lowercased()
        guard want.count == 64 else { return nil }
        for origin in await order(original: original, vault: vault, address: address ?? want, preferOriginalOnTie: preferOriginalOnTie) {
            let candidate: URL?
            switch origin {
            case .vault: candidate = await vault?.url(for: (address ?? want).lowercased(), filename: filename)
            case .original: candidate = original
            }
            guard let url = candidate else { continue }
            let got: String
            do {
                got = try await VolumeReadLanes.withRead(url) {
                    try await Task.detached(priority: .utility) { try StreamingFileCopy.hash(url).sha256 }.value
                }
            } catch {
                KalsmritikoshLog.storage.error("FastestCopy: the \(origin.rawValue, privacy: .public) copy could not be read: \(error.localizedDescription, privacy: .private)")
                continue
            }
            if got.lowercased() == want { return (url, origin) }
            KalsmritikoshLog.storage.error("FastestCopy: the \(origin.rawValue, privacy: .public) copy does not match the recorded fingerprint — not used")
        }
        return nil
    }
}
