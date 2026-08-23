//
//  RootCauseAIAssist.swift
//  Kalsmritikosh
//
//  OPTIONAL, Full-power-only assist for the Reasoning Studio. It never decides
//  anything: it only proposes candidate causes or a next "why" that the
//  investigator reviews, edits, and accepts or discards. Deterministic value
//  (the whole studio) works with this turned off.
//
//  Capability-routed (no model names here), returns plain suggestion strings.
//  Any failure returns an empty list so the UI silently degrades to manual.
//

import Foundation

public enum RootCauseAIAssist {

    /// Propose short candidate causes for the problem, excluding ones already
    /// captured. Returns [] on any failure.
    public static func suggestCauses(problem: String,
                                     existing: [String],
                                     capabilities: CapabilityRegistry) async -> [String] {
        let problem = problem.trimmed
        guard problem.count >= 4 else { return [] }
        let prompt = """
        You are helping an investigator brainstorm POSSIBLE causes (hypotheses, not conclusions) \
        for the problem below. Give 5–8 short candidate causes, each a noun phrase under 12 words. \
        Do not repeat any already listed. Reply as a minified JSON array of strings only.

        PROBLEM: \(problem)
        ALREADY LISTED: \(existing.isEmpty ? "(none)" : existing.joined(separator: "; "))
        JSON:
        """
        return await runList(prompt, purpose: "rca.suggestCauses",
                             capabilities: capabilities, exclude: existing, cap: 8)
    }

    /// Given the chain of answers so far, propose the next "why" answer to test.
    /// Returns nil on any failure.
    public static func suggestNextWhy(problem: String,
                                      answersSoFar: [String],
                                      capabilities: CapabilityRegistry) async -> String? {
        guard problem.trimmed.count >= 4 else { return nil }
        let chain = answersSoFar.isEmpty ? "(none yet)" : answersSoFar.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        An investigator is doing a 5 Whys on the problem below. Given the answers so far, \
        propose ONE deeper candidate answer to the next "why?" — a single sentence, a hypothesis \
        to test, not a certainty. Reply as a minified JSON object: {"why":"..."}.

        PROBLEM: \(problem.trimmed)
        ANSWERS SO FAR:
        \(chain)
        JSON:
        """
        guard let raw = await generate(prompt, purpose: "rca.nextWhy", maxTokens: 120,
                                       capabilities: capabilities),
              let json = jsonObject(raw),
              let obj = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)),
              let why = obj["why"]?.trimmed, !why.isEmpty else { return nil }
        return String(why.prefix(300))
    }

    // MARK: - Shared plumbing

    private static func runList(_ prompt: String, purpose: String,
                                capabilities: CapabilityRegistry,
                                exclude: [String], cap: Int) async -> [String] {
        guard let raw = await generate(prompt, purpose: purpose, maxTokens: 300, capabilities: capabilities),
              let json = jsonArray(raw),
              let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        let seen = Set(exclude.map { $0.lowercased().trimmed })
        var out: [String] = []
        for s in arr {
            let t = s.trimmed
            guard !t.isEmpty, !seen.contains(t.lowercased()), t.count <= 120 else { continue }
            if !out.contains(where: { $0.lowercased() == t.lowercased() }) { out.append(String(t.prefix(120))) }
            if out.count >= cap { break }
        }
        return out
    }

    private static func generate(_ prompt: String, purpose: String, maxTokens: Int,
                                 capabilities: CapabilityRegistry) async -> String? {
        let spec = CapabilitySpec.reasoning(contextTokens: 1_500, purpose: purpose)
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return nil }
        let options = GenerationOptions(
            maxTokens: maxTokens, temperature: 0.5,
            systemPrompt: "You propose hypotheses for a human investigator to review. Be concise. Reply with JSON only, no prose."
        )
        return try? await provider.generate(prompt: prompt, options: options)
    }

    private static func jsonArray(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b else { return nil }
        return String(s[a...b])
    }
    private static func jsonObject(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }
}
