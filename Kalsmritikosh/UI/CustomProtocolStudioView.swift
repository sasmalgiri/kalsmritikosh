//
//  CustomProtocolStudioView.swift
//  Kalsmritikosh
//
//  Conformance roadmap 2.0 — the Custom Protocol Studio (shipped OFF by
//  default; Settings › Custom protocol studio). An organization authors its
//  OWN constitution through the governed lifecycle:
//
//     Draft → Structure → Compile → Test → Sign → Register/Activate
//
//  AI may only DRAFT (SutraDraftParser turns pasted SOP text into a starting
//  structure); every rule the pack ships is human-edited, deterministically
//  compiled (typed rules, fail-closed), simulated against sample facts, and
//  signed with the installation key under a self-declared assurance label
//  ("self-authored" / "organization-approved") — authorship is proven,
//  adequacy never pretended. The output is a standard signed .kalprotocol
//  pack: the same offline verification and registry lifecycle as any other.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Model (testable core)

@MainActor
@Observable
public final class CustomProtocolStudioModel {
    // Draft
    public var sopText = ""
    public private(set) var drafting = false
    // Structure
    public var title = ""
    public var identifier = ""
    public var provenance = ""
    public var globalRequirementsText = ""     // one requirement per line
    public var phaseEdits: [PhaseEdit] = []
    // Sign
    public var publisher = ""
    public var assurance = "self-authored"
    public private(set) var status: String?

    public struct PhaseEdit: Identifiable, Sendable {
        public var id: String { kind.rawValue }
        public let kind: PersonaJobKind
        public let phaseTitle: String
        public let tier: PhaseTier
        public let method: AnalyticMethod
        public let surface: String?
        public var include: Bool
        public var obligationsText: String
        public var humanDecisionsText: String
        public var prohibitionsText: String
    }

    public init() {
        seed(from: SutraCompiler.shared())
    }

    /// Seed the structure editor from a base constitution (the standard phase
    /// skeleton; organizations rebind their own text onto it).
    public func seed(from base: Sutra) {
        provenance = "Authored in the Custom Protocol Studio"
        phaseEdits = base.phases.map { p in
            PhaseEdit(kind: p.kind, phaseTitle: p.title, tier: p.tier, method: p.method,
                      surface: p.surface, include: true,
                      obligationsText: p.obligations.joined(separator: "\n"),
                      humanDecisionsText: p.humanDecisions.joined(separator: "\n"),
                      prohibitionsText: p.prohibitedConclusions.joined(separator: "\n"))
        }
    }

    /// AI-assisted DRAFT only — the result seeds the editors; nothing ships
    /// until the human structures, compiles, tests and signs it.
    public func draftWithAI(capabilities: CapabilityRegistry) async {
        guard !sopText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafting = true
        defer { drafting = false }
        guard let draft = await SutraDraftParser.draft(fromSOP: sopText, capabilities: capabilities) else {
            status = "The AI could not draft from that text — structure it manually below."
            return
        }
        title = draft.title
        identifier = draft.id.hasPrefix("sutra.") ? draft.id : "sutra.custom.\(draft.id)"
        let byKind = Dictionary(uniqueKeysWithValues: draft.phases.map { ($0.kind, $0) })
        for i in phaseEdits.indices {
            guard let d = byKind[phaseEdits[i].kind] else { phaseEdits[i].include = false; continue }
            phaseEdits[i].include = true
            phaseEdits[i].obligationsText = d.obligations.joined(separator: "\n")
            phaseEdits[i].humanDecisionsText = d.humanDecisions.joined(separator: "\n")
            phaseEdits[i].prohibitionsText = d.prohibitedConclusions.joined(separator: "\n")
        }
        status = "Draft applied — review every line before compiling; the AI only drafts."
    }

    /// Deterministic build of the edited constitution. nil until title,
    /// identifier and at least one included phase with at least one rule exist.
    /// Built-in identifiers are RESERVED — a custom protocol can never shadow
    /// the developer doctrine's id from the studio (audit 2026-08-25 item 6).
    public func buildSutra() -> Sutra? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !id.isEmpty else { return nil }
        let base = SutraCompiler.shared()
        guard id != base.id, id != SutraCompiler.clinicalDifferential().id else {
            status = "The identifier '\(id)' is reserved for a built-in doctrine — choose your own (e.g. sutra.acme.hr)."
            return nil
        }
        let phases: [SutraPhase] = phaseEdits.filter(\.include).map { e in
            SutraPhase(kind: e.kind, title: e.phaseTitle, tier: e.tier, method: e.method,
                       surface: e.surface,
                       obligations: lines(e.obligationsText),
                       humanDecisions: lines(e.humanDecisionsText),
                       prohibitedConclusions: lines(e.prohibitionsText))
        }
        guard !phases.isEmpty else { return nil }
        var sutra = Sutra(id: id, version: 1, title: name,
                          provenance: provenance.isEmpty ? "Custom Protocol Studio" : provenance,
                          reliabilityScale: base.reliabilityScale,
                          phases: phases,
                          standardsOfProof: base.standardsOfProof,
                          reportSections: base.reportSections)
        let globals = lines(globalRequirementsText)
        sutra.globalRequirements = globals.isEmpty ? nil : globals
        // A protocol with zero rules would be vacuously conformant — refuse.
        guard !SutraRuleCompiler.rules(for: sutra).isEmpty else {
            status = "The protocol compiles to zero rules — add at least one obligation, decision, prohibition or global requirement."
            return nil
        }
        return sutra
    }

    /// Compile check via the SAME gate that guards pack activation: export →
    /// verify (signature + hash + schema-compile) with an ephemeral in-memory
    /// signature. Returns the rule count, or the refusal message.
    public func compileCheck(at now: Date) -> Result<Int, Error> {
        guard let sutra = buildSutra() else {
            return .failure(ProtocolPackError.schemaDoesNotCompile("title, identifier and at least one phase are required"))
        }
        do {
            let data = try ProtocolPacks.export(sutra: sutra, publisher: "compile-check",
                                                assurance: assurance, at: now)
            let verified = try ProtocolPacks.verify(data)
            return .success(SutraRuleCompiler.rules(for: verified.sutra).count)
        } catch {
            return .failure(error)
        }
    }

    /// Sign the constitution into distributable pack bytes.
    public func signedPack(at now: Date) throws -> Data {
        guard let sutra = buildSutra() else {
            throw ProtocolPackError.schemaDoesNotCompile("title, identifier and at least one phase are required")
        }
        let who = publisher.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ProtocolPacks.export(sutra: sutra,
                                        publisher: who.isEmpty ? "Unnamed publisher" : who,
                                        assurance: assurance, at: now)
    }

    public func note(_ message: String) { status = message }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - View

public struct CustomProtocolStudioView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = CustomProtocolStudioModel()
    // Test simulator facts.
    @State private var simPhases: Set<PersonaJobKind> = [.findings]
    @State private var simProofDeclared = true
    @State private var simOpenAcked = true
    @State private var simDecisionsMade = true
    @State private var simAttestAll = true

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Custom Protocol Studio", systemImage: "hammer")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Draft → Structure → Compile → Test → Sign. The AI only drafts; every shipped rule is yours. The result is a signed offline pack with a \"\(model.assurance)\" assurance label — authorship is proven, legal adequacy is not claimed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    draftSection
                    structureSection
                    compileAndTestSection
                    signSection
                    if let status = model.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · Draft (optional)").font(.title3.weight(.bold))
            Text("Paste your organization's SOP text; the on-device model proposes a structure. Skip this to edit the standard skeleton directly.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.sopText)
                .font(.callout).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Button {
                guard let caps = appState.capabilities else {
                    model.note("On-device AI is unavailable — structure manually below."); return
                }
                Task { await model.draftWithAI(capabilities: caps) }
            } label: {
                Label(model.drafting ? "Drafting…" : "Draft with on-device AI", systemImage: "wand.and.stars")
            }
            .disabled(model.drafting || appState.capabilities == nil)
        }
    }

    private var structureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2 · Structure").font(.title3.weight(.bold))
            TextField("Protocol title (e.g. ACME HR Investigations)", text: $model.title)
                .textFieldStyle(.roundedBorder)
            TextField("Identifier (e.g. sutra.acme.hr)", text: $model.identifier)
                .textFieldStyle(.roundedBorder)
            TextField("Provenance (who owns this SOP)", text: $model.provenance)
                .textFieldStyle(.roundedBorder)
            Text("Global requirements — apply to the whole run, one per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.globalRequirementsText)
                .font(.callout).frame(minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            ForEach($model.phaseEdits) { $edit in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Obligations (one per line)").font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $edit.obligationsText).font(.callout).frame(minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text("Reserved human decisions").font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $edit.humanDecisionsText).font(.callout).frame(minHeight: 32)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text("Prohibited conclusions").font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $edit.prohibitionsText).font(.callout).frame(minHeight: 32)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    .padding(.top, 4)
                } label: {
                    Toggle(edit.phaseTitle, isOn: $edit.include).font(.callout.weight(.medium))
                }
            }
        }
    }

    private var compileAndTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3 · Compile & test").font(.title3.weight(.bold))
            Button {
                switch model.compileCheck(at: Date()) {
                case .success(let count):
                    model.note("✓ Compiles: \(count) typed rule(s); signature, hash and schema gates all pass.")
                case .failure(let error):
                    model.note("✗ Does not compile: \(error)")
                }
            } label: { Label("Compile check", systemImage: "checkmark.seal") }
            HStack(spacing: 12) {
                Toggle("Findings reached", isOn: Binding(
                    get: { simPhases.contains(.findings) },
                    set: { if $0 { simPhases.insert(.findings) } else { simPhases.remove(.findings) } }))
                Toggle("Proof declared", isOn: $simProofDeclared)
                Toggle("Open items acked", isOn: $simOpenAcked)
                Toggle("Decisions made", isOn: $simDecisionsMade)
                Toggle("Attest all", isOn: $simAttestAll)
            }
            .font(.caption)
            if let sutra = model.buildSutra() {
                let facts = simulatedFacts(for: sutra)
                let assessment = SutraConformance.assess(facts: facts, against: sutra, at: Date())
                Label(assessment.status.summaryLine,
                      systemImage: assessment.status == .conformant ? "checkmark.seal.fill"
                                 : assessment.status == .notConformant ? "xmark.seal.fill" : "seal")
                    .font(.caption)
                    .foregroundStyle(assessment.status == .conformant ? Color.green
                                   : assessment.status == .notConformant ? Color.red : Color.orange)
            } else {
                Text("Complete the structure to simulate.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func simulatedFacts(for sutra: Sutra) -> ConformanceFacts {
        let attested = simAttestAll
            ? Set(SutraRuleCompiler.rules(for: sutra)
                .filter { $0.phaseKind.map(simPhases.contains) ?? true }.map(\.id))
            : Set<String>()
        return ConformanceFacts(
            completedPhaseKinds: simPhases,
            standardOfProofDeclared: simProofDeclared,
            openItemsAcknowledged: simOpenAcked,
            humanDecisionsMade: simDecisionsMade ? simPhases : [],
            attestedRuleIDs: attested)
    }

    private var signSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("4 · Sign & register").font(.title3.weight(.bold))
            TextField("Publisher (your organization's exact name)", text: $model.publisher)
                .textFieldStyle(.roundedBorder)
            Picker("Assurance label", selection: $model.assurance) {
                Text("Self-authored").tag("self-authored")
                Text("Organization-approved").tag("organization-approved")
            }
            .frame(maxWidth: 340)
            HStack(spacing: 10) {
                Button { exportPack() } label: { Label("Export signed pack…", systemImage: "square.and.arrow.up") }
                Button { Task { await registerHere() } } label: { Label("Register in this app", systemImage: "tray.and.arrow.down") }
                    .help("Verifies and imports the pack into this Mac's registry — activate it on the Compliance Board to govern new runs.")
            }
        }
    }

    private func exportPack() {
        let panel = NSSavePanel()
        let name = model.identifier.isEmpty ? "custom-protocol" : model.identifier
        panel.nameFieldStringValue = "\(name)-v1.\(ProtocolPacks.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (try model.signedPack(at: Date())).write(to: url)
            model.note("Exported signed pack: \(url.lastPathComponent)")
        } catch { model.note("Export failed: \(error)") }
    }

    private func registerHere() async {
        guard let repo = appState.protocolRegistry else { return }
        do {
            let data = try model.signedPack(at: Date())
            let (pack, sutra) = try ProtocolPacks.verify(data)
            _ = try await repo.importPack(pack, at: Date())
            model.note("Registered \(sutra.citation) — activate it on the Compliance Board to govern new runs.")
        } catch { model.note("Registration refused: \(error)") }
    }
}

