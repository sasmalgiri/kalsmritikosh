//
//  SutraDraftParser.swift
//  Kalsmritikosh
//
//  OPTIONAL, Full-power-only. Drafts a Sūtra from an SOP using the on-device
//  model — the frontier the research points at (SOP → executable doctrine) — but
//  bounded by the app's safety model: the model may only MAP each SOP step onto
//  one of the 16 known job-kinds and write plain-language obligations / human
//  decisions / prohibited conclusions. It never chooses tooling: the ENGINE
//  assigns tier / method / surface from JobToolingCatalog. So a drafted Sūtra can
//  only ever reach surfaces the app already trusts. It is a DRAFT — a human
//  ratifies it before it is used; nothing is auto-adopted (VISION §4).
//

import Foundation

public enum SutraDraftParser {

    /// Draft a Sūtra from SOP text. Returns nil on any failure (no model, bad
    /// JSON, no valid phases) — the caller then stays manual. Never throws.
    public static func draft(fromSOP sop: String, capabilities: CapabilityRegistry) async -> Sutra? {
        let text = sop.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { return nil }
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "sutra.draft")
        guard let provider = try? await capabilities.resolve(spec), await provider.isAvailable() else { return nil }
        let options = GenerationOptions(maxTokens: 900, temperature: 0.2, systemPrompt: Self.systemPrompt)
        guard let raw = try? await provider.generate(prompt: userPrompt(text), options: options) else { return nil }
        return decode(raw)
    }

    /// The model's raw text → a validated draft Sūtra, or nil. Split out so the
    /// safety-critical validation is unit-testable without a live model.
    static func decode(_ response: String) -> Sutra? {
        guard let json = jsonObject(response),
              let dto = try? JSONDecoder().decode(DraftDTO.self, from: Data(json.utf8)) else { return nil }

        var phases: [SutraPhase] = []
        for dp in dto.phases ?? [] {
            // The kind MUST be one of the known 16 — anything else is dropped.
            guard let kind = PersonaJobKind(rawValue: dp.kind),
                  let profile = JobToolingCatalog.profile(for: kind) else { continue }
            let title = clean1(dp.title) ?? SutraDoctrine.title(kind)
            phases.append(SutraPhase(
                kind: kind, title: title,
                tier: profile.tier, method: profile.method, surface: profile.surface,   // engine-assigned
                obligations: clean(dp.obligations), humanDecisions: clean(dp.humanDecisions),
                prohibitedConclusions: clean(dp.prohibited)))
        }
        guard phases.count >= 2 else { return nil }

        let title = clean1(dto.title) ?? "Imported discipline"
        return Sutra(
            id: "sutra.custom." + slug(title),
            version: 1, title: title,
            provenance: "Drafted by the on-device AI from your SOP — a draft to review and ratify, not an authority. Tooling was assigned by the engine, not the model.",
            reliabilityScale: clean1(dto.reliabilityScale) ?? "—",
            phases: phases,
            standardsOfProof: EvidentiaryStandard.allCases,
            reportSections: cleanList(dto.reportSections) ?? ["Summary", "Evidence", "Analysis", "Findings", "Sign-off"])
    }

    // MARK: - Prompt

    private static let systemPrompt =
        "You convert a standard operating procedure into a structured 'sutra'. You may ONLY map each SOP step " +
        "onto one of the given job-kinds and write short obligations, human decisions, and prohibited conclusions. " +
        "Never invent job-kinds and never choose tooling. Reply with ONE minified JSON object and nothing else."

    private static func userPrompt(_ sop: String) -> String {
        let kinds = PersonaJobKind.allCases.map { "\($0.rawValue) — \(SutraDoctrine.title($0))" }.joined(separator: "\n")
        return """
        JOB-KINDS (pick each phase's "kind" from these rawValues only):
        \(kinds)

        Output JSON shape:
        {"title":"<discipline>","reliabilityScale":"<optional>","phases":[{"kind":"<rawValue>","title":"<phase name>","obligations":["..."],"humanDecisions":["..."],"prohibited":["..."]}],"reportSections":["..."]}
        Rules: order phases as the SOP flows; use each kind at most once; keep every string short; omit anything you're unsure of.

        SOP:
        \(sop)
        JSON:
        """
    }

    // MARK: - DTO + helpers

    struct DraftDTO: Decodable {
        let title: String?
        let reliabilityScale: String?
        let phases: [DraftPhase]?
        let reportSections: [String]?
    }
    struct DraftPhase: Decodable {
        let kind: String
        let title: String?
        let obligations: [String]?
        let humanDecisions: [String]?
        let prohibited: [String]?
    }

    private static func clean(_ xs: [String]?) -> [String] {
        (xs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { String($0.prefix(160)) }
    }
    private static func clean1(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(120))
    }
    private static func cleanList(_ xs: [String]?) -> [String]? {
        let c = clean(xs); return c.isEmpty ? nil : c
    }
    private static func slug(_ s: String) -> String {
        let base = s.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return base.isEmpty ? "discipline" : String(base.prefix(40))
    }
    private static func jsonObject(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }
}
