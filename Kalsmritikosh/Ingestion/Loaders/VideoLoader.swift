//
//  VideoLoader.swift
//  Kalsmritikosh
//
//  Extracts the audio track, sends it to the SpeechTranscriber, persists
//  the transcript as the KnowledgeObject content. Falls back to metadata
//  only if extraction fails.
//

import Foundation
import OSLog
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct VideoLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.mp4, .mov]
    public let primaryLane: ResourceLane = .neuralEngine // SFSpeechRecognizer over the audio track
    private let transcriber: any AudioTranscribing

    public nonisolated init(transcriber: any AudioTranscribing) {
        self.transcriber = transcriber
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("video-asr:\(transcriber.engineID)"))
        ]
        var content = ""
        var confidence = Confidence.low

        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration).seconds {
            meta["durationSeconds"] = AnyCodable(.double(duration))
        }
        if let audioURL = try? await exportAudio(from: asset, original: url) {
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                // Prefer timecoded segments so a cited answer can point at the
                // exact moment in the recording; fall back to the flat transcript
                // when the engine can't produce timings.
                let segments = try await transcriber.transcribeSegments(audioAt: audioURL)
                if segments.isEmpty {
                    content = try await transcriber.transcribe(audioAt: audioURL)
                } else {
                    content = segments.timecodedTranscript()
                    meta["transcriptTimecoded"] = AnyCodable(.bool(true))
                    meta["segmentCount"] = AnyCodable(.int(Int64(segments.count)))
                }
                confidence = content.isEmpty ? .low : .high
            } catch {
                meta["asrError"] = AnyCodable(.string("\(error)"))
            }
        }
        #endif

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content.isEmpty ? "[video: transcription unavailable]" : content,
            metadata: meta,
            confidence: confidence
        )
    }

    #if canImport(AVFoundation)
    private func exportAudio(from asset: AVURLAsset, original: URL) async throws -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsmritikosh-asr-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return nil }
        // macOS 15+ async throwing export API (replaces the deprecated
        // outputURL/outputFileType + export() + status dance).
        do {
            try await export.export(to: outputURL, as: .m4a)
            return outputURL
        } catch {
            KalsmritikoshLog.knowledge.error("VideoLoader: audio export failed for \(original.lastPathComponent, privacy: .private) — \(String(describing: error), privacy: .public)")
            return nil
        }
    }
    #endif
}
