//
//  SimulatedSharedCaseVault.swift
//  Kalsmritikosh
//
//  Unified path R2-E (SEC-04, owner 2026-11-22 round 2) — not tested yet. SIMULATED shared-data encryption boundary with
//  per-member keys (CryptoKit): each shared case has a content key (AES-256-GCM); the key is wrapped for each member
//  with an ephemeral Curve25519 key agreement + HKDF-SHA256 to that member's public key. The "service" side of this
//  actor holds only ciphertext, wrapped keys and public keys — never a private key or plaintext. Removing a member
//  rotates the content key: the lead's client re-encrypts the items under the new key and wraps it for the remaining
//  members only, so the removed member cannot open anything written or re-encrypted afterwards (what they already
//  downloaded is out of reach of any revocation, and `disclosure` says so).
//

import Foundation
import CryptoKit
import os

public nonisolated enum SimulatedEncryptionDisclosure {
    /// SEC-04 accept: server-side processing is never described as end-to-end encryption the server cannot read.
    public static let text = """
    SIMULATED shared-case encryption. In this simulation the service stores only encrypted items and per-member \
    wrapped keys; it cannot read case content. Any feature that processes shared content on a server (search, AI, \
    previews) would make that content readable by the server and would NOT be end-to-end encrypted; it must be \
    disclosed as such. Removing a member rotates the key for new and re-encrypted items; copies a member already \
    downloaded cannot be recalled.
    """
}

public nonisolated enum SimVaultError: Error, Equatable {
    case unknownCase, noKeyForMember, keyOutOfDate, decryptFailed, notLead
}

public actor SimulatedSharedCaseVault {
    public struct WrappedKey: Sendable, Codable, Equatable {
        public let epoch: Int
        public let ephemeralPublicKey: Data
        public let sealed: Data
    }
    public struct SealedItem: Sendable, Codable, Equatable {
        public let id: UUID
        public let epoch: Int
        public let author: SimAccountID
        public let combined: Data
    }
    struct CaseState {
        var epoch: Int
        var lead: SimAccountID
        var envelopes: [SimAccountID: WrappedKey]
        var items: [SealedItem]
    }
    private var cases: [UUID: CaseState] = [:]

    public nonisolated init() {}

    // MARK: Client-side helpers (run on a member's own Mac; the private key never reaches the service)

    public nonisolated static func wrap(_ contentKey: SymmetricKey, for member: Curve25519.KeyAgreement.PublicKey, caseID: UUID, epoch: Int) throws -> WrappedKey {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let kek = try kek(eph.sharedSecretFromKeyAgreement(with: member), caseID: caseID, epoch: epoch)
        let raw = contentKey.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(raw, using: kek).combined else { throw SimVaultError.decryptFailed }
        return WrappedKey(epoch: epoch, ephemeralPublicKey: eph.publicKey.rawRepresentation, sealed: sealed)
    }

    public nonisolated static func unwrap(_ w: WrappedKey, with key: Curve25519.KeyAgreement.PrivateKey, caseID: UUID) throws -> SymmetricKey {
        let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: w.ephemeralPublicKey)
        let kek = try kek(key.sharedSecretFromKeyAgreement(with: eph), caseID: caseID, epoch: w.epoch)
        do { return SymmetricKey(data: try AES.GCM.open(AES.GCM.SealedBox(combined: w.sealed), using: kek)) } catch {
            KalsmritikoshLog.app.notice("SIMULATED vault: a wrapped key did not open with this member's key")
            throw SimVaultError.decryptFailed
        }
    }

    nonisolated static func kek(_ secret: SharedSecret, caseID: UUID, epoch: Int) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(caseID.uuidString.utf8),
                                       sharedInfo: Data("kals.sim.case-key.v1|\(epoch)".utf8), outputByteCount: 32)
    }

    // MARK: Service side

    /// The lead opens the shared case: a new content key, wrapped for the lead (and any first members).
    public func open(caseID: UUID, lead: SimAccountID, members: [(SimAccountID, Curve25519.KeyAgreement.PublicKey)]) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var env: [SimAccountID: WrappedKey] = [:]
        for (id, pub) in members { env[id] = try Self.wrap(key, for: pub, caseID: caseID, epoch: 1) }
        cases[caseID] = CaseState(epoch: 1, lead: lead, envelopes: env, items: [])
        return key
    }

    /// A member added: the lead's client wraps the current content key for the new member's public key.
    public func addMember(caseID: UUID, member: SimAccountID, publicKey: Curve25519.KeyAgreement.PublicKey, leadKey: Curve25519.KeyAgreement.PrivateKey) throws {
        guard var c = cases[caseID], let leadEnv = c.envelopes[c.lead] else { throw SimVaultError.unknownCase }
        let content = try Self.unwrap(leadEnv, with: leadKey, caseID: caseID)
        c.envelopes[member] = try Self.wrap(content, for: publicKey, caseID: caseID, epoch: c.epoch)
        cases[caseID] = c
    }

    public func envelope(caseID: UUID, member: SimAccountID) -> WrappedKey? { cases[caseID]?.envelopes[member] }

    /// A member writes: their client unwraps the key with their own private key and seals the item.
    public func put(caseID: UUID, plaintext: Data, author: SimAccountID, authorKey: Curve25519.KeyAgreement.PrivateKey) throws -> UUID {
        guard var c = cases[caseID] else { throw SimVaultError.unknownCase }
        guard let env = c.envelopes[author] else { throw SimVaultError.noKeyForMember }
        let key = try Self.unwrap(env, with: authorKey, caseID: caseID)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw SimVaultError.decryptFailed }
        let item = SealedItem(id: UUID(), epoch: c.epoch, author: author, combined: combined)
        c.items.append(item)
        cases[caseID] = c
        return item.id
    }

    /// A member reads: only with an envelope of the item's epoch and their own private key.
    public func read(caseID: UUID, itemID: UUID, as member: SimAccountID, key: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let c = cases[caseID], let item = c.items.first(where: { $0.id == itemID }) else { throw SimVaultError.unknownCase }
        guard let env = c.envelopes[member] else { throw SimVaultError.noKeyForMember }
        guard env.epoch == item.epoch else { throw SimVaultError.keyOutOfDate }
        let content = try Self.unwrap(env, with: key, caseID: caseID)
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: item.combined), using: content) } catch {
            KalsmritikoshLog.app.notice("SIMULATED vault: an item did not open with this member's key")
            throw SimVaultError.decryptFailed
        }
    }

    /// Remove a member and rotate: the lead's client decrypts every item under the old key, re-encrypts it under a new
    /// key and wraps the new key for the remaining members only.
    public func removeAndRotate(caseID: UUID, removed: SimAccountID, remaining: [(SimAccountID, Curve25519.KeyAgreement.PublicKey)],
                                leadKey: Curve25519.KeyAgreement.PrivateKey) throws {
        guard var c = cases[caseID], let leadEnv = c.envelopes[c.lead] else { throw SimVaultError.unknownCase }
        let old = try Self.unwrap(leadEnv, with: leadKey, caseID: caseID)
        let new = SymmetricKey(size: .bits256)
        let epoch = c.epoch + 1
        var items: [SealedItem] = []
        for item in c.items {
            let plain: Data
            do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: item.combined), using: old) } catch {
                KalsmritikoshLog.app.error("SIMULATED vault: an item could not be re-encrypted during rotation")
                throw SimVaultError.decryptFailed
            }
            guard let combined = try AES.GCM.seal(plain, using: new).combined else { throw SimVaultError.decryptFailed }
            items.append(SealedItem(id: item.id, epoch: epoch, author: item.author, combined: combined))
        }
        var env: [SimAccountID: WrappedKey] = [:]
        for (id, pub) in remaining where id != removed { env[id] = try Self.wrap(new, for: pub, caseID: caseID, epoch: epoch) }
        c.epoch = epoch; c.items = items; c.envelopes = env
        cases[caseID] = c
    }

    /// Everything the service stores for a case (tests check that no plaintext is in it).
    public func serverVisibleBytes(caseID: UUID) -> Data {
        guard let c = cases[caseID] else { return Data() }
        var d = Data()
        for e in c.envelopes.values { d.append(e.ephemeralPublicKey); d.append(e.sealed) }
        for i in c.items { d.append(i.combined) }
        return d
    }
}
