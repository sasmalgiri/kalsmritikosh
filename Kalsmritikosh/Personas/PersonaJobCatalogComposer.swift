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
        return try builder.build()
    }

    /// The launchable jobs a persona declares, keyed by application id. This is the enumeration source the
    /// live consumer uses; it is defined ONCE here so discovery (the catalog) and enumeration (this table)
    /// never diverge.
    public static func jobs(forPersona applicationID: ApplicationDefinitionID) -> [PersonaJob] {
        switch applicationID {
        case InvestigatorPersonaPackage.applicationID: return InvestigatorPersonaPackage.jobs
        default: return []
        }
    }
}
