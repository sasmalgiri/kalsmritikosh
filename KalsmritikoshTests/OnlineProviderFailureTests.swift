//
//  OnlineProviderFailureTests.swift
//  KalsmritikoshTests
//
//  K8 — every way an online provider call can fail is named honestly and answers nothing:
//  401/403, 429, 5xx, other 4xx (short message, no echo), refusals in each provider's own form,
//  malformed and empty replies, a reply that never comes (deadline), cancellation by the person,
//  and an outbound record that cannot be written (nothing is sent).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Online provider failures (K8)")
struct OnlineProviderFailureTests {

    static func reply(_ status: Int, _ json: String) -> OutboundHTTPResponse {
        OutboundHTTPResponse(status: status, body: Data(json.utf8))
    }

    @Test("HTTP status classes: key refused, rate-limited, provider error, other 4xx short")
    func statuses() {
        for kind in [OnlineProviderKind.anthropic, .openai, .gemini] {
            #expect(throws: OnlineRequestBuilder.ParseError.auth(401)) { try OnlineRequestBuilder.parse(kind: kind, response: Self.reply(401, "{}")) }
            #expect(throws: OnlineRequestBuilder.ParseError.auth(403)) { try OnlineRequestBuilder.parse(kind: kind, response: Self.reply(403, "{}")) }
            #expect(throws: OnlineRequestBuilder.ParseError.rateLimited) { try OnlineRequestBuilder.parse(kind: kind, response: Self.reply(429, "{}")) }
            #expect(throws: OnlineRequestBuilder.ParseError.server(503)) { try OnlineRequestBuilder.parse(kind: kind, response: Self.reply(503, "<html>")) }
        }
        let long = String(repeating: "x", count: 1000)
        do {
            _ = try OnlineRequestBuilder.parse(kind: .anthropic, response: Self.reply(400, #"{"error":{"message":"\#(long)"}}"#))
            Issue.record("a 400 was accepted")
        } catch let OnlineRequestBuilder.ParseError.http(code, message) {
            #expect(code == 400 && message.count == 200, "the provider's message is kept short")
        } catch { Issue.record("unexpected \(error)") }
        // The person reads what to do, not a raw code.
        #expect(OnlineRequestBuilder.ParseError.auth(401).errorDescription?.contains("Settings") == true)
    }

    @Test("Refusals in each provider's form are refusals, not answers")
    func refusals() {
        #expect(throws: OnlineRequestBuilder.ParseError.refused("refusal")) {
            try OnlineRequestBuilder.parse(kind: .anthropic, response: Self.reply(200, #"{"stop_reason":"refusal","content":[]}"#))
        }
        #expect(throws: OnlineRequestBuilder.ParseError.refused("I can't help with that.")) {
            try OnlineRequestBuilder.parse(kind: .openai, response: Self.reply(200, #"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."}}]}"#))
        }
        #expect(throws: OnlineRequestBuilder.ParseError.refused("content filter")) {
            try OnlineRequestBuilder.parse(kind: .openai, response: Self.reply(200, #"{"choices":[{"finish_reason":"content_filter","message":{"content":""}}]}"#))
        }
        #expect(throws: OnlineRequestBuilder.ParseError.refused("SAFETY")) {
            try OnlineRequestBuilder.parse(kind: .gemini, response: Self.reply(200, #"{"candidates":[{"finishReason":"SAFETY"}]}"#))
        }
        #expect(throws: OnlineRequestBuilder.ParseError.refused("OTHER")) {
            try OnlineRequestBuilder.parse(kind: .gemini, response: Self.reply(200, #"{"promptFeedback":{"blockReason":"OTHER"}}"#))
        }
    }

    @Test("Malformed or empty replies are unreadable; a good reply reads")
    func malformed() throws {
        for kind in [OnlineProviderKind.anthropic, .openai, .gemini] {
            #expect(throws: OnlineRequestBuilder.ParseError.unreadable) { try OnlineRequestBuilder.parse(kind: kind, response: Self.reply(200, "not json")) }
            #expect(throws: OnlineRequestBuilder.ParseError.unreadable) { try OnlineRequestBuilder.parse(kind: kind, response: Self.reply(200, "{}")) }
        }
        #expect(throws: OnlineRequestBuilder.ParseError.unreadable) {
            try OnlineRequestBuilder.parse(kind: .openai, response: Self.reply(200, #"{"choices":[{"message":{"content":""}}]}"#))
        }
        #expect(try OnlineRequestBuilder.parse(kind: .anthropic, response: Self.reply(200, #"{"content":[{"type":"text","text":"ok"}]}"#)) == "ok")
        #expect(try OnlineRequestBuilder.parse(kind: .openai, response: Self.reply(200, #"{"choices":[{"message":{"content":"ok"}}]}"#)) == "ok")
        #expect(try OnlineRequestBuilder.parse(kind: .gemini, response: Self.reply(200, #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#)) == "ok")
    }

    @Test("A reply that never comes times out; cancellation stops the wait; a prompt reply passes through")
    func deadlineAndCancel() async throws {
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await OnlineCloudProvider.withDeadline(.milliseconds(100)) { () async throws -> Int in
                try await Task.sleep(for: .seconds(30)); return 1
            }
        }
        let fast = try await OnlineCloudProvider.withDeadline(.seconds(5)) { 42 }
        #expect(fast == 42)
        let task = Task {
            try await OnlineCloudProvider.withDeadline(.seconds(30)) { () async throws -> Int in
                // Never returns on its own, like an XPC reply that is lost.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = Date()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 5, "cancellation does not wait for the deadline")
        if case .failure(let e) = result { #expect(e is CancellationError) } else { Issue.record("a cancelled wait succeeded") }
    }

    @Test("No outbound record, no send: a log that cannot be written refuses before anything leaves")
    func loggingFailureRefuses() async throws {
        let provider = OnlineCloudProvider(outboundLog: nil, knownNames: { [] })
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            try await provider.recordPending(.anthropic, "m", "text", 0)
        }
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("DROP TABLE outbound_log;")
        let broken = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] })
        await #expect(throws: (any Error).self) {
            try await broken.recordPending(.anthropic, "m", "text", 0)
        }
        // A working log records the attempt without counting its bytes as sent.
        let ok = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let log = OutboundLogRepository(database: ok)
        try await OnlineCloudProvider(outboundLog: log, knownNames: { [] }).recordPending(.anthropic, "m", "text", 0)
        #expect(try await log.bytesSentToday() == 0)
        #expect(try await log.recent().first?.outcome == "sending")
    }

    @Test("T1: a change of mode, provider, key, model or document terms while the consent dialog is open voids the consent")
    func changeDuringConsent() {
        let before = SendSettings(cloudAllowed: true, kind: .anthropic, model: "m", keyDigest: "k1", documentsEligible: true)
        #expect(SendSettings.changed(from: before, to: before, carriesDocuments: true) == nil)
        func with(_ f: (inout (Bool, OnlineProviderKind, String, String?, Bool)) -> Void) -> SendSettings {
            var v = (true, OnlineProviderKind.anthropic, "m", Optional("k1"), true); f(&v)
            return SendSettings(cloudAllowed: v.0, kind: v.1, model: v.2, keyDigest: v.3, documentsEligible: v.4)
        }
        #expect(SendSettings.changed(from: before, to: with { $0.0 = false }, carriesDocuments: false) == "Online mode")
        #expect(SendSettings.changed(from: before, to: with { $0.1 = .openai }, carriesDocuments: false) == "the provider")
        #expect(SendSettings.changed(from: before, to: with { $0.3 = "k2" }, carriesDocuments: false) == "the API key")
        #expect(SendSettings.changed(from: before, to: with { $0.3 = nil }, carriesDocuments: false) == "the API key")
        #expect(SendSettings.changed(from: before, to: with { $0.2 = "other" }, carriesDocuments: false) == "the model")
        #expect(SendSettings.changed(from: before, to: with { $0.4 = false }, carriesDocuments: true) == "the provider's document terms confirmation")
        #expect(SendSettings.changed(from: before, to: with { $0.4 = false }, carriesDocuments: false) == nil, "a question-only send does not need document terms")
        #expect(OnlineCloudProvider.OnlineError.changedDuringConsent("Online mode").errorDescription?.contains("Not sent") == true)
    }
}
