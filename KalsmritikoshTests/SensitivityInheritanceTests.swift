//
//  SensitivityInheritanceTests.swift
//  KalsmritikoshTests
//
//  SEC-001 — derived data inherits the max sensitivity + any privilege of its sources; a
//  release guard prevents leaking a protected value into a lower-sensitivity output.
//

import Testing
@testable import Kalsmritikosh

@Suite("SEC-001 SensitivityInheritance")
struct SensitivityInheritanceTests {

    @Test("Derived sensitivity is the max of its sources")
    func maxSensitivity() {
        let d = SensitivityInheritance.inherit(from: [
            ProtectionLabel(sensitivity: .publicLevel),
            ProtectionLabel(sensitivity: .restricted),
            ProtectionLabel(sensitivity: .internalLevel)])
        #expect(d.sensitivity == .restricted)
    }

    @Test("Privilege is sticky — any privileged source makes the derived privileged")
    func stickyPrivilege() {
        let d = SensitivityInheritance.inherit(from: [
            ProtectionLabel(sensitivity: .publicLevel, privileged: false),
            ProtectionLabel(sensitivity: .publicLevel, privileged: true)])
        #expect(d.privileged)
    }

    @Test("No sources → internal (never assumed public)")
    func unknownProvenance() {
        #expect(SensitivityInheritance.inherit(from: []).sensitivity == .internalLevel)
    }

    @Test("Release guard blocks over-sensitive or privileged artifacts")
    func releaseGuard() {
        let restricted = ProtectionLabel(sensitivity: .restricted)
        let publicOK = ProtectionLabel(sensitivity: .publicLevel)
        let privileged = ProtectionLabel(sensitivity: .publicLevel, privileged: true)
        #expect(!SensitivityInheritance.canRelease(restricted, at: .publicLevel))
        #expect(SensitivityInheritance.canRelease(publicOK, at: .publicLevel))
        #expect(!SensitivityInheritance.canRelease(privileged, at: .restricted)) // privileged never releases
    }

    @Test("Sensitivity lattice is ordered")
    func ordering() {
        #expect(SensitivityLevel.publicLevel < .internalLevel)
        #expect(SensitivityLevel.confidential < .restricted)
    }
}
