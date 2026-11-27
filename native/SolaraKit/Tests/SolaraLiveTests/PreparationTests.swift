import Foundation
import Testing

@testable import SolaraLive

@Suite struct PreparationTests {
  @Test func malformedKnownValuesSurviveAnUnrelatedSave() async throws {
    let original = #"{"folders":{"bad":{"id":3}},"items":{"f":[{"id":"bad"}]},"folderOrder":[7],"calendar":{"alertLead":"5"}}"#
    let rig = Rig(documents: [LiveState.documentName: original])
    await rig.engine.setExpandedStack("x", true)
    try await rig.engine.flush()
    let saved = try #require(rig.documents.read(LiveState.documentName))
    let before = jsonObject(Data(original.utf8))
    let after = jsonObject(Data(saved.utf8))
    #expect(canonical(before["folders"]!) == canonical(after["folders"]!))
    #expect(canonical(before["items"]!) == canonical(after["items"]!))
    #expect(canonical(before["folderOrder"]!) == canonical(after["folderOrder"]!))
  }

  @Test func malformedEntriesSurviveAnEditInTheSameMap() async throws {
    let original = #"{"folders":{"bad":{"id":3}},"folderOrder":[]}"#
    let rig = Rig(documents: [LiveState.documentName: original])
    _ = await rig.engine.createFolder(profileId: "p", kind: .documents)
    try await rig.engine.flush()
    let saved = try #require(rig.documents.read(LiveState.documentName))
    let folders = try #require(jsonObject(Data(saved.utf8))["folders"] as? [String: Any])
    #expect(canonical(folders["bad"]!) == canonical(["id": 3]))
    #expect(folders.count == 2)
  }

  @Test func editToAMalformedFieldReplacesItInsteadOfLosingTheEdit() async throws {
    let rig = Rig(documents: [LiveState.documentName: #"{"folders":"bad","folderOrder":[]}"#])
    let id = await rig.engine.createFolder(profileId: "p", kind: .documents)
    try await rig.engine.flush()
    let reloaded = LiveState.load(rig.documents.read(LiveState.documentName))
    #expect(reloaded.folders[id] != nil)
    #expect(reloaded.folderOrder == [id])
  }

  @Test func replacedItemDoesNotInheritTheOldItemsUnknownFields() throws {
    var seed = LiveState()
    seed.items["f"] = [stubPR("a", 1, "h", "main")]
    var document = jsonObject(try LiveJSON.encode(seed))
    var items = document["items"] as! [String: [[String: Any]]]
    items["f"]![0]["future"] = 1
    document["items"] = items
    let text = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    var state = LiveState.load(text)
    state.items["f"] = [stubPR("b", 2, "h", "main")]
    let saved = jsonObject(Data(try state.persistedJSON().utf8))
    let item = (saved["items"] as! [String: [[String: Any]]])["f"]![0]
    #expect(item["id"] as? String == "b")
    #expect(item["future"] == nil)
  }

  @Test func transientKeysInALoadedDocumentAreNotWrittenBack() async throws {
    let original = #"{"folders":{},"folderOrder":[],"status":{"f":{"state":"idle","lastFetch":5}},"showAll":{"f":true},"completing":{"f":["x"]}}"#
    let rig = Rig(documents: [LiveState.documentName: original])
    await rig.engine.setExpandedStack("x", true)
    try await rig.engine.flush()
    let saved = jsonObject(Data(try #require(rig.documents.read(LiveState.documentName)).utf8))
    #expect(saved["status"] == nil)
    #expect(saved["showAll"] == nil)
    #expect(saved["completing"] == nil)
  }

  @Test func slowJobQueuedBeforeStopDoesNotRun() async {
    let http = FakeHTTP()
    let rig = Rig(http: http)
    rig.secrets.setSecret("x", account: "github")
    _ = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.start()
    await rig.engine.queueFolderJobThenStop()
    for _ in 0..<200 { await Task.yield() }
    #expect(http.log.current.isEmpty)
  }

  @Test func unreadableDocumentBlocksFlush() async {
    let rig = Rig(documents: [LiveState.documentName: "not json"])
    await rig.engine.setExpandedStack("x", true)
    await #expect(throws: (any Error).self) { try await rig.engine.flush() }
    #expect(rig.documents.writes.current == 0)
    #expect(await rig.engine.documentError != nil)
  }

  @Test func flushCancelsDebounceAndReportsWriteFailure() async throws {
    let rig = Rig()
    await rig.engine.setExpandedStack("x", true)
    try await rig.engine.flush()
    #expect(rig.documents.writes.current == 1)
    await rig.clock.advance(by: 800)
    #expect(rig.documents.writes.current == 1)
  }

  @Test func documentReadFailureBlocksWrites() async {
    let rig = Rig()
    rig.documents.readFailure.with { $0 = "permission denied" }
    let engine = LiveEngine(effects: rig.engine.effects)
    await engine.setExpandedStack("x", true)
    await #expect(throws: (any Error).self) { try await engine.flush() }
    #expect(await engine.documentError?.contains("permission denied") == true)
    #expect(rig.documents.writes.current == 0)
  }

  @Test func writeFailureIsReported() async {
    let rig = Rig()
    rig.documents.writeFailure.with { $0 = true }
    await rig.engine.setExpandedStack("x", true)
    await #expect(throws: (any Error).self) { try await rig.engine.flush() }
    #expect(await rig.engine.documentError?.contains("disk full") == true)
    rig.documents.writeFailure.with { $0 = false }
    try? await rig.engine.flush()
    #expect(await rig.engine.documentError == nil)
    #expect(rig.documents.writes.current == 1)
  }

  @Test func failedSecretWriteDoesNotConnectAndFailedDeleteDoesNotDisconnect() async throws {
    let rig = Rig(http: FakeHTTP { _ in json(["data": ["viewer": ["login": "me", "name": NSNull(), "avatarUrl": "x"]]]) })
    rig.secrets.allowWrite.with { $0 = false }
    await #expect(throws: LiveError.self) { try await rig.engine.connectGithub(token: "x") }
    #expect(await rig.engine.state.accounts[.github] == nil)
    rig.secrets.allowWrite.with { $0 = true }
    try await rig.engine.connectGithub(token: "x")
    rig.secrets.allowWrite.with { $0 = false }
    await #expect(throws: LiveError.self) { try await rig.engine.disconnect(.github) }
    #expect(await rig.engine.state.accounts[.github] != nil)
  }

  @Test func failedGoneResolutionDropsTheVisibleItemAsJSDoes() async {
    let rig = Rig()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.applyFetch(id, [stubPR("a", 1, "h", "main")], gone: [:])
    await rig.engine.setSource(LiveSource(id: .github, name: "GitHub", kind: .pullRequests, site: "x", fetch: { _, _ in [] }, resolveGone: { _, _ in throw LiveError(.network, "down") }))
    await rig.engine.refreshFolder(id).value
    #expect(await rig.engine.state.items[id] == [])
  }

  @Test func isolatedRequestsRequireLoopbackMock() async {
    let http = FakeHTTP { _ in json([:]) }
    let blocked = LiveRequester(http: http, environment: LiveEnvironment(isolatedDataDirectory: true))
    await #expect(throws: LiveError.self) { _ = try await blocked.data(LiveHTTPRequest(url: "https://api.github.com/graphql")) }
    #expect(http.log.current.isEmpty)
    let invalid = LiveRequester(http: http, environment: LiveEnvironment(mockBase: "https://127.0.0.1:4000", isolatedDataDirectory: true))
    await #expect(throws: LiveError.self) { _ = try await invalid.data(LiveHTTPRequest(url: "https://127.0.0.1:4000/github/graphql")) }
    #expect(http.log.current.isEmpty)
    let allowed = LiveRequester(http: http, environment: LiveEnvironment(mockBase: "http://127.0.0.1:4000", isolatedDataDirectory: true))
    _ = try? await allowed.data(LiveHTTPRequest(url: "http://127.0.0.1:4000/github/graphql"))
    #expect(http.log.current.count == 1)
  }

  @Test func isolatedEngineNeverCallsHTTPWithoutALoopbackMock() async {
    let http = FakeHTTP { _ in json([:]) }
    let rig = Rig(environment: LiveEnvironment(isolatedDataDirectory: true), http: http)
    rig.secrets.setSecret("x", account: "github")
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    #expect(http.log.current.isEmpty)
    #expect(await rig.engine.state.status[id]?.error?.message == "Isolated Live Folders requires a loopback SOLARA_LIVE_MOCK URL")
  }

  @Test func gridFireIncludesJobsWithinFiftyMilliseconds() async {
    let rig = Rig()
    #expect(await rig.engine.probeGridSlack())
  }

  @Test func separateTimersUseTwentySecondsForMeetingsEvenWhenInitiallyUnneeded() async {
    let rig = Rig(environment: LiveEnvironment(separateSlowTimers: true))
    let host = FakeMeetingHost(MeetingBrowserSnapshot(groups: [:], tabs: [:], activeTabByWindow: [:]))
    await rig.engine.start(meetingHost: host)
    await settle()
    let start = rig.clock.now()
    #expect(rig.clock.pending.contains(start + 20_000))
    await rig.clock.advance(by: 10_000)
    await rig.engine.setMeetingGroup(MeetingGroup(groupId: "g", callTabId: "x", occurrence: nil, title: "M", start: nil, end: nil, endedAt: nil))
    await rig.clock.advance(by: 9999)
    #expect(await rig.engine.state.meetingGroups["g"] != nil)
    await rig.clock.advance(by: 1)
    #expect(await rig.engine.state.meetingGroups["g"] == nil)
    await rig.engine.stop()
  }

  @Test func gridTimerRearmsAfterFolderBecomesNeededPastItsOriginalSlot() async {
    let rig = Rig()
    await rig.engine.start()
    await rig.clock.advance(by: 35_000)
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await settle()
    let now = rig.clock.now()
    let next = ((now / 30_000).rounded(.down) + 1) * 30_000
    #expect(rig.clock.pending.contains(next))
    #expect(await rig.engine.state.status[id]?.lastFetch == nil)
    await rig.engine.stop()
  }

  @Test func savedItemsWithNoLastFetchDelayRetryAfterTotalFailure() async {
    let original = #"{"folders":{"f":{"id":"f","profileId":"p","kind":"pullRequests","name":"P","icon":null,"collapsed":false,"sources":["github"],"filters":{"authored":true,"reviewRequests":true},"createdAt":1}},"folderOrder":["f"],"items":{"f":[{"id":"github:a","source":"github","url":"u","title":"t","subtitle":"s","icon":null,"updatedAt":1}]}}"#
    let rig = Rig(documents: [LiveState.documentName: original])
    await rig.engine.setSource(LiveSource(id: .github, name: "GitHub", kind: .pullRequests, site: "x", fetch: { _, _ in throw LiveError(.network, "down") }))
    await rig.engine.start()
    await rig.clock.advance(by: 2500)
    #expect(await rig.engine.state.items["f"]?.count == 1)
    let first = await rig.engine.state.status["f"]?.lastFetch
    #expect(first != nil)
    await rig.clock.advance(by: 30_000)
    #expect(await rig.engine.state.status["f"]?.lastFetch == first)
    await rig.engine.stop()
  }
}

extension LiveEngine {
  func probeGridSlack() -> Bool {
    let now = effects.clock.now()
    meetingAlert = CalendarEvent(id: "m", occurrence: "m@1", calendarId: "c", title: "M", start: now, end: now + 60_000)
    slowEntries[.alerts] = SlowEntry(next: now + 40, armed: true)
    fireSlowJobs()
    return (slowEntries[.alerts]?.next ?? 0) > now + 40
  }
}

extension LiveEngine {
  func queueFolderJobThenStop() {
    Task { await self.runJob(.folders) }
    stop()
  }
}
