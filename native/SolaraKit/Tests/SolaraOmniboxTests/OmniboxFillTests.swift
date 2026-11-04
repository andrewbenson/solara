import Foundation
import Testing

@testable import SolaraOmnibox

struct OmniboxFillTests {
  @Test func aPageFillsItsAddressWithoutTheWebScheme() {
    #expect(OmniboxFill.text(for: .page(url: "https://github.com/andrewbenson/solara/releases/tag/v0.1.0", title: "Release", favicon: nil))
      == "github.com/andrewbenson/solara/releases/tag/v0.1.0")
    #expect(OmniboxFill.text(for: .page(url: "http://localhost:3000/", title: "", favicon: nil)) == "localhost:3000")
    #expect(OmniboxFill.text(for: .page(url: "https://github.com/andrewbenson/solara/", title: "", favicon: nil)) == "github.com/andrewbenson/solara/")
    #expect(OmniboxFill.text(for: .page(url: "HTTPS://www.example.com/a?b=1#c", title: "", favicon: nil)) == "www.example.com/a?b=1#c")
  }

  @Test func otherSchemesStayWhole() {
    #expect(OmniboxFill.text(for: .page(url: "solara://settings", title: "Settings", favicon: nil)) == "solara://settings")
    #expect(OmniboxFill.text(for: .page(url: "file:///Users/a/b.pdf", title: "", favicon: nil)) == "file:///Users/a/b.pdf")
  }

  @Test func aSwitchToTabRowFillsTheTabsAddress() {
    #expect(OmniboxFill.text(for: .page(url: "https://news.ycombinator.com/", title: "HN", favicon: nil, tabId: "t2")) == "news.ycombinator.com")
  }

  @Test func aSearchFillsItsQuery() {
    #expect(OmniboxFill.text(for: .search(query: "solara car", url: "https://www.google.com/search?q=solara+car", engine: "Google", suggested: true))
      == "solara car")
  }

  @Test func rowsThatRunSomethingKeepWhatWasTyped() {
    #expect(OmniboxFill.text(for: .search(query: "cats", url: "https://www.google.com/search?q=cats", engine: "Google", bang: true)) == nil)
    #expect(OmniboxFill.text(for: .calc(expression: "6*7", value: "42", url: "https://x")) == nil)
    #expect(OmniboxFill.text(for: .action(id: "settings", title: "Open Settings")) == nil)
    #expect(OmniboxFill.text(for: .create(id: "doc", title: "New Doc", url: "https://docs.new", site: "Docs")) == nil)
    #expect(OmniboxFill.text(for: .extension(id: "e", title: "Ext", icon: nil, open: .action)) == nil)
  }

  @Test func theHomeRowShowsTheTypedTextAndOtherRowsFill() {
    let items: [Suggestion] = [
      .page(url: "https://github.com/", title: "GitHub", favicon: nil),
      .search(query: "git", url: "https://g/?q=git", engine: "G"),
      .page(url: "https://gitlab.com/x", title: "GitLab", favicon: nil),
      .action(id: "a", title: "Action"),
    ]
    #expect(OmniboxFill.shown(selected: 0, home: 0, items: items) == nil)
    #expect(OmniboxFill.shown(selected: 1, home: 0, items: items) == "git")
    #expect(OmniboxFill.shown(selected: 2, home: 0, items: items) == "gitlab.com/x")
    #expect(OmniboxFill.shown(selected: 3, home: 0, items: items) == nil)
    #expect(OmniboxFill.shown(selected: 7, home: 0, items: items) == nil)
  }

  @Test func withNothingTypedEveryRowFills() {
    let items: [Suggestion] = [.page(url: "https://a.com/", title: "A", favicon: nil, tabId: "1"), .page(url: "https://b.com/", title: "B", favicon: nil, tabId: "2")]
    #expect(OmniboxFill.shown(selected: -1, home: -1, items: items) == nil)
    #expect(OmniboxFill.shown(selected: 0, home: -1, items: items) == "a.com")
    #expect(OmniboxFill.shown(selected: 1, home: -1, items: items) == "b.com")
  }
}
