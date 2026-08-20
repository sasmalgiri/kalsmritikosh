//
//  PersonaJobCatalogComposer.swift
//  Kalsmritikosh
//
//  #142 — the ONE production composition of the PersonaJobCatalog. Before this, the catalog and its builder
//  were exercised only in tests; nothing in the app composed a live catalog. This is the single place the
//  production catalog is built and every persona package is registered. AppState boots exactly one catalog
//  from here and hands it to the ONE live consumer (PersonaJobService). There is no other production
//  composition path.
//

import Foundation

public nonisolated enum PersonaJobCatalogComposer {

    /// Build the production PersonaJobCatalog with every persona package registered. Throws if any package
    /// fails cross-registry validation (fail-closed: no partial catalog is returned). Currently registers the
    /// Investigator package; further personas register here as they ship.
    public static func composeProduction() throws -> PersonaJobCatalog {
        var builder = PersonaJobCatalogBuilder(composerRegistry: try WorkProductComposerRegistry.makeDefault())
        try InvestigatorPersonaPackage.register(into: &builder)
        try ResearcherPersonaPackage.register(into: &builder)
        try JournalistPersonaPackage.register(into: &builder)
        try IndividualPersonaPackage.register(into: &builder)
        try LawyerPersonaPackage.register(into: &builder)
        // Buyer-research personas (2026-08-19) — the four segments that buy
        // evidence software today, each a vocabulary lens over the same
        // shared engines (no forked services, no new stores).
        try SIUPersonaPackage.register(into: &builder)
        try ForensicAccountantPersonaPackage.register(into: &builder)
        try CompliancePersonaPackage.register(into: &builder)
        try GenealogistPersonaPackage.register(into: &builder)
        // Content Creator (2026-08-20) — the steady researched-content pipeline
        // segment; a vocabulary lens over the same shared engines, distinct
        // from the Journalist's verification-for-publication job.
        try ContentCreatorPersonaPackage.register(into: &builder)
        return try builder.build()
    }

    /// Every launchable job across ALL registered personas — the static, nonisolated
    /// enumeration used to generate one guided workflow per job (WCCatalog.jobWorkflows).
    /// Same order as composeProduction() so coverage is discoverable and stable.
    public static var allJobs: [PersonaJob] {
        InvestigatorPersonaPackage.jobs
            + ResearcherPersonaPackage.jobs
            + JournalistPersonaPackage.jobs
            + IndividualPersonaPackage.jobs
            + LawyerPersonaPackage.jobs
            + SIUPersonaPackage.jobs
            + ForensicAccountantPersonaPackage.jobs
            + CompliancePersonaPackage.jobs
            + GenealogistPersonaPackage.jobs
            + ContentCreatorPersonaPackage.jobs
    }

    /// The launchable jobs a persona declares, keyed by application id. This is the enumeration source the
    /// live consumer uses; it is defined ONCE here so discovery (the catalog) and enumeration (this table)
    /// never diverge.
    public static func jobs(forPersona applicationID: ApplicationDefinitionID) -> [PersonaJob] {
        switch applicationID {
        case InvestigatorPersonaPackage.applicationID: return InvestigatorPersonaPackage.jobs
        case ResearcherPersonaPackage.applicationID:   return ResearcherPersonaPackage.jobs
        case JournalistPersonaPackage.applicationID:   return JournalistPersonaPackage.jobs
        case IndividualPersonaPackage.applicationID:   return IndividualPersonaPackage.jobs
        case LawyerPersonaPackage.applicationID:       return LawyerPersonaPackage.jobs
        case SIUPersonaPackage.applicationID:          return SIUPersonaPackage.jobs
        case ForensicAccountantPersonaPackage.applicationID: return ForensicAccountantPersonaPackage.jobs
        case CompliancePersonaPackage.applicationID:   return CompliancePersonaPackage.jobs
        case GenealogistPersonaPackage.applicationID:  return GenealogistPersonaPackage.jobs
        case ContentCreatorPersonaPackage.applicationID: return ContentCreatorPersonaPackage.jobs
        default: return []
        }
    }
}
