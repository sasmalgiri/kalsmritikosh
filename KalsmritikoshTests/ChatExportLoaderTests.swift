//
//  ChatExportLoaderTests.swift
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ChatExportLoader — format detection")
struct ChatExportLoaderTests {
    @Test("WhatsApp shape recognized")
    func whatsappShape() {
        let line = "[3/14/25, 9:12:34 AM] Alice: Did you sign the contract?"
        let regex = ChatExportLoader.whatsappRegex
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, options: [], range: range) != nil)
    }

    @Test("Signal Desktop shape recognized")
    func signalShape() {
        let line = "2025-03-14 09:12:34 - Alice: Did you sign the contract?"
        let regex = ChatExportLoader.signalRegex
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, options: [], range: range) != nil)
    }

    @Test("Slack TXT export shape recognized")
    func slackShape() {
        let line = "[2025-03-14, 09:12 AM] alice: Did you sign the contract?"
        let regex = ChatExportLoader.slackRegex
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, options: [], range: range) != nil)
    }
}
