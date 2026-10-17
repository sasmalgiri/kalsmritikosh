//
//  PDFMarksBar.swift
//  Kalsmritikosh
//
//  X-3 — the strip under a PDF in the source viewer: highlight / underline / strike out the
//  selected text, add a note, choose a colour, list and remove marks, export an annotated
//  copy. The original PDF is never written.
//

#if canImport(PDFKit)
import SwiftUI
import AppKit
import os

struct PDFMarksBar: View {
    @Bindable var controller: PDFMarksController
    let original: URL
    @State private var showList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach([PDFMarkKind.highlight, .underline, .strikeout]) { kind in
                    Button(kind.label) { Task { await controller.markSelection(kind) } }
                        .help("\(kind.label) the selected text")
                }
                Picker("Colour", selection: $controller.color) {
                    ForEach(PDFMarksController.colors, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .frame(width: 130)
                TextField("Note (optional for marks)", text: $controller.noteText)
                    .onSubmit { Task { await controller.addNote() } }
                Button("Add note") { Task { await controller.addNote() } }
                Button {
                    showList.toggle()
                } label: { Label("Marks (\(controller.marks.count))", systemImage: "list.bullet") }
                .popover(isPresented: $showList) { list }
                Button("Export annotated copy…") { export() }
                    .disabled(controller.marks.isEmpty)
            }
            .controlSize(.small)
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marks on this PDF").font(.headline)
            Text("Kept beside the PDF; the file itself is not changed.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.marks) { m in
                        HStack(alignment: .top) {
                            Rectangle().fill(Color(nsColor: PDFMarksController.nsColor(m.color, alpha: 1))).frame(width: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Page \(m.page + 1) · \(m.kind.label)").font(.caption.weight(.semibold))
                                if let q = m.quote, !q.isEmpty { Text("\u{201C}\(q)\u{201D}").font(.caption).lineLimit(2) }
                                if let c = m.contents, !c.isEmpty { Text(c).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Remove") { Task { await controller.remove(m) } }.buttonStyle(.borderless).font(.caption2)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding()
        .frame(width: 360)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose where to save the annotated copy and the list of marks."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let r = try PDFMarksController.exportAnnotatedCopy(of: original, marks: controller.marks, into: folder)
            controller.message = "Saved \u{201C}\(r.pdf.lastPathComponent)\u{201D} with \(r.marks) mark\(r.marks == 1 ? "" : "s")"
                + (r.originalUnchanged ? "; the original is unchanged." : ". Warning: the original's bytes differ from before the export.")
            NSWorkspace.shared.activateFileViewerSelecting([r.pdf])
        } catch {
            KalsmritikoshLog.app.error("Annotated export failed: \(error.localizedDescription, privacy: .public)")
            controller.message = error.localizedDescription
        }
    }
}
#endif
