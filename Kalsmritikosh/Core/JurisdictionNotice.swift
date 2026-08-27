//
//  JurisdictionNotice.swift
//  Kalsmritikosh
//
//  D-7 (completion instructions) — jurisdiction disclosure for the studios
//  whose templates cite a NAMED national instrument (FRCP, NAIC/NICB, ACAS/
//  EEOC, FTC Guides, GPS). The procedures are jurisdiction-neutral; the
//  citations are not — the user must adapt them locally and record an
//  authorized deviation for any rule that does not apply where they practise.
//
//  Deliberately a NEW file, not part of LegalNotice.swift: LegalNotice is one
//  of the eight CORE_FILES embedded into the generated standalone verifier
//  (scripts/generate-kalverify.sh), and these strings have no role in bundle
//  verification — keeping them here leaves kalverify.swift byte-identical.
//

import Foundation

public nonisolated enum JurisdictionNotice {
    /// Studio-level line naming the instrument a template follows.
    public static func studio(instrument: String) -> String {
        "This workflow follows \(instrument). The procedure is jurisdiction-neutral; the citation is not — adapt it to your jurisdiction, and record an authorized deviation for any rule that does not apply where you practise. The SOP register (Settings → Compliance Board) maps each workflow to US, UK/Commonwealth, EU, Indian and international equivalents."
    }

    /// One line printed on every studio hardcopy.
    public static let hardcopy =
        "Cited instruments are those named in this workflow (see the SOP register in the app). Procedures are jurisdiction-neutral; citations may need adapting locally. Any authorized deviation is recorded on the conformance certificate."
}
