//
//  CloudEndpointRegistry.swift
//  Kalsmritikosh
//
//  Persists user-supplied cloud-model endpoints (BYO API key +
//  base URL + model name). The endpoint *metadata* lives in a JSON
//  file in Application Support; the API key itself is stored in
//  the macOS Keychain under a unique account name, so it never
//  hits disk in cleartext.
//
//  PrivacyGate still gates whether these endpoints can be RESOLVED
//  for capability satisfaction — adding an endpoint here doesn't
//  override the user's privacy choice. The Settings UI shows
//  "Cloud routing disabled — endpoints registered but not callable"
//  when the gate is off.
//

import Foundation
import Security
import OSLog

public actor CloudEndpointRegistry {

    public struct Endpoint: Codable, Sendable, Equatable {
        public let id: String           // stable id, e.g. "provider.cloud.openai-default"
        public let displayName: String
        /// Base URL — e.g. https://api.openai.com/v1
        public let baseURL: String
        /// Model name the API expects in its body (e.g. "gpt-4o-mini").
        public let modelName: String
        public let contextWindow: Int
        public let tier: ModelManifest.Tier
        /// Family label for the advisor's display ("openai", "anthropic",
        /// "azure", "ollama-remote", "custom"). Not load-bearing.
        public let family: String

        public init(
            id: String,
            displayName: String,
            baseURL: String,
            modelName: String,
            contextWindow: Int,
            tier: ModelManifest.Tier,
            family: String
        ) {
            self.id = id
            self.displayName = displayName
            self.baseURL = baseURL
            self.modelName = modelName
            self.contextWindow = contextWindow
            self.tier = tier
            self.family = family
        }

        public var keychainAccount: String {
            // One key per endpoint id so revoking a key only affects
            // that endpoint.
            "kalsmritikosh.cloud.\(id)"
        }
    }

    private let storeURL: URL
    private let keychainService: String = "ecosanskritiinnovation.Kalsmritikosh.cloud"
    private var entries: [Endpoint] = []

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = appSupport.appendingPathComponent("Kalsmritikosh", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("cloud-endpoints.json", isDirectory: false)
        }
    }

    public func load() async -> [Endpoint] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Endpoint].self, from: data)
        else { return [] }
        entries = decoded
        return entries
    }

    public func all() -> [Endpoint] { entries }

    /// Register a new cloud endpoint. The API key is written to the
    /// Keychain; the rest of the metadata is persisted to JSON.
    public func add(_ endpoint: Endpoint, apiKey: String) async throws {
        try writeKeychain(account: endpoint.keychainAccount, key: apiKey)
        if let i = entries.firstIndex(where: { $0.id == endpoint.id }) {
            entries[i] = endpoint
        } else {
            entries.append(endpoint)
        }
        try persistMetadata()
    }

    public func remove(id: String) async {
        if let entry = entries.first(where: { $0.id == id }) {
            try? deleteKeychain(account: entry.keychainAccount)
        }
        entries.removeAll { $0.id == id }
        try? persistMetadata()
    }

    /// Read the stored API key for an endpoint. Returns nil if the
    /// endpoint doesn't exist or the Keychain entry was deleted out
    /// of band.
    public func apiKey(for id: String) -> String? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return readKeychain(account: entry.keychainAccount)
    }

    // MARK: - Keychain helpers

    private func writeKeychain(account: String, key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw NSError(domain: "CloudEndpointRegistry", code: 1)
        }
        // Delete any existing entry for this account first so add
        // can be idempotent.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "CloudEndpointRegistry",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain write failed (status \(status))"]
            )
        }
    }

    private func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "CloudEndpointRegistry", code: Int(status))
        }
    }

    private func persistMetadata() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: storeURL, options: .atomic)
    }
}
