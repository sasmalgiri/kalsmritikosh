//
//  OnlineFallbackTranscriber.swift
//  Kalsmritikosh
//
//  Unified path IN-23 (owner 2026-11-22) — not tested yet. On-device speech first; when it fails or hears
//  nothing, the recording may be transcribed by the person's AI plan through the Online provider — ONLY in
//  Online mode, and every send goes through the provider's own preview and consent (a recording is always
//  previewed: it cannot be masked). This type makes no network call: `online` is a closure the app injects
//  (AppState → Routing/Providers/Online), nil when Online transcription is not available now.
//
//  The online transcript is marked as such in the text, so it is never mistaken for the on-device one.
//  WhisperKit stays compiled out (it needs a package — a new dependency); OpenAIWhisperTranscriber is not
//  wired (it would call the network from Ingestion).
//

import Foundation
import os

public actor OnlineFallbackTranscriber: AudioTranscribing {
    public nonisolated let engineID: String
    private let primary: any AudioTranscribing
    /// The online transcription for a recording, or nil when it is not available now (Online off, no AI plan,
    /// the person declined). Throws when the send failed.
    private let online: @Sendable (URL) async throws -> String?
    /// Recordings the on-device engine already failed on in this session (no second on-device attempt).
    private var primaryFailed = Set<URL>()

    public nonisolated static let marker = "[Transcribed online by your AI plan, with your consent — an AI transcript; check a quote you rely on against the recording.]"

    public init(primary: any AudioTranscribing, online: @escaping @Sendable (URL) async throws -> String?) {
        self.primary = primary
        self.online = online
        self.engineID = primary.engineID + "+online-fallback"
    }

    public func transcribeSegments(audioAt url: URL) async throws -> [ASRSegment] {
        do {
            let segments = try await primary.transcribeSegments(audioAt: url)
            if segments.isEmpty { primaryFailed.insert(url) }   // the flat pass decides (and may go online)
            return segments
        } catch {
            KalsmritikoshLog.ingestion.info("transcription: on-device segments failed (\(error.localizedDescription, privacy: .public)); trying the fallback")
            primaryFailed.insert(url)
            return []
        }
    }

    public func transcribe(audioAt url: URL) async throws -> String {
        var primaryError: Error?
        // Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. One AI: inside an import the person
        // allowed AI for, the recording goes to the online AI first; on-device speech is the fallback.
        if ImportAIPermission.allowsAIHere {
            do {
                if let text = try await online(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return Self.marker + "\n" + text
                }
            } catch {
                KalsmritikoshLog.ingestion.error("transcription: online (first) failed: \(error.localizedDescription, privacy: .public); on-device speech instead")
            }
            do { return try await primary.transcribe(audioAt: url) } catch {
                KalsmritikoshLog.ingestion.error("transcription: on-device after online failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        if !primaryFailed.contains(url) {
            do {
                let text = try await primary.transcribe(audioAt: url)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            } catch {
                KalsmritikoshLog.ingestion.info("transcription: on-device failed (\(error.localizedDescription, privacy: .public)); trying the fallback")
                primaryError = error
            }
        }
        primaryFailed.remove(url)
        do {
            if let text = try await online(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self.marker + "\n" + text
            }
        } catch {
            KalsmritikoshLog.ingestion.error("transcription: online fallback failed: \(error.localizedDescription, privacy: .public)")
            if primaryError == nil { primaryError = error }
        }
        if let primaryError { throw primaryError }
        return ""
    }
}
