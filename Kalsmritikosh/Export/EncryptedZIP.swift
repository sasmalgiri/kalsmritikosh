//
//  EncryptedZIP.swift
//  Kalsmritikosh
//
//  ALCOA ALC-21 (DATA-31, owner 2026-11-24) — optional export encryption: a password-protected ZIP in the WinZip AES
//  format (AE-2, AES-256): per member a random 16-byte salt, PBKDF2-HMAC-SHA1 (1,000 rounds, as the format fixes) for
//  the AES key, the HMAC key and a 2-byte password check, AES-256 in counter mode (little-endian counter from 1), and a
//  10-byte HMAC-SHA1 authentication code over the encrypted bytes. Members are stored (no compression). Built only from
//  the system's CommonCrypto and CryptoKit — no dependency. Opens with 7-Zip, Keka, The Unarchiver, bsdtar/libarchive
//  and WinZip; Finder's built-in Archive Utility does not open AES ZIPs (the export says so).
//  The file names inside a ZIP are not encrypted (the format does not allow it): the app names members neutrally.
//

import Foundation
import CommonCrypto
import CryptoKit
import os

public nonisolated enum EncryptedZIP {

    public enum ZIPError: Error, LocalizedError, Equatable {
        case passwordTooShort, cryptoFailed, notEncryptedZIP, wrongPassword, damaged
        public var errorDescription: String? {
            switch self {
            case .passwordTooShort: return "Use a password of at least 8 characters."
            case .cryptoFailed: return "The archive could not be encrypted."
            case .notEncryptedZIP: return "This is not a password-protected ZIP made by the app."
            case .wrongPassword: return "The password does not open this archive."
            case .damaged: return "The archive is damaged: a member does not match its authentication code."
            }
        }
    }

    /// What every encrypted export says about opening it.
    public static let viewerNote = "Password-protected ZIP (AES-256, WinZip AES format). Open it with 7-Zip, Keka, The Unarchiver or WinZip; macOS Archive Utility (double-click in Finder) does not open AES ZIPs."

    static let minimumPassword = 8

    struct Keys { let enc: Data; let mac: Data; let verifier: Data }

    static func derive(password: String, salt: Data) throws -> Keys {
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 66)
        let rc = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pw.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000, &out, out.count)
        }
        guard rc == kCCSuccess else { throw ZIPError.cryptoFailed }
        return Keys(enc: Data(out[0..<32]), mac: Data(out[32..<64]), verifier: Data(out[64..<66]))
    }

    /// AES-256-CTR with the WinZip counter (16-byte little-endian block counter starting at 1). Same call encrypts and decrypts.
    static func ctr(_ data: Data, key: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let blocks = (data.count + 15) / 16
        var counters = Data(count: blocks * 16)
        counters.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<blocks {
                var n = UInt64(i + 1)
                for b in 0..<8 { p[i * 16 + b] = UInt8(n & 0xff); n >>= 8 }
            }
        }
        var stream = Data(count: counters.count)
        var moved = 0
        let rc = stream.withUnsafeMutableBytes { out in
            counters.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, inp.baseAddress, counters.count, out.baseAddress, counters.count, &moved)
                }
            }
        }
        guard rc == kCCSuccess else { throw ZIPError.cryptoFailed }
        var result = Data(count: data.count)
        result.withUnsafeMutableBytes { r in
            data.withUnsafeBytes { d in
                stream.withUnsafeBytes { s in
                    let rp = r.bindMemory(to: UInt8.self), dp = d.bindMemory(to: UInt8.self), sp = s.bindMemory(to: UInt8.self)
                    for i in 0..<data.count { rp[i] = dp[i] ^ sp[i] }
                }
            }
        }
        return result
    }

    static func authCode(_ cipher: Data, key: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: cipher, using: SymmetricKey(data: key)).prefix(10))
    }

    /// The AES extra field (0x9901): vendor version 2 (AE-2), "AE", strength 3 (AES-256), actual method 0 (stored).
    static let extra: Data = {
        var d = Data()
        d.putLE(UInt16(0x9901)); d.putLE(UInt16(7)); d.putLE(UInt16(2))
        d.append(contentsOf: [0x41, 0x45, 0x03]); d.putLE(UInt16(0))
        return d
    }()

    /// A password-protected ZIP of `entries`. Each member gets its own random salt.
    public static func build(_ entries: [ZIPArchiveWriter.Entry], password: String) throws -> Data {
        guard password.count >= minimumPassword else { throw ZIPError.passwordTooShort }
        var local = Data(), central = Data()
        for entry in entries {
            var salt = Data(count: 16)
            let ok = salt.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return SecRandomCopyBytes(kSecRandomDefault, 16, base) == errSecSuccess
            }
            guard ok else { throw ZIPError.cryptoFailed }
            let keys = try derive(password: password, salt: salt)
            let cipher = try ctr(entry.data, key: keys.enc)
            let body = salt + keys.verifier + cipher + authCode(cipher, key: keys.mac)
            let name = Data(entry.path.utf8)
            let offset = UInt32(local.count)
            func header(_ d: inout Data, centralDir: Bool) {
                d.putLE(UInt32(centralDir ? 0x0201_4b50 : 0x0403_4b50))
                if centralDir { d.putLE(UInt16(51)) }       // version made by
                d.putLE(UInt16(51))                         // version needed (AES)
                d.putLE(UInt16(0x0001))                     // encrypted
                d.putLE(UInt16(99))                         // method: AES
                d.putLE(UInt16(0)); d.putLE(UInt16(0x0021))   // fixed DOS time/date (1980-01-01)
                d.putLE(UInt32(0))                          // CRC: 0 in AE-2 (the HMAC authenticates)
                d.putLE(UInt32(body.count)); d.putLE(UInt32(entry.data.count))
                d.putLE(UInt16(name.count)); d.putLE(UInt16(extra.count))
                if centralDir {
                    d.putLE(UInt16(0)); d.putLE(UInt16(0)); d.putLE(UInt16(0)); d.putLE(UInt32(0)); d.putLE(offset)
                }
                d.append(name); d.append(extra)
            }
            header(&local, centralDir: false)
            local.append(body)
            header(&central, centralDir: true)
        }
        var out = local
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.putLE(UInt32(0x0605_4b50)); out.putLE(UInt16(0)); out.putLE(UInt16(0))
        out.putLE(UInt16(entries.count)); out.putLE(UInt16(entries.count))
        out.putLE(UInt32(central.count)); out.putLE(centralOffset); out.putLE(UInt16(0))
        return out
    }

    /// Read back an archive this writer made: every member checked against its authentication code, then decrypted.
    public static func open(_ zip: Data, password: String) throws -> [ZIPArchiveWriter.Entry] {
        var out: [ZIPArchiveWriter.Entry] = []
        var i = 0
        func u16(_ at: Int) -> Int { Int(zip[zip.startIndex + at]) | Int(zip[zip.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        while i + 30 <= zip.count, u32(i) == 0x0403_4b50 {
            guard u16(i + 8) == 99 else { throw ZIPError.notEncryptedZIP }
            let size = u32(i + 18), nameLen = u16(i + 26), extraLen = u16(i + 28)
            let nameStart = i + 30, dataStart = nameStart + nameLen + extraLen
            guard dataStart + size <= zip.count, size >= 28 else { throw ZIPError.damaged }
            let name = String(decoding: zip.subdata(in: (zip.startIndex + nameStart)..<(zip.startIndex + nameStart + nameLen)), as: UTF8.self)
            let body = zip.subdata(in: (zip.startIndex + dataStart)..<(zip.startIndex + dataStart + size))
            let salt = body.prefix(16), verifier = body.subdata(in: (body.startIndex + 16)..<(body.startIndex + 18))
            let cipher = body.subdata(in: (body.startIndex + 18)..<(body.endIndex - 10)), mac = body.suffix(10)
            let keys = try derive(password: password, salt: Data(salt))
            guard keys.verifier == verifier else { throw ZIPError.wrongPassword }
            guard authCode(cipher, key: keys.mac) == Data(mac) else { throw ZIPError.damaged }
            out.append(.init(path: name, data: try ctr(cipher, key: keys.enc)))
            i = dataStart + size
        }
        guard !out.isEmpty else { throw ZIPError.notEncryptedZIP }
        return out
    }
}

fileprivate extension Data {
    mutating func putLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func putLE(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}
