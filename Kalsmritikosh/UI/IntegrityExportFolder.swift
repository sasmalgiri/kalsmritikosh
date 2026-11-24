//
//  IntegrityExportFolder.swift
//  Kalsmritikosh
//
//  ALCOA ALC-13 (owner 2026-11-24) — where the data integrity report is written: a folder the person chooses (a folder,
//  so the certification files can sit beside the report in the sandbox), and the receipt line afterwards.
//

import AppKit

@MainActor
enum IntegrityExportFolder {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export the report here"
        panel.message = "The data integrity report (archival PDF, JSON and the evidence files' manifest) is written into a new folder here."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func line(_ out: CaseIntegrityReport.Exported) -> String {
        if out.encrypted {
            return "Exported one encrypted ZIP (\(out.files.first?.lastPathComponent ?? "")). " + EncryptedZIP.viewerNote
        }
        return "Exported \(out.files.count) files into “\(out.files.first?.deletingLastPathComponent().lastPathComponent ?? "")”, \(out.sidecarsWritten) with a certification beside it. "
            + ArchivalPDF.statement
    }
}
