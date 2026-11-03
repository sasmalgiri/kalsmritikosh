//
//  OnlineCenter.swift
//  Kalsmritikosh
//
//  Online mode's user-facing state, all on the main actor:
//   * OnlineSettings — chosen provider, model, key (Keychain), consent style, daily limit (I-8).
//   * OutboundConsent — O-5: before each send, the exact text, destination and size are shown
//     and the user allows or declines; "allow for this session" is remembered in memory only.
//   * OnlineStatus — O-7: the last online failure, shown to the user; the app never switches
//     mode on its own.
//

import Foundation
import Observation
import Security
import os

// MARK: - Settings

public nonisolated enum OnlineSettings {
    private static let kindKey = "kalsmritikosh.online.provider"
    private static let modelKey = "kalsmritikosh.online.model"
    private static let consentKey = "kalsmritikosh.online.askEveryTime"
    private static let capKey = "kalsmritikosh.online.dailyByteCap"
    private static let documentTermsKey = "kalsmritikosh.online.documentTermsConfirmed."
    private static let keychainService = "ecosanskritiinnovation.Kalsmritikosh.onlineKeys"

    public static var kind: OnlineProviderKind {
        get { OnlineProviderKind(rawValue: UserDefaults.standard.string(forKey: kindKey) ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: kindKey) }
    }

    public static var model: String {
        get {
            if !kind.usesOwnKey { return kind.defaultModel }   // AI Included: the relay's model, not a choice
            let stored = UserDefaults.standard.string(forKey: modelKey) ?? ""
            return stored.isEmpty ? kind.defaultModel : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// true = ask before every send (default); false = once per app session.
    public static var askEveryTime: Bool {
        get { UserDefaults.standard.object(forKey: consentKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: consentKey) }
    }

    /// Review L2 — the reviewed-terms version the person confirmed for `kind` (nil = never confirmed).
    public static func confirmedDocumentTerms(for kind: OnlineProviderKind) -> String? {
        UserDefaults.standard.string(forKey: documentTermsKey + kind.rawValue)
    }
    public static func setDocumentTermsConfirmed(_ confirmed: Bool, for kind: OnlineProviderKind) {
        if confirmed { UserDefaults.standard.set(kind.documentTermsVersion, forKey: documentTermsKey + kind.rawValue) }
        else { UserDefaults.standard.removeObject(forKey: documentTermsKey + kind.rawValue) }
    }

    /// I-8 — bytes that may be sent per day; nil = no limit, 0 = nothing may be sent.
    public static var dailyByteCap: Int? {
        get { UserDefaults.standard.object(forKey: capKey) as? Int }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: capKey) }
            else { UserDefaults.standard.removeObject(forKey: capKey) }
        }
    }

    public static func apiKey(for kind: OnlineProviderKind) -> String? {
        // A2 — AI Included has no key on the Mac: the verified subscription number stands in for it.
        if kind == .included { return AIIncludedRelay.isConfigured ? AIIncludedAccess.subscriptionID : nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: kind.rawValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    public static func setAPIKey(_ key: String?, for kind: OnlineProviderKind) -> Bool {
        guard kind.usesOwnKey else { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: kind.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { KalsmritikoshLog.app.error("Online key save failed: \(status, privacy: .public)") }
        return status == errSecSuccess
    }

    /// Online answers may run: mode in force, module on, and a key for the chosen provider.
    public static var cloudAllowed: Bool {
        // A3 — and only where the App Store country allows generative AI.
        ConnectivityMode.current == .online && ProductModuleFlags.isEnabled(.onlineAnswers) && AIRegion.allowsAI
    }
}

// MARK: - Consent (O-5)

public struct OutboundPreview: Sendable, Identifiable {
    public let id = UUID()
    public let provider: String
    public let model: String
    public let host: String
    public let text: String
    public let bytes: Int
    public let maskedCount: Int
    /// Review L2 — the text includes document excerpts: always previewed, never covered by "this session".
    public var carriesDocuments: Bool = false
    /// The provider's retention / training terms, shown with a document send.
    public var providerTerms: String? = nil
    /// A2 — sent through AI Included (one of the subscriber's monthly questions), not the person's own key.
    public var aiIncluded: Bool = false
}

@MainActor
@Observable
public final class OutboundConsent {
    public static let shared = OutboundConsent()

    public private(set) var pending: OutboundPreview?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var allowedThisSession = false

    /// Ask the user. Returns true to send, false to decline.
    public func request(_ preview: OutboundPreview) async -> Bool {
        if !OnlineSettings.askEveryTime, allowedThisSession, !preview.carriesDocuments { return true }
        // One prompt at a time: a second request waits for the first to resolve.
        while pending != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        return await withCheckedContinuation { c in
            continuation = c
            pending = preview
        }
    }

    public func resolve(allow: Bool, forSession: Bool = false) {
        if allow && forSession { allowedThisSession = true }
        pending = nil
        continuation?.resume(returning: allow)
        continuation = nil
    }
}

// MARK: - Status (O-7)

@MainActor
@Observable
public final class OnlineStatus {
    public static let shared = OnlineStatus()
    public private(set) var lastFailure: String?
    public private(set) var lastFailureAt: Date?
    /// What kind of failure it was (no credit, key refused …); an account problem shows a lasting banner.
    public private(set) var lastFailureKind: OnlineFailure?

    public func recordFailure(_ reason: String, kind: OnlineFailure? = nil) {
        lastFailure = reason
        lastFailureAt = Date()
        lastFailureKind = kind
    }

    /// The account-level banner for the last failure, if it was one ("Your AI account has no credit …").
    public var accountBanner: String? { lastFailureKind?.banner }

    public func clear() { lastFailure = nil; lastFailureAt = nil; lastFailureKind = nil }
}
