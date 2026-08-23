//
//  PersonaDeliverables2.swift
//  Kalsmritikosh
//
//  PERSONA STUDIOS #6–#9 — the last four real-life deliverables:
//    Researcher      → PRISMA screening flow + extraction table + GRADE summary
//    Genealogist     → GPS proof argument (research log with nil results,
//                      analysis, conflict resolution, written conclusion)
//    Content Creator → publish package (claims checked, rights cleared,
//                      disclosures, corrections path)
//    Individual      → emergency / legacy binder (findability is the goal)
//  Each: pure Codable model with real-life stage gates + hardcopy renderer +
//  worked sample + the shared audit-trail history.
//

import Foundation

// MARK: - #6 Researcher — PRISMA / extraction / GRADE

public struct RSStudy: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var study: String = ""       // author, year
    public var design: String = ""
    public var sample: String = ""
    public var outcome: String = ""
    public var result: String = ""
    public var source: String = ""
    public init() {}
    public var isComplete: Bool { !study.trimmed.isEmpty && !result.trimmed.isEmpty }
}

public struct ResearchReview: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    public var question: String = ""            // fixed BEFORE screening (protocol)
    public var reviewer: String = ""
    // PRISMA counts + exclusion reasons.
    public var identified = 0, screened = 0, eligible = 0, included = 0
    public var exclusionReasons: String = ""
    public var studies: [RSStudy] = []
    public var synthesis: String = ""
    public var certainty: GRADECertainty?
    public var limitations: String = ""

    public init(title: String, now: Date) { self.title = title; createdAt = now; updatedAt = now }

    public enum Stage: Int, CaseIterable, Sendable {
        case protocolStage, screening, extraction, synthesis
        public var title: String {
            switch self {
            case .protocolStage: return "Protocol"
            case .screening: return "Screening (PRISMA)"
            case .extraction: return "Extraction"
            case .synthesis: return "Synthesis (GRADE)"
            }
        }
        public var systemImage: String {
            switch self {
            case .protocolStage: return "doc.badge.gearshape"
            case .screening: return "line.3.horizontal.decrease.circle"
            case .extraction: return "tablecells"
            case .synthesis: return "checkmark.seal"
            }
        }
    }
    public func isComplete(_ s: Stage) -> Bool {
        switch s {
        case .protocolStage: return !question.trimmed.isEmpty
        case .screening: return identified >= screened && screened >= eligible && eligible >= included
            && identified > 0 && !exclusionReasons.trimmed.isEmpty
        case .extraction: return !studies.isEmpty && studies.allSatisfy(\.isComplete) && studies.count == included
        case .synthesis: return !synthesis.trimmed.isEmpty && certainty != nil
        }
    }
    public var completionFraction: Double { Double(Stage.allCases.filter { isComplete($0) }.count) / 4 }

    public static func sample(now: Date) -> ResearchReview {
        var r = ResearchReview(title: "Remote work & productivity — rapid review", now: now)
        r.question = "Does remote work change measured productivity in knowledge workers (2019–2026)?"
        r.reviewer = "R. Researcher"
        r.identified = 412; r.screened = 380; r.eligible = 41; r.included = 2
        r.exclusionReasons = "Duplicates (32); off-topic (339); no productivity measure (24); no full text (15)."
        var s1 = RSStudy(); s1.study = "Bloom et al., 2015 ext. 2021"; s1.design = "RCT"; s1.sample = "16,000"; s1.outcome = "Calls handled"; s1.result = "+13% performance"; s1.source = "bloom-2021.pdf"
        var s2 = RSStudy(); s2.study = "Gibbs et al., 2023"; s2.design = "Panel"; s2.sample = "10,000"; s2.outcome = "Output/hour"; s2.result = "−8 to −19% productivity"; s2.source = "gibbs-2023.pdf"
        r.studies = [s1, s2]
        r.synthesis = "Findings conflict by task type: routine, individually-measurable work shows gains; collaborative knowledge work shows losses. The conflict is presented, not averaged; certainty is LOW given heterogeneity."
        r.certainty = .low
        r.limitations = "Two included studies; English-only; no meta-analysis performed."
        StudioAudit.record(&r.history, "Worked example created", at: now)
        return r
    }
}

public enum ResearchReviewRenderer {
    public static func markdown(_ r: ResearchReview, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Evidence Review — \(r.title.trimmed.isEmpty ? "Untitled" : r.title)\n\n"
        out += "**Reviewer:** \(r.reviewer.dash) · **Date:** \(df.string(from: generatedAt))\n\n---\n\n"
        out += "## 1. Question & protocol\n\n\(r.question.dashText)\n\n_The question and criteria were fixed before screening._\n\n"
        out += "## 2. Screening (PRISMA flow)\n\n"
        out += "Identification **\(r.identified)** → Screening **\(r.screened)** → Eligibility **\(r.eligible)** → **Included \(r.included)**\n\n"
        out += "**Exclusion reasons:** \(r.exclusionReasons.dash)\n\n"
        out += "## 3. Extraction (one row per included study)\n\n"
        out += "| Study | Design | Sample | Outcome | Result | Source |\n|---|---|---|---|---|---|\n"
        for s in r.studies { out += "| \(s.study.dash) | \(s.design.dash) | \(s.sample.dash) | \(s.outcome.dash) | \(s.result.dash) | \(s.source.dash) |\n" }
        out += "\n## 4. Synthesis & certainty (GRADE)\n\n\(r.synthesis.dashText)\n\n"
        out += "**Certainty of evidence: \(r.certainty?.label ?? "—")** — \(r.certainty?.detail ?? "")\n\n"
        if !r.limitations.trimmed.isEmpty { out += "**Limitations:** \(r.limitations)\n\n" }
        out += "---\n\nPrepared by **\(r.reviewer.dash)**\n"
        out += StudioAudit.appendix(r.history)
        return out
    }
}

// MARK: - #7 Genealogist — GPS proof argument

public struct GNSearch: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: String = ""
    public var repository: String = ""
    public var source: String = ""
    public var result: String = ""      // including NIL results — they count
    public init() {}
    public var isComplete: Bool { !repository.trimmed.isEmpty && !source.trimmed.isEmpty && !result.trimmed.isEmpty }
}

public struct ProofArgument: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    public var question: String = ""            // the genealogical question
    public var researcher: String = ""
    public var searches: [GNSearch] = []        // GPS 1 — reasonably exhaustive, nils logged
    public var analysis: String = ""            // GPS 3 — original/derivative, primary/secondary, correlation
    public var conflictResolution: String = ""  // GPS 4 — conflicts resolved with reasoning
    public var conclusion: String = ""          // GPS 5 — the written, soundly-reasoned conclusion
    public var citationsComplete = false        // GPS 2 — every fact reopens its source

    public init(title: String, now: Date) { self.title = title; createdAt = now; updatedAt = now }

    public enum Stage: Int, CaseIterable, Sendable {
        case question, research, analysis, proof
        public var title: String {
            switch self {
            case .question: return "Question"
            case .research: return "Research log"
            case .analysis: return "Analysis & conflicts"
            case .proof: return "Proof argument"
            }
        }
        public var systemImage: String {
            switch self {
            case .question: return "questionmark.circle"
            case .research: return "books.vertical"
            case .analysis: return "scalemass"
            case .proof: return "checkmark.seal"
            }
        }
    }
    public func isComplete(_ s: Stage) -> Bool {
        switch s {
        case .question: return !question.trimmed.isEmpty
        case .research: return !searches.isEmpty && searches.allSatisfy(\.isComplete)
        case .analysis: return !analysis.trimmed.isEmpty && !conflictResolution.trimmed.isEmpty
        case .proof: return !conclusion.trimmed.isEmpty && citationsComplete
        }
    }
    public var completionFraction: Double { Double(Stage.allCases.filter { isComplete($0) }.count) / 4 }

    public static func sample(now: Date) -> ProofArgument {
        var p = ProofArgument(title: "Who were the parents of Mary H. (b. ~1852, Ohio)?", now: now)
        p.question = "Identify the parents of Mary H., born about 1852 in Ohio, who married J. Smith in 1874."
        p.researcher = "G. Genealogist"
        var s1 = GNSearch(); s1.date = "2026-06-01"; s1.repository = "FamilySearch"; s1.source = "Ohio births & christenings index"; s1.result = "No entry for Mary H. 1850–1854 — NIL result logged."
        var s2 = GNSearch(); s2.date = "2026-06-03"; s2.repository = "County courthouse (digitized)"; s2.source = "1874 marriage record, Smith–H."; s2.result = "Marriage record names father 'A. H.'; original image saved."
        var s3 = GNSearch(); s3.date = "2026-06-05"; s3.repository = "NARA"; s3.source = "1860 federal census, Ohio"; s3.result = "Mary (8) enumerated in household of A. and C. H. — original image."
        p.searches = [s1, s2, s3]
        p.analysis = "The marriage record (original, primary information for the father's name) and the 1860 census (original, secondary for relationships) correlate: the same father's name, right age, right county."
        p.conflictResolution = "An online tree claims different parents, citing no source; the derivative, unsourced claim is rejected in favour of the original records, with reasoning stated."
        p.conclusion = "On the correlated original records, Mary H.'s parents were A. H. and C. H. of Ohio. The conclusion is written, cited, and the conflicting unsourced claim is resolved — the five GPS elements are addressed."
        p.citationsComplete = true
        StudioAudit.record(&p.history, "Worked example created", at: now)
        return p
    }
}

public enum ProofArgumentRenderer {
    public static func markdown(_ p: ProofArgument, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Proof Argument — \(p.title.trimmed.isEmpty ? "Untitled" : p.title)\n\n"
        out += "**Researcher:** \(p.researcher.dash) · **Date:** \(df.string(from: generatedAt))\n"
        out += "**Standard:** Genealogical Proof Standard (five elements).\n\n---\n\n"
        out += "## 1. Research question\n\n\(p.question.dashText)\n\n"
        out += "## 2. Research log (reasonably exhaustive — nil results logged)\n\n"
        out += "| Date | Repository | Source searched | Result |\n|---|---|---|---|\n"
        for s in p.searches { out += "| \(s.date.dash) | \(s.repository.dash) | \(s.source.dash) | \(s.result.dash) |\n" }
        out += "\n## 3. Analysis & correlation\n\n\(p.analysis.dashText)\n\n"
        out += "## 4. Resolution of conflicting evidence\n\n\(p.conflictResolution.dashText)\n\n"
        out += "## 5. Conclusion (written, soundly reasoned)\n\n\(p.conclusion.dashText)\n\n"
        out += "Citations complete — every fact reopens its source: **\(p.citationsComplete ? "Yes" : "No")**\n\n"
        out += "_\(GenealogicalProofStandard.disciplineNote)_\n\n---\n\nPrepared by **\(p.researcher.dash)**\n"
        out += StudioAudit.appendix(p.history)
        return out
    }
}

// MARK: - #8 Content Creator — publish package

public struct CCClaim: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String = ""
    public var checked = false
    public var source: String = ""
    public init() {}
    public var isComplete: Bool { !text.trimmed.isEmpty && checked && !source.trimmed.isEmpty }
}
public struct CCAsset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var asset: String = ""       // clip / image / quote / track
    public var rights: String = ""      // licence / permission / own work
    public init() {}
    public var isComplete: Bool { !asset.trimmed.isEmpty && !rights.trimmed.isEmpty }
}

public struct PublishPackage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    public var piece: String = ""       // what's being published, where
    public var creator: String = ""
    public var claims: [CCClaim] = []
    public var assets: [CCAsset] = []
    public var disclosures: String = "" // sponsorships / affiliate / AI-generated material
    public var disclosureConfirmed = false
    public var correctionsPathConfirmed = false

    public init(title: String, now: Date) { self.title = title; createdAt = now; updatedAt = now }

    public enum Stage: Int, CaseIterable, Sendable {
        case piece, claims, rights, package
        public var title: String {
            switch self {
            case .piece: return "Piece"
            case .claims: return "Claims checked"
            case .rights: return "Rights & disclosures"
            case .package: return "Publish package"
            }
        }
        public var systemImage: String {
            switch self {
            case .piece: return "play.rectangle"
            case .claims: return "checkmark.bubble"
            case .rights: return "checkmark.shield"
            case .package: return "shippingbox"
            }
        }
    }
    public func isComplete(_ s: Stage) -> Bool {
        switch s {
        case .piece: return !piece.trimmed.isEmpty
        case .claims: return !claims.isEmpty && claims.allSatisfy(\.isComplete)
        case .rights: return !assets.isEmpty && assets.allSatisfy(\.isComplete) && disclosureConfirmed
        case .package: return correctionsPathConfirmed
        }
    }
    public var completionFraction: Double { Double(Stage.allCases.filter { isComplete($0) }.count) / 4 }

    public static func sample(now: Date) -> PublishPackage {
        var p = PublishPackage(title: "Video: 'How the city awarded that contract'", now: now)
        p.piece = "12-minute explainer video; YouTube + newsletter, publishing 2026-06-10."
        p.creator = "C. Creator"
        var c1 = CCClaim(); c1.text = "The contract was awarded without competitive tender."; c1.checked = true; c1.source = "council minutes 2026-03-12"
        var c2 = CCClaim(); c2.text = "The winning firm is part-owned by the deputy mayor's brother."; c2.checked = true; c2.source = "companies register filing"
        p.claims = [c1, c2]
        var a1 = CCAsset(); a1.asset = "Council-meeting clip (0:42)"; a1.rights = "Public-meeting recording; council terms permit reuse with attribution."
        var a2 = CCAsset(); a2.asset = "Background track"; a2.rights = "Licensed (Artlist, licence #88231)."
        p.assets = [a1, a2]
        p.disclosures = "Newsletter contains affiliate links (disclosed); no sponsorship of this piece; AI voice not used."
        p.disclosureConfirmed = true
        p.correctionsPathConfirmed = true
        StudioAudit.record(&p.history, "Worked example created", at: now)
        return p
    }
}

public enum PublishPackageRenderer {
    public static func markdown(_ p: PublishPackage, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Publish Package — \(p.title.trimmed.isEmpty ? "Untitled" : p.title)\n\n"
        out += "**Creator:** \(p.creator.dash) · **Date:** \(df.string(from: generatedAt))\n\n---\n\n"
        out += "## 1. The piece\n\n\(p.piece.dashText)\n\n"
        out += "## 2. Claims — checked to a source\n\n| Claim | Checked | Source |\n|---|---|---|\n"
        for c in p.claims { out += "| \(c.text.dash) | \(c.checked ? "✓" : "✗") | \(c.source.dash) |\n" }
        out += "\n## 3. Rights & clearances\n\n| Asset | Rights / clearance |\n|---|---|\n"
        for a in p.assets { out += "| \(a.asset.dash) | \(a.rights.dash) |\n" }
        out += "\n## 4. Disclosures\n\n\(p.disclosures.dashText)\n\n"
        out += "Material connections disclosed: **\(p.disclosureConfirmed ? "Yes" : "No")** · Corrections path: **\(p.correctionsPathConfirmed ? "Yes" : "No")**\n\n"
        out += "_\(PublishReadiness.disciplineNote)_\n\n---\n\nPrepared by **\(p.creator.dash)**\n"
        out += StudioAudit.appendix(p.history)
        return out
    }
}

// MARK: - #9 Individual — emergency / legacy binder

public struct BinderItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var item: String = ""        // passport / will / policy / account
    public var location: String = ""    // where it physically/digitally lives
    public var access: String = ""      // who can access, and how
    public init() {}
    public var isComplete: Bool { !item.trimmed.isEmpty && !location.trimmed.isEmpty }
}
public struct BinderContact: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String = ""
    public var role: String = ""        // doctor / lawyer / next of kin / executor
    public var reach: String = ""       // phone / email
    public init() {}
    public var isComplete: Bool { !name.trimmed.isEmpty && !role.trimmed.isEmpty }
}

public struct EmergencyBinder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    public var owner: String = ""
    public var contacts: [BinderContact] = []
    public var items: [BinderItem] = []
    public var wishes: String = ""      // instructions / wishes for the reader
    public var reviewedRecently = false // binders go stale — the real-life gate

    public init(title: String, now: Date) { self.title = title; createdAt = now; updatedAt = now }

    public enum Stage: Int, CaseIterable, Sendable {
        case people, documents, wishes, binder
        public var title: String {
            switch self {
            case .people: return "Key people"
            case .documents: return "Documents & accounts"
            case .wishes: return "Instructions"
            case .binder: return "The binder"
            }
        }
        public var systemImage: String {
            switch self {
            case .people: return "person.2"
            case .documents: return "folder"
            case .wishes: return "text.quote"
            case .binder: return "book.closed"
            }
        }
    }
    public func isComplete(_ s: Stage) -> Bool {
        switch s {
        case .people: return !contacts.isEmpty && contacts.allSatisfy(\.isComplete)
        case .documents: return !items.isEmpty && items.allSatisfy(\.isComplete)
        case .wishes: return !wishes.trimmed.isEmpty
        case .binder: return reviewedRecently
        }
    }
    public var completionFraction: Double { Double(Stage.allCases.filter { isComplete($0) }.count) / 4 }

    public static func sample(now: Date) -> EmergencyBinder {
        var b = EmergencyBinder(title: "Family emergency binder", now: now)
        b.owner = "S. Owner"
        var c1 = BinderContact(); c1.name = "Dr. A. Physician"; c1.role = "GP"; c1.reach = "+1 555-0100"
        var c2 = BinderContact(); c2.name = "L. Counsel"; c2.role = "Lawyer (holds the will)"; c2.reach = "counsel@example.com"
        b.contacts = [c1, c2]
        var i1 = BinderItem(); i1.item = "Will (signed original)"; i1.location = "Lawyer's office safe"; i1.access = "Executor on ID"
        var i2 = BinderItem(); i2.item = "Life insurance policy #LI-2204"; i2.location = "Home safe + policy PDF in binder folder"; i2.access = "Spouse knows the code"
        var i3 = BinderItem(); i3.item = "Bank accounts (list)"; i3.location = "Binder folder / accounts.pdf"; i3.access = "Spouse; executor via will"
        b.items = [i1, i2, i3]
        b.wishes = "If I'm incapacitated: contact Dr. Physician first, then L. Counsel. The insurance policy covers the mortgage — claim before selling anything."
        b.reviewedRecently = true
        StudioAudit.record(&b.history, "Worked example created", at: now)
        return b
    }
}

public enum EmergencyBinderRenderer {
    public static func markdown(_ b: EmergencyBinder, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Emergency Binder — \(b.title.trimmed.isEmpty ? "Untitled" : b.title)\n\n"
        out += "**Owner:** \(b.owner.dash) · **Last reviewed:** \(df.string(from: generatedAt))\n\n"
        out += "_The point of this binder is findability in an emergency: where each thing lives, and who can reach it._\n\n---\n\n"
        out += "## 1. Key people\n\n| Name | Role | Reach |\n|---|---|---|\n"
        for c in b.contacts { out += "| \(c.name.dash) | \(c.role.dash) | \(c.reach.dash) |\n" }
        out += "\n## 2. Documents & accounts\n\n| Item | Where it lives | Who can access |\n|---|---|---|\n"
        for i in b.items { out += "| \(i.item.dash) | \(i.location.dash) | \(i.access.dash) |\n" }
        out += "\n## 3. Instructions\n\n\(b.wishes.dashText)\n\n"
        out += "Reviewed within the last year: **\(b.reviewedRecently ? "Yes" : "No — review it; binders go stale")**\n\n"
        out += "---\n\nPrepared by **\(b.owner.dash)**\n"
        out += StudioAudit.appendix(b.history)
        return out
    }
}

// MARK: - shared tiny helpers

fileprivate extension String {
    var dash: String { trimmed.isEmpty ? "—" : self }
    var dashText: String { trimmed.isEmpty ? "_Not stated._" : self }
}
