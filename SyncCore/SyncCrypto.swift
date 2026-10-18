//
//  SyncCrypto.swift
//  SyncCore
//
//  X-5 — the sync store's cryptography, Apple frameworks only:
//   * store key = HKDF-SHA256( PBKDF2-HMAC-SHA256(passphrase, salt, rounds) ), 256-bit;
//   * every batch and blob is sealed with AES-GCM under that key (a changed byte fails);
//   * every batch is signed with the writing device's Ed25519 key.
//  The passphrase is never stored; a wrong one cannot open `store.json`'s check.
//

import Foundation
import CryptoKit
import CommonCrypto

nonisolated enum SyncCrypto {
    static let checkPlaintext = Data("kalsmritikosh-sync-store-v1".utf8)
    static let defaultRounds = 210_000

    enum Failure: Error, Equatable, LocalizedError {
        case emptyPassphrase, derivationFailed, wrongPassphrase, unreadable, badSignature
        var errorDescription: String? {
            switch self {
            case .emptyPassphrase: return "Choose a sync passphrase."
            case .derivationFailed: return "The sync key could not be made from the passphrase."
            case .wrongPassphrase: return "That passphrase does not open this sync folder."
            case .unreadable: return "A file in the sync folder could not be read; it may be damaged or changed."
            case .badSignature: return "A change in the sync folder is not signed by the device it claims to come from."
            }
        }
    }

    static func randomSalt() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// The store key for `passphrase` with this store's salt.
    static func storeKey(passphrase: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr -> Int32 in
            password.withUnsafeBufferPointer { pw -> Int32 in
                pw.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pwChars in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwChars, pw.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                         &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: derived), salt: salt,
                                      info: Data("kalsmritikosh.sync.store.v1".utf8), outputByteCount: 32)
    }

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw Failure.unreadable }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
        catch { throw Failure.unreadable }
    }

    /// The check value for a new store.
    static func makeCheck(key: SymmetricKey) throws -> String {
        try seal(checkPlaintext, key: key).base64EncodedString()
    }

    /// Throws `.wrongPassphrase` unless `key` opens the store's check.
    static func verify(check: String, key: SymmetricKey) throws {
        guard let data = Data(base64Encoded: check),
              let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key),
              opened == checkPlaintext else { throw Failure.wrongPassphrase }
    }

    // MARK: - Device signatures

    static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    static func verifySignature(_ signature: String, of data: Data, publicKey: String) throws {
        guard let sig = Data(base64Encoded: signature), let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(sig, for: data) else { throw Failure.badSignature }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
