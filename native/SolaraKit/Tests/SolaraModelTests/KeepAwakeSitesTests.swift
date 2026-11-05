import SolaraModel
import Testing

@Suite struct KeepAwakeSitesTests {
  @Test(arguments: [
    ("chat.example.com", "chat.example.com"),
    ("  Example.COM  ", "example.com"),
    ("https://mail.example.com/inbox?x=1#top", "mail.example.com"),
    ("http://user@example.com:8080/", "example.com"),
    (".example.com.", "example.com"),
    ("localhost", "localhost"),
    ("[*.]example.com", "example.com"),
    ("*.example.com", "example.com"),
    ("intranet", "intranet"),
    ("http://wiki:8080/page", "wiki"),
    ("http://[::1]:8080/", "[::1]"),
    ("::1", "[::1]"),
    ("[FE80::1]", "[fe80::1]"),
    ("192.168.1.10:3000", "192.168.1.10"),
    ("e\u{301}.example", "\u{e9}.example"),
  ])
  func normalizesWhatPeopleType(_ input: String, _ expected: String) {
    #expect(KeepAwakeSites.normalized(input) == expected)
  }

  @Test(arguments: ["", "   ", "not a site", "[::1", "[]", "[zz::1]", "a*b.com", "http://"])
  func refusesWhatIsNotASite(_ input: String) {
    #expect(KeepAwakeSites.normalized(input) == nil)
  }

  @Test func exactEntryCoversItsHost() {
    #expect(KeepAwakeSites.cover(of: "chat.example.com", in: ["chat.example.com", "example.com"]) == .exact("chat.example.com"))
  }

  @Test func parentEntryCoversSubdomainsButNotLookalikes() {
    #expect(KeepAwakeSites.cover(of: "a.b.example.com", in: ["example.com", "b.example.com"]) == .parent("b.example.com"))
    #expect(KeepAwakeSites.cover(of: "notexample.com", in: ["example.com"]) == .none)
    #expect(KeepAwakeSites.cover(of: "example.com", in: ["chat.example.com"]) == .none)
    #expect(KeepAwakeSites.cover(of: "", in: ["example.com"]) == .none)
    #expect(KeepAwakeSites.cover(of: "::1", in: ["[::1]"]) == .exact("[::1]"))
    #expect(KeepAwakeSites.cover(of: "Chat.Example.com", in: ["example.com"]) == .parent("example.com"))
  }

  @Test func addingKeepsOrderAndSkipsDuplicates() {
    #expect(KeepAwakeSites.adding("b.com", to: ["a.com"]) == ["a.com", "b.com"])
    #expect(KeepAwakeSites.adding("a.com", to: ["a.com"]) == ["a.com"])
  }

  @Test func adoptingChromesOwnExceptionsKeepsTheListAndAddsTheirSites() {
    #expect(KeepAwakeSites.adopting(["[*.]chat.example.com", "https://mail.example.com/x", "a.com", "not a site", "[::1]", "https://example.org:8443"], into: ["a.com"]) == ["a.com", "chat.example.com", "mail.example.com", "[::1]", "example.org"])
  }

  @Test func sleepDelayFallsBackToThirtyMinutes() {
    #expect(KeepAwakeSites.sleepAfterMinutes(.number(120)) == 120)
    #expect(KeepAwakeSites.sleepAfterMinutes(.number(7)) == 30)
    #expect(KeepAwakeSites.sleepAfterMinutes(nil) == 30)
  }
}
