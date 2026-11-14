//
//  CaseMapExportRoutes.swift
//  Kalsmritikosh
//
//  Living case map, M8 (plan §9): the ONLY place the case map's content can leave the app — file, clipboard
//  or print — and every entry point takes a package CaseOutputService prepared (frozen, revalidated,
//  protected) and releases it through CaseOutputService.write / release, which re-check at the moment of
//  release and record what left. There is no screenshot, image or copy command on the canvas: the map views
//  never render themselves to an image, the pasteboard or the printer (CaseMapHistoryTests checks the sources).
//

import AppKit
import Foundation
import os

@MainActor
enum CaseMapExportRoutes {

    /// Ask where to save, then prepare and write. A cancelled panel prepares, writes and records nothing.
    static func exportFile(outputs: CaseOutputService, request: CaseMapExportRequest, format: CaseMapExportFormat, actor: String) async -> String {
        let panel = NSSavePanel()
        let base = "Case map — \(request.projection.title)".replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = base + (format == .pdf ? ".pdf" : format == .png ? ".png" : " — relationships.csv")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return "Not exported (cancelled). Nothing was recorded." }
        do {
            let pkg = try await outputs.prepareMap(request, format: format, route: .file, actor: actor)
            var summary = await write(outputs, pkg, to: url)
            // A picture alone cannot be traced to its sources: a PNG goes with its table.
            if format == .png {
                let csvPanel = NSSavePanel()
                csvPanel.nameFieldStringValue = base + " — relationships.csv"
                csvPanel.message = "Save the relationship and evidence table that goes with the image."
                if csvPanel.runModal() == .OK, let csvURL = csvPanel.url {
                    let table = try await outputs.prepareMap(request, format: .csv, route: .file, actor: actor)
                    summary += " " + (await write(outputs, table, to: csvURL))
                } else {
                    summary += " The relationship table was not saved; the image alone does not show the sources — export the table too."
                }
            }
            return summary
        } catch {
            KalsmritikoshLog.ui.error("Case map export refused: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    /// Write a prepared package (authorised again at release, read back, recorded).
    static func write(_ outputs: CaseOutputService, _ pkg: CaseOutputPackage, to url: URL) async -> String {
        await outputs.write(pkg, to: url).summary
    }

    /// Copy the relationship and evidence table (the protected text), recorded as a clipboard release.
    static func copyTable(outputs: CaseOutputService, request: CaseMapExportRequest, actor: String) async -> String {
        do {
            let pkg = try await outputs.prepareMap(request, format: .csv, route: .clipboard, actor: actor)
            return await deliverToClipboard(outputs, pkg)
        } catch {
            KalsmritikoshLog.ui.error("Case map copy refused: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    static func deliverToClipboard(_ outputs: CaseOutputService, _ pkg: CaseOutputPackage) async -> String {
        let r = await outputs.release(pkg) { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true
        }
        return r.status == .released ? "Copied the relationship table. " + r.summary : r.summary
    }

    /// Print the relationship and evidence table, recorded only when it was printed (or saved from the preview).
    static func printTable(outputs: CaseOutputService, request: CaseMapExportRequest, actor: String) async -> String {
        do {
            let pkg = try await outputs.prepareMap(request, format: .csv, route: .print, actor: actor)
            return await deliverToPrinter(outputs, pkg, title: request.projection.title)
        } catch {
            KalsmritikoshLog.ui.error("Case map print refused: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    // MARK: S11 — reviewed case products (OUTPUT-01..05), each through CaseOutputService and written with `write`

    /// Ask where to save, then prepare (frozen, revalidated, protected) and write; a cancelled panel does nothing.
    static func saveProduct(name: String, message: String, outputs: CaseOutputService,
                            prepare: @escaping () async throws -> CaseOutputPackage) async -> String {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-")
        panel.message = message
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return "Not exported (cancelled). Nothing was recorded." }
        do {
            let pkg = try await prepare()
            return await write(outputs, pkg, to: url)
        } catch {
            KalsmritikoshLog.ui.error("Case product export refused: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    /// The portable read-only case package (one HTML file that runs no script and fetches nothing).
    static func exportPackage(outputs: CaseOutputService, caseID: UUID, title: String, selection: CasePackageSelection, actor: String,
                              service: CaseMapService) async -> String {
        await saveProduct(name: "Case package — \(title).html",
                          message: "A read-only package of the case: items, relationships, evidence, findings, open work and money, with what was left out.",
                          outputs: outputs) {
            try await outputs.preparePackage(caseID: caseID, selection: selection, actor: actor) { id in await service.load(caseID: id, generation: 0) }
        }
    }

    static func exportMoneyReport(outputs: CaseOutputService, caseID: UUID, title: String, actor: String) async -> String {
        await saveProduct(name: "Money — \(title).md", message: "The case's money report, as the report and the package show it.", outputs: outputs) {
            try await outputs.prepareMoneyReport(caseID: caseID, actor: actor)
        }
    }

    static func exportReviewRecord(outputs: CaseOutputService, review: CaseHistoryReviewService, caseID: UUID, title: String, actor: String) async -> String {
        await saveProduct(name: "Review record — \(title).md", message: "This review's own findings, authorship and chronology.", outputs: outputs) {
            try await outputs.prepareReviewRecord(caseID: caseID, review: review, actor: actor)
        }
    }

    static func exportBriefing(outputs: CaseOutputService, caseID: UUID, briefingID: UUID, title: String, actor: String, service: CaseMapService) async -> String {
        await saveProduct(name: "Briefing — \(title).md", message: "The briefing's steps (as frozen, or as the case is now).", outputs: outputs) {
            try await outputs.prepareBriefing(caseID: caseID, briefingID: briefingID, actor: actor) { id in await service.load(caseID: id, generation: 0) }
        }
    }

    /// S12 (ADAPT-06) — the case's structured exchange file (ime-case-exchange JSON v1) through the output door: the person's
    /// export permission, protected names, written, read back and recorded.
    static func exportExchange(outputs: CaseOutputService, file: CaseFileRepository, caseID: UUID, title: String, actor: String) async -> String {
        await saveProduct(name: "Exchange — \(title).json", message: "This case's questions, people, dated events, their sources and your links, in the documented exchange format.",
                          outputs: outputs) {
            let doc = try await file.exchangeDocument(caseID: caseID)
            let text = String(decoding: try CaseExchange.encode(doc), as: UTF8.self)
            let citations = doc.records.flatMap { r in r.sources.compactMap { s in UUID(uuidString: s.sourceVersionID).map { StudioEvidenceRef(sourceVersionID: $0, quote: s.quote) } } }
            return try await outputs.prepareText(caseID: caseID, kind: .structuredExchange, route: .file, actor: actor, citations: citations, text: text)
        }
    }

    static func deliverToPrinter(_ outputs: CaseOutputService, _ pkg: CaseOutputPackage, title: String) async -> String {
        let r = await outputs.release(pkg) { text in AppPrinting.run(text: text, jobTitle: "Case map — \(title)", fontSize: 9).released }
        return r.status == .released ? "Printed. " + r.summary : r.summary
    }
}
