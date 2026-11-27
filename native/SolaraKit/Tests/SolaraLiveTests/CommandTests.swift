import Foundation
import Testing

@testable import SolaraLive

@Suite struct CommandTests {
  func command(_ name: String, _ payload: String = "{}") throws -> LiveCommand {
    try LiveJSON.decode(LiveCommand.self, from: #"{"name":"\#(name)","payload":\#(payload)}"#)
  }

  @Test func folderDeletionRequiresWorkspaceAcceptance() async throws {
    let closed = Locked<[String]>([])
    let refusal = Locked(true)
    let rig = Rig(closeFolderTabs: { id in
      if refusal.current { throw LiveError(.other, "Workspace refused deletion") }
      closed.with { $0.append(id) }
    })
    let id = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [])
    let deletion = try command("removeFolder", #"{"folderId":"\#(id)"}"#)
    await #expect(throws: LiveError(.other, "Workspace refused deletion")) {
      try await rig.engine.perform(deletion)
    }
    #expect(await rig.engine.state.folders[id] != nil)
    refusal.with { $0 = false }
    _ = try await rig.engine.perform(deletion)
    #expect(closed.current == [id])
    #expect(await rig.engine.state.folders[id] == nil)
  }

  @Test func dismissAlertOnlyRecordsWhileAlertsStayInJS() async throws {
    let rig = Rig()
    await rig.engine.start(jobs: [.folders])
    _ = try await rig.engine.perform(command("dismissAlert", #"{"occurrence":"event@1"}"#))
    #expect(await rig.engine.state.dismissedAlerts == ["event@1"])
    #expect(rig.notifier.removed.current.isEmpty)
    await rig.engine.stop()
  }

  @Test func commandCreatesAndValidatesFolders() async throws {
    let rig = Rig()
    let created = try await rig.engine.perform(command("createFolder", #"{"profileId":"p","kind":"pullRequests","sources":["github"]}"#))
    let id = try #require(created.folderId)
    #expect(await rig.engine.state.folders[id]?.sources == [.github])
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("updateFolder", #"{"folderId":"missing","patch":{"name":"X"}}"#)) }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("updateFolder", #"{"folderId":"\#(id)","patch":{"unknown":true}}"#)) }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("createFolder", #"{"profileId":"p","kind":"documents","sources":["invalid"]}"#)) }
  }

  @Test func markUnreadAndImportDeduplication() async throws {
    let rig = Rig()
    let input = try command("importFolder", #"{"profileId":"p","kind":"pullRequests","source":"github"}"#)
    let results = try await withThrowingTaskGroup(of: LiveCommandResult.self) { group in
      for _ in 0..<2 { group.addTask { try await rig.engine.perform(input) } }
      var found: [LiveCommandResult] = []
      for try await result in group { found.append(result) }
      return found
    }
    #expect(results[0].folderId == results[1].folderId)
    #expect(await rig.engine.state.folders.count == 1)
    let id = try #require(results[0].folderId)
    _ = try await rig.engine.perform(command("markUnread", #"{"folderId":"\#(id)","itemId":"a"}"#))
    #expect(await rig.engine.state.unread[id] == ["a"])
    _ = try await rig.engine.perform(command("markRead", #"{"folderId":"\#(id)","itemIds":["a"]}"#))
    #expect(await rig.engine.state.unread[id] == [])
  }

  @Test func revisionsAndReplicaAdvanceTogether() async throws {
    let rig = Rig()
    let initial = try await rig.engine.currentReplica()
    let stream = await rig.engine.changes()
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next()?.revision == initial.revision)
    let created = try await rig.engine.perform(command("createFolder", #"{"profileId":"p","kind":"documents","sources":[]}"#))
    #expect(created.revision > initial.revision)
    #expect(await iterator.next()?.revision == created.revision)
    let current = try await rig.engine.currentReplica()
    #expect(current.revision == created.revision)
    #expect(current.replicaJSON.contains(created.folderId!))
    let next = try await rig.engine.perform(command("setExpandedStack", #"{"key":"stack","expanded":true}"#))
    #expect(next.revision > created.revision)
    #expect(await iterator.next()?.revision == next.revision)
  }

  @Test func persistedMutationCommandsUseTheStateRules() async throws {
    let rig = Rig()
    let a = try #require(try await rig.engine.perform(command("createFolder", #"{"profileId":"p","kind":"pullRequests","sources":[]}"#)).folderId)
    let b = try #require(try await rig.engine.perform(command("createFolder", #"{"profileId":"p","kind":"documents","sources":[]}"#)).folderId)
    _ = try await rig.engine.perform(command("updateFolder", #"{"folderId":"\#(a)","patch":{"name":"Review","icon":null,"collapsed":true,"filters":{"authored":false,"reviewRequests":true},"groupStacks":false,"showCompleted":false,"sources":["github"]}}"#))
    #expect(await rig.engine.state.folders[a]?.name == "Review")
    #expect(await rig.engine.state.folders[a]?.filters.authored == false)
    _ = try await rig.engine.perform(command("arrangeFolders", #"{"placed":[{"id":"\#(b)","after":null},{"id":"\#(a)","after":"anchor"}]}"#))
    #expect(await rig.engine.state.folderOrder == [b, a])
    let item = try LiveJSON.text(stubPR("pr", 1, "head", "main"))
    _ = try await rig.engine.perform(command("applyFetch", "{\"folderId\":\"\(a)\",\"items\":[\(item)],\"gone\":{}}"))
    _ = try await rig.engine.perform(command("markUnread", #"{"folderId":"\#(a)","itemId":"pr"}"#))
    _ = try await rig.engine.perform(command("hideItems", "{\"folderId\":\"\(a)\",\"items\":[\(item)]}"))
    #expect(await rig.engine.state.hidden[a]?.count == 1)
    _ = try await rig.engine.perform(command("unhide", #"{"folderId":"\#(a)"}"#))
    #expect(await rig.engine.state.items[a]?.count == 1)
    _ = try await rig.engine.perform(command("setExpandedStack", #"{"key":"stack","expanded":true}"#))
    _ = try await rig.engine.perform(command("updateConfig", #"{"patch":{"githubClientId":"client"}}"#))
    _ = try await rig.engine.perform(command("updateCalendarSettings", #"{"patch":{"showPreview":false,"prompted":true}}"#))
    _ = try await rig.engine.perform(command("setCalendarHidden", #"{"id":"work","hidden":true}"#))
    _ = try await rig.engine.perform(command("dismissAlert", #"{"occurrence":"event@1"}"#))
    _ = try await rig.engine.perform(command("setMeetingGroup", #"{"group":{"groupId":"g","callTabId":"t","occurrence":null,"title":"Call","start":null,"end":null,"endedAt":null}}"#))
    #expect(await rig.engine.state.meetingGroups["g"]?.title == "Call")
    _ = try await rig.engine.perform(command("setMeetingGroup", #"{"group":null,"groupId":"g"}"#))
    #expect(await rig.engine.state.meetingGroups["g"] == nil)
    #expect(await rig.engine.state.expandedStacks["stack"] == true)
    #expect(await rig.engine.state.config.githubClientId == "client")
    #expect(await rig.engine.state.calendar.hiddenCalendarIds == ["work"])
    #expect(await rig.engine.state.dismissedAlerts == ["event@1"])
    _ = try await rig.engine.perform(command("removeFolder", #"{"folderId":"\#(a)"}"#))
    _ = try await rig.engine.perform(command("removeProfile", #"{"profileId":"p"}"#))
    #expect(await rig.engine.state.folders.isEmpty)
  }

  @Test func commandWireAndInvalidFields() async throws {
    let names = "createFolder newProfileLiveFolder importFolder updateFolder removeFolder removeProfile arrangeFolders markRead markUnread hideItems unhide setExpandedStack updateConfig updateCalendarSettings setCalendarHidden dismissAlert setMeetingGroup refreshFolder manualRefresh refreshCalendar windowFocused appResignedActive liveTabDeactivated connectCalendar connectGithub connectNotion connectGoogleDrive disconnect startGithubDeviceFlow finishGithubDeviceFlow cancelGithubDeviceFlow offerAlertsForPinnedTab answerAlertOffer applyFetch setStatus".split(separator: " ")
    for name in names {
      let parsed = try command(String(name))
      #expect(try LiveJSON.decode(LiveCommand.self, from: LiveJSON.encode(parsed)) == parsed)
    }
    let rig = Rig()
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("updateFolder", #"{"folderId":"missing","patch":{"sources":null}}"#)) }
    let id = try #require(try await rig.engine.perform(command("createFolder", #"{"profileId":"p","kind":"documents"}"#)).folderId)
    for patch in [#"{"sources":null}"#, #"{"collapsed":"yes"}"#, #"{"filters":{"authored":true}}"#, #"{"filters":{"authored":true,"reviewRequests":false,"extra":1}}"#, #"{"surprise":1}"#] {
      await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("updateFolder", "{\"folderId\":\"\(id)\",\"patch\":\(patch)}")) }
    }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("updateConfig", #"{"patch":{"googleClientId":null}}"#)) }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("updateCalendarSettings", #"{"patch":{"prompted":null}}"#)) }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("disconnect", #"{"source":"unknown"}"#)) }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("finishGithubDeviceFlow", #"{"id":"missing"}"#)) }
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("cancelGithubDeviceFlow", #"{"id":"missing"}"#)) }
    #expect(throws: LiveError.self) { _ = try command("nonexistent") }
  }

  @Test func retiredConnectionCommandsAreUnknown() {
    for name in ["connectBitbucket", "connectConfluence"] {
      #expect(throws: LiveError.self) { _ = try command(name) }
    }
  }

  @Test func retiredConfigFieldsAreUnknown() async throws {
    let rig = Rig()
    for field in ["bitbucketUser", "confluenceSite", "confluenceEmail"] {
      await #expect(throws: LiveError.self) {
        _ = try await rig.engine.perform(command("updateConfig", "{\"patch\":{\"\(field)\":\"old\"}}"))
      }
    }
  }

  @Test func synchronousInitialReplicaMatchesLoadedState() async throws {
    let text = #"{"calendar":{"showPreview":false},"future":{"flag":true}}"#
    let rig = Rig(documents: [LiveState.documentName: text])
    let initial = try LiveEngine.initialReplica(documentText: text)
    let loaded = try await rig.engine.currentReplica()
    #expect(initial.revision == loaded.revision)
    #expect(initial.replicaJSON == loaded.replicaJSON)
    #expect(initial.replicaJSON.contains("future"))
    #expect(throws: (any Error).self) { _ = try LiveEngine.initialReplica(documentText: "not json") }
  }

  @Test func operationalCommandsRouteThroughTheEngine() async throws {
    let rig = Rig()
    let id = try #require(try await rig.engine.perform(command("newProfileLiveFolder", #"{"profileId":"p","kind":"documents","sources":[]}"#)).folderId)
    _ = try await rig.engine.perform(command("refreshFolder", #"{"folderId":"\#(id)"}"#))
    _ = try await rig.engine.perform(command("setStatus", #"{"folderId":"\#(id)","status":{"state":"idle","lastFetch":123,"error":null}}"#))
    #expect(await rig.engine.state.status[id]?.lastFetch == 123)
    await rig.engine.hideItems(id, [stubPR("x", 1, "h", "main")])
    _ = try await rig.engine.perform(command("manualRefresh", #"{"folderId":"\#(id)"}"#))
    #expect(await rig.engine.state.hidden[id] == nil)
    _ = try await rig.engine.perform(command("windowFocused"))
    _ = try await rig.engine.perform(command("appResignedActive"))
    #expect(await rig.engine.appActive == false)
    _ = try await rig.engine.perform(command("liveTabDeactivated", #"{"folderId":"\#(id)"}"#))
    _ = try await rig.engine.perform(command("refreshCalendar"))
    let connected = try await rig.engine.perform(command("connectCalendar"))
    #expect(connected.boolean == true)
    #expect(await rig.engine.calendarData.connected)
    let offered = try await rig.engine.perform(command("offerAlertsForPinnedTab", #"{"url":"https://calendar.google.com/calendar/u/0/r"}"#))
    #expect(offered.boolean == true)
    #expect(await rig.engine.state.calendar.prompted)
    _ = try await rig.engine.perform(command("answerAlertOffer", #"{"confirmed":false}"#))
    #expect(await rig.engine.state.calendar.alertLead == "never")
    for name in ["connectGithub", "connectNotion", "connectGoogleDrive", "disconnect", "startGithubDeviceFlow"] {
      await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command(name)) }
    }
  }

  @Test func connectionAndDeviceFlowCommandsUseIds() async throws {
    let http = FakeHTTP { request in
      if request.url.contains("device/code") {
        return json(["device_code": "device", "user_code": "CODE", "verification_uri": "https://example.com/device", "expires_in": 900, "interval": 1])
      }
      return json(["data": ["viewer": ["login": "me", "name": NSNull(), "avatarUrl": "x"]]])
    }
    let rig = Rig(http: http)
    _ = try await rig.engine.perform(command("connectGithub", #"{"token":"secret"}"#))
    #expect(await rig.engine.state.accounts[.github]?.login == "me")
    _ = try await rig.engine.perform(command("disconnect", #"{"source":"github"}"#))
    #expect(await rig.engine.state.accounts[.github] == nil)
    let begun = try await rig.engine.perform(command("startGithubDeviceFlow", #"{"clientId":"client"}"#))
    let flow = try #require(begun.deviceFlow)
    #expect(flow.userCode == "CODE")
    _ = try await rig.engine.perform(command("cancelGithubDeviceFlow", #"{"id":"\#(flow.id)"}"#))
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command("finishGithubDeviceFlow", #"{"id":"\#(flow.id)"}"#)) }
  }

  @Test func failedPollsKeepSavedItemsForFailedSources() async throws {
    let rig = Rig()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github, .notion])
    let github = stubPR("github:old", 1, "head", "main")
    var notion = stubPR("notion:old", 1, "head", "main")
    notion.id = "notion:old"
    notion.source = .notion
    await rig.engine.applyFetch(id, [github, notion], gone: [:])
    try await rig.engine.flush()
    await rig.engine.setSource(LiveSource(id: .github, name: "GitHub", kind: .pullRequests, site: "x", fetch: { _, _ in throw LiveError(.network, "down") }))
    await rig.engine.setSource(LiveSource(id: .notion, name: "Notion", kind: .pullRequests, site: "x", fetch: { _, _ in throw LiveError(.network, "down") }))
    await rig.engine.refreshFolder(id).value
    #expect(await rig.engine.state.items[id]?.map(\.id) == [github.id, notion.id])
    try await rig.engine.flush()
    #expect(LiveState.load(rig.documents.read(LiveState.documentName)).items[id]?.count == 2)
    let savedNotion = notion
    await rig.engine.setSource(LiveSource(id: .notion, name: "Notion", kind: .pullRequests, site: "x", fetch: { _, _ in [savedNotion] }))
    await rig.engine.refreshFolder(id).value
    #expect(Set(await rig.engine.state.items[id]?.map(\.id) ?? []) == [github.id, notion.id])
    try await rig.engine.flush()
    #expect(LiveState.load(rig.documents.read(LiveState.documentName)).items[id]?.count == 2)
  }

  @Test func dismissedAlertsKeepOnlyTheLastTwoHundred() async throws {
    let rig = Rig()
    for index in 0..<201 {
      _ = try await rig.engine.perform(command("dismissAlert", "{\"occurrence\":\"event@\(index)\"}"))
    }
    let ids = await rig.engine.state.dismissedAlerts
    #expect(ids.count == 200)
    #expect(ids.first == "event@1")
    #expect(ids.last == "event@200")
  }

  @Test func folderOnlyJobsLeaveCalendarIdle() async throws {
    let rig = Rig(documents: [CalendarFixture.documentName: Fixture.text("calendar-fixture.json")], environment: LiveEnvironment(calendarFixture: true))
    await rig.engine.start(jobs: [.folders])
    await rig.clock.advance(by: 600_000)
    #expect(await rig.engine.calendarData.access == .notDetermined)
    #expect(rig.notifier.posted.current.isEmpty)
    await rig.engine.stop()
  }

  @Test func quitTextIsTheDebouncedTextAndBlockedOnUnreadableLoad() async throws {
    let rig = Rig()
    let latest = Locked<String?>(nil)
    await rig.engine.setPersistedTextSink { text in latest.with { $0 = text } }
    _ = try await rig.engine.perform(command("updateConfig", #"{"patch":{"githubClientId":"x"}}"#))
    let text = try #require(latest.current)
    await rig.clock.advance(by: 800)
    #expect(rig.documents.read(LiveState.documentName) == text)
    let broken = Rig(documents: [LiveState.documentName: "not json"])
    let blocked = Locked<String?>(nil)
    await broken.engine.setPersistedTextSink { text in blocked.with { $0 = text } }
    await broken.engine.setExpandedStack("x", true)
    #expect(blocked.current == nil)
  }
}

@Suite struct BlockedDocumentCommandTests {
  @Test func mutationsAreRefusedWhileLiveJsonCannotBeRead() async throws {
    let rig = Rig(documents: [LiveState.documentName: "not json"])
    await #expect(throws: LiveError.self) {
      _ = try await rig.engine.perform(LiveJSON.decode(LiveCommand.self, from: #"{"name":"createFolder","payload":{"profileId":"p","kind":"documents"}}"#))
    }
    #expect(await rig.engine.state.folders.isEmpty)
  }
}
