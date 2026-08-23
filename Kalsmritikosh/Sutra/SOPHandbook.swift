//
//  SOPHandbook.swift
//  Kalsmritikosh
//
//  The presentable, in-app SOP handbook: the system flow (the six-step SOP
//  lifecycle the app is built on) + the core SOPs + every built-in
//  constitution's phases, obligations, reserved human decisions, and
//  prohibited conclusions + the compliance board. GENERATED from the live
//  Sutra values and board records — it can never drift from what the app
//  actually enforces.
//

import Foundation

public nonisolated enum SOPHandbook {

    public static let coreSOPs: [(String, String)] = [
        ("Evidence-only answering", "No claim without cited evidence IDs, validated against the retrieval set."),
        ("Conflict preservation", "Conflicting evidence is shown with both sources — never averaged away."),
        ("Reserved human decisions", "Merges, root causes, dispositions, and approvals are made by a person — never auto-asserted."),
        ("Standard of proof", "Findings cannot be approved without a declared evidentiary standard."),
        ("Source reliability", "Sources are rated on the Admiralty scale (A–F × 1–6) before weight is placed on them."),
        ("Chain of custody", "Custody recorded contemporaneously; evidence hashed early (SWGDE/NIST; intl. ISO/IEC 27037)."),
        ("Privacy by architecture", "No document, question, or ledger content ever leaves the device."),
        ("AI disclosure at point of use", "Every answer and every report declares AI assistance and requires human review."),
        ("Document history", "Every deliverable carries its audit trail, printed on the hardcopy."),
        ("Amendment-only change", "SOPs change by versioned amendment, never silent rewrite; certificates cite the version verified against."),
    ]

    public static func markdown(now: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .long
        var out = "# Kalsmritikosh SOP Handbook — \(f.string(from: now))\n\n"
        out += """
        ## The system flow (how this app works)

        The app is not a bag of features — it is a set of Standard Operating \
        Procedures, executed gate by gate, ending in the professional's real \
        deliverable. Its lifecycle:

        1. **Obtain the SOPs** — the current editions from their governing bodies.
        2. **Pin the versions** — each edition named on the Compliance Board.
        3. **Extract the meaning** — each SOP becomes obligations, reserved human \
        decisions, and prohibited conclusions (a Sūtra).
        4. **Enforce, don't display** — the studios gate every stage on those rules; \
        the deliverable cannot complete without satisfying them.
        5. **Verify the result** — hardcopies match the professional original \
        (structure-locked by tests); each sealed run carries a conformance \
        certificate naming the constitution and version it satisfied.
        6. **Maintain compliance** — the Compliance Board re-checks every SOP \
        periodically; changes happen only as versioned amendments.


        """
        out += "## Core SOPs (bind every workflow)\n\n"
        for (i, s) in coreSOPs.enumerated() { out += "\(i + 1). **\(s.0)** — \(s.1)\n" }
        out += "\n## The constitutions (binding, machine-readable form)\n\n"
        for d in SutraCompiler.builtInDisciplines {
            let s = d.sutra
            out += "### \(s.citation)\n\n"
            out += "_\(s.provenance)_\n\nReliability scale: \(s.reliabilityScale)\n\n"
            for p in s.phases {
                out += "**\(p.title)** (\(p.tier.rawValue) · \(p.method.rawValue))\n"
                for o in p.obligations { out += "- Must: \(o)\n" }
                for h in p.humanDecisions { out += "- Human decides: \(h)\n" }
                for x in p.prohibitedConclusions { out += "- Never: \(x)\n" }
                out += "\n"
            }
            if let a = s.amendments, !a.isEmpty {
                out += "Amendments:\n"
                for am in a { out += "- v\(am.version) (\(am.date)): \(am.summary)\n" }
                out += "\n"
            }
        }
        out += ComplianceBoard.markdown(now: now)
        return out
    }
}
