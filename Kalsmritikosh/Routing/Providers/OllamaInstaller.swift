//
//  OllamaInstaller.swift
//  Kalsmritikosh
//
//  In-app `ollama pull` driver. Wraps Ollama's `/api/pull` streaming
//  endpoint so the user can click "Download recommended model" from
//  the Settings panel and watch progress. Honors the user's stated
//  consent — the actor doesn't kick off a download until the UI
//  calls `pull(modelTag:)`.
//
//  Requires the Ollama daemon to be reachable; this is the LAST
//  step of the onboarding flow (install Ollama → pull a model →
//  start using it).
//

import Foundation
import OSLog

public actor OllamaInstaller {

    public struct Progress: Sendable, Equatable {
        public let status: String          // human-readable status from Ollama
        public let completedBytes: Int64
        public let totalBytes: Int64
        public let isComplete: Bool

        public init(status: String, completedBytes: Int64, totalBytes: Int64, isComplete: Bool) {
            self.status = status
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
            self.isComplete = isComplete
        }

        public var fractionComplete: Double {
            totalBytes > 0 ? min(1.0, Double(completedBytes) / Double(totalBytes)) : 0
        }
    }

    public enum InstallError: Error, Sendable {
        case ollamaUnreachable
        case httpError(Int)
        case streamFailed(String)
    }

    private let baseURL: URL

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    /// Begin pulling `modelTag` from the Ollama registry. Returns an
    /// AsyncStream that emits Progress updates as the download
    /// proceeds; the terminal value has `isComplete == true`.
    ///
    /// Caller cancels by cancelling the consuming task — Ollama's
    /// /api/pull will eventually notice the client went away.
    public func pull(modelTag: String) -> AsyncStream<Result<Progress, InstallError>> {
        let url = baseURL.appendingPathComponent("api/pull")
        let body: [String: Any] = ["name": modelTag, "stream": true]
        let baseURL = self.baseURL

        return AsyncStream { continuation in
            let task = Task<Void, Never> {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 3_600  // big models take a while

                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 3_600
                config.timeoutIntervalForResource = 86_400  // 1 day cap
                let session = URLSession(configuration: config)

                let bytesStream: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytesStream, response) = try await session.bytes(for: request)
                } catch {
                    KalsmritikoshLog.routing.error("OllamaInstaller: connect to \(baseURL.absoluteString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.failure(.ollamaUnreachable))
                    continuation.finish()
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    continuation.yield(.failure(.httpError(http.statusCode)))
                    continuation.finish()
                    return
                }

                // Ollama streams newline-delimited JSON objects.
                do {
                    for try await line in bytesStream.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8),
                              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        let status = (obj["status"] as? String) ?? ""
                        let total = (obj["total"] as? NSNumber)?.int64Value ?? 0
                        let completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
                        // Ollama emits "success" once the model is
                        // fully pulled and verified.
                        let done = status.lowercased() == "success"
                            || (total > 0 && completed >= total && status.lowercased().contains("success"))

                        continuation.yield(.success(Progress(
                            status: status,
                            completedBytes: completed,
                            totalBytes: total,
                            isComplete: done
                        )))

                        if done {
                            continuation.finish()
                            return
                        }
                    }
                    // Stream ended without an explicit "success" —
                    // assume complete.
                    continuation.yield(.success(Progress(
                        status: "complete",
                        completedBytes: 0,
                        totalBytes: 0,
                        isComplete: true
                    )))
                    continuation.finish()
                } catch {
                    KalsmritikoshLog.routing.error("OllamaInstaller: stream failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.failure(.streamFailed("\(error)")))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
