//
//  ComplianceBoardView.swift
//  Kalsmritikosh
//
//  The futuristic board (SOP lifecycle step 6): every tracked external SOP with
//  the edition the app implements, when it was last verified, and whether its
//  periodic re-check is due. "Mark reviewed today" records a manual
//  re-verification on-device; the whole board is copyable as a hardcopy.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct ComplianceBoardView: View {
    /// Owner review overrides: SOP id → yyyy-mm-dd of last manual verification.
    @AppStorage("kalsmritikosh.sopboard.reviews") private var reviewBlob = ""

    public init() {}

    private var overrides: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(reviewBlob.utf8))) ?? [:]
    }
    private func markReviewed(_ id: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var o = overrides
        o[id] = f.string(from: Date())
        if let d = try? JSONEncoder().encode(o), let s = String(data: d, encoding: .utf8) { reviewBlob = s }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("SOP Compliance Board", systemImage: "checklist.checked")
                        .font(.largeTitle.weight(.bold))
                    Text("Every external SOP the app implements, at the exact edition verified — with a periodic re-check so compliance is maintained, not just achieved once. Checks are on-device reminders; re-verification is a human act against the governing body's current text.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let due = ComplianceBoard.due(now: Date(), overrides: overrides)
                if !due.isEmpty {
                    Label("\(due.count) SOP(s) due for periodic re-verification.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                }
                Button { copyBoard() } label: { Label("Copy board as hardcopy", systemImage: "doc.on.doc") }
                    .guidance(GuidanceTip("Copy board",
                                          what: "Copies the whole board as a markdown table — the compliance evidence you can hand to anyone."))
                VStack(spacing: 10) {
                    ForEach(ComplianceBoard.records) { r in row(r) }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Compliance Board")
    }

    private func row(_ r: SOPRecord) -> some View {
        let verified = overrides[r.id] ?? r.verifiedOn
        let effective = SOPRecord(id: r.id, title: r.title, governingBody: r.governingBody,
                                  editionImplemented: r.editionImplemented, implementedIn: r.implementedIn,
                                  verifiedOn: verified, reviewIntervalDays: r.reviewIntervalDays)
        let isDue = effective.isDue(now: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.title).font(.headline)
                Spacer()
                Label(isDue ? "Review due" : "Current",
                      systemImage: isDue ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDue ? Color.orange : Color.green)
            }
            Text("\(r.governingBody) — \(r.editionImplemented)")
                .font(.callout).foregroundStyle(.secondary)
            Text("Enforced in: \(r.implementedIn)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Verified \(verified) · re-check every \(r.reviewIntervalDays) days")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Mark reviewed today") { markReviewed(r.id) }
                    .controlSize(.small)
                    .guidance(GuidanceTip("Mark reviewed",
                                          what: "Records that you checked the governing body's current text today and the app's procedure still matches it. Stored on-device with the date."))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func copyBoard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ComplianceBoard.markdown(now: Date(), overrides: overrides), forType: .string)
        #endif
    }
}

#if DEBUG
#Preview("Compliance Board") { ComplianceBoardView().frame(width: 1000, height: 720) }
#endif
