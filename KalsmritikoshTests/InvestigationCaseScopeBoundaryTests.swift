//
//  InvestigationCaseScopeBoundaryTests.swift
//  KalsmritikoshTests
//
//  INV-01-B2 architecture guards (§15). Prove case-scope enforcement COMPOSES the shared retrieval stack
//  rather than forking it: there is no Investigator-specific retriever; the scope filter is a pure
//  deterministic policy that never re-ranks; it forks neither the source-identity model nor SensitiveScope;
//  it is fail-closed with no workspace-wide fallback; and the Investigator side only RESOLVES a case into
//  the shared scope value. Source scanning + type/value checks — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-B2 — case-scope architecture guards")
struct InvestigationCaseScopeBoundaryTests {

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
    private let policyRel = "Kalsmritikosh/Retrieval/SourceScopeRetrievalPolicy.swift"
    private let retrieverRel = "Kalsmritikosh/Retrieval/SourceScopedRetriever.swift"
    private let resolverRel = "Kalsmritikosh/Personas/Investigator/CaseRetrievalScopeResolver.swift"

    @Test("All three case-scope files are present")
    func present() {
        for rel in [policyRel, retrieverRel, resolverRel] { #expect((try? read(rel)) != nil, "\(rel) missing") }
    }

    @Test("No model names anywhere in the case-scope subsystem")
    func noModelNames() throws {
        let models = ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"]
        for rel in [policyRel, retrieverRel, resolverRel] {
            let lower = codeOnly(try read(rel)).lowercased()
            for m in models { #expect(!lower.contains(m), "\(rel) names model \(m)") }
        }
    }

    @Test("There is no Investigator-specific retriever — the decorator wraps the shared Retriever protocol")
    func noForkedRetriever() throws {
        let retriever = codeOnly(try read(retrieverRel))
        #expect(retriever.contains("SourceScopedRetriever: Retriever"))   // conforms to the shared protocol
        #expect(retriever.contains("base.retrieve"))                       // delegates to the wrapped retriever
        #expect(!retriever.contains("class HybridRetriever") && !retriever.contains("struct HybridRetriever"))
        // The resolver is not a retriever.
        let resolver = codeOnly(try read(resolverRel))
        #expect(!resolver.contains(": Retriever"))
    }

    @Test("The scope filter is pure and never re-ranks or re-scores")
    func noReRanking() throws {
        let policy = codeOnly(try read(policyRel))
        for banned in [".sorted(", ".sort(", ".shuffled(", "EvidenceRanker", "Reranker", "score ="] {
            #expect(!policy.contains(banned), "scope policy re-ranks: \(banned)")
        }
        // The composing decorator does not re-rank either.
        let retriever = codeOnly(try read(retrieverRel))
        for banned in [".sorted(", "EvidenceRanker", "Reranker"] {
            #expect(!retriever.contains(banned), "decorator re-ranks: \(banned)")
        }
    }

    @Test("Neither the source-identity model nor SensitiveScope is forked")
    func noForkedAuthorities() throws {
        let all = ([policyRel, retrieverRel, resolverRel].compactMap { try? read($0) }).map(codeOnly).joined(separator: "\n")
        for banned in ["struct SensitiveScope", "actor SensitiveRetrievalPolicy", "struct SensitiveRetrievalPolicy",
                       "struct SourceVersion", "enum SourceVersion", "struct EvidenceBlock"] {
            #expect(!all.contains(banned), "forks a canonical authority: \(banned)")
        }
        // Case scope is enforced through the ONE shared policy.
        #expect(codeOnly(try read(retrieverRel)).contains("SourceScopeRetrievalPolicy.filter"))
    }

    @Test("The policy is fail-closed: an unresolved identity resolves to NOT authorized")
    func failClosedSource() throws {
        let policy = codeOnly(try read(policyRel))
        // The single resolution helper defaults a missing id to false (never admitted by default).
        #expect(policy.contains("guard let id else { return false }"))
        // No branch returns the full result while active (the only early return is the inactive no-op).
        #expect(policy.contains("guard scope.isActive else"))
    }

    // MARK: - Value-level composition invariants

    @Test("A SourceScopedRetriever IS a Retriever and can stand in wherever the shared retriever is used")
    func decoratorIsARetriever() async throws {
        let evidence = EvidenceStore(database: try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion))
        struct Empty: Retriever {
            func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { RetrievalResult() }
        }
        let d: any Retriever = SourceScopedRetriever(base: Empty(), evidence: evidence, scope: .unscoped)
        _ = d   // compiles ⇒ the decorator is a drop-in Retriever (no forked retrieval surface)
    }

    @Test("Scope activeness is explicit: unscoped is inactive; an empty allow-set is active-but-empty")
    func scopeActiveness() {
        #expect(RetrievalSourceScope.unscoped.isActive == false)
        #expect(RetrievalSourceScope.authorizing([]).isActive == true)
        #expect(RetrievalSourceScope.authorizing([]).authorizedSourceVersionIDs.isEmpty)
    }

    @Test("The answer engine sources its evidence packet from the injected retriever — so a scoped retriever governs it")
    func answerEngineConsumesInjectedRetriever() throws {
        // MasterBrain builds retrieval from its injected `retriever` and takes `.result` as the packet.
        // Injecting a SourceScopedRetriever therefore places the case boundary BEFORE the evidence packet
        // (§9) with no bypass — the live-answer wiring that injects it is built in INV-01-C.
        let brain = codeOnly(try read("Kalsmritikosh/Brain/MasterBrain.swift"))
        #expect(brain.contains("retriever.retrieve("))
        #expect(brain.contains("access:"))
    }
}
