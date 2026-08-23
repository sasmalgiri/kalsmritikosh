//
//  FeedbackMail.swift
//  Kalsmritikosh
//
//  "Report a problem" for a FULLY-PRIVATE app: the app itself makes NO network
//  call and collects NOTHING. It only composes a mailto: draft that opens in the
//  user's own mail client — the user sees every character before sending, can
//  delete any of it, and sends from their own account or not at all. The
//  pre-filled context is limited to app + macOS versions (visible, deletable);
//  no document content, no ledger data, no identifiers.
//
//  This keeps the App Store "Data Not Collected" label and the in-app
//  privacyStatement truthful: user-initiated email is the user contacting the
//  developer, not the app collecting data.
//

import Foundation

public enum FeedbackMail {

    /// The support address — the same one published on the website's support page.
    public static let supportAddress = "sasmalgiri@gmail.com"

    /// Build the mailto: URL for a problem report. Pure and testable.
    /// - Parameters:
    ///   - appVersion: e.g. "1.0 (42)" — shown to the user in the draft, deletable.
    ///   - osVersion: e.g. "macOS 15.6" — same.
    public static func reportProblemURL(appVersion: String, osVersion: String) -> URL? {
        let subject = "Kalsmritikosh — problem report"
        let body = """
        What happened:


        What I expected:


        Where in the app (screen / step):


        ----
        You can delete anything below — it just helps reproduce the problem.
        App version: \(appVersion)
        System: \(osVersion)

        Note: this draft was composed on your Mac; Kalsmritikosh itself sends nothing.
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    /// The current app + OS versions for the draft (visible to the user, deletable).
    public static func currentVersions() -> (app: String, os: String) {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ("\(short) (\(build))", "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}
