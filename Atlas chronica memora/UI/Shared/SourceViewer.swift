//
//  SourceViewer.swift
//  Atlas chronica memora
//
//  Opens the original source file in Finder / Quick Look so the user
//  can verify cited evidence. M5 swaps in an embedded PDFKit / text
//  viewer that highlights the cited character range.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct SourceViewer: View {
    let url: URL
    public init(url: URL) { self.url = url }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text(url.lastPathComponent).font(.title3)
            Text(url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack {
                Button("Reveal in Finder") { reveal() }
                Button("Open") { open() }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 240)
    }

    private func reveal() {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
    private func open() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

public struct EvidenceViewer: View {
    let citation: VerifiedAnswer.Citation
    public init(citation: VerifiedAnswer.Citation) { self.citation = citation }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.bubble")
                Text("Evidence").font(.headline)
                Spacer()
            }
            Text(citation.snippet)
                .font(.callout)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            Text("Source KO: \(citation.objectID.uuidString.prefix(8))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 460, minHeight: 220)
    }
}
