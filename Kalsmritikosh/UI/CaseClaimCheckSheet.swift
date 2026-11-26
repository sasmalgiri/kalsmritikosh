//
//  CaseClaimCheckSheet.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (SEARCH-15) — "Check this claim…": the two queries CaseClaimCheck builds from an item's words
//  (supporting, and same subject without the claimed figure), shown and editable before anything runs. Choosing one hands
//  it to the case search, which runs it with its usual receipt (what was searched and what was not). AI off.
//

import SwiftUI

struct CaseClaimCheckSheet: View {
    let claim: String
    let run: (String) -> Void
    let close: () -> Void
    @State private var supporting = ""
    @State private var contrary = ""
    @State private var plan: CaseClaimCheck.Plan?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check this claim").font(.title3.weight(.semibold))
            Text("\u{201C}\(claim)\u{201D}").font(.callout).foregroundStyle(.secondary).lineLimit(4)
            if let plan { Text(plan.explanation).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Text("Records that support it").font(.callout.weight(.semibold))
            HStack {
                TextField("Search", text: $supporting).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("case.claimCheck.supporting")
                Button("Search for it") { run(supporting) }
                    .disabled(supporting.trimmingCharacters(in: .whitespaces).isEmpty)
                    .caseMapControlHelp("Search for it")
            }
            Text("Records about the same subject that do not state it").font(.callout.weight(.semibold))
            HStack {
                TextField("No other-figure query: the claim states no figure", text: $contrary).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("case.claimCheck.contrary")
                Button("Search against it") { run(contrary) }
                    .disabled(contrary.trimmingCharacters(in: .whitespaces).isEmpty)
                    .caseMapControlHelp("Search against it")
            }
            Text("A record matching the words does not by itself prove the claim, and a record missing them does not disprove it. Read the passages; the search's receipt says what it did not search.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(minWidth: 520)
        .task {
            let p = CaseClaimCheck.plan(claim: claim)
            plan = p; supporting = p.supporting; contrary = p.contrary ?? ""
        }
    }
}
