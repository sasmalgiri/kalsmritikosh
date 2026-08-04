//
//  InvestigationCaseBoundaryTests.swift
//  KalsmritikoshTests
//
//  INV-01-A architecture guards. The Investigator case is a LENS over the one canonical engine: it may
//  define its OWN persona state (the investigation_case* tables) but must REFERENCE canonical identities
//  by id and fork none of them. These guards prove: no model names; the persona neither redefines nor
//  writes canonical evidence/Claim/Deadline/DeadlineCandidate/SensitiveScope authorities; the confirmed-
//  deadline binding is validated against the canonical `deadlines` table (possible ≠ confirmed) and never
//  fabricates one; and — as a pure value check — the in-scope source set is the hard authorization
//  boundary. Source scanning + value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-A — investigation-case architecture guards")
struct InvestigationCaseBoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    private let rels = [
        "Kalsmritikosh/Personas/Investigator/InvestigationCase.swift",
        "Kalsmritikosh/Personas/Investigator/InvestigationCaseRepository.swift"]
    private func files() -> [(String, String)] { rels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }
    private func allCode() -> String { files().map { codeOnly($0.1) }.joined(separator: "\n") }

    @Test("The investigation-case subsystem is present")
    func present() { #expect(files().count == 2) }

    @Test("No model names anywhere in the investigation-case subsystem")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama"]
        for (name, text) in files() {
            let lower = codeOnly(text).lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("The persona redefines no canonical authority type")
    func forksNoCanonicalType() {
        let all = allCode()
        for banned in ["struct Claim", "struct EvidenceBlock", "struct SensitiveScope", "struct DeadlineCandidate ",
                       "struct Deadline ", "enum Deadline ", "class ProfessionalTask", "struct WorkflowRun"] {
            #expect(!all.contains(banned), "persona forks a canonical type: \(banned)")
        }
    }

    @Test("The persona never writes canonical evidence tables — it only references them")
    func writesNoCanonicalTable() {
        let all = allCode()
        // It defines its OWN persona tables, but must not create or mutate canonical evidence/deadline tables.
        for banned in ["CREATE TABLE deadlines", "CREATE TABLE deadline_candidates", "CREATE TABLE workspaces",
                       "INSERT INTO deadlines", "UPDATE deadlines", "DELETE FROM deadlines",
                       "INSERT INTO deadline_candidates", "INSERT INTO workspaces"] {
            #expect(!all.contains(banned), "persona writes canonical table: \(banned)")
        }
    }

    @Test("Binding a confirmed deadline is validated against the canonical confirmed table (possible ≠ confirmed)")
    func confirmedDeadlineValidatedAgainstCanonical() {
        let repo = files().first { $0.0.hasSuffix("InvestigationCaseRepository.swift") }.map { codeOnly($0.1) } ?? ""
        #expect(repo.contains("FROM deadlines"))                 // validates existence in the confirmed table
        #expect(repo.contains("deadlineNotConfirmed"))           // refuses anything not confirmed
        #expect(!repo.contains("FROM deadline_candidates"))      // a candidate is never accepted as authoritative
    }

    @Test("The closed status / source-kind / action vocabularies are exactly as specified")
    func closedVocabularies() {
        #expect(Set(InvestigationCaseStatus.allCases.map(\.rawValue)) == ["open", "scopeConfirmed", "closed"])
        #expect(Set(InvestigationSourceKind.allCases.map(\.rawValue)) == ["logicalSource", "sourceVersion", "workspaceSource"])
        #expect(Set(InvestigationCaseEventAction.allCases.map(\.rawValue)) ==
                ["created", "scopeSet", "sourceIncluded", "sourceExcluded", "scopeConfirmed", "deadlineBound", "reopened"])
    }

    @Test("authorizedSourceRefs is a pure boundary: only in-scope refs, sorted, excluding excluded/unlisted")
    func authorizedIsPureBoundary() {
        let caseID = UUID()
        func src(_ ref: String, _ inScope: Bool) -> InvestigationScopeSource {
            InvestigationScopeSource(id: UUID(), caseID: caseID, sourceRef: ref, sourceKind: .logicalSource,
                                     inScope: inScope, note: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        }
        let header = InvestigationCase(id: caseID, workspaceID: UUID(), title: "T", purpose: nil, scopeStatement: nil,
                                       outOfScopeStatement: nil, timeWindowStart: nil, timeWindowEnd: nil, status: .open,
                                       confirmedDeadlineID: nil, possibleDeadlineNote: nil, revision: 1, actor: "u",
                                       createdAt: Date(timeIntervalSinceReferenceDate: 0), updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        let record = InvestigationCaseRecord(caseHeader: header,
                                             sources: [src("z-in", true), src("a-in", true), src("m-out", false)], events: [])
        #expect(record.authorizedSourceRefs == ["a-in", "z-in"])   // sorted, out-of-scope dropped
        #expect(record.excludedSourceRefs == ["m-out"])
        #expect(record.isAuthorized("a-in"))
        #expect(!record.isAuthorized("m-out"))
        #expect(!record.isAuthorized("never-listed"))
    }
}
