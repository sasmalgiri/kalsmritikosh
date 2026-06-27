//
//  OpenAIWhisperTranscriber.swift
//  Kalsmritikosh
//
//  Cloud audio transcription via OpenAI's /v1/audio/transcriptions
//  endpoint. Uses the same wire format as Whisper Large-v3, which
//  also runs on the OpenAI Whisper API ("whisper-1"). Supports 99
//  languages with sub-5% English WER and excellent multilingual
//  coverage — useful when Apple Speech mid-tiers on accented or
//  non-English audio.
//
//  Drops into the AudioTranscribing protocol. AudioLoader /
//  VideoLoader pick it up via constructor injection:
//      AudioLoader(transcriber: OpenAIWhisperTranscriber(apiKey: key))
//
//  Privacy: audio is uploaded to OpenAI. PrivacyGate callers must
//  verify the user has opted into cloud routing.
//

import Foundation
import OSLog

public actor OpenAIWhisperTranscriber: AudioTranscribing {
    public nonisolated let engineID = "openai-whisper-1"

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let language: String?
    private let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        model: String = "whisper-1",
        language: String? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.language = language
        let config = URLSessionConfiguration.default
        // Long audio = long transcription. 10-minute upload + 5-min
        // inference fits in this budget for typical podcast / meeting
        // recordings.
        config.timeoutIntervalForRequest = 1_800
        config.timeoutIntervalForResource = 1_800
        self.session = URLSession(configuration: config)
    }

    public func transcribe(audioAt url: URL) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
        let boundary = "----AtlasBoundary\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body: model field, optional language field,
        // file field.
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", model)
        if let lang = language { appendField("language", lang) }
        appendField("response_format", "text")

        // File part
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            throw NSError(
                domain: "atlas.asr.openai-whisper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Read audio file failed: \(error)"]
            )
        }
        let mimeType: String = {
            switch url.pathExtension.lowercased() {
            case "mp3": return "audio/mpeg"
            case "m4a": return "audio/mp4"
            case "wav": return "audio/wav"
            case "aac": return "audio/aac"
            default: return "audio/mpeg"
            }
        }()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NSError(
                domain: "atlas.asr.openai-whisper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI transcription HTTP call failed: \(error)"]
            )
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            AtlasLog.knowledge.error("OpenAIWhisperTranscriber: HTTP \(http.statusCode, privacy: .public): \(bodyStr.prefix(400), privacy: .public)")
            throw NSError(
                domain: "atlas.asr.openai-whisper",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr.prefix(200))"]
            )
        }
        // response_format=text returns the transcript as the
        // response body directly (not JSON).
        return String(data: data, encoding: .utf8) ?? ""
    }
}
