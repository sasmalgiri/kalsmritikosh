//
//  ReceiptVerifierView.swift
//  Kalsmritikosh
//
//  The other half of verifiable receipts: open a receipt .json exported by
//  Kalsmritikosh (on any machine) and re-check its hash chain. Fully offline.
//
//  Honest scope (conformance roadmap 1.0.x-B): the chain is UNKEYED SHA-256, so
//  a pass proves internal consistency — the entries match the seal — NOT origin
//  or authorship: anyone who edits a receipt can recompute a valid chain. The
//  wording below claims exactly that and no more. Signed conformance seals
//  (ConformanceSeal, ECDSA P-256) carry the authenticity claim instead.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct ReceiptVerifierView: View {
    @State private var receipt: SealedReceipt?
    @State private var isValid: Bool?
    @State private var filename: String?
    @State private var parseError = false
    @State private var showOpen = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify a receipt")
                .font(.title3.bold())
            Text("Open a receipt \u{2019}.json\u{2019} exported by Kalsmritikosh — from this Mac or anyone else\u{2019}s. We recompute its hash chain and tell you whether the entries are internally consistent with the seal. This detects accidental corruption and casual edits; it does not prove who produced the receipt. No internet needed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                parseError = false
                showOpen = true
            } label: {
                Label("Open receipt…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .fileImporter(isPresented: $showOpen,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { openReceipt(url) }
            }

            if parseError {
                Label("That file isn\u{2019}t a Kalsmritikosh receipt.", systemImage: "xmark.octagon")
                    .foregroundStyle(.orange)
            }

            if let receipt, let isValid {
                resultBanner(isValid: isValid, receipt: receipt)
                entryList(receipt)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle("Verify Receipt")
    }

    private func resultBanner(isValid: Bool, receipt: SealedReceipt) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isValid ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(isValid ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(isValid ? "Integrity check passed — hash chain is internally consistent"
                             : "Integrity check FAILED — the chain does not match the seal")
                    .font(.headline)
                    .foregroundStyle(isValid ? .green : .red)
                Text(receipt.title).font(.caption).foregroundStyle(.secondary)
                if let filename { Text(filename).font(.caption2).foregroundStyle(.tertiary) }
                Text("Seal: \(receipt.seal.prefix(24))…").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isValid ? Color.green : Color.red).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func entryList(_ receipt: SealedReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(receipt.entries.count) claim(s)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            List(receipt.entries) { e in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(e.index + 1). \(e.claim)").font(.callout.weight(.medium))
                    Text(e.source).font(.caption2).foregroundStyle(.secondary)
                    Text(e.passage).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                    Text("passage sha256: \(e.passageHash.prefix(24))…")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }

    private func openReceipt(_ url: URL) {
        // .fileImporter hands back a security-scoped URL — start access to read it.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            receipt = nil; isValid = nil; filename = nil; parseError = true
            return
        }
        guard let parsed = VerifiableReceipt.parse(data) else {
            receipt = nil; isValid = nil; filename = nil; parseError = true
            return
        }
        receipt = parsed
        isValid = VerifiableReceipt.verify(parsed)
        filename = url.lastPathComponent
    }
}
