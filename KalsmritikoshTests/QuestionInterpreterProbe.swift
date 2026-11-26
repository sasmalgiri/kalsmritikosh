//
//  QuestionInterpreterProbe.swift
//  KalsmritikoshTests
//
//  Owner-run, never in CI: does nothing unless INTERPRETER_PROBE_DIR is set (pass it as
//  TEST_RUNNER_INTERPRETER_PROBE_DIR). For every question of a case bench set it asks the phrase
//  rules and the on-device interpreter which field the question asks for, among the fields that
//  case's ledger actually held (read from the bench results), and writes one JSON line per
//  question to INTERPRETER_PROBE_OUT. Scoring is done outside (expected field per question kind).
//

import Testing
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kalsmritikosh

@Suite("Question interpreter probe")
struct QuestionInterpreterProbe {

    static let env = ProcessInfo.processInfo.environment

    @Test("Interpret every question of a bench set")
    func probe() async throws {
        guard let root = Self.env["INTERPRETER_PROBE_DIR"], let resultsDir = Self.env["INTERPRETER_PROBE_RESULTS"],
              let outPath = Self.env["INTERPRETER_PROBE_OUT"] else { return }
        let fm = FileManager.default
        // Fields each case's ledger held, from the bench results ("field=value").
        var fieldsByCase: [String: Set<String>] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: resultsDir)) ?? [] where name.hasSuffix(".jsonl") {
            let text = (try? String(contentsOfFile: resultsDir + "/" + name, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let c = obj["case"] as? String, let facts = obj["facts"] as? [String] else { continue }
                fieldsByCase[c, default: []].formUnion(facts.compactMap { $0.split(separator: "=").first.map { String($0).lowercased() } })
            }
        }
        let interpreter = FoundationModelsQuestionInterpreter()
        var health = "unknown"
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do { health = "ok: " + (try await LanguageModelSession().respond(to: "Say OK.").content) }
            catch { health = "error: \(error)" }
        }
        #endif
        let limit = Int(Self.env["INTERPRETER_PROBE_LIMIT"] ?? "") ?? .max
        var out = ""
        var count = 0
        let enumerator = fm.enumerator(atPath: root)
        while let path = enumerator?.nextObject() as? String {
            guard path.hasSuffix("truth.jsonl"), count < limit else { continue }
            let text = (try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where count < limit {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let c = obj["case"] as? String, let source = obj["source"] as? String,
                      let questions = obj["questions"] as? [[String: Any]] else { continue }
                let fields = Array(fieldsByCase[c] ?? []).sorted()
                for q in questions where count < limit {
                    guard let id = q["id"] as? String, let text = q["q"] as? String else { continue }
                    let rules = SlotFieldResolver.resolve(in: text, knownFields: Set(fields)).first?.fieldID
                    let started = Date()
                    let model = await interpreter.field(askedBy: text, among: fields)
                    let seconds = Date().timeIntervalSince(started)
                    let row: [String: Any] = ["case": c, "source": source, "id": id, "q": text, "fields": fields,
                                              "rules": rules ?? NSNull(), "model": model ?? NSNull(), "seconds": seconds]
                    if let data = try? JSONSerialization.data(withJSONObject: row), let s = String(data: data, encoding: .utf8) {
                        out += s + "\n"
                    }
                    count += 1
                }
            }
        }
        try ("{\"health\": \(String(reflecting: health))}\n" + out).write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}
