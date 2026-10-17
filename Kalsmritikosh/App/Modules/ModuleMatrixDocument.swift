//
//  ModuleMatrixDocument.swift
//  Kalsmritikosh
//
//  W0-M — renders MODULE_MATRIX.md from the two module enums, so the document
//  can never drift from the code (the final test phase compares the committed
//  file with this output, as CAPABILITY_MATRIX.md is compared).
//

import Foundation

public enum ModuleMatrixDocument {

    public static func render() -> String {
        var out: [String] = []
        out.append("# MODULE_MATRIX — every switch in Kalsmritikosh")
        out.append("")
        out.append("Generated from `ProductModule` and `KnowledgeModule`. Do not hand-edit.")
        out.append("")
        out.append("A module runs only when its code has landed, its gates pass and its switch is on.")
        out.append("New modules default OFF until the owner promotes them. Off is never destructive.")
        out.append("")
        out.append("## Product modules (beat-DEVONthink plan)")
        out.append("")
        out.append("| Plan | Module | Group | Built | Default | Gates | When off |")
        out.append("|---|---|---|---|---|---|---|")
        for m in ProductModule.allCases {
            let s = m.spec
            var gates: [String] = []
            if s.requiresOnline { gates.append("Online mode") }
            if s.requiresAI { gates.append("AI") }
            gates += s.dependsOn.map { "needs \($0.planID)" }
            out.append("| \(s.planID) | \(s.title) | \(s.group) | \(s.implemented ? "yes" : "not yet") | \(s.defaultEnabled ? "on" : "off") | \(gates.isEmpty ? "—" : gates.joined(separator: ", ")) | \(s.whenOff) |")
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
