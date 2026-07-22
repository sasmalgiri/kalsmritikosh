//
//  ReportEditorView.swift
//  Kalsmritikosh
//
//  EXP-001 — the claim/evidence report editor. Presents a WorkProduct section by section;
//  every claim shows its epistemic status and its supporting/contradicting citation counts,
//  and the editor flags any section whose claims lack supporting evidence — enforcing the
//  "every section has claims/assets" contract before the report can be exported (EXP-002
//  validates the package). Presentational: the parent owns the WorkProduct.
//

import SwiftUI

public struct ReportEditorView: View {
    private let product: WorkProduct
    public init(workProduct: WorkProduct) { self.product = workProduct }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(product.sections) { section in sectionView(section) }
                    if let disclaimer = product.disclaimer, !disclaimer.isEmpty {
                        Text(disclaimer).font(.caption2).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(14)
            }
        }
    }

    private var header: some View {
        let unsupported = product.sections.flatMap(\.claims).filter { $0.supporting.isEmpty }.count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.title).font(.headline)
                Text("\(product.template.displayName) · \(product.sections.count) section(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if unsupported > 0 {
                Label("\(unsupported) claim(s) need evidence", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else {
                Label("Every claim cited", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
        }
        .padding(12)
    }

    private func sectionView(_ section: WorkProductSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title).font(.title3.weight(.semibold))
                Spacer()
                if section.claims.isEmpty {
                    Text("empty").font(.caption2).foregroundStyle(.orange)
                }
            }
            ForEach(section.preamble, id: \.self) { p in
                Text(p).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(section.claims) { claim in claimRow(claim) }
        }
    }

    private func claimRow(_ claim: WorkProductClaim) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(claim.text).font(.callout)
            HStack(spacing: 10) {
                Text(claim.status.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Label("\(claim.supporting.count)", systemImage: "checkmark.circle")
                    .font(.caption2).foregroundStyle(claim.supporting.isEmpty ? .orange : .green)
                if !claim.contradicting.isEmpty {
                    Label("\(claim.contradicting.count)", systemImage: "xmark.circle")
                        .font(.caption2).foregroundStyle(.red)
                }
                if claim.supporting.isEmpty {
                    Text("no supporting evidence").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.05)))
    }
}
