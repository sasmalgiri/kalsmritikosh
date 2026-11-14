//
//  ProtectedSourceUnlockService.swift
//  Kalsmritikosh
//
//  Smart-map IN-09 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04): protected and damaged
//  inputs are told apart — needs a password, wrong password, corrupt, locked by the file system, and an
//  encryption the app cannot open — and the investigator can supply a password for ONE exact source version.
//
//  The original is never changed: the exact bytes are re-verified (SourceVersionByteResolver), opened in
//  memory, and on success an unprotected copy is ingested as its own source, linked to the original by the
//  `derivedConversion` relation with the method recorded (SRC-06). The password lives only in the call: it is
//  never written to the ledger, a log, a file name or an error message. Every attempt records its OUTCOME
//  (source_unlock_attempts), so a wrong password, a corrupt file or an unsupported scheme stays visible with
//  its remedy, and the investigator keeps the choices: try again, open the original, or leave it preserved.
//

import Foundation
import os
#if canImport(PDFKit)
import PDFKit
#endif

/// The protection / damage state of a source version's bytes.
public nonisolated enum ProtectedSourceState: String, Sendable, Equatable, CaseIterable {
    case notProtected
    case unlocked
    case wrongPassword
    case passwordNeeded
    case unsupportedEncryption
    case corrupt
    case locked
    case unavailable

    public var label: String {
        switch self {
        case .notProtected: return "Not password-protected"
        case .unlocked: return "Opened — a readable copy was added"
        case .wrongPassword: return "Wrong password"
        case .passwordNeeded: return "Needs a password"
        case .unsupportedEncryption: return "Protected in a way the app cannot open"
        case .corrupt: return "Damaged — could not be opened"
        case .locked: return "Locked by the file system"
        case .unavailable: return "Original not available"
        }
    }

    /// What the investigator can do next. The original is preserved in every state.
    public var remedy: String {
        switch self {
        case .notProtected: return "Nothing to unlock. If it still shows no text, re-read it or open the original."
        case .unlocked: return "The readable copy is linked to the original, which is kept unchanged."
        case .wrongPassword: return "Try the password again, or open the original in the app that made it. The original is kept."
        case .passwordNeeded: return "Enter the password to read it, or open the original. The original is kept unchanged."
        case .unsupportedEncryption: return "Save an unprotected copy in the app that made it and add that copy. The original is kept."
        case .corrupt: return "Ask the supplier for a fresh copy, or open the original to see what survives. The original is kept."
        case .locked: return "Close the file in other apps or give read permission, then retry. The original is kept."
        case .unavailable: return "Reconnect the drive or folder the original came from, then retry."
        }
    }

    /// States where entering a password can help.
    public var acceptsPassword: Bool { self == .passwordNeeded || self == .wrongPassword }
}

public nonisolated struct ProtectedSourceAttempt: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let state: ProtectedSourceState
    public let detail: String?
    /// The readable copy made from the original (only when `state == .unlocked`).
    public let derivedSourceVersionID: UUID?
    public let attemptedAt: Date
}

/// Pure byte classification — no password, no ledger.
public nonisolated enum ProtectedSourceProbe {

    /// Classify the bytes of one file as the app would read them.
    public static func classify(fileAt url: URL, type: SourceType) -> (state: ProtectedSourceState, detail: String?) {
        let data: Data
        do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { return readFailure(error) }
        return classify(data: data, type: type)
    }

    public static func classify(data: Data, type: SourceType) -> (state: ProtectedSourceState, detail: String?) {
        // An OOXML document (docx/xlsx/pptx) saved with a password is not a ZIP at all: Office wraps it in an
        // OLE2 compound file carrying "EncryptionInfo" / "EncryptedPackage" streams.
        if ([.docx, .xlsx, .pptx] as [SourceType]).contains(type) {
            if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
                return (.unsupportedEncryption, "Office password protection (encrypted package)")
            }
            return data.starts(with: [0x50, 0x4B]) ? (.notProtected, nil) : (.corrupt, "not a readable Office document")
        }
        switch type {
        case .pdf:
            #if canImport(PDFKit)
            guard let doc = PDFDocument(data: data) else { return (.corrupt, "PDF could not be opened") }
            if doc.isLocked {
                return doc.unlock(withPassword: "") ? (.notProtected, "owner-only protection; opens without a password")
                    : (.passwordNeeded, "PDF user password")
            }
            return (.notProtected, doc.isEncrypted ? "encrypted with permissions only; readable" : nil)
            #else
            return (.unsupportedEncryption, "PDF reading is unavailable on this platform")
            #endif
        case .zip:
            guard let entries = try? ZIPReader(data: data).entries() else { return (.corrupt, "the archive's directory could not be read") }
            let encrypted = entries.filter(\.isEncrypted)
            guard !encrypted.isEmpty else { return (.notProtected, nil) }
            // Method 99 is WinZip AES; otherwise traditional PKWARE encryption. The app decrypts neither.
            let aes = encrypted.contains { $0.compressionMethod == 99 }
            return (.unsupportedEncryption, "\(encrypted.count) of \(entries.count) member(s) encrypted (\(aes ? "AES" : "traditional ZIP encryption"))")
        default:
            return (.notProtected, nil)
        }
    }

    /// A read that failed before any byte was seen: permissions/locks vs a missing file.
    static func readFailure(_ error: Error) -> (state: ProtectedSourceState, detail: String?) {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if ns.code == NSFileReadNoPermissionError || posix == Int(EACCES) || posix == Int(EPERM) {
            return (.locked, "read permission refused")
        }
        if ns.code == NSFileReadNoSuchFileError || posix == Int(ENOENT) { return (.unavailable, "file not found") }
        return (.unavailable, "could not be read")
    }

    /// Try `password` on PDF bytes. Returns an UNPROTECTED copy (every page, text layer kept) on success.
    /// The password is used for this call only.
    public static func open(pdf data: Data, password: String) -> (state: ProtectedSourceState, copy: Data?, detail: String?) {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data) else { return (.corrupt, nil, "PDF could not be opened") }
        guard doc.isLocked else { return (.notProtected, nil, nil) }
        guard doc.unlock(withPassword: password) else { return (.wrongPassword, nil, nil) }
        // A fresh document of the unlocked pages: same page content streams (selectable text kept), no encryption.
        let out = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else {
                return (.unsupportedEncryption, nil, "opened, but page \(i + 1) could not be copied")
            }
            out.insert(page, at: out.pageCount)
        }
        guard let copy = out.dataRepresentation(), let check = PDFDocument(data: copy), !check.isLocked,
              check.pageCount == doc.pageCount else {
            return (.unsupportedEncryption, nil, "opened, but a readable copy could not be made")
        }
        return (.unlocked, copy, "\(doc.pageCount) page(s)")
        #else
        return (.unsupportedEncryption, nil, "PDF reading is unavailable on this platform")
        #endif
    }
}

/// SRC-06 — the recorded method of a derived copy (source_conversions).
public nonisolated struct SourceConversionRecorder: Sendable {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// Record how `derived` was made from `original` (idempotent: the first record of a pair stands).
    public func record(derived: UUID, original: UUID, method: String, detail: String?, at date: Date) async throws {
        guard derived != original else { return }
        try await database.exec("""
            INSERT OR IGNORE INTO source_conversions (source_version_id, original_source_version_id, method, detail, recorded_at)
            VALUES (?,?,?,?,?);
            """, [.uuid(derived), .uuid(original), .text(method), .optionalText(detail), .date(date)])
    }

    /// The recorded method of a derived version, when it has one.
    public func method(derived: UUID) async throws -> String? {
        try await database.query("SELECT method FROM source_conversions WHERE source_version_id = ? LIMIT 1;", [.uuid(derived)]).first?.string(0)
    }
}

public actor ProtectedSourceUnlockService {
    /// Ingest an opened copy of `original` (bytes at a temporary URL) as a linked derived source; returns its version.
    public typealias IngestDerivative = @Sendable (_ original: UUID, _ bytes: URL, _ filename: String) async throws -> UUID?

    private let database: Database
    private let byteResolver: SourceVersionByteResolver
    private let ingestDerivative: IngestDerivative
    private let conversions: SourceConversionRecorder

    public static let unlockMethod = "Opened with a password the investigator supplied (the password is not kept); the original is unchanged."

    public init(database: Database, byteResolver: SourceVersionByteResolver, ingestDerivative: @escaping IngestDerivative) {
        self.database = database
        self.byteResolver = byteResolver
        self.ingestDerivative = ingestDerivative
        self.conversions = SourceConversionRecorder(database: database)
    }

    /// The most recent recorded attempt for a version (what the source list shows), nil when never checked.
    public func latest(sourceVersionID: UUID) async throws -> ProtectedSourceAttempt? {
        try await database.query("""
            SELECT outcome, detail, derived_source_version_id, attempted_at FROM source_unlock_attempts
             WHERE source_version_id = ? ORDER BY attempted_at DESC, rowid DESC LIMIT 1;
            """, [.uuid(sourceVersionID)]).first.flatMap { r in
            guard let state = r.string(0).flatMap(ProtectedSourceState.init(rawValue:)) else { return nil }
            return ProtectedSourceAttempt(sourceVersionID: sourceVersionID, state: state, detail: r.string(1),
                                          derivedSourceVersionID: r.uuid(2), attemptedAt: r.date(3) ?? Date(timeIntervalSince1970: 0))
        }
    }

    /// Classify the exact version's bytes (no password) and record the outcome.
    @discardableResult
    public func probe(sourceVersionID: UUID, at date: Date = Date()) async -> ProtectedSourceAttempt {
        let resolved: SourceVersionByteResolver.Resolved
        do { resolved = try await byteResolver.resolve(sourceVersionID: sourceVersionID, at: date) }
        catch {
            KalsmritikoshLog.ingestion.error("protected-source probe \(sourceVersionID.uuidString, privacy: .public): bytes unavailable — \(String(describing: error), privacy: .public)")
            return await record(sourceVersionID, .unavailable, "the exact original could not be reopened", derived: nil, at: date)
        }
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
        let (state, detail) = ProtectedSourceProbe.classify(fileAt: resolved.snapshotURL, type: resolved.sourceType)
        return await record(sourceVersionID, state, detail, derived: nil, at: date)
    }

    /// Try `password` on ONE exact source version. On success an unprotected copy is ingested, linked to the
    /// original (derivedConversion) with the method recorded; repeating it finds the same copy. The password
    /// is never stored or logged; only the outcome is recorded.
    @discardableResult
    public func unlock(sourceVersionID: UUID, password: String, at date: Date = Date()) async -> ProtectedSourceAttempt {
        let resolved: SourceVersionByteResolver.Resolved
        do { resolved = try await byteResolver.resolve(sourceVersionID: sourceVersionID, at: date) }
        catch {
            KalsmritikoshLog.ingestion.error("unlock \(sourceVersionID.uuidString, privacy: .public): bytes unavailable — \(String(describing: error), privacy: .public)")
            return await record(sourceVersionID, .unavailable, "the exact original could not be reopened", derived: nil, at: date)
        }
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }

        let (probeState, probeDetail) = ProtectedSourceProbe.classify(fileAt: resolved.snapshotURL, type: resolved.sourceType)
        // A password cannot help a file that is not protected, is damaged, locked, or uses a scheme the app does
        // not decrypt — record that state instead of pretending to try.
        guard probeState == .passwordNeeded else {
            return await record(sourceVersionID, probeState, probeDetail, derived: nil, at: date)
        }
        guard !password.isEmpty else {
            return await record(sourceVersionID, .wrongPassword, "no password was entered", derived: nil, at: date)
        }
        let data: Data
        do { data = try Data(contentsOf: resolved.snapshotURL) }
        catch {
            let (state, detail) = ProtectedSourceProbe.readFailure(error)
            KalsmritikoshLog.ingestion.error("unlock \(sourceVersionID.uuidString, privacy: .public): snapshot read failed — \(error.localizedDescription, privacy: .public)")
            return await record(sourceVersionID, state, detail, derived: nil, at: date)
        }
        let opened = ProtectedSourceProbe.open(pdf: data, password: password)
        guard opened.state == .unlocked, let copy = opened.copy else {
            return await record(sourceVersionID, opened.state, opened.detail, derived: nil, at: date)
        }
        // One logical effect: the right password on an original that was already opened finds the copy made
        // then (a fresh copy's bytes can differ by their creation stamp, which would add a second version).
        if let existing = try? await existingCopy(of: sourceVersionID) {
            return await record(sourceVersionID, .unlocked, opened.detail, derived: existing, at: date)
        }

        // The opened copy: a temporary file whose bytes intake keeps in managed custody.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unlock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = (resolved.identityURL.lastPathComponent as NSString).deletingPathExtension
        let name = SafeFilename.sanitize("\(stem.isEmpty ? "document" : stem) (opened).pdf", fallback: "opened.pdf")
        let file = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try copy.write(to: file, options: .atomic)
            guard let derived = try await ingestDerivative(sourceVersionID, file, name) else {
                return await record(sourceVersionID, .unsupportedEncryption, "opened, but the readable copy could not be added", derived: nil, at: date)
            }
            try await conversions.record(derived: derived, original: sourceVersionID, method: Self.unlockMethod, detail: opened.detail, at: date)
            return await record(sourceVersionID, .unlocked, opened.detail, derived: derived, at: date)
        } catch {
            KalsmritikoshLog.ingestion.error("unlock \(sourceVersionID.uuidString, privacy: .public): the opened copy could not be added — \(error.localizedDescription, privacy: .public)")
            return await record(sourceVersionID, .unsupportedEncryption, "opened, but the readable copy could not be added", derived: nil, at: date)
        }
    }

    /// The readable copy already made from this original by a password unlock, when it still exists.
    private func existingCopy(of original: UUID) async throws -> UUID? {
        try await database.query("""
            SELECT c.source_version_id FROM source_conversions c
              JOIN source_versions v ON v.id = c.source_version_id
             WHERE c.original_source_version_id = ? AND c.method = ?
             ORDER BY c.recorded_at LIMIT 1;
            """, [.uuid(original), .text(Self.unlockMethod)]).first?.uuid(0)
    }

    /// SRC-05 / IN-09 — a re-verified, read-only copy of the EXACT original bytes for inspection in another app
    /// (the hash is checked by the resolver; a changed or missing original throws instead of opening something else).
    public func inspectOriginal(sourceVersionID: UUID, at date: Date = Date()) async throws -> URL {
        let resolved = try await byteResolver.resolve(sourceVersionID: sourceVersionID, at: date)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("original-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SafeFilename.sanitize(resolved.identityURL.lastPathComponent, fallback: "original")
        let out = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
        try FileManager.default.copyItem(at: resolved.snapshotURL, to: out)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: out.path)
        return out
    }

    /// Record one attempt's outcome. Never carries the password (callers pass only state and fixed details).
    private func record(_ svid: UUID, _ state: ProtectedSourceState, _ detail: String?, derived: UUID?, at date: Date) async -> ProtectedSourceAttempt {
        let attempt = ProtectedSourceAttempt(sourceVersionID: svid, state: state, detail: detail, derivedSourceVersionID: derived, attemptedAt: date)
        do {
            try await database.exec("""
                INSERT INTO source_unlock_attempts (id, source_version_id, outcome, detail, derived_source_version_id, attempted_at)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(svid), .text(state.rawValue), .optionalText(detail), derived.map { .uuid($0) } ?? .null, .date(date)])
        } catch {
            // The version may be gone (erased) — the attempt still returns its state to the caller.
            KalsmritikoshLog.ingestion.error("unlock attempt not recorded for \(svid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return attempt
    }
}
