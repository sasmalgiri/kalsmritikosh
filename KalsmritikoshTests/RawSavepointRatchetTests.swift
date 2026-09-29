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
}
