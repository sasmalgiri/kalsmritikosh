//
//  DemoArchive.swift
//  Kalsmritikosh
//
//  The ONE resolver for the bundled ProjectDelta demo corpus (release-candidate
//  physical proof, 2026-08-28). Xcode's synchronized resource folder FLATTENS
//  Resources/Fixtures/ProjectDelta into Contents/Resources — there is no
//  "Fixtures/ProjectDelta" directory in the shipped bundle, so the old
//  Bundle.url(forResource:subdirectory:) lookup returned nil and the
//  onboarding "Try the demo archive" button silently disappeared (App Review's
//  documented first step). This helper supports both layouts: a real bundled
//  folder when present, otherwise the flattened files are materialized ONCE
//  per launch-version into an app-container folder that can be bookmarked and
//  ingested like any user folder. Fail-closed: a partial fixture set returns
//  nil rather than a half-demo.
//

import Foundation

public nonisolated enum DemoArchive {

    /// The complete ProjectDelta fixture set (kept in step with
    /// Kalsmritikosh/Resources/Fixtures/ProjectDelta — 8 files).
    public static let fixtureNames = [
        "amendment-7.md", "contract.md",
        "invoice-401.eml", "invoice-432.eml",
        "supplier_abc_22.eml", "supplier_abc_23.eml",
        "supplier_abc_24.eml", "supplier_abc_25.eml",
    ]

    /// The demo corpus as a real on-disk folder, or nil when this build does
    /// not carry the fixtures (e.g. stripped unit-test hosts).
    public static func url() -> URL? {
        // Layout 1 — a genuine bundled directory (folder-reference builds).
        if let dir = Bundle.main.url(forResource: "ProjectDelta", withExtension: nil,
                                     subdirectory: "Fixtures") {
            return dir
        }
        if let dir = Bundle.main.url(forResource: "ProjectDelta", withExtension: nil),
           (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return dir
        }
        // Layout 2 — flattened resources: materialize into the app container.
        return materializedFromFlattenedBundle()
    }

    private static func materializedFromFlattenedBundle() -> URL? {
        let fm = FileManager.default
        let sources: [(name: String, url: URL)] = fixtureNames.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: nil).map { (name, $0) }
        }
        guard sources.count == fixtureNames.count else { return nil }  // partial set ⇒ no demo
        do {
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: true)
                .appendingPathComponent("DemoArchive", isDirectory: true)
                .appendingPathComponent("ProjectDelta", isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            for (name, src) in sources {
                let dst = base.appendingPathComponent(name)
                // Overwrite so the on-disk copy always matches THIS app version.
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            return base
        } catch {
            return nil
        }
    }
}
