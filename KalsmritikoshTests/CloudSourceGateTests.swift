//
//  CloudSourceGateTests.swift
//  KalsmritikoshTests
//
//  Final completion instructions K1: before document-derived text becomes a cloud prompt, each source
//  document is checked for that purpose; and no capability request reaches the cloud unless it says
//  it may.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Cloud source gate (K1)")
struct CloudSourceGateTests {

    @Test("Privileged, restricted, untraceable or unreadable documents are not cleared; internal and confidential are")
    func decisions() async {
        let internalDoc = UUID(), confidential = UUID(), restricted = UUID(), privileged = UUID(),
            legacyPrivileged = UUID(), broken = UUID(), unreadable = UUID()
        struct Unreadable: Error {}
        let gate = CloudSourceGate(resolve: { id in
            switch id {
            case internalDoc, legacyPrivileged: return .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false))
            case confidential: return .resolved(ProtectionLabel(sensitivity: .confidential, privileged: false))
            case restricted: return .resolved(ProtectionLabel(sensitivity: .restricted, privileged: false))
            case privileged: return .resolved(ProtectionLabel(sensitivity: .publicLevel, privileged: true))
            case broken: return .brokenLineage
            default: throw Unreadable()
            }
        }, legacyPrivileged: { [legacyPrivileged] })
        let r = await gate.clear([internalDoc, confidential, restricted, privileged, legacyPrivileged, broken, unreadable], purpose: "test")
        #expect(r.clearance.clearedObjectIDs == [internalDoc, confidential])
        #expect(r.denied.keys.sorted() == [restricted, privileged, legacyPrivileged, broken, unreadable].sorted())
        #expect(r.clearance.deniedCount == 5)
        // A local scope stricter than the cloud ceiling is honoured too.
        let strict = CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .confidential, privileged: false)) },
                                     legacyPrivileged: { [] }, localCeiling: .internalLevel)
        #expect(await strict.clear([confidential], purpose: "t").clearance.clearedObjectIDs.isEmpty)
        // The privileged list cannot be read: nothing is cleared.
        let blind = CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .publicLevel, privileged: false)) },
                                    legacyPrivileged: { throw Unreadable() })
        #expect(await blind.clear([internalDoc], purpose: "t").clearance.clearedObjectIDs.isEmpty)
    }

    @Test("Only a request that says it may go to the cloud can resolve to a cloud provider, and only in Online mode")
    func registryHonoursSpecPrivacy() {
        let reasoning = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "t")
        let cloud = CapabilitySpec(requires: reasoning.requires, privacy: .cloud, purpose: "t")
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: reasoning, cloudAllowed: true))
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: .textGeneration(purpose: "t"), cloudAllowed: true))
        #expect(CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: cloud, cloudAllowed: true))
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: cloud, cloudAllowed: false))
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: CapabilitySpec(requires: [.embedding], privacy: .cloud), cloudAllowed: true))
    }
}
