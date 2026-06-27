//
//  AudioLoader.swift
//  Kalsmritikosh
//
//  Apple Speech transcription at ingest. WhisperKit can swap in later as
//  another SpeechTranscriber implementation behind the same protocol.
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct AudioLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.mp3, .wav, .m4a, .aac]
    public let primaryLane: ResourceLane = .neuralEngine // SFSpeechRecognizer
    private let transcriber: any AudioTranscribing

    public nonisolated init(transcriber: any AudioTranscribing = SpeechTranscriber()) {
        self.transcriber = transcriber
    }

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string(transcriber.engineID))
        ]
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        if let duration { meta["durationSeconds"] = AnyCodable(.double(duration)) }
        #endif

        var content = ""
        var confidence = Confidence.low
        do {
            content = try await transcriber.transcribe(audioAt: url)
            confidence = content.isEmpty ? .low : .high
        } catch {
            meta["asrError"] = AnyCodable(.string("\(error)"))
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content.isEmpty ? "[audio: transcription unavailable]" : content,
            metadata: meta,
            confidence: confidence
        )
    }
}
