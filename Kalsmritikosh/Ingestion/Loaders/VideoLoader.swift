//
//  VideoLoader.swift
//  Kalsmritikosh
//
//  Extracts the audio track, sends it to the SpeechTranscriber, persists
//  the transcript as the KnowledgeObject content. Falls back to metadata
//  only if extraction fails.
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct VideoLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.mp4, .mov]
    private let transcriber: SpeechTranscriber

    public init(transcriber: SpeechTranscriber = SpeechTranscriber()) {
        self.transcriber = transcriber
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("video-asr"))
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
                content = try await transcriber.transcribe(audioAt: audioURL)
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
            .appendingPathComponent("atlas-asr-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return nil }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        await export.export()
        return export.status == .completed ? outputURL : nil
    }
    #endif
}
