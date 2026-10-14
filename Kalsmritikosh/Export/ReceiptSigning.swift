//
//  ReceiptSigning.swift
//  Kalsmritikosh
//
//  W1-3 — signed receipts. A VerifiableReceipt's SHA-256 chain proves the
//  entries match the seal, but anyone who edits a receipt can recompute a valid
//  chain. Signing the seal with this installation's P-256 key (Secure Enclave
//  when available — the same key the conformance seal uses) makes a changed
//  byte OR a different signer fail verification, and the embedded public key
//  lets anyone check it with any standard ECDSA P-256 verifier.
//
//  Wire format: the v1 receipt JSON gains one field, `signature`, which older
//  verifiers ignore, so signed and unsigned receipts both still parse.
//    "signature": {"algorithm":"ECDSA-P256-SHA256","publicKey":"<base64 X9.63>",
//                  "value":"<base64 DER>","signedAt":"<ISO 8601>","keyStore":"secure-enclave"}
//  Signed message (UTF-8): "kalsmritikosh.receipt.v1|" + title + "|" + seal.
//
//  Honest scope: proves THIS installation's key signed this exact receipt —
//  not which person ran it.
//

import Foundation
import CryptoKit

public enum ReceiptSignatureCheck: Sendable, Equatable {
    case unsigned
    /// `fingerprint` is the first 16 hex digits of SHA-256(public key).
    case valid(fingerprint: String, keyStore: String, signedAt: String)
    case invalid
}

public enum ReceiptSigner {

    static let algorithm = "ECDSA-P256-SHA256"

    static func message(title: String, seal: String) -> Data {
        Data("kalsmritikosh.receipt.v1|\(title)|\(seal)".utf8)
    }

    /// The JSON to export: signed when the module is on and a key is available,
    /// otherwise the plain v1 receipt exactly as before.
    public static func exportJSON(_ r: SealedReceipt) -> String {
        let base = VerifiableReceipt.json(r)
        guard ProductModuleFlags.isEnabled(.signedReceipts),
              let key = ConformanceSigningKey.loadOrGenerateBackend() else { return base }
        return signed(base, receipt: r, key: key) ?? base
    }

    static func signed(_ base: String, receipt r: SealedReceipt, key: ConformanceSigningKey.Backend) -> String? {
        guard let sig = try? key.signature(for: message(title: r.title, seal: r.seal)),
              base.hasSuffix("}") else { return nil }
        let block = """
        ,"signature":{"algorithm":"\(algorithm)","publicKey":"\(key.publicKey.x963Representation.base64EncodedString())","value":"\(sig.derRepresentation.base64EncodedString())","signedAt":"\(ISO8601DateFormatter().string(from: Date()))","keyStore":"\(key.assurance)"}
        """
        return String(base.dropLast()) + block + "}"
    }

    /// Check the signature of receipt bytes (the hash chain is checked separately
    /// by `VerifiableReceipt.verify`).
    public static func check(_ data: Data) -> ReceiptSignatureCheck {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .invalid }
        guard let sig = obj["signature"] as? [String: Any] else { return .unsigned }
        guard sig["algorithm"] as? String == algorithm,
              let title = obj["title"] as? String,
              let seal = obj["seal"] as? String,
              let keyB64 = sig["publicKey"] as? String, let keyData = Data(base64Encoded: keyB64),
              let valueB64 = sig["value"] as? String, let valueData = Data(base64Encoded: valueB64),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: valueData),
              publicKey.isValidSignature(signature, for: message(title: title, seal: seal))
        else { return .invalid }
        let fp = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined().prefix(16)
        return .valid(fingerprint: String(fp),
                      keyStore: sig["keyStore"] as? String ?? "unknown",
                      signedAt: sig["signedAt"] as? String ?? "")
    }
}
