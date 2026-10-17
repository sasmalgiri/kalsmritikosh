//
//  RawSavepointRatchetTests.swift
//  KalsmritikoshTests
//
//  F28 — a raw `exec("SAVEPOINT …")` whose body awaits other database calls is NOT an isolated
//  transaction on the shared Database actor: other callers interleave, a rollback can undo their
//  writes and a release can swallow their savepoint. The safe shape is `Database.withSavepoint`
//  (synchronous, isolated closure). This ratchet freezes the files that still use the raw pattern
//  (audited 2026-09-28, review finding F28) so the list can only SHRINK: a new file using it fails
//  here, and a converted file must be removed from the list.
//

import Foundation
import Testing

@Suite("F28 — raw SAVEPOINT ratchet")
struct RawSavepointRatchetTests {

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh")
    }

    /// Files still issuing raw savepoints across suspension points. EMPTY since F28b: every transaction
    /// runs in `Database.withSavepoint`; any new raw use fails the test below.
    private static let knownRawSavepointFiles: Set<String> = [
    ]

    @Test("No NEW file opens a raw SAVEPOINT; converted files leave the list")
    func rawSavepointsOnlyShrink() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            Issue.record("source tree not found at \(appRoot.path)"); return
        }
        var found = Set<String>()
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(appRoot.path.count + 1))
            // The Database actor and migrations own SAVEPOINT legitimately (synchronous, isolated).
            if rel.hasPrefix("Storage/Database/") || rel.hasPrefix("Storage/Schema/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("exec(\"SAVEPOINT") { found.insert(rel) }
        }
        let added = found.subtracting(Self.knownRawSavepointFiles)
        #expect(added.isEmpty, "new raw SAVEPOINT use — use Database.withSavepoint instead: \(added.sorted())")
        let converted = Self.knownRawSavepointFiles.subtracting(found)
        #expect(converted.isEmpty, "remove converted files from the ratchet list: \(converted.sorted())")
        #expect(!found.contains("Workbench/Persistence/WorkbenchTransformRepository.swift"))
    }

    /// Files allowed to issue raw transaction statements, each for a stated reason. Nothing else —
    /// no directory is excluded wholesale.
    private static let transactionStatementOwners: [String: String] = [
        // The actor itself: `withSavepoint` (synchronous, isolated) and the read-only snapshot
        // connection's BEGIN on its OWN handle.
        "Storage/Database/DatabaseStack.swift": "the one transaction owner",
        // Boot-only: `migrate` runs before any repository is wired, so nothing can interleave.
        "Storage/Schema/SchemaMigrations.swift": "initialization-only migrations",
    ]

    /// F28 (residual) — the raw-SAVEPOINT scan missed `beginTransaction()` + awaits + commit, which
    /// held a transaction open while OTHER callers' ordinary writes ran inside it. Any await-spanning
    /// transaction form — the gate API or a raw BEGIN/COMMIT/ROLLBACK/RELEASE statement — fails here.
    @Test("No await-spanning transaction API or raw transaction statement outside the named owners")
    func noAwaitSpanningTransactionAPI() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            Issue.record("source tree not found at \(appRoot.path)"); return
        }
        let apiCalls = ["beginTransaction(", "commitTransaction(", "rollbackTransaction("]
        let statements = ["BEGIN", "COMMIT", "END", "ROLLBACK", "RELEASE", "SAVEPOINT"]
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(appRoot.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for call in apiCalls where text.contains(call) { offenders.append("\(rel): \(call)") }
            guard Self.transactionStatementOwners[rel] == nil else { continue }
            for verb in statements {
                for opener in ["exec(\"", "execRaw(\"", "query(\""] where text.contains(opener + verb) {
                    offenders.append("\(rel): \(opener)\(verb)")
                }
            }
        }
        #expect(scanned > 500, "the scan must cover the whole app (scanned \(scanned))")
        #expect(offenders.isEmpty, "use Database.withSavepoint (synchronous, isolated): \(offenders.sorted())")
    }
}
