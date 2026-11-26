//
//  CertifiedCopy.swift
//  Kalsmritikosh
//
//  ALCOA ALC-17 (DATA-27, owner 2026-11-24) — original. Every exported original or derived copy gets a certification
//  sidecar beside it (`<file>.certification.txt`): the file's SHA-256 and size, whether it is an original or a derived
//  copy, the source versions it was made from, the producer (app, version, build) and the person, the time with its
//  zone, and the result of reading the written file back and hashing it again. The sidecar is plain text with one
//  "key: value" line each, so a person and a program can both read it. It certifies that the copy is what the app
//  wrote from those sources — it is not an e-signature and not a statement of compliance.
//

import Foundation
import CryptoKit
import os

public nonisolated struct CertifiedCopy: Sendable, Equatable {
    public enum Kind: String, Sendable { case original, derived }

    public let fileName: String
    public let sha256: String
    public let bytes: Int
    public let kind: Kind
    /// Source version ids (or document fingerprints) the copy was made from; empty when the export does not carry them.
    public let sources: [String]
    public let producer: String
    public let producedBy: String
    public let producedAt: Date
    public let zone: TimeZone
    /// "verified — the file read back hashes to the SHA-256 above", or what was found.
    public let verifyResult: String
    /// For an original: the SHA-256 recorded for the original when it was taken in (nil when not known).
    public let originalSHA256: String?

    public static let sidecarSuffix = ".certification.txt"

    /// The app, its version and build — the producer named on every certification.
    public static var producerName: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Investigations Made Easy \(v) (build \(b))"
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The certification page, plain English first, then the fields.
    public var text: String {
        var out = "CERTIFICATION OF COPY\n\n"
        out += kind == .original
            ? "This file is a copy of an original document as the app holds it. "
            : "This file is a copy derived by the app (a report, an extract or a rendering) from the sources listed below. "
        out += "Its SHA-256 below was computed from the bytes written and checked again by reading the file back. "
        out += "Any change to the file changes the SHA-256. Built on ALCOA++ principles, with Secure and Reliable; this is not an e-signature.\n\n"
        out += "file: \(fileName)\n"
        out += "sha256: \(sha256)\n"
        out += "bytes: \(bytes)\n"
        out += "copy_kind: \(kind.rawValue)\n"
        if let originalSHA256 { out += "original_sha256_at_intake: \(originalSHA256)\n" }
        out += "source_versions: \(sources.isEmpty ? "not recorded for this export" : sources.joined(separator: ", "))\n"
        out += "producer: \(producer)\n"
        out += "produced_by: \(producedBy)\n"
        out += "produced_at: \(ExportDateStyle.stamp(producedAt, zone: zone, seconds: true))\n"
        out += "time_zone: \(zone.identifier)\n"
        out += "verify_result: \(verifyResult)\n"
        return out
    }

    /// Hash `url` as written, compare with `expected` (when given), and build the certification.
    public static func certify(fileAt url: URL, kind: Kind, sources: [String], producedBy: String, expectedSHA256: String? = nil,
                               originalSHA256: String? = nil, at date: Date = Date(), zone: TimeZone = .current) -> CertifiedCopy {
        let data: Data?
        do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) } catch {
            KalsmritikoshLog.app.error("Certified copy: the written file could not be read back: \(error.localizedDescription, privacy: .private)")
            data = nil
        }
        let digest = data.map(sha256) ?? ""
        let verify: String
        if data == nil { verify = "NOT verified — the written file could not be read back" }
        else if let expectedSHA256, expectedSHA256.lowercased() != digest { verify = "MISMATCH — the file read back does not hash to what the app wrote (\(expectedSHA256.prefix(16))…)" }
        else if let originalSHA256, kind == .original, originalSHA256.lowercased() != digest { verify = "MISMATCH — the copy does not hash to the original recorded at intake" }
        else { verify = "verified — the file read back hashes to the SHA-256 above" + (kind == .original && originalSHA256 != nil ? ", the same as the original recorded at intake" : "") }
        return CertifiedCopy(fileName: url.lastPathComponent, sha256: digest, bytes: data?.count ?? 0, kind: kind, sources: sources,
                             producer: producerName, producedBy: producedBy, producedAt: date, zone: zone, verifyResult: verify,
                             originalSHA256: originalSHA256)
    }

    /// The sidecar's location for a written file.
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + sidecarSuffix)
    }

    /// Certify `url` and write the sidecar beside it. The certification is returned either way; `sidecarWritten` is false
    /// when the folder did not allow a second file (a sandboxed save window grants only the file chosen) — the
    /// certification is then kept in the ledger only (export_certifications) and printed in the case's data integrity report.
    @discardableResult
    public static func writeSidecar(for url: URL, kind: Kind, sources: [String], producedBy: String, expectedSHA256: String? = nil,
                                    originalSHA256: String? = nil) -> (cert: CertifiedCopy, sidecarWritten: Bool) {
        let cert = certify(fileAt: url, kind: kind, sources: sources, producedBy: producedBy, expectedSHA256: expectedSHA256, originalSHA256: originalSHA256)
        do {
            try Data(cert.text.utf8).write(to: sidecarURL(for: url), options: .atomic)
            return (cert, true)
        } catch {
            KalsmritikoshLog.app.error("Certified copy: sidecar not written (kept in the ledger): \(error.localizedDescription, privacy: .private)")
            return (cert, false)
        }
    }

    /// Keep the certification in the ledger (append-only; removed with its case or by a full erase).
    public static func record(_ db: Database, _ cert: CertifiedCopy, caseID: UUID?, path: String?, sidecarWritten: Bool) async {
        let sources = (try? JSONEncoder().encode(cert.sources)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        do {
            try await db.exec("""
                INSERT INTO export_certifications (id, case_id, file_name, file_path, sha256, bytes, copy_kind, sources_json, producer, produced_by,
                                                   produced_at, recorded_tz, verify_result, sidecar_written)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), caseID.map { .uuid($0) } ?? .null, .text(cert.fileName), path.map { .text($0) } ?? .null, .text(cert.sha256),
                      .integer(Int64(cert.bytes)), .text(cert.kind.rawValue), .text(sources), .text(cert.producer), .text(cert.producedBy),
                      .date(cert.producedAt), .text(cert.zone.identifier), .text(cert.verifyResult), .integer(sidecarWritten ? 1 : 0)])
        } catch {
            KalsmritikoshLog.app.error("Certified copy: not kept in the ledger: \(String(describing: error), privacy: .private)")
        }
    }

    /// The ledger the app has open, for exports that do not hold it (set when the ledger opens; nil: not recorded).
    public static let ledger = LedgerHolder()
    public final class LedgerHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var db: Database?
        public func set(_ d: Database?) { lock.lock(); db = d; lock.unlock() }
        public func clear(ifSame d: Database) { lock.lock(); if db === d { db = nil }; lock.unlock() }
        public var current: Database? { lock.lock(); defer { lock.unlock() }; return db }
    }

    /// Certify, write the sidecar and keep the certification in the open ledger.
    public static func certifyAndRecord(_ url: URL, kind: Kind, sources: [String], producedBy: String, expectedSHA256: String?,
                                        caseID: UUID? = nil, database: Database? = nil) async -> (cert: CertifiedCopy, sidecarWritten: Bool) {
        let out = writeSidecar(for: url, kind: kind, sources: sources, producedBy: producedBy, expectedSHA256: expectedSHA256)
        if let db = database ?? ledger.current {
            await record(db, out.cert, caseID: caseID, path: url.standardizedFileURL.path, sidecarWritten: out.sidecarWritten)
        }
        return out
    }

    /// Read a sidecar's fields back ("key: value" lines).
    public static func fields(ofSidecar text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: ": "), !line.hasPrefix(" ") else { continue }
            let k = String(line[..<r.lowerBound])
            guard k.range(of: "^[a-z_0-9]+$", options: .regularExpression) != nil else { continue }
            out[k] = String(line[r.upperBound...])
        }
        return out
    }
}
