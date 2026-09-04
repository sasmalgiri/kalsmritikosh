//
//  RawMatchBoundaryTests.swift
//  KalsmritikoshTests
//
//  GO2R U0-c — the structural boundary: `GenericFact.rawMatch` is extraction
//  provenance (the corrupt/original form C-7 preserved for the ingestion
//  train), never answer material. Verified live 2026-09-03: zero rawMatch
//  readers in Brain/ and Retrieval/, zero v2 stored values carrying label
//  tokens. This guard keeps it that way — a future renderer reaching for
//  rawMatch reds HERE with the law spelled out, not in a witness session.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("U0-c — rawMatch never reaches an answer surface")
struct RawMatchBoundaryTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("No answer-surface source file reads GenericFact.rawMatch")
    func noAnswerSurfaceReadsRawMatch() throws {
        let answerSurfaces = ["Kalsmritikosh/Brain", "Kalsmritikosh/Retrieval"]
        var offenders: [String] = []
        for dir in answerSurfaces {
            let root = repoRoot().appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = String(line).components(separatedBy: "//").first ?? ""
                    if code.contains("rawMatch") || code.contains("raw_match") {
                        offenders.append("\(url.lastPathComponent):\(n + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty,
                "rawMatch is extraction provenance, never answer material — offenders: \(offenders)")
    }
}
