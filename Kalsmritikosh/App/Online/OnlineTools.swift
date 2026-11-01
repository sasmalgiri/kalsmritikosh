//
//  OnlineTools.swift
//  Kalsmritikosh
//
//  A8–A11 — the Online tools as the person uses them: exchange rate at a date, sanctions check,
//  company registry, court records (A8/A10, through OnlineLookupClient), web capture as evidence (A9)
//  and transcription of a recording with speakers (A11, through the Online AI). Captures and
//  transcriptions become documents in the archive with a record of where and when they came from;
//  lookups are shown with their source and time, for the person to cite or ignore.
//

import Foundation
import os

nonisolated enum OnlineToolDocuments {
    /// The capture record kept beside the captured page: what was asked for, when, what came back.
    static func captureRecord(url: String, status: Int, bytes: Int, sha256: String, at date: Date, savedAs: String) -> String {
        """
        WEB CAPTURE RECORD
        Address requested: \(url)
        Captured: \(ISO8601DateFormatter().string(from: date))
        HTTP status: \(status)
        Bytes received: \(bytes)
        SHA-256 of the saved page: \(sha256)
        Saved as: \(savedAs)
        The page was fetched by this Mac's network helper exactly as the site returned it, without running its scripts or loading its images. Sites can show different content to different visitors and change it later; this record shows what was received at the time above.

        """
    }

    static func transcriptDocument(original: String, originalSHA256: String, provider: String, model: String,
                                   at date: Date, body: String) -> String {
        """
        AI TRANSCRIPTION OF A RECORDING — NOT THE RECORDING
        Recording: \(original)
        Recording SHA-256: \(originalSHA256)
        Transcribed by: \(provider), model \(model), on \(ISO8601DateFormatter().string(from: date))
        Speaker labels (Speaker 1, Speaker 2, …) are the model's guesses of who is speaking, not identifications. Check every quotation and timecode against the recording before relying on it. [inaudible] marks what the model could not hear.

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    static func safeName(_ s: String) -> String {
        String(s.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }.prefix(80))
    }

    static let audioTypes: [String: String] = ["m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav", "aac": "audio/aac",
                                                "aiff": "audio/aiff", "aif": "audio/aiff", "flac": "audio/flac", "ogg": "audio/ogg",
                                                "mp4": "video/mp4", "mov": "video/quicktime"]
    /// AI Included and Gemini accept recordings up to this size inline.
    static let maxRecordingBytes = 18 * 1024 * 1024
}

extension AppState {

    /// The client for public-record lookups and captures (Online mode only).
    var lookupClient: OnlineLookupClient {
        let folder = try? ScanRescue.folder().deletingLastPathComponent().appendingPathComponent("Public lists", isDirectory: true)
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return OnlineLookupClient(outboundLog: outboundLog, listFolder: folder)
    }

    /// A9 — capture a web page as evidence: the page exactly as received plus its capture record, both
    /// added to the archive.
    func captureWebPage(_ address: String) async -> String {
        guard PurchaseCenter.shared.allowPaidAction("add documents", importing: true) else { return PaidUse.refusal("add documents", importing: true)?.reason ?? "A subscription is needed." }
        guard let ingest else { return "The ledger is not open yet." }
        do {
            let c = try await lookupClient.capture(address)
            let host = URL(string: c.url)?.host ?? "page"
            let stamp = ISO8601DateFormatter().string(from: c.capturedAt).replacingOccurrences(of: ":", with: "-")
            let folder = try ScanRescue.folder().deletingLastPathComponent().appendingPathComponent("Web captures", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = OnlineToolDocuments.safeName("\(host) \(stamp)")
            let page = folder.appendingPathComponent("\(base) — web capture.html")
            let record = folder.appendingPathComponent("\(base) — capture record.txt")
            try c.body.write(to: page, options: .atomic)
            try OnlineToolDocuments.captureRecord(url: c.url, status: c.status, bytes: c.body.count, sha256: c.sha256,
                                                  at: c.capturedAt, savedAs: page.lastPathComponent)
                .write(to: record, atomically: true, encoding: .utf8)
            _ = try await ingest.ingest(fileAt: record, intent: .fullAvailable)
            let r = try await ingest.ingest(fileAt: page, intent: .fullAvailable)
            await runPostIngestChecksSinceLast()
            return "Captured \(c.url) (\(c.body.count) bytes, SHA-256 \(c.sha256.prefix(12))…): \(r.chunkCount) passage\(r.chunkCount == 1 ? "" : "s"), with its capture record."
        } catch {
            KalsmritikoshLog.app.error("Web capture failed: \(error.localizedDescription, privacy: .public)")
            return "Not captured: \(error.localizedDescription)"
        }
    }

    /// A11 — transcribe a recording the person chose, with speaker labels and timecodes, and add the
    /// transcript as its own marked document.
    func transcribeRecording(_ url: URL) async -> String {
        guard PurchaseCenter.shared.allowPaidAction("add documents", importing: true) else { return PaidUse.refusal("add documents", importing: true)?.reason ?? "A subscription is needed." }
        guard let ingest else { return "The ledger is not open yet." }
        guard OnlineSettings.cloudAllowed else {
            return AIRegion.current.explanation ?? "Transcription needs Online mode with AI Included or your own Gemini key (Settings ▸ Online)."
        }
        guard let provider = onlineProvider, await provider.isAvailable() else { return OnlineCloudProvider.OnlineError.notAvailable.localizedDescription }
        guard let type = OnlineToolDocuments.audioTypes[url.pathExtension.lowercased()] else {
            return "\(url.lastPathComponent) is not a recording this can send (m4a, mp3, wav, aac, aiff, flac, ogg, mp4, mov)."
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= OnlineToolDocuments.maxRecordingBytes else {
                return "\(url.lastPathComponent) is \(data.count / 1_048_576) MB; recordings up to 18 MB can be sent. Split it and transcribe the parts."
            }
            let text = try await provider.transcribeRecording(OutboundImage(mediaType: type, data: data, label: url.lastPathComponent),
                                                              fileName: url.lastPathComponent)
            let s = OnlineSnapshot.current()
            let doc = OnlineToolDocuments.transcriptDocument(original: url.lastPathComponent, originalSHA256: ScanRescue.sha256(of: url),
                                                             provider: s.kind.displayName, model: s.kind == .included ? "Gemini (AI Included)" : s.model,
                                                             at: Date(), body: text)
            let out = try ScanRescue.folder().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) — AI transcript.txt")
            try doc.write(to: out, atomically: true, encoding: .utf8)
            let r = try await ingest.ingest(fileAt: out, intent: .fullAvailable)
            await runPostIngestChecksSinceLast()
            return "Added “\(out.lastPathComponent)”: \(r.chunkCount) passage\(r.chunkCount == 1 ? "" : "s"), marked as an AI transcript of the recording."
        } catch is CancellationError {
            return "Stopped. Nothing was added."
        } catch {
            KalsmritikoshLog.app.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            return "Not transcribed: \(error.localizedDescription)"
        }
    }
}
