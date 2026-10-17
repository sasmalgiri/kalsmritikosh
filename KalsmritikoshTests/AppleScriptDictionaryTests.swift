//
//  AppleScriptDictionaryTests.swift
//  KalsmritikoshTests
//
//  P-4 — the AppleScript dictionary ships in the app and every command it declares resolves
//  to its command class.
//

import AppKit
import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P-4 AppleScript dictionary")
struct AppleScriptDictionaryTests {
    private static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    @Test("Scripting is switched on and the dictionary is in the app")
    func ships() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["NSAppleScriptEnabled"] as? Bool == true)
        let name = try #require(info["OSAScriptingDefinition"] as? String)
        let url = try #require(Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "sdef"))
        let doc = try XMLDocument(contentsOf: url)
        let commands = try doc.nodes(forXPath: "//suite[@code='Kals']/command/@name").compactMap(\.stringValue)
        #expect(Set(commands) == ["ask", "search", "add files", "open link"])
    }

    @Test("Each command resolves to its class", arguments: [
        ("KalsAsk ", "KalsAskCommand"), ("KalsSrch", "KalsSearchCommand"),
        ("KalsAddF", "KalsAddFilesCommand"), ("KalsOpnL", "KalsOpenLinkCommand")
    ])
    @MainActor func commandClasses(code: String, className: String) throws {
        let eventClass = Self.fourCC(String(code.prefix(4))), eventID = Self.fourCC(String(code.suffix(4)))
        let description = try #require(NSScriptSuiteRegistry.shared()
            .commandDescription(withAppleEventClass: eventClass, andAppleEventCode: eventID))
        #expect(description.commandClassName == className)
        #expect(NSClassFromString(className) is NSScriptCommand.Type)
    }

    @Test("Errors read as the same sentences the Shortcuts actions use")
    func errorText() {
        #expect(ScriptCommandError.message(for: KalsmritikoshIntentError.switchedOff).contains("Shortcuts actions"))
        #expect(ScriptCommandError.message(for: ScriptCommandError.missing("a question")) == "Give a question.")
    }
}
