//
//  ModuleMatrixDocument.swift
//  Kalsmritikosh
//
//  W0-M — renders MODULE_MATRIX.md from the two module enums, so the document
//  can never drift from the code (the final test phase compares the committed
//  file with this output, as CAPABILITY_MATRIX.md is compared).
//

import Foundation
import os

public enum ModuleMatrixDocument {

    public static func render() -> String {
        var out: [String] = []
        out.append("# MODULE_MATRIX — every switch in Investigations Made Easy")
        out.append("")
        out.append("Generated from `ProductModule` and `KnowledgeModule`. Do not hand-edit.")
        out.append("")
        out.append("A module runs only when its code has landed, its gates pass and its switch is on.")
        out.append("New modules default OFF until the owner promotes them. Off is never destructive.")
        out.append("")
        out.append("## Product modules")
        out.append("")
        out.append("Disposition is the 2026-11-06 scope decision (docs/IME_Core_and_Add_On_Scope_2026-11-06.md §6); the machine-readable inventory is docs/CAPABILITY_INVENTORY.json.")
        out.append("")
        out.append("| Plan | Module | Disposition | Family | Built | Default | Gates | When off |")
        out.append("|---|---|---|---|---|---|---|---|")
        for m in ProductModule.allCases {
            let s = m.spec
            var gates: [String] = []
            if s.requiresOnline { gates.append("Online mode") }
            if s.requiresAI { gates.append("AI") }
            gates += s.dependsOn.map { "needs \($0.planID)" }
            out.append("| \(s.planID) | \(s.title) | \(m.disposition.rawValue) | \(m.family.title) | \(s.implemented ? "yes" : "not yet") | \(s.defaultEnabled ? "on" : "off") | \(gates.isEmpty ? "—" : gates.joined(separator: ", ")) | \(s.whenOff) |")
        }
        let built = ProductModule.allCases.filter(\.implemented).count
        out.append("")
        out.append("_\(built) of \(ProductModule.allCases.count) product modules built._")
        out.append("")
        out.append("## Knowledge modules (ledger and answer internals)")
        out.append("")
        out.append("| Module | Group | Built | Default | Gates |")
        out.append("|---|---|---|---|---|")
        for m in KnowledgeModule.allCases {
            var gates: [String] = []
            if m.requiresAI { gates.append("AI") }
            gates += m.dependsOn.map { "needs \($0.title)" }
            out.append("| \(m.title) | \(m.group) | \(m.implemented ? "yes" : "not yet") | \(m.defaultEnabled ? "on" : "off") | \(gates.isEmpty ? "—" : gates.joined(separator: ", ")) |")
        }
        out.append("")
        out.append("## Not switchable, by design")
        out.append("")
        for i in ModuleInvariant.allCases { out.append("- \(i.statement)") }
        out.append("")
        return out.joined(separator: "\n")
    }
}

/// §9.1 — the machine-readable capability inventory (docs/CAPABILITY_INVENTORY.json), generated from the
/// module specs so it cannot drift (ScopeInventoryDriftTests). One record per product module.
public enum CapabilityInventoryDocument {

    public static let sourceDecision = "docs/IME_Core_and_Add_On_Scope_2026-11-06.md"

    public static func records() -> [[String: Any]] {
        ProductModule.allCases.map { m in
            let s = m.spec
            var r: [String: Any] = [
                "key": m.rawValue,
                "planID": s.planID,
                "title": s.title,
                "disposition": m.disposition.rawValue,
                "family": m.family.rawValue,
                "implemented": s.implemented,
                "defaultEnabled": s.defaultEnabled,
                "preview": s.preview,
                "requiresOnline": s.requiresOnline,
                "entitlement": m.entitlement.rawValue,
                "dependsOn": s.dependsOn.map(\.rawValue),
                "verification": m.verification.rawValue,
                "verificationEvidence": m.verificationEvidence,
                "neverSwitchedOnAutomatically": ProductModule.neverSwitchedOnAutomatically.contains(m),
                "whenOff": s.whenOff
            ]
            r["coreRetained"] = m.coreRetained ?? NSNull()
            return r
        }
    }

    public static func render() -> String {
        let root: [String: Any] = [
            "generatedFrom": "ProductModule (Kalsmritikosh/App/Modules/ProductModule.swift). Do not hand-edit.",
            "scopeDecision": sourceDecision,
            "concerns": [
                "core": "disposition + coreRetained",
                "optionalVisibility": "ProductModuleFlags (module switch)",
                "purchaseEntitlement": "entitlement (PurchaseGate decides access; no switch is a purchase)",
                "diagnosticOrPreview": "preview flag and the INTERNAL disposition"
            ],
            "invariants": ModuleInvariant.allCases.map(\.statement),
            "modules": records()
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return (String(data: data, encoding: .utf8) ?? "") + "\n"
        } catch {
            KalsmritikoshLog.app.error("Capability inventory render failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
