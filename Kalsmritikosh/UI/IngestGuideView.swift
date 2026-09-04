//
//  IngestGuideView.swift
//  Kalsmritikosh
//
//  A reference the user can open to see, per file type, how long
//  ingesting 100 MB takes in each of the three system modes. Makes the
//  cost of scanned PDFs / audio (OCR + ASR) and of the Full-LLM
//  architecture visible up front so people can predict + choose.
//

import SwiftUI

public struct IngestGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let estimator = IngestEstimator()
    /// Size the guide is computed for.
    private let referenceMB: Double = 100

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    modeHeaderRow
                    ForEach(FileClass.allCases) { cls in
                        fileRow(cls)
                    }
                    footnote
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .background(AuroraBackdrop(intensity: 0.4))
            .navigationTitle("Ingestion time · per 100 MB")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How long to ingest 100 MB")
                .font(Theme.display(22, .bold))
            Text("Estimated wall-clock time for 100 MB of a single file type, in each system mode. Scanned PDFs and images cost far more (OCR). Audio/video is catalogued at ingest, not transcribed — on-demand transcription in Transcripts is a separate, later cost.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            basisLine
        }
    }

    /// States clearly whose machine the numbers reflect: a reference
    /// configuration until this Mac has been measured, then this Mac.
    private var basisLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: CalibrationStore.isCalibrated ? "checkmark.seal.fill" : "gauge.with.dots.needle.33percent")
                .foregroundStyle(CalibrationStore.isCalibrated ? .green : .orange)
                .imageScale(.small)
            Text(CalibrationStore.isCalibrated
                 ? "Calibrated to THIS Mac (\(CalibrationStore.sampleCount) LLM calls, \(String(format: "%.1f", IngestEstimator.effectiveSecondsPerLLMCall))s/call)."  // jargon-ok: developer diagnostics
                 : "These figures assume a \(IngestEstimator.referenceMachineDescription) — NOT your Mac. After your first LLM-heavy ingest they self-calibrate to this Mac.")  // jargon-ok: developer diagnostics
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var modeHeaderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All times below are per 100 MB of that file type")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.brand)
            HStack {
                Text("File type · /100 MB").font(.caption.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
                Text("Ledger").font(.caption.weight(.bold)).foregroundStyle(.green).frame(width: 74, alignment: .trailing)
                Text("Hot/W/C").font(.caption.weight(.bold)).foregroundStyle(.orange).frame(width: 74, alignment: .trailing)
                Text("Full AI").font(.caption.weight(.bold)).foregroundStyle(Theme.brand).frame(width: 74, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func fileRow(_ cls: FileClass) -> some View {
        let ledger = estimator.estimate(sizeMB: referenceMB, fileClass: cls, mode: .ledgerEventDriven)
        let hwc = estimator.estimate(sizeMB: referenceMB, fileClass: cls, mode: .hotWarmCold)
        let full = estimator.estimate(sizeMB: referenceMB, fileClass: cls, mode: .fullLLM)
        HStack(spacing: 6) {
            Label {
                Text(cls.label).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: cls.systemImage).foregroundStyle(Theme.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(ledger.totalSeconds, .green)
            cell(hwc.totalSeconds, .orange)
            cell(full.totalSeconds, Theme.brand)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardSurface(cornerRadius: 10)
    }

    private func cell(_ seconds: Double, _ tint: Color) -> some View {
        Text(IngestEstimator.humanDuration(seconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
            .frame(width: 74, alignment: .trailing)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why the difference")
                .font(.caption.weight(.semibold))
            Text("• Ledger mode: rule-based extraction + one document-card AI call per file (its first chunk); time is dominated by parsing/OCR/transcription.\n• Hot/Warm/Cold: one document-card call per file + deep AI only for the important (hot) slice.\n• Full AI runs an AI pass over every slice of text, so text-heavy archives balloon into hours.\n• OCR (scanned PDF, images) is expensive in every mode because the text has to be recovered first. Audio/video is NOT transcribed during ingest — it is catalogued and preserved; transcription runs only on demand (Transcripts screen, on-device).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
