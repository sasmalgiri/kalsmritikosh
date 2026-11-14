//
//  TimelineExport.swift
//  Kalsmritikosh
//
//  The Timeline screen's own export: exactly the events the screen shows (its scope,
//  without excluded events), oldest first, each with the date as shown — the same
//  precision phrase and the "~" mark for an untrusted date — its source file, and both
//  confidences. The Export Center's timeline subject reads every event in the ledger;
//  this one matches what the investigator is looking at.
//

import Foundation

public nonisolated enum TimelineExport {

    public static let columns = ["Date", "Date precision", "Kind", "Event", "Summary", "Source",
                                 "Event confidence", "Date confidence"]

    /// - Parameters:
    ///   - events: the events on screen (excluded events must not be passed).
    ///   - scope: the scope label shown in the title ("Global", "Person: Maria Lopez").
    ///   - dateLabel: the screen's date label for an event.
    ///   - sourceNames: source file name per knowledge-object id; a missing name is written as "(source not found)".
    public static func table(events: [Event], scope: String, dateLabel: (Event) -> String,
                             sourceNames: [UUID: String]) -> LedgerExportTable {
        var t = LedgerExportTable(title: "Timeline — \(scope)", columns: columns, rows: [], sources: [], passages: [])
        for e in events.sorted(by: { $0.date < $1.date }) {
            let source = sourceNames[e.sourceObjectID] ?? "(source not found)"
            let summary = e.summary ?? ""
            t.rows.append([dateLabel(e), e.datePrecision.displayName, e.kind.rawValue, e.title, summary, source,
                           percent(e.confidence.value), percent(e.dateConfidence)])
            t.sources.append(source)
            t.passages.append(summary.isEmpty ? e.title : summary)
        }
        t.originals = Array(repeating: nil, count: t.rows.count)
        return t
    }

    /// The rendered text for a text format (CSV or Markdown), before the protected-identity gate.
    public static func render(_ t: LedgerExportTable, format: LedgerExportFormat) -> String {
        switch format {
        case .markdown:
            return LedgerExportRenderer.markdown(t)
                + "\n_\(t.rows.count) event\(t.rows.count == 1 ? "" : "s"), oldest first. A date marked ~ is approximate. "
                + "Read every event against its source before relying on it._\n"
        default:
            return LedgerExportRenderer.csv(t)
        }
    }

    static func percent(_ v: Double) -> String { "\(Int((max(0, min(1, v)) * 100).rounded())) %" }
}
