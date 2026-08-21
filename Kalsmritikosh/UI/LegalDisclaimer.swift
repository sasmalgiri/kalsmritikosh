//
//  LegalDisclaimer.swift
//  Kalsmritikosh
//
//  Small reusable "not legal advice" notice. Placed on the surfaces that
//  produce legally-sensitive output (redaction, authenticity, citations) and,
//  in general form, in Settings. Keeps the product honest about what it is:
//  a tool, not a lawyer or a certifying authority.
//

import SwiftUI

struct LegalDisclaimer: View {
    /// The default, app-wide notice. Individual surfaces can pass a more
    /// specific line that still ends with the not-legal-advice point.
    static let general = "This app is a tool, not legal advice. Using it creates no attorney–client relationship, and its output is not a certification. Verify against current law, court rules, and a qualified professional before you rely on anything here."

    var text: String = LegalDisclaimer.general

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
