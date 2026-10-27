//
//  FactCheckMemo.swift
//  Kalsmritikosh
//
//  PERSONA STUDIO #5 (Journalist) — the pre-publication fact-check memo +
//  right-of-reply log: the newsroom deliverable an editor (and a media lawyer)
//  reviews before a contested story runs. The real disciplines, enforced:
//  every claim carries a verification status with its sources and corroboration
//  (a single source is a lead, not a fact); every person facing a serious claim
//  is offered a fair right of reply with a deadline; what isn't verified is
//  labelled ALLEGED in copy, never stated as fact; and a corrections path exists.
//
//  Pure Codable model + pure hardcopy renderer; persists on-device as JSON.
//

import Foundation

public nonisolated enum ClaimVerification: String, Codable, Sendable, CaseIterable, Equatable {
    case verified, partiallyVerified, unverified, disputed
    public var label: String {
        switch self {
        case .verified: return "Verified"
        case .partiallyVerified: return "Partially verified"
        case .unverified: return "Unverified"
        case .disputed: return "Disputed"
        }
    }
    /// Anything short of verified must be framed as alleged/unconfirmed in copy.
    public var mustBeLabelledAlleged: Bool { self != .verified }
}

public struct JClaim: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String = ""
    public var status: ClaimVerification?
    public var sources: String = ""          // who/what supports it
    public var corroboration: String = ""    // independent corroboration, or its absence
    /// Final brief §3.6: whether the claim is adverse to someone, and to whom — each named subject
    /// is owed a reply on THIS claim (optional so earlier memos open).
    public var adverse: Bool?
    public var affectedSubjects: [String]?
    public init(text: String = "") { self.text = text }
    public var isComplete: Bool { !text.trimmed.isEmpty && status != nil && !sources.trimmed.isEmpty }
    /// The claim needs a reply: marked adverse, or (memos without the mark) short of verified.
    var needsReply: Bool { adverse ?? (status?.mustBeLabelledAlleged == true) }
}

public struct ReplyEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var subject: String = ""          // the person/org facing the claim
    public var claimSummary: String = ""     // what was put to them
    public var contactedDate: String = ""    // yyyy-MM-dd
    public var method: String = ""           // email / phone / letter
    public var deadline: String = ""
    public var response: String = ""         // their answer, or "no response by deadline"
    /// The claims this reply put to the subject (final brief §3.6).
    public var claimIDs: [UUID]?
    /// How the story treats the reply (quoted, summarised, not used and why).
    public var editorialTreatment: String?
    public init() {}
    public var isComplete: Bool {
        !subject.trimmed.isEmpty && !claimSummary.trimmed.isEmpty && !contactedDate.trimmed.isEmpty
    }
}

public struct FactCheckMemo: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?
    /// A2 — where each filled field came from (case evidence or investigator entry).
    public var provenance: StudioProvenance?

    // Stage 1 — Story.
    public var premise: String = ""          // what the story alleges, in one paragraph
    public var reporter: String = ""
    public var editor: String = ""

    // Stage 2 — Claims.
    public var claims: [JClaim] = []

    // Stage 3 — Right of reply.
    public var replies: [ReplyEntry] = []

    // Stage 4 — Pre-publication checks.
    public var allegedLabellingConfirmed = false   // unverified/disputed framed as alleged in copy
    public var correctionsPathConfirmed = false    // a way to correct the record exists

    public init(title: String, now: Date) {
        self.title = title; self.createdAt = now; self.updatedAt = now
    }

    public enum Stage: Int, CaseIterable, Sendable {
        case story, claims, reply, memo
        public var title: String {
            switch self {
            case .story: return "Story"
            case .claims: return "Claims"
            case .reply: return "Right of reply"
            case .memo: return "Memo"
            }
        }
        public var systemImage: String {
            switch self {
            case .story: return "newspaper"
            case .claims: return "checkmark.bubble"
            case .reply: return "arrowshape.turn.up.left"
            case .memo: return "doc.richtext"
            }
        }
    }

    public func isComplete(_ stage: Stage) -> Bool {
        switch stage {
        case .story:  return !premise.trimmed.isEmpty && !reporter.trimmed.isEmpty
        case .claims: return !claims.isEmpty && claims.allSatisfy(\.isComplete)
        case .reply:
            return replyGaps.isEmpty
        case .memo:   return allegedLabellingConfirmed && correctionsPathConfirmed
        }
    }
    public var completionFraction: Double {
        Double(Stage.allCases.filter { isComplete($0) }.count) / Double(Stage.allCases.count)
    }

    /// Every adverse claim and every subject it affects, without a complete reply entry that put
    /// THAT claim to THAT subject ("claim 3 → Deputy Mayor's office"). A claim that names no
    /// subject yet is itself a gap. One unrelated reply no longer satisfies the stage.
    public var replyGaps: [String] {
        var gaps: [String] = []
        let linked = replies.contains { $0.claimIDs != nil }
        for (i, c) in claims.enumerated() where c.needsReply {
            if !linked && c.affectedSubjects == nil {
                // A memo from before linking: the old rule (a complete reply exists) still applies.
                if replies.isEmpty || !replies.allSatisfy(\.isComplete) { gaps.append("claim \(i + 1): no complete reply entry") }
                continue
            }
            let subjects = (c.affectedSubjects ?? []).map { $0.trimmed }.filter { !$0.isEmpty }
            if subjects.isEmpty { gaps.append("claim \(i + 1): no affected subject named"); continue }
            for subject in subjects {
                let ok = replies.contains { r in
                    r.isComplete && (r.claimIDs ?? []).contains(c.id) && r.subject.trimmed.lowercased() == subject.lowercased()
                }
                if !ok { gaps.append("claim \(i + 1) → \(subject): no reply that put this claim to them") }
            }
        }
        return gaps
    }

    /// Worked example — a procurement story with one verified and one disputed claim.
    public static func sample(now: Date) -> FactCheckMemo {
        var m = FactCheckMemo(title: "City procurement story — pre-pub check", now: now)
        m.premise = "The story alleges the city awarded a $2.1M roadworks contract to a firm part-owned by the deputy mayor's brother, without competitive tender."
        m.reporter = "J. Reporter"; m.editor = "E. Editor"
        var c1 = JClaim(text: "The contract was awarded without competitive tender.")
        c1.status = .verified
        c1.sources = "Council minutes 2026-03-12 (p.4); procurement register export"
        c1.corroboration = "Two independent documentary sources; confirmed by a council officer on record."
        var c2 = JClaim(text: "The deputy mayor's brother part-owns the winning firm.")
        c2.status = .verified
        c2.sources = "Companies register filing (director/shareholder list)"
        c2.corroboration = "Registry document; identity confirmed against birth records."
        var c3 = JClaim(text: "The deputy mayor personally intervened to steer the award.")
        c3.status = .disputed
        c3.sources = "One former procurement officer (anonymous)"
        c3.corroboration = "Single source; no documentary support located; the deputy mayor denies it."
        c2.adverse = true; c2.affectedSubjects = ["Winning firm (director)"]
        c3.adverse = true; c3.affectedSubjects = ["Deputy Mayor's office"]
        c1.adverse = true; c1.affectedSubjects = ["Deputy Mayor's office", "Winning firm (director)"]
        m.claims = [c1, c2, c3]
        var r1 = ReplyEntry()
        r1.subject = "Deputy Mayor's office"
        r1.claimSummary = "All three claims, in full, including the intervention allegation."
        r1.contactedDate = "2026-05-02"; r1.method = "Email + phone"; r1.deadline = "2026-05-06 17:00"
        r1.response = "Statement received 2026-05-05: denies intervention; notes the tender exemption was approved by committee."
        r1.claimIDs = [c1.id, c3.id]
        r1.editorialTreatment = "Denial quoted in paragraph 6, beside the intervention claim."
        var r2 = ReplyEntry()
        r2.subject = "Winning firm (director)"
        r2.claimSummary = "Ownership and the no-tender award."
        r2.contactedDate = "2026-05-02"; r2.method = "Email"; r2.deadline = "2026-05-06 17:00"
        r2.response = "No response by deadline."
        r2.claimIDs = [c1.id, c2.id]
        r2.editorialTreatment = "Story states the firm did not respond by the deadline."
        m.replies = [r1, r2]
        m.allegedLabellingConfirmed = true
        m.correctionsPathConfirmed = true
        StudioAudit.record(&m.history, "Worked example created", at: now)
        return m
    }
}

// MARK: - The hardcopy-faithful renderer

public enum FactCheckMemoRenderer {

    public static func markdown(_ m: FactCheckMemo, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Pre-publication Fact-Check Memo — \(m.title.trimmed.isEmpty ? "Untitled" : m.title)\n\n"
        out += "**Reporter:** \(m.reporter.orDashJ) · **Editor:** \(m.editor.orDashJ) · **Date:** \(df.string(from: generatedAt))\n\n---\n\n"

        out += "## 1. Story premise\n\n\(m.premise.trimmed.isEmpty ? "_Not stated._" : m.premise)\n\n"

        // 2. Claim-by-claim fact check.
        out += "## 2. Claim-by-claim fact check\n\n"
        out += "| # | Claim | Status | Sources | Corroboration |\n|---|---|---|---|---|\n"
        for (i, c) in m.claims.enumerated() {
            out += "| \(i + 1) | \(c.text.orDashJ) | **\(c.status?.label ?? "—")** | \(c.sources.orDashJ) | \(c.corroboration.orDashJ) |\n"
        }
        out += "\n_\(JournalisticVerification.disciplineNote)_\n\n"

        // 3. Right-of-reply log.
        out += "## 3. Right-of-reply log\n\n"
        if m.replies.isEmpty { out += "_No reply entries — no claim short of verified._\n\n" }
        else {
            out += "| Subject | Claims put | What was put to them | Contacted | Method | Deadline | Response | Treatment in the story |\n|---|---|---|---|---|---|---|---|\n"
            for r in m.replies {
                let nums = (r.claimIDs ?? []).compactMap { id in m.claims.firstIndex { $0.id == id }.map { "\($0 + 1)" } }
                out += "| \(r.subject.orDashJ) | \(nums.isEmpty ? "—" : nums.joined(separator: ", ")) | \(r.claimSummary.orDashJ) | \(r.contactedDate.orDashJ) | \(r.method.orDashJ) | \(r.deadline.orDashJ) | \(r.response.orDashJ) | \((r.editorialTreatment ?? "").orDashJ) |\n"
            }
            out += "\n_No response is not an admission._\n\n"
        }
        let gaps = m.replyGaps
        if !gaps.isEmpty { out += "**Right of reply not yet complete:** \(gaps.joined(separator: "; ")).\n\n" }

        // 4. Copy flags — what must run as ALLEGED.
        let mustFlag = m.claims.filter { $0.status?.mustBeLabelledAlleged == true }
        out += "## 4. Copy flags — run as alleged, not fact\n\n"
        if mustFlag.isEmpty { out += "_None — every claim is verified._\n\n" }
        else {
            for c in mustFlag { out += "- **[\(c.status?.label ?? "—")]** \(c.text)\n" }
            out += "\n"
        }

        // 5. Pre-publication checks.
        out += "## 5. Pre-publication checks\n\n"
        out += "- Unverified/disputed claims framed as alleged in copy: **\(m.allegedLabellingConfirmed ? "Yes" : "No")**\n"
        out += "- A corrections path exists post-publication: **\(m.correctionsPathConfirmed ? "Yes" : "No")**\n\n"

        out += "---\n\nPrepared by **\(m.reporter.orDashJ)** · Reviewed by **\(m.editor.orDashJ)**\n"
        out += StudioExportGate.provenanceAppendix(m.gateValues, provenance: m.provenance)
        out += StudioAudit.appendix(m.history)
        return out
    }
}

private extension String {
    var orDashJ: String { trimmed.isEmpty ? "—" : self }
}
