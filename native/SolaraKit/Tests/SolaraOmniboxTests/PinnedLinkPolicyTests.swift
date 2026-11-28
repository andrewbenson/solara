import SolaraOmnibox
import Testing

struct PinnedLinkPolicyTests {
  @Test func routesOnlyAcrossSites() {
    let cases = [
      ("https://a.example.co.uk", "https://b.example.co.uk:8443/a", false),
      ("https://a.github.io", "https://b.github.io", true),
      ("https://a.internal", "https://b.internal", true),
      ("https://localhost:3000", "http://localhost:3001", false),
      ("http://localhost", "http://127.0.0.1", true),
      ("http://192.168.0.1", "http://192.168.0.2", true),
      ("https://a.www.ck", "https://www.ck", false),
      ("https://a.b.ck", "https://c.b.ck", true),
      ("https://www.google.com", "https://www.google.com/url?q=https%3A%2F%2Fother.test", true),
      ("https://www.google.com", "https://www.google.com/url?q=https%3A%2F%2Fdocs.google.com", false),
      ("https://www.google.com", "https://www.google.com/url?q=https%3A%2F%2Fother.test&url=https%3A%2F%2Fdocs.google.com", false),
      ("https://example.test", "https://user@other.test", false),
      ("https://example.test", "https://other.test/%z", false),
      ("https://example.test", "file:///example.txt", false),
    ]
    for (source, destination, crossesSites) in cases {
      #expect(PinnedLinkPolicy.crossesSites(from: source, to: destination) == crossesSites, "\(source) → \(destination)")
    }
  }

  @Test func unwrapsNestedRedirects() {
    let url = "https://www.google.com/url?q=https%3A%2F%2Fslack-redir.net%2Flink%3Furl%3Dhttps%253A%252F%252Ftarget.test%252F"
    #expect(PinnedLinkPolicy.unwrapRedirects(url) == "https://target.test/")
  }
}
