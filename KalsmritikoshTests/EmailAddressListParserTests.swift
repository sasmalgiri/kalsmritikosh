//
//  EmailAddressListParserTests.swift
//  KalsmritikoshTests
//
//  OPS-005 — Proves EmailAddressListParser handles the full range of
//  RFC 2822 address-list shapes that appear on real email corpora.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-005 — EmailAddressListParser")
struct EmailAddressListParserTests {

    typealias PA = EmailAddressListParser.ParsedAddress

    // MARK: - Case 1: bare address

    @Test("Bare address is extracted with no display name")
    func bareAddress() {
        let result = EmailAddressListParser.parse("user@example.com")
        #expect(result == [PA(address: "user@example.com", displayName: nil)])
    }

    // MARK: - Case 2: angle-bracket form with no display name

    @Test("Angle-bracket form with no display name extracts address")
    func angleBracketOnly() {
        let result = EmailAddressListParser.parse("<user@example.com>")
        #expect(result == [PA(address: "user@example.com", displayName: nil)])
    }

    // MARK: - Case 3: display name before angle brackets

    @Test("Display name before angle bracket is captured")
    func displayNameAngleBracket() {
        let result = EmailAddressListParser.parse("Alice Smith <alice@example.com>")
        #expect(result.count == 1)
        #expect(result[0].address == "alice@example.com")
        #expect(result[0].displayName == "Alice Smith")
    }

    // MARK: - Case 4: quoted display name

    @Test("Quoted display name containing a comma is captured correctly")
    func quotedDisplayName() {
        let result = EmailAddressListParser.parse("\"Smith, Alice\" <alice@example.com>")
        #expect(result.count == 1)
        #expect(result[0].address == "alice@example.com")
        #expect(result[0].displayName == "Smith, Alice")
    }

    // MARK: - Case 5: multiple comma-separated entries

    @Test("Multiple comma-separated entries are all returned in order")
    func multipleEntries() {
        let input = "alice@example.com, Bob Jones <bob@example.com>, charlie@example.com"
        let result = EmailAddressListParser.parse(input)
        #expect(result.count == 3)
        #expect(result[0].address == "alice@example.com")
        #expect(result[1].address == "bob@example.com")
        #expect(result[1].displayName == "Bob Jones")
        #expect(result[2].address == "charlie@example.com")
    }

    // MARK: - Case 6: group syntax

    @Test("Group syntax prefix is skipped and member addresses are extracted")
    func groupSyntax() {
        let input = "Recipients: alice@example.com, bob@example.com;"
        let result = EmailAddressListParser.parse(input)
        let addresses = result.map(\.address)
        #expect(addresses.contains("alice@example.com"))
        #expect(addresses.contains("bob@example.com"))
    }

    // MARK: - Case 7: empty / whitespace input

    @Test("Empty input returns empty array")
    func emptyInput() {
        #expect(EmailAddressListParser.parse("").isEmpty)
        #expect(EmailAddressListParser.parse("   ").isEmpty)
    }

    // MARK: - Case 8: addresses are lowercased

    @Test("Addresses are normalised to lower-case")
    func addressesAreLowercased() {
        let result = EmailAddressListParser.parse("User.Name@Example.COM")
        #expect(result.count == 1)
        #expect(result[0].address == "user.name@example.com")
    }
}
