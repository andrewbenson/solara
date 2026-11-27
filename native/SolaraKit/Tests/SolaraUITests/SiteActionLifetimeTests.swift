import SolaraModel
import Testing
@testable import SolaraUI

@Suite struct SiteActionLifetimeTests {
  @Test func sameOriginNavigationAndProfileChangeInvalidateReads() throws {
    var session = SiteControlsSession()
    let first: JSONValue = ["url": "https://example.com/a", "profileId": "private-a", "profile": "shared"]
    let next: JSONValue = ["url": "https://example.com/b", "profileId": "private-a", "profile": "shared"]
    let other: JSONValue = ["url": "https://example.com/b", "profileId": "private-b", "profile": "shared"]
    let firstRefresh = session.beginRefresh(context: first)
    let firstToken = try #require(firstRefresh)
    let nextRefresh = session.beginRefresh(context: next)
    let nextToken = try #require(nextRefresh)
    #expect(!session.accepts(token: firstToken))
    let otherRefresh = session.beginRefresh(context: other)
    #expect(otherRefresh != nil)
    #expect(!session.accepts(token: nextToken))
  }
}
