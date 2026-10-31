//
//  HelpRegistryTests.swift
//  KalsmritikoshTests
//
//  App Store completion instructions §6: the one help registry is complete, current and honest.
//  - every topic id is unique and stable in form;
//  - every sidebar destination has a screen topic; the nine professions each have a derived recipe;
//  - every control name a topic or tutorial step quotes exists as a literal in the UI sources, so
//    help never names a button that is not there;
//  - no help, guide, onboarding or home text makes an absolute claim the mandate forbids;
//  - the tutorial has the mandated path and runs only in the sample case;
//  - search finds tasks by plain words;
//  - the generated manual and coverage matrix match the registry (drift tests; regenerate with
//    HELP_DOCS_WRITE=1).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite struct HelpRegistryTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift source under Kalsmritikosh/UI and Kalsmritikosh/App, concatenated once.
    static let uiSources: String = {
        let fm = FileManager.default
        var out = ""
        for dir in ["Kalsmritikosh/UI", "Kalsmritikosh/App"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                if let s = try? String(contentsOf: url, encoding: .utf8) { out += s; out += "\n" }
            }
        }
        return out
    }()

    @Test("Topic ids are unique, lowercase-kebab, and every topic has a title and summary")
    func idsAndShape() {
        let ids = HelpRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
        for t in HelpRegistry.all {
            #expect(t.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil, "id \(t.id)")
            #expect(!t.title.isEmpty && !t.summary.isEmpty, "\(t.id)")
        }
        #expect(HelpRegistry.all.count >= 60)
    }

    @Test("Every sidebar destination has a screen topic")
    func screensCoverEveryDestination() {
        for group in Destination.Group.allCases {
            for dest in group.items {
                #expect(HelpRegistry.screenTopic(for: dest) != nil, "no screen topic for \(dest.rawValue)")
            }
        }
    }

    @Test("Nine persona recipes, derived from the real jobs, in the mandate's order")
    func nineRecipes() {
        let recipes = HelpRegistry.topics(of: .persona)
        #expect(recipes.count == 9)
        #expect(recipes.map(\.persona) == ["Investigator", "Lawyer / Professional Reviewer", "Compliance / HR Investigator", "Forensic Accountant", "Insurance Fraud (SIU)", "Journalist", "Researcher / Historian", "Genealogist / Family Historian", "Individual"])
        for r in recipes {
            let jobs = PersonaJobCatalogComposer.jobs(forPersona: HelpRegistry.personaOrder.first { $0.label == r.persona }!.applicationID)
            #expect(!jobs.isEmpty, "\(r.id)")
            for job in jobs { #expect(r.steps.contains { $0.contains("“\(job.title)”") }, "\(r.id) misses job \(job.title)") }
            #expect(r.notes.contains { $0.hasPrefix("Professional limits:") }, "\(r.id)")
            #expect(r.steps.first?.contains("Start matter") == true && r.steps.last?.contains("Case file report…") == true, "\(r.id)")
        }
        #expect(!recipes.contains { $0.persona == "Content Creator" })
    }

    @Test("Every quoted control name exists as a literal in the UI sources")
    func controlsExist() {
        let names = Set(HelpRegistry.all.flatMap(\.controls) + HelpTutorial.steps.flatMap(\.controls))
        #expect(names.count >= 20)
        for name in names {
            #expect(Self.uiSources.contains("\"\(name)") || Self.uiSources.contains("\(name)\""), "control “\(name)” not found in UI sources")
        }
    }

    @Test("No forbidden absolute claims in help, guide, onboarding or home text")
    func noAbsoluteClaims() throws {
        let forbidden = ["never invent", "never invents", "100% on your mac", "nothing ever leaves", "calibrated, not a guess", "calibrated, not a vibe",
                         "cannot be wrong", "always correct", "guarantee", "fully on-device", "works offline forever", "never auto-transcribed", "never automatic"]
        var texts: [(String, String)] = HelpRegistry.all.map { ($0.id, $0.searchText) }
        for file in ["Kalsmritikosh/UI/GuideContent.swift", "Kalsmritikosh/UI/GuideView.swift", "Kalsmritikosh/UI/OnboardingView.swift",
                     "Kalsmritikosh/UI/HomeView.swift", "Kalsmritikosh/UI/PurchaseGate.swift", "docs/GLOSSARY.md", "release/SUPPORT.md", "docs/USER_MANUAL.md"] {
            let s = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            texts.append((file, s.lowercased()))
        }
        for (where_, text) in texts {
            for phrase in forbidden { #expect(!text.contains(phrase), "“\(phrase)” in \(where_)") }
        }
    }

    @Test("The tutorial follows the mandated path, names its controls, and runs only in the sample case")
    func tutorialPath() async {
        let ids = HelpTutorial.steps.map(\.id)
        #expect(ids == ["open-sample", "question", "authorise", "ask", "citation", "conflict", "review", "carry", "export", "finish"])
        for s in HelpTutorial.steps { #expect(!s.instruction.isEmpty && !s.expect.isEmpty, "\(s.id)") }
        // Both a supported conclusion and an insufficient one are shown.
        let all = HelpTutorial.steps.map(\.expect).joined(separator: " ")
        #expect(all.contains("2 May 2024") && all.contains("invoice 432") && all.contains("none is invented"))
        // Progress is one observable integer mirrored to the preference store; it clamps to the steps.
        let p = await MainActor.run { HelpTutorial.progress }
        await MainActor.run {
            p.stop()
            #expect(!p.isRunning)
            p.set(7)
            #expect(p.isRunning && p.index == 7 && AppDefaults.store.integer(forKey: TutorialProgress.stepKey) == 7)
            p.set(99)
            #expect(p.index == HelpTutorial.steps.count - 1)
            p.stop()
            #expect(AppDefaults.store.object(forKey: TutorialProgress.stepKey) == nil)
        }
        // The panel is gated on the sample mode in RootView (source check: the overlay condition).
        #expect(Self.uiSources.contains("SampleArchiveMode.isActive && HelpTutorial.progress.isRunning"))
    }

    @Test("Search finds tasks by plain words and ranks title matches first")
    func search() {
        #expect(HelpRegistry.search("export").contains { $0.id == "task-review-approve-export" })
        #expect(HelpRegistry.search("refund").contains { $0.id == "task-money" })
        #expect(HelpRegistry.search("namesake").contains { $0.id == "task-people-and-namesakes" })
        #expect(HelpRegistry.search("cancel trial").first?.id == "subscription-plans")
        #expect(HelpRegistry.search("recovery key").contains { $0.id == "task-keys-backup-erase" })
        #expect(HelpRegistry.search("zzzz-nothing").isEmpty)
        #expect(HelpRegistry.search("   ").count == HelpRegistry.all.count)
    }

    @Test("Information buttons read the registry")
    func infoTopics() {
        for id in ["task-review-approve-export", "task-private-online", "task-keys-backup-erase", "task-people-and-namesakes", "subscription-plans", "safety-amounts"] {
            #expect(HelpRegistry.topic(id) != nil, "\(id)")
        }
        #expect(HelpRegistry.topic("no-such-topic") == nil)
    }

    // MARK: - Generated documents (drift)

    @Test("docs/USER_MANUAL.md and docs/HELP_COVERAGE_MATRIX.md are generated from the registry")
    func generatedDocsMatch() throws {
        let manual = HelpDocsRenderer.manual()
        let matrix = HelpDocsRenderer.coverageMatrix()
        let manualURL = Self.repoRoot.appendingPathComponent("docs/USER_MANUAL.md")
        let matrixURL = Self.repoRoot.appendingPathComponent("docs/HELP_COVERAGE_MATRIX.md")
        if ProcessInfo.processInfo.environment["HELP_DOCS_WRITE"] == "1" {
            try manual.write(to: manualURL, atomically: true, encoding: .utf8)
            try matrix.write(to: matrixURL, atomically: true, encoding: .utf8)
        }
        let onDiskManual = (try? String(contentsOf: manualURL, encoding: .utf8)) ?? ""
        let onDiskMatrix = (try? String(contentsOf: matrixURL, encoding: .utf8)) ?? ""
        // The sandboxed test host cannot write into the repository (and its container is not readable
        // from a shell), so a differing rendering is printed to the console between markers; the
        // regeneration script `scripts/help-docs-from-console.py` cuts it out and writes docs/.
        if onDiskManual != manual { print("===HELP_DOCS_BEGIN USER_MANUAL.md===\n" + manual + "===HELP_DOCS_END===") }
        if onDiskMatrix != matrix { print("===HELP_DOCS_BEGIN HELP_COVERAGE_MATRIX.md===\n" + matrix + "===HELP_DOCS_END===") }
        #expect(onDiskManual == manual, "docs/USER_MANUAL.md differs from the registry rendering; run scripts/help-docs-from-console.py on this run's console log")
        #expect(onDiskMatrix == matrix, "docs/HELP_COVERAGE_MATRIX.md differs from the registry rendering; run scripts/help-docs-from-console.py on this run's console log")
        #expect(manual.contains("# Investigations Made Easy — user manual") && !manual.lowercased().contains("team review"))
    }
}
