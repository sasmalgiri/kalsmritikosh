//
//  UserPreferences.swift
//  Kalsmritikosh
//
//  Persists per-capability provider overrides chosen by the user from the
//  Settings panel. The CapabilityRegistry consults this BEFORE running its
//  auto-recommendation logic — explicit pinning always wins.
//
//  Stored under UserDefaults so it survives launches; cleared on factory
//  reset.
//

import Foundation

public final class ModelUserPreferences: @unchecked Sendable {
    public nonisolated static let shared = ModelUserPreferences()

    private let defaultsKey = "kalsmritikosh.model.preferences"
    private let queue = DispatchQueue(label: "kalsmritikosh.preferences", attributes: .concurrent)

    public nonisolated struct Pin: Codable, Sendable, Hashable {
        public let capability: ModelCapability
        public let providerID: String
        public init(capability: ModelCapability, providerID: String) {
            self.capability = capability
            self.providerID = providerID
        }
    }

    /// Returns the pinned provider ID for a given capability, if any.
    public nonisolated func pinnedProvider(for capability: ModelCapability) -> String? {
        queue.sync { self.pinsByCapability()[capability] }
    }

    public func setPin(_ providerID: String, for capability: ModelCapability) {
        queue.async(flags: .barrier) {
            var pins = self.pinsByCapability()
            pins[capability] = providerID
            self.persist(pins: pins)
        }
    }

    public func clearPin(for capability: ModelCapability) {
        queue.async(flags: .barrier) {
            var pins = self.pinsByCapability()
            pins.removeValue(forKey: capability)
            self.persist(pins: pins)
        }
    }

    public func allPins() -> [Pin] {
        queue.sync {
            self.pinsByCapability().map { Pin(capability: $0.key, providerID: $0.value) }
        }
    }

    // MARK: - Internals

    private nonisolated func pinsByCapability() -> [ModelCapability: String] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let pins = try? JSONDecoder().decode([Pin].self, from: data) else {
            return [:]
        }
        var dict: [ModelCapability: String] = [:]
        for p in pins { dict[p.capability] = p.providerID }
        return dict
    }

    private nonisolated func persist(pins: [ModelCapability: String]) {
        let array = pins.map { Pin(capability: $0.key, providerID: $0.value) }
        if let data = try? JSONEncoder().encode(array) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
