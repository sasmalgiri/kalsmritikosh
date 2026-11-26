//
//  CaseFactAttestationBoundaryTests.swift
//  KalsmritikoshTests
//
//  N3 (2026-11-03) — the human-only rule. A person's "verified" mark on a chronology entry is set or
//  withdrawn only by a person pressing the button on the case file screen. No job, import, AI,
//  batch or service path may call `markVerified(` or `withdraw(entryID:`, and nothing outside the
//  case file repository writes `case_fact_attestations`. Source-scanning, in the style of
//  RawMatchBoundaryTests: a future caller reds HERE with the rule spelled out.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("N3 — only a person sets or withdraws the verified mark")
struct CaseFactAttestationBoundaryTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every Swift file under Kalsmritikosh/ with its repo-relative path and comment-stripped lines.
    private func productSources() -> [(path: String, lines: [String])] {
        let root = repoRoot().appendingPathComponent("Kalsmritikosh")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, [String])] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let rel = String(url.path.dropFirst(repoRoot().path.count + 1))
            out.append((rel, text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).components(separatedBy: "//").first ?? "" }))
        }
        return out
    }

    @Test("markVerified( and withdraw(entryID: are called only from UI/ (the definitions excepted)")
    func onlyTheUICallsTheMark() throws {
        let sources = productSources()
        #expect(sources.count > 100, "the product sources must be readable for this scan to mean anything (read \(sources.count))")
        let definitions = "Kalsmritikosh/Investigate/CaseFile/CaseFileRepository.swift"
        var offenders: [String] = []
        var uiCallers: [String] = []
        for (path, lines) in sources {
            for (n, code) in lines.enumerated() {
                let calls = code.contains("markVerified(") || code.contains("withdraw(entryID:")
                guard calls else { continue }
                let isDefinition = path == definitions && code.contains("func ")
                if isDefinition { continue }
                if path.hasPrefix("Kalsmritikosh/UI/") { uiCallers.append("\(path):\(n + 1)") } else { offenders.append("\(path):\(n + 1)") }
            }
        }
        #expect(offenders.isEmpty, "A person's verified mark is set only by a person pressing the button in UI/ — offenders: \(offenders)")
        #expect(uiCallers.count >= 2, "the case file screen's Mark verified… / Withdraw… actions are the callers (found \(uiCallers))")
    }

    @Test("Only the case file repository writes case_fact_attestations")
    func onlyTheRepositoryWritesTheTable() throws {
        var offenders: [String] = []
        for (path, lines) in productSources() where !path.hasSuffix("CaseFileRepository.swift") && !path.hasSuffix("SchemaMigrations.swift") {
            for (n, code) in lines.enumerated() {
                let upper = code.uppercased()
                if upper.contains("CASE_FACT_ATTESTATIONS"), upper.contains("INSERT") || upper.contains("UPDATE") || upper.contains("DELETE") {
                    offenders.append("\(path):\(n + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "case_fact_attestations is written only by markVerified / withdraw — offenders: \(offenders)")
    }
}
