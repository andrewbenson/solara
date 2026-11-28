import Foundation
import Testing

@testable import SolaraLive

@Suite struct RoundTripTests {
  func roundTrips<T: Codable>(_ type: T.Type, _ name: String) {
    let original = try! JSONSerialization.jsonObject(with: Fixture.data(name))
    let value = Fixture.decode(type, name)
    #expect(canonical(encoding: value) == canonical(original), "\(name)")
  }

  @Test func everyFixtureDecodesAndReencodesToWhatJSWouldWrite() {
    roundTrips(GithubResponse.self, "github.json")
    roundTrips(CalendarFixture.self, "calendar-fixture.json")
    roundTrips(NotionSearch.self, "notion-search.json")
    roundTrips(NotionUsers.self, "notion-users.json")
    roundTrips(NotionMe.self, "notion-me.json")
    roundTrips(DriveFiles.self, "drive-files.json")
  }

  @Test func nullAndAbsentFieldsStayAsJSWritesThem() throws {
    let item = LiveItem(id: "x", source: .notion, url: "u", title: "t", subtitle: "s", updatedAt: 1, doc: DocumentInfo(kind: "Page", editedBy: nil, place: nil))
    #expect(try LiveJSON.text(item) == #"{"doc":{"editedBy":null,"kind":"Page","place":null},"icon":null,"id":"x","source":"notion","subtitle":"s","title":"t","updatedAt":1,"url":"u"}"#)
    var folder = LiveFolder(id: "f", profileId: "p", kind: .documents, name: "D", sources: [.notion], createdAt: 5)
    #expect(!(try LiveJSON.text(folder)).contains("after"))
    folder.after = .some(nil)
    #expect(try LiveJSON.text(folder).contains(#""after":null"#))
    folder.after = .some("tab")
    let back = try LiveJSON.decode(LiveFolder.self, from: try LiveJSON.text(folder))
    #expect(back.after == .some("tab"))
    let status = FolderStatus(state: .idle)
    #expect(try LiveJSON.text(status) == #"{"error":null,"lastFetch":null,"state":"idle"}"#)
  }

  @Test func aDocumentWithOneBrokenKeyKeepsTheRest() {
    let state = LiveState.load(
      #"{"folders":{"f":{"id":"f","profileId":"p","kind":"documents","name":"D","icon":null,"collapsed":false,"sources":["notion"],"filters":{"authored":true,"reviewRequests":true},"createdAt":1}},"folderOrder":["f"],"items":"broken","config":{"googleClientId":"me"},"calendar":{"alertLead":"5"}}"#)
    #expect(state.folderOrder == ["f"])
    #expect(state.items == [:])
    #expect(state.config.googleClientId == "me")
    #expect(state.config.githubClientId == "")
    #expect(state.calendar.alertLead == "5")
    #expect(state.calendar.showPreview == true)
    #expect(LiveState.load("not json") == LiveState())
  }
}

@Suite struct NetTests {
  func error(_ response: LiveHTTPResponse) -> LiveError? {
    do {
      try LiveNet.check(response)
      return nil
    } catch {
      return error as? LiveError
    }
  }

  @Test func statusCodesMapToTheKindsJSGives() {
    #expect(error(LiveHTTPResponse(status: 200)) == nil)
    #expect(error(LiveHTTPResponse(status: 401)) == LiveError(.signedOut, "Signed out"))
    #expect(error(LiveHTTPResponse(status: 403, headers: ["X-GitHub-SSO": "required; url=x"])) == LiveError(.sso, "Needs Single Sign-On"))
    #expect(error(LiveHTTPResponse(status: 403, headers: ["x-github-sso": ""], body: Data("nope".utf8))) == LiveError(.signedOut, "403 nope"))
    #expect(error(LiveHTTPResponse(status: 429)) == LiveError(.rateLimited, "Rate Limit Exceeded"))
    #expect(error(LiveHTTPResponse(status: 403, headers: ["X-RateLimit-Remaining": "0"])) == LiveError(.rateLimited, "Rate Limit Exceeded"))
    #expect(error(LiveHTTPResponse(status: 502)) == LiveError(.other, "502"))
    let long = String(repeating: "é", count: 300)
    #expect(error(LiveHTTPResponse(status: 500, body: Data(long.utf8)))?.message == "500 \(String(repeating: "é", count: 200))")
  }

  @Test func aTransportFailureIsANetworkErrorAndBadJSONIsNotALiveError() async {
    struct Down: Error {}
    let down = LiveRequester(http: FakeHTTP { _ in throw Down() })
    await #expect(throws: LiveError(.network, "Couldn't connect")) { _ = try await down.data(LiveHTTPRequest(url: "https://x")) }
    let garbled = LiveRequester(http: FakeHTTP { _ in LiveHTTPResponse(status: 200, body: Data("<html>".utf8)) })
    do {
      _ = try await garbled.json(NotionMe.self, LiveHTTPRequest(url: "https://x"))
      Issue.record("decoded garbage")
    } catch {
      #expect(!(error is LiveError))
    }
  }

  @Test func requestsAskForJSONUnlessTheyAlreadySay() async throws {
    let http = FakeHTTP { _ in LiveHTTPResponse(status: 200, body: Data("{}".utf8)) }
    let requester = LiveRequester(http: http)
    _ = try await requester.data(LiveHTTPRequest(url: "https://x"))
    _ = try await requester.data(LiveHTTPRequest(url: "https://x", headers: ["accept": "text/plain"]))
    #expect(http.log.current[0].headers["Accept"] == "application/json")
    #expect(http.log.current[1].headers == ["accept": "text/plain"])
  }

  @Test func formsAndSecretAccountsUseTheExpectedEncoding() {
    #expect(LiveNet.form([("client_id", "a b"), ("scope", "repo read:org")]) == "client_id=a%20b&scope=repo%20read%3Aorg")
    #expect(LiveEndpoints(mock: "http://m").secretAccount(.github) == "mock:github")
    #expect(LiveEndpoints(mock: nil).secretAccount(.gdrive) == "gdrive")
  }

  @Test func engineDescribesFailuresLikeJS() async {
    let rig = Rig()
    struct Odd: Error, CustomStringConvertible { var description: String { "odd" } }
    #expect(rig.engine.describe(.notion, LiveError(.sso, "m")) == FolderError(kind: .sso, message: "m", source: .notion))
    #expect(rig.engine.describe(.gdrive, Odd()) == FolderError(kind: .other, message: "odd", source: .gdrive))
  }
}

@Suite struct ReplicaTests {
  @Test func theReplicaOnlyCarriesMeetingFields() async throws {
    let rig = Rig()
    let id = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [])
    await rig.engine.setShowAll("\(id):documents", true)
    let group = MeetingGroup(groupId: "group", callTabId: "tab", occurrence: nil, title: "Call", start: nil, end: nil, endedAt: nil)
    await rig.engine.setMeetingGroup(group)
    let state = await rig.engine.state
    let replica = jsonObject(Data(try state.replicaJSON().utf8))
    let persisted = jsonObject(Data(try state.persistedJSON().utf8))
    #expect(Set(replica.keys) == ["calendar", "meetingGroups"])
    #expect((replica["calendar"] as? [String: Bool]) == ["prompted": false])
    #expect((replica["meetingGroups"] as? [String: [String: Any]])?["group"]?["callTabId"] as? String == "tab")
    #expect((persisted["folders"] as? [String: Any])?[id] != nil)
    #expect(persisted["status"] == nil)
  }

  @Test func pinningACalendarOffersAlertsOnce() async {
    let rig = Rig()
    #expect(await rig.engine.offerAlertsForPinnedTab(url: "https://example.com") == false)
    #expect(await rig.engine.offerAlertsForPinnedTab(url: "https://calendar.google.com/") == true)
    #expect(await rig.engine.offerAlertsForPinnedTab(url: "https://calendar.google.com/") == false)
    await rig.engine.answerAlertOffer(confirmed: false)
    #expect(await rig.engine.state.calendar.alertLead == "never")
  }
}

@Suite struct LossyLoadTests {
  @Test func oneMalformedEntryOrUnknownSourceKeepsEveryOtherEntry() {
    let good = #"{"id":"a","source":"github","url":"u","title":"t","subtitle":"s","icon":null,"updatedAt":1}"#
    let state = LiveState.load(
      #"""
      {"folders":{"f":{"id":"f","profileId":"p","kind":"documents","name":"D","icon":null,"collapsed":false,"sources":["notion","linear"],"filters":{"authored":true,"reviewRequests":true},"createdAt":1},"bad":{"id":3}},
       "folderOrder":["f",7],
       "items":{"f":[\#(good),{"id":"b"},"junk",\#(good.replacingOccurrences(of: "\"a\"", with: "\"c\""))],"g":"broken"},
       "hidden":{"f":[{"id":"x","source":"linear"}]},
       "accounts":{"github":{"login":"o","name":null,"avatar":null,"connectedAt":1},"linear":{"login":"j","name":null,"avatar":null,"connectedAt":1},"notion":{"login":1}},
       "dismissedAlerts":["a@1",null,"b@2"]}
      """#)
    #expect(state.folders.keys.sorted() == ["f"])
    #expect(state.folders["f"]?.sources == [.notion])
    #expect(state.folderOrder == ["f"])
    #expect(state.items["f"]?.map(\.id) == ["a", "c"])
    #expect(state.items["g"] == nil)
    #expect(state.hidden["f"] == [])
    #expect(Array(state.accounts.keys) == [.github])
    #expect(state.dismissedAlerts == ["a@1", "b@2"])
  }
}
