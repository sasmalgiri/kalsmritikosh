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
    public init(text: String = "") { self.text = text }
    public var isComplete: Bool { !text.trimmed.isEmpty && status != nil && !sources.trimmed.isEmpty }
}

public struct ReplyEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var subject: String = ""          // the person/org facing the claim
    public var claimSummary: String = ""     // what was put to them
    public var contactedDate: String = ""    // yyyy-MM-dd
    public var method: String = ""           // email / phone / letter
    public var deadline: String = ""
    public var response: String = ""         // their answer, or "no response by deadline"
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
            // Every DISPUTED or serious unverified claim's subject deserves a reply
            // entry; structurally we require at least one complete entry whenever
            // any claim is short of verified.
            let needsReply = claims.contains { $0.status?.mustBeLabelledAlleged == true }
            return needsReply ? (!replies.isEmpty && replies.allSatisfy(\.isComplete)) : true
        case .memo:   return allegedLabellingConfirmed && correctionsPathConfirmed
        }
    }
    public var completionFraction: Double {
        Double(Stage.allCases.filter { isComplete($0) }.count) / Double(Stage.allCases.count)
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
        m.claims = [c1, c2, c3]
        var r1 = ReplyEntry()
        r1.subject = "Deputy Mayor's office"
        r1.claimSummary = "All three claims, in full, including the intervention allegation."
        r1.contactedDate = "2026-05-02"; r1.method = "Email + phone"; r1.deadline = "2026-05-06 17:00"
        r1.response = "Statement received 2026-05-05: denies intervention; notes the tender exemption was approved by committee."
        var r2 = ReplyEntry()
        r2.subject = "Winning firm (director)"
        r2.claimSummary = "Ownership and the no-tender award."
        r2.contactedDate = "2026-05-02"; r2.method = "Email"; r2.deadline = "2026-05-06 17:00"
        r2.response = "No response by deadline."
        m.replies = [r1, r2]
        m.allegedLabellingConfirmed = true
        m.correctionsPathConfirmed = true
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
            out += "| Subject | What was put to them | Contacted | Method | Deadline | Response |\n|---|---|---|---|---|---|\n"
            for r in m.replies {
                out += "| \(r.subject.orDashJ) | \(r.claimSummary.orDashJ) | \(r.contactedDate.orDashJ) | \(r.method.orDashJ) | \(r.deadline.orDashJ) | \(r.response.orDashJ) |\n"
            }
            out += "\n"
        }

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
        return out
    }
}

private extension String {
    var orDashJ: String { trimmed.isEmpty ? "—" : self }
}
