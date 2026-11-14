import SolaraModel
import SolaraStore
import Synchronization
import Testing

private func cliStore() -> Store {
  Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "cli")), checksInvariants: true, clock: { 1_000 })
}

private func cliWindow(_ store: Store, privateWindow: Bool = false) throws -> (String, [String]) {
  let window = try store.dispatch(Command("createWindow", [["url": "https://one.example/", "incognito": .bool(privateWindow)]])).result!.string!
  for url in ["https://two.example/", "https://three.example/"] {
    try store.dispatch(Command("newTab", [.string(window), ["url": .string(url)]]))
  }
  return (window, store.state.windows[window]!.tabIds)
}

private func cliRequest(_ operation: String, _ values: JSONObject = [:]) -> JSONValue {
  var values = values
  values["operation"] = .string(operation)
  return .object(values)
}

private func cliCreated(_ store: Store, _ operation: String, _ ids: [String]) throws -> String {
  try store.cliSidebar(cliRequest(operation, ["name": "Work", "tabs": JSONValue(ids)]))["id"]!.string!
}

@Suite struct CliSidebarTests {
  @Test func groupsUseExistingCreateRenameAndDeleteCommands() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let created = try store.cliSidebar(cliRequest("group.create", ["name": "Work", "color": "blue", "tabs": JSONValue([ids[0], ids[1]])]))
    let group = created["id"]!.string!
    #expect(created["changes"]?.array?.first?.string?.contains("color blue") == true)
    #expect(store.state.groups[group]?.tabIds == [ids[0], ids[1]])
    #expect(store.state.groups[group]?.color == "blue")
    #expect(store.state.groups[group]?.pinned == false)
    try store.cliSidebar(cliRequest("group.rename", ["id": .string(group), "name": "Research"]))
    #expect(store.state.groups[group]?.name == "Research")
    try store.cliSidebar(cliRequest("group.delete", ["id": .string(group)]))
    #expect(store.state.groups[group] == nil)
    #expect(store.state.tabs[ids[0]] == nil)
    #expect(store.state.deletedGroups.last?.group.name == "Research")
  }

  @Test func foldersUseExistingTileFolderActionsAndDeleteKeepsTabs() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let folder = try cliCreated(store, "folder.create", [ids[0], ids[1]])
    #expect(store.state.tabs[ids[0]]?.tileFolder?.id == folder)
    #expect(store.state.tabs[ids[1]]?.pinned == true)
    try store.cliSidebar(cliRequest("folder.rename", ["id": .string(folder), "name": "Apps"]))
    #expect(store.state.tabs[ids[0]]?.tileFolder?.name == "Apps")
    try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[2]), "toFolder": .string(folder)]))
    #expect(store.state.tabs[ids[2]]?.tileFolder?.id == folder)
    try store.cliSidebar(cliRequest("folder.delete", ["id": .string(folder)]))
    #expect(ids.allSatisfy { store.state.tabs[$0]?.tileFolder == nil && store.state.tabs[$0]?.pinned == true })
  }

  @Test func tabMovesIntoGroupsUnpinsAndUsesWholeSplitRows() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let group = try cliCreated(store, "group.create", [ids[0]])
    try store.dispatch(Command("createSplit", [JSONValue([ids[1], ids[2]])]))
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[1])]))
    try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[1]), "toGroup": .string(group)]))
    #expect(Set(store.state.groups[group]!.tabIds) == Set(ids))
    #expect(ids.allSatisfy { store.state.tabs[$0]?.pinned == false })
  }

  @Test func pinUnpinAndRenameAreSidebarEdits() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[1])]))
    #expect(store.state.tabs[ids[1]]?.pinned == true)
    try store.cliSidebar(cliRequest("tab.rename", ["id": .string(ids[1]), "title": "Inbox"]))
    #expect(store.state.tabs[ids[1]]?.customTitle == "Inbox")
    try store.cliSidebar(cliRequest("tab.unpin", ["id": .string(ids[1])]))
    #expect(store.state.tabs[ids[1]]?.pinned == false)
  }

  @Test func reorderBeforeAndAfterPreservesContainer() throws {
    let store = cliStore()
    let (window, ids) = try cliWindow(store)
    let group = try cliCreated(store, "group.create", ids)
    try store.cliSidebar(cliRequest("tab.reorder", ["id": .string(ids[2]), "before": .string(ids[0])]))
    #expect(store.state.windows[window]?.tabIds == [ids[2], ids[0], ids[1]])
    try store.cliSidebar(cliRequest("tab.reorder", ["id": .string(ids[2]), "after": .string(ids[1])]))
    #expect(store.state.windows[window]?.tabIds == ids)
    #expect(store.state.groups[group]?.tabIds == ids)
  }

  @Test func reorderMovesSplitRowsAsOneUnit() throws {
    let store = cliStore()
    let (window, ids) = try cliWindow(store)
    try store.dispatch(Command("createSplit", [JSONValue([ids[0], ids[1]])]))
    try store.cliSidebar(cliRequest("tab.reorder", ["id": .string(ids[2]), "after": .string(ids[0])]))
    #expect(store.state.windows[window]?.tabIds == ids)
    try store.cliSidebar(cliRequest("tab.reorder", ["id": .string(ids[1]), "after": .string(ids[2])]))
    #expect(store.state.windows[window]?.tabIds == [ids[2], ids[0], ids[1]])
  }

  @Test func windowAndProfileMovesUseNativeActions() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let (target, _) = try cliWindow(store)
    let moved = try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[0]), "toWindow": .string(target)]))
    #expect(moved["changes"]?.array?.first?.string?.contains("to window") == true)
    #expect(store.state.tabs[ids[0]]?.windowId == target)
    let profile = try store.dispatch(Command("createProfile", [["name": "Work"]])).result!.string!
    let changedProfile = try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[0]), "toProfile": "Work"]))
    #expect(changedProfile["changes"]?.array?.first?.string?.contains("fresh navigation") == true)
    #expect(store.state.tabs[ids[0]]?.profileId == profile)
    #expect(store.state.tabs[ids[0]]?.adoptId == nil)
  }

  @Test func everyDryRunLeavesStateRevisionAndIdSourceUntouched() throws {
    let store = cliStore()
    let (window, ids) = try cliWindow(store)
    let group = try cliCreated(store, "group.create", [ids[0]])
    let folder = try cliCreated(store, "folder.create", [ids[1]])
    try store.dispatch(Command("createProfile", [["name": "Work"]]))
    let (other, _) = try cliWindow(store)
    let requests: [JSONValue] = [
      cliRequest("group.create", ["name": "New", "tabs": JSONValue([ids[2]])]),
      cliRequest("folder.create", ["name": "New", "tabs": JSONValue([ids[2]])]),
      cliRequest("group.rename", ["id": .string(group), "name": "New"]),
      cliRequest("group.delete", ["id": .string(group)]),
      cliRequest("folder.rename", ["id": .string(folder), "name": "New"]),
      cliRequest("folder.delete", ["id": .string(folder)]),
      cliRequest("tab.pin", ["id": .string(ids[2])]),
      cliRequest("tab.unpin", ["id": .string(ids[1])]),
      cliRequest("tab.rename", ["id": .string(ids[2]), "title": "New"]),
      cliRequest("tab.reorder", ["id": .string(ids[2]), "after": .string(ids[2])]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toGroup": .string(group)]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toFolder": .string(folder)]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toWindow": .string(other)]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toProfile": "Work"]),
    ]
    let state = store.state
    let rev = store.rev
    let serial = store.memory.ids
    for request in requests {
      var dry = request.object!
      dry["dryRun"] = true
      let result = try store.cliSidebar(.object(dry))
      #expect(result["dryRun"] == true)
      #expect(result["changes"]?.array?.isEmpty == false)
      #expect(store.state == state)
      #expect(store.rev == rev)
      #expect(store.memory.ids == serial)
    }
    #expect(store.state.windows[window] != nil)
  }

  @Test func unknownIdsMalformedRequestsAndCrossContainerReordersAreAtomicErrors() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let (other, _) = try cliWindow(store)
    let group = try cliCreated(store, "group.create", [ids[0]])
    let folder = try cliCreated(store, "folder.create", [ids[1]])
    let requests: [JSONValue] = [
      cliRequest("group.create", ["name": "New", "tabs": JSONValue([ids[2], "missing"])]),
      cliRequest("folder.create", ["name": "New", "tabs": JSONValue([ids[2], "missing"])]),
      cliRequest("group.create", ["name": "New", "color": "invalid", "tabs": JSONValue([ids[2]])]),
      cliRequest("group.rename", ["id": "missing", "name": "New"]), cliRequest("group.delete", ["id": "missing"]),
      cliRequest("folder.rename", ["id": "missing", "name": "New"]), cliRequest("folder.delete", ["id": "missing"]),
      cliRequest("tab.pin", ["id": "missing"]), cliRequest("tab.unpin", ["id": "missing"]),
      cliRequest("tab.rename", ["id": "missing", "title": "New"]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toGroup": "missing"]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toFolder": "missing"]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toWindow": "missing"]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toProfile": "missing"]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toGroup": .string(group), "toFolder": .string(folder)]),
      cliRequest("tab.reorder", ["id": .string(ids[2]), "before": "missing"]),
      cliRequest("tab.reorder", ["id": .string(ids[2]), "before": .string(ids[0])]),
      cliRequest("tab.move", ["id": .string(ids[2]), "toGroup": .string(group), "extra": true]),
      cliRequest("tab.rename", ["id": .string(ids[2]), "title": "New", "dryRun": "yes"]),
      cliRequest("folder.create", ["name": "New", "tabs": []]),
      cliRequest("group.create", ["name": "New", "windowId": .string(other), "tabs": JSONValue([ids[2]])]),
    ]
    let before = store.state
    let rev = store.rev
    for request in requests {
      #expect(throws: CommandError.self) { try store.cliSidebar(request) }
      #expect(store.state == before)
      #expect(store.rev == rev)
    }
  }

  @Test func privateSourcesDestinationsAndFocusedFallbackAreRefused() throws {
    let store = cliStore()
    let (_, normal) = try cliWindow(store)
    let (privateWindow, privateTabs) = try cliWindow(store, privateWindow: true)
    let privateProfile = store.state.tabs[privateTabs[0]]!.profileId
    let privateGroup = try store.dispatch(Command("createGroup", [JSONValue(privateTabs), ["name": "Secret"]])).result!.string!
    let requests: [JSONValue] = [
      cliRequest("tab.pin", ["id": .string(privateTabs[0])]),
      cliRequest("tab.move", ["id": .string(normal[0]), "toWindow": .string(privateWindow)]),
      cliRequest("tab.move", ["id": .string(normal[0]), "toProfile": .string(privateProfile)]),
      cliRequest("tab.move", ["id": .string(normal[0]), "toGroup": .string(privateGroup)]),
      cliRequest("group.rename", ["id": .string(privateGroup), "name": "Leak"]),
      cliRequest("group.create", ["name": "Leak", "tabs": JSONValue([normal[0], privateTabs[0]])]),
      cliRequest("folder.create", ["name": "Leak", "windowId": .string(privateWindow)]),
    ]
    for request in requests {
      #expect(throws: CommandError.self) { try store.cliSidebar(request) }
    }
    try store.dispatch(Command("setFocusedWindow", [.string(privateWindow)]))
    #expect(throws: CommandError.self) { try store.cliSidebar(cliRequest("group.create", ["name": "Leak"])) }
    let inventory = try store.cliSidebar(cliRequest("sidebar.list"))
    #expect(inventory["windows"]?.array?.contains { $0["id"]?.string == privateWindow } == false)
    #expect(inventory["tabs"]?.array?.contains { $0["id"]?.string == privateTabs[0] } == false)
    #expect(inventory["groups"]?.array?.contains { $0["id"]?.string == privateGroup } == false)
  }

  @Test func dryRunDoesNotDrainUnrelatedQueuedEngineEdits() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    store.enqueueSequenced(Command("updateTab", [.string(ids[0]), ["customTitle": "Queued"]]))
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[0]), "dryRun": true]))
    #expect(store.displayState.tabs[ids[0]]?.customTitle == nil)
    #expect(store.displayState.tabs[ids[0]]?.pinned == false)
  }

  @Test func omittedTabsUseActiveTabAndMissingPageFails() throws {
    let store = cliStore()
    #expect(throws: CommandError.self) { try store.cliSidebar(cliRequest("group.create", ["name": "No page"])) }
    let (window, ids) = try cliWindow(store)
    try store.dispatch(Command("setFocusedWindow", [.string(window)]))
    try store.dispatch(Command("activate", [.string(ids[1])]))
    let group = try store.cliSidebar(cliRequest("group.create", ["name": "Active"]))["id"]!.string!
    #expect(store.state.groups[group]?.tabIds == [ids[1]])
  }
}

extension CliSidebarTests {
  @Test func mutationsPublishExistingNativeCommandsAndNormalSyncOrigin() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let commands = Mutex<[String]>([])
    let origins = Mutex<[Origin]>([])
    store.subscribe { commit in
      commands.withLock { $0.append(contentsOf: commit.commands.map(\.name)) }
      origins.withLock { $0.append(commit.origin) }
    }
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[0])]))
    try store.cliSidebar(cliRequest("tab.rename", ["id": .string(ids[0]), "title": "Pinned"]))
    let group = try cliCreated(store, "group.create", [ids[0]])
    #expect(commands.withLock { $0 } == ["pinTabs", "updateTab", "pinTabs", "createGroup"])
    #expect(origins.withLock { $0 }.allSatisfy { $0 == .native })
    #expect(store.state.groups[group]?.pinned == false)
    #expect(store.state.tabs[ids[0]]?.pinned == false)
  }

  @Test func repeatedPinAndUnpinDoNotReorderExistingTabs() throws {
    let store = cliStore()
    let (window, ids) = try cliWindow(store)
    try store.cliSidebar(cliRequest("tab.unpin", ["id": .string(ids[0])]))
    #expect(store.state.windows[window]?.tabIds == ids)
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[0])]))
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[1])]))
    let order = store.state.windows[window]?.tabIds
    let rev = store.rev
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[0])]))
    #expect(store.state.windows[window]?.tabIds == order)
    #expect(store.rev == rev)
    try store.cliSidebar(cliRequest("tab.rename", ["id": .string(ids[0]), "title": ""]))
    #expect(store.state.tabs[ids[0]]?.customTitle == nil)
  }

  @Test func folderEditsMirrorThroughTheNativePinActions() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let (second, _) = try cliWindow(store)
    let folder = try cliCreated(store, "folder.create", [ids[0], ids[1]])
    let copies = store.state.windows[second]!.tabIds.filter { store.state.tabs[$0]?.tileFolder?.id == folder }
    #expect(copies.count == 2)
    try store.dispatch(Command("setFocusedWindow", [.string(second)]))
    try store.cliSidebar(cliRequest("folder.rename", ["id": .string(folder), "name": "Mirrored"]))
    #expect(store.state.tabs.values.filter { $0.tileFolder?.id == folder }.allSatisfy { $0.tileFolder?.name == "Mirrored" })
    try store.cliSidebar(cliRequest("folder.delete", ["id": .string(folder)]))
    #expect(store.state.tabs.values.allSatisfy { $0.tileFolder?.id != folder })
    #expect(copies.allSatisfy { store.state.tabs[$0] != nil })
  }

  @Test func ambiguousProfilesAndCrossWindowGroupsFailWithoutEdits() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let (_, otherIds) = try cliWindow(store)
    let group = try cliCreated(store, "group.create", [otherIds[0]])
    for _ in 0..<2 { try store.dispatch(Command("createProfile", [["name": "Work"]])) }
    let before = store.state
    let requests = [
      cliRequest("tab.move", ["id": .string(ids[0]), "toProfile": "Work"]),
      cliRequest("tab.move", ["id": .string(ids[0]), "toGroup": .string(group)]),
      cliRequest("group.create", ["name": "Mixed", "tabs": JSONValue([ids[0], otherIds[0]])]),
      cliRequest("folder.create", ["name": "Mixed", "tabs": JSONValue([ids[0], otherIds[0]])]),
    ]
    for request in requests {
      #expect(throws: CommandError.self) { try store.cliSidebar(request) }
      #expect(store.state == before)
    }
  }

  @Test func foldersRejectPrivateOwnersAndSplitRows() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let (_, privateIds) = try cliWindow(store, privateWindow: true)
    let privateFolder = try store.dispatch(Command("newTileFolder", [JSONValue([privateIds[0]]), "Private"])).result!.string!
    #expect(throws: CommandError.self) { try store.cliSidebar(cliRequest("folder.rename", ["id": .string(privateFolder), "name": "No"])) }
    #expect(throws: CommandError.self) { try store.cliSidebar(cliRequest("folder.delete", ["id": .string(privateFolder)])) }
    let folder = try cliCreated(store, "folder.create", [ids[0]])
    try store.dispatch(Command("createSplit", [JSONValue([ids[1], ids[2]])]))
    let before = store.state
    #expect(throws: CommandError.self) { try store.cliSidebar(cliRequest("folder.create", ["name": "No", "tabs": JSONValue([ids[1]])])) }
    #expect(throws: CommandError.self) { try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[1]), "toFolder": .string(folder)])) }
    #expect(store.state == before)
  }
}

extension CliSidebarTests {
  @Test func reorderWithinATileFolderKeepsItsMembershipAndName() throws {
    let store = cliStore()
    let (window, ids) = try cliWindow(store)
    let folder = try cliCreated(store, "folder.create", ids)
    try store.cliSidebar(cliRequest("tab.reorder", ["id": .string(ids[2]), "before": .string(ids[0])]))
    #expect(store.state.windows[window]?.tabIds == [ids[2], ids[0], ids[1]])
    #expect(ids.allSatisfy { store.state.tabs[$0]?.tileFolder?.id == folder && store.state.tabs[$0]?.tileFolder?.name == "Work" })
    try store.cliSidebar(cliRequest("tab.reorder", ["id": .string(ids[2]), "after": .string(ids[1])]))
    #expect(store.state.windows[window]?.tabIds == ids)
    #expect(ids.allSatisfy { store.state.tabs[$0]?.tileFolder?.id == folder })
  }

  @Test func unpinLeavesAPinnedGroupAndPinSplitKeepsAllPanes() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let group = try store.dispatch(Command("groupTabs", [JSONValue([ids[0]]), ["pinned": true]])).result!.string!
    #expect(store.state.inPinnedContainer(ids[0]))
    try store.cliSidebar(cliRequest("tab.unpin", ["id": .string(ids[0])]))
    #expect(!store.state.inPinnedContainer(ids[0]))
    #expect(store.state.groups[group] == nil)
    try store.dispatch(Command("createSplit", [JSONValue([ids[1], ids[2]])]))
    try store.cliSidebar(cliRequest("tab.pin", ["id": .string(ids[1])]))
    #expect([ids[1], ids[2]].allSatisfy { store.state.tabs[$0]?.pinned == true && store.state.tabs[$0]?.pinnedAsRow == true })
    try store.cliSidebar(cliRequest("tab.unpin", ["id": .string(ids[2])]))
    #expect([ids[1], ids[2]].allSatisfy { store.state.tabs[$0]?.pinned == false })
  }
}

extension CliSidebarTests {
  @Test func profilePrivacyUsesIdentityRatherThanDisplayName() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let name = "incognito: research"
    let profile = try store.dispatch(Command("createProfile", [["name": .string(name)]])).result!.string!
    try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[0]), "toProfile": .string(name)]))
    #expect(store.state.tabs[ids[0]]?.profileId == profile)
  }

  @Test func privateFolderDestinationHasAClearPrivateRefusal() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let (_, privateIds) = try cliWindow(store, privateWindow: true)
    let folder = try store.dispatch(Command("newTileFolder", [JSONValue([privateIds[0]]), "Private"])).result!.string!
    do {
      try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[0]), "toFolder": .string(folder)]))
      Issue.record("A private folder was accepted")
    } catch {
      #expect(String(describing: error).contains("Private"))
    }
  }
}


private func cliRejected(_ store: Store, _ request: JSONValue, containing: String? = nil) throws {
  for dryRun in [true, false] {
    var values = request.object!
    values["dryRun"] = .bool(dryRun)
    let state = store.displayState
    let rev = store.rev
    let ids = store.memory.ids
    do {
      try store.cliSidebar(.object(values))
      Issue.record("Invalid sidebar request was accepted")
    } catch {
      let message = String(describing: error)
      #expect(message.unicodeScalars.count <= 1024)
      if let containing { #expect(message.contains(containing)) }
    }
    #expect(store.displayState == state)
    #expect(store.rev == rev)
    #expect(store.memory.ids == ids)
  }
}

private func cliManyTabs(_ count: Int) throws -> (Store, String, [String]) {
  let source = cliStore()
  let (window, _) = try cliWindow(source)
  var state = source.state
  let profile = state.windows[window]!.profileId
  state.tabs = Table()
  let ids = (0..<count).map { "tab-\($0)" }
  for id in ids { state.tabs[id] = Tab(id: id, windowId: window, profileId: profile, url: "https://example.com/", now: 1_000) }
  state.windows[window]!.tabIds = ids
  state.windows[window]!.activeTabIds[profile] = ids[0]
  return (Store(state: state, memory: StoreMemory(ids: IdSource(launch: "limits")), checksInvariants: true, clock: { 1_000 }), window, ids)
}

extension CliSidebarTests {
  @Test func textLimitsPreserveAcceptedValuesAndRejectOversizedRawInputs() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let group = try cliCreated(store, "group.create", [ids[0]])
    let folder = try cliCreated(store, "folder.create", [ids[1]])
    for size in [255, 256] {
      let text = String(repeating: "😀", count: size)
      let requests = [
        cliRequest("group.create", ["name": .string(text), "tabs": JSONValue([ids[2]])]),
        cliRequest("folder.create", ["name": .string(text), "tabs": JSONValue([ids[2]])]),
        cliRequest("group.rename", ["id": .string(group), "name": .string(text)]),
        cliRequest("folder.rename", ["id": .string(folder), "name": .string(text)]),
        cliRequest("tab.rename", ["id": .string(ids[2]), "title": .string(text)]),
      ]
      for request in requests {
        var dry = request.object!
        dry["dryRun"] = true
        #expect(try store.cliSidebar(.object(dry))["changes"]?.array?.first?.string?.contains(text) == true)
        #expect(try store.cliSidebar(request)["changes"]?.array?.first?.string?.contains(text) == true)
      }
      #expect(store.state.groups[group]?.name == text)
      #expect(store.state.tabs[ids[1]]?.tileFolder?.name == text)
      #expect(store.state.tabs[ids[2]]?.customTitle == text)
    }
    for text in [String(repeating: "x", count: 257), String(repeating: " ", count: 257) + "x", "e" + String(repeating: "\u{301}", count: 256)] {
      for request in [
        cliRequest("group.create", ["name": .string(text), "tabs": JSONValue([ids[2]])]),
        cliRequest("folder.create", ["name": .string(text), "tabs": JSONValue([ids[2]])]),
        cliRequest("group.rename", ["id": .string(group), "name": .string(text)]),
        cliRequest("folder.rename", ["id": .string(folder), "name": .string(text)]),
        cliRequest("tab.rename", ["id": .string(ids[2]), "title": .string(text)]),
      ] { try cliRejected(store, request, containing: "at most 256") }
    }
  }

  @Test func acceptedTextIsNeverSilentlyTrimmed() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let group = try store.cliSidebar(cliRequest("group.create", ["name": "  Work  ", "tabs": JSONValue([ids[0]])]))["id"]!.string!
    #expect(store.state.groups[group]?.name == "  Work  ")
    try store.cliSidebar(cliRequest("group.rename", ["id": .string(group), "name": " New "]))
    #expect(store.state.groups[group]?.name == " New ")
    for title in ["  Inbox  ", "  ", ""] {
      try store.cliSidebar(cliRequest("tab.rename", ["id": .string(ids[1]), "title": .string(title)]))
      #expect(store.state.tabs[ids[1]]?.customTitle == (title.isEmpty ? nil : title))
    }
    let folder = try cliCreated(store, "folder.create", [ids[2]])
    for text in [" Work", "Work ", "\tWork\n"] {
      try cliRejected(store, cliRequest("folder.create", ["name": .string(text), "tabs": JSONValue([ids[1]])]))
      try cliRejected(store, cliRequest("folder.rename", ["id": .string(folder), "name": .string(text)]))
    }
  }

  @Test func identifierLimitsAndCharsetCoverEveryIdentifierArgument() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    for key in ["id", "windowId", "toGroup", "toFolder", "toWindow", "before", "after", "tabs"] {
      for size in [255, 256, 257] {
        let text = String(repeating: "a", count: size)
        var values: JSONObject = ["id": .string(ids[0])]
        var operation = "tab.move"
        switch key {
        case "id": operation = "tab.pin"
        case "windowId", "tabs": operation = "group.create"; values = ["name": "Work"]
        case "before", "after": operation = "tab.reorder"
        default: break
        }
        values[key] = key == "tabs" ? JSONValue([text]) : .string(text)
        try cliRejected(store, cliRequest(operation, values), containing: size > 256 ? "at most 256" : "Unknown")
        values[key] = key == "tabs" ? JSONValue(["invalid/id"]) : "invalid/id"
        try cliRejected(store, cliRequest(operation, values), containing: "ASCII")
      }
    }
    for invalid in ["has space", "slash/id", "back\\slash", "tab\tid", "line\nid", "é", "\u{0}"] {
      try cliRejected(store, cliRequest("tab.pin", ["id": .string(invalid)]), containing: "ASCII")
      try cliRejected(store, cliRequest("group.create", ["name": "Work", "tabs": JSONValue([ids[0], invalid])]), containing: "ASCII")
    }
    try cliRejected(store, cliRequest("tab.pin", ["id": "aZ09._:@-"]), containing: "Unknown")
  }

  @Test func operationColorAndProfileNameHaveBoundedErrors() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    for size in [63, 64, 65, 10_000] {
      try cliRejected(store, cliRequest(String(repeating: "x", count: size)), containing: size > 64 ? "at most 64" : "unknown sidebar operation")
    }
    for size in [31, 32, 33, 10_000] {
      try cliRejected(store, cliRequest("group.create", ["name": "Work", "tabs": JSONValue([ids[0]]), "color": .string(String(repeating: "x", count: size))]), containing: size > 32 ? "at most 32" : "Unknown group color")
    }
    for size in [255, 256] {
      let name = String(repeating: "😀", count: size)
      let profile = try store.dispatch(Command("createProfile", [["name": .string(name)]])).result!.string!
      try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[0]), "toProfile": .string(name), "dryRun": true]))
      try store.cliSidebar(cliRequest("tab.move", ["id": .string(ids[0]), "toProfile": .string(name)]))
      #expect(store.state.tabs[ids[0]]?.profileId == profile)
    }
    for size in [257, 10_000] {
      try cliRejected(store, cliRequest("tab.move", ["id": .string(ids[0]), "toProfile": .string(String(repeating: "x", count: size))]), containing: "at most 256")
    }
  }

  @Test func tabArrayLimitCountsDuplicatesBeforeDeduplication() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    for operation in ["group.create", "folder.create"] {
      for count in [499, 500] {
        for dryRun in [true, false] {
          let result = try store.cliSidebar(cliRequest(operation, ["name": "Work", "tabs": JSONValue(Array(repeating: ids[0], count: count)), "dryRun": .bool(dryRun)]))
          #expect(result["changes"]?.array?.count == 1)
        }
      }
      try cliRejected(store, cliRequest(operation, ["name": "Work", "tabs": JSONValue(Array(repeating: ids[0], count: 501))]), containing: "500")
    }
  }

  @Test func expandedSplitSelectionLimitRejectsTheWholeEdit() throws {
    for count in [499, 500, 501] {
      let (store, _, ids) = try cliManyTabs(count)
      try store.dispatch(Command("createSplit", [JSONValue(Array(ids.suffix(2)))]))
      let selected = Array(ids.dropLast())
      let request = cliRequest("group.create", ["name": "Work", "tabs": JSONValue(selected)])
      if count > 500 { try cliRejected(store, request, containing: "500") }
      else {
        var dry = request.object!
        dry["dryRun"] = true
        try store.cliSidebar(.object(dry))
        let group = try store.cliSidebar(request)["id"]!.string!
        #expect(store.state.groups[group]?.tabIds.count == count)
      }
    }
  }

  @Test func oversizeRejectionDoesNotDrainQueuedEdits() throws {
    let store = cliStore()
    let (_, ids) = try cliWindow(store)
    let state = store.displayState
    let commits = Mutex(0)
    store.subscribe { _ in commits.withLock { $0 += 1 } }
    store.enqueueSequenced(Command("updateTab", [.string(ids[0]), ["customTitle": "Queued"]]))
    for dryRun in [true, false] {
      #expect(throws: CommandError.self) {
        try store.cliSidebar(cliRequest("tab.rename", ["id": .string(ids[0]), "title": .string(String(repeating: "x", count: 257)), "dryRun": .bool(dryRun)]))
      }
      #expect(store.displayState == state)
      #expect(commits.withLock { $0 } == 0)
    }
  }

  @Test func inventoryCapsLegacyFieldsWithoutRefusingTheListing() throws {
    let source = cliStore()
    let (window, ids) = try cliWindow(source)
    let group = try cliCreated(source, "group.create", [ids[0]])
    let folder = try cliCreated(source, "folder.create", [ids[1]])
    let profile = source.state.windows[window]!.profileId
    for field in ["profile.name", "tab.title", "tab.url", "group.name", "group.color", "folder.name", "tab.id"] {
      let limit = field == "tab.url" ? 8192 : field == "group.color" ? 32 : field == "tab.id" ? 256 : 1024
      for count in [limit - 1, limit, limit + 1] {
        var state = source.state
        let text = String(repeating: "x", count: count)
        switch field {
        case "profile.name": state.profiles[profile]!.name = text
        case "tab.title": state.tabs[ids[0]]!.title = text
        case "tab.url": state.tabs[ids[0]]!.url = text
        case "group.name": state.groups[group]!.name = text
        case "group.color": state.groups[group]!.color = text
        case "folder.name": state.tabs[ids[1]]!.tileFolder = TileFolder(id: folder, name: text, renamedAt: 1_000)
        default:
          var tab = state.tabs[ids[2]]!
          state.tabs[ids[2]] = nil
          tab.id = text
          state.tabs[text] = tab
          state.windows[window]!.tabIds = state.windows[window]!.tabIds.map { $0 == ids[2] ? text : $0 }
        }
        let store = Store(state: state)
        let before = store.displayState
        let revision = store.rev
        let result = try store.cliSidebar(cliRequest("sidebar.list"))
        let rows = ["profiles", "tabs", "groups", "folders"].flatMap { result[$0]?.array ?? [] }
        let outputField = field == "tab.id" ? "id" : String(field.split(separator: ".").last!)
        let matching = rows.filter { $0[outputField]?.string == String(repeating: "x", count: min(count, limit)) }
        #expect(!matching.isEmpty)
        #expect(matching.contains { $0["truncated"]?.bool == true } == (count > limit))
        #expect(store.displayState == before)
        #expect(store.rev == revision)
      }
    }
  }
  @Test func inventoryCapsWebsiteTitleAndMegabyteDataURLWithoutChangingState() throws {
    let source = cliStore()
    let (_, ids) = try cliWindow(source)
    var state = source.state
    state.tabs[ids[0]]!.title = String(repeating: "😀", count: 10_000)
    state.tabs[ids[0]]!.url = "data:text/plain," + String(repeating: "x", count: 1_048_576)
    state.tabs[ids[1]]!.title = "e" + String(repeating: "\u{301}", count: 9999)
    let store = Store(state: state)
    let before = store.displayState
    let revision = store.rev
    let result = try store.cliSidebar(cliRequest("sidebar.list"))
    let row = try #require(result["tabs"]?.array?.first { $0["id"]?.string == ids[0] })
    #expect(row["title"]?.string == String(repeating: "😀", count: 1024))
    #expect(row["url"]?.string == "data:text/plain," + String(repeating: "x", count: 8176))
    #expect(row["truncated"]?.bool == true)
    let combining = try #require(result["tabs"]?.array?.first { $0["id"]?.string == ids[1] })
    #expect(combining["title"]?.string == "e" + String(repeating: "\u{301}", count: 1023))
    #expect(combining["title"]?.string?.unicodeScalars.count == 1024)
    #expect(combining["truncated"]?.bool == true)
    #expect(result["tabs"]?.array?.count == 3)
    #expect(result.text().utf8.count <= 262_144)
    #expect(store.displayState == before)
    #expect(store.rev == revision)
  }

  @Test func inventoryBudgetCountsEscapedStringsAndReportsEveryOmittedRow() throws {
    let (source, _, ids) = try cliManyTabs(80)
    var state = source.state
    let title = String(repeating: "\u{0}", count: 10_000)
    let url = "data:text/plain," + String(repeating: "x", count: 1_048_576)
    for id in ids {
      state.tabs[id]!.title = title
      state.tabs[id]!.url = url
    }
    let store = Store(state: state)
    let before = store.displayState
    let result = try store.cliSidebar(cliRequest("sidebar.list"))
    let rows = try #require(result["tabs"]?.array)
    let more = try #require(result["more"]?["tabs"]?.int)
    #expect(!rows.isEmpty)
    #expect(more > 0)
    #expect(rows.count + more == 80)
    #expect(rows.allSatisfy { $0["truncated"]?.bool == true && $0["title"]?.string?.unicodeScalars.count == 1024 && $0["url"]?.string?.unicodeScalars.count == 8192 })
    #expect(result.text().utf8.count <= 262_144)
    #expect(try JSONValue.parse(result.text()) == result)
    #expect(try store.cliSidebar(cliRequest("sidebar.list")) == result)
    #expect(store.displayState == before)
  }

  @Test func inventoryCapsMembershipListsAndCountsOmittedRows() throws {
    let (source, window, ids) = try cliManyTabs(2000)
    let group = try source.dispatch(Command("createGroup", [JSONValue(ids), ["name": "Many"]])).result!.string!
    let result = try source.cliSidebar(cliRequest("sidebar.list"))
    let windowRow = try #require(result["windows"]?.array?.first { $0["id"]?.string == window })
    let groupRow = try #require(result["groups"]?.array?.first { $0["id"]?.string == group })
    for row in [windowRow, groupRow] {
      #expect(row["tabIds"]?.array?.count == 500)
      #expect(row["more"]?["tabIds"]?.int == 1500)
      #expect(row["truncated"]?.bool == true)
    }
    #expect((result["tabs"]?.array?.count ?? 0) + (result["more"]?["tabs"]?.int ?? -1) == 2000)
    #expect(result.text().utf8.count <= 262_144)
  }

  @Test func inventoryOmitsAnIndividuallyOversizedRowAndContinuesListing() throws {
    let (source, window, ids) = try cliManyTabs(500)
    var state = source.state
    let longIds = ids.indices.map { index in
      let digits = String(index)
      return String(repeating: "😀", count: 252) + String(repeating: "0", count: 4 - digits.count) + digits
    }
    state.tabs = Table()
    for (id, original) in zip(longIds, ids) {
      var tab = source.state.tabs[original]!
      tab.id = id
      state.tabs[id] = tab
    }
    state.windows[window]!.tabIds = longIds
    state.windows[window]!.activeTabIds[state.windows[window]!.profileId] = longIds[0]
    let store = Store(state: state)
    let result = try store.cliSidebar(cliRequest("sidebar.list"))
    #expect(result["windows"]?.array?.isEmpty == true)
    #expect(result["more"]?["windows"]?.int == 1)
    #expect(result["tabs"]?.array?.isEmpty == false)
    #expect((result["tabs"]?.array?.count ?? 0) + (result["more"]?["tabs"]?.int ?? -1) == 500)
    #expect(result.text().utf8.count <= 262_144)
  }

  @Test func inventoryBudgetIncludesChromiumEscapingAndProtocolEnvelope() throws {
    let (source, _, ids) = try cliManyTabs(80)
    var state = source.state
    for id in ids {
      state.tabs[id]!.title = String(repeating: "<", count: 10_000)
      state.tabs[id]!.url = String(repeating: "<\u{2028}\u{2029}", count: 10_000)
    }
    let store = Store(state: state)
    let result = try store.cliSidebar(cliRequest("sidebar.list"))
    let wrapper: JSONValue = ["id": -2_147_483_648, "result": result]
    var wire = ""
    for scalar in wrapper.text().unicodeScalars {
      switch scalar.value {
      case 0x3C: wire += "\\u003C"
      case 0x2028: wire += "\\u2028"
      case 0x2029: wire += "\\u2029"
      default: wire.unicodeScalars.append(scalar)
      }
    }
    #expect(wire.utf8.count <= 262_144)
    #expect(result.text().utf8.count <= 262_144)
    #expect(result["tabs"]?.array?.isEmpty == false)
    #expect((result["tabs"]?.array?.count ?? 0) + (result["more"]?["tabs"]?.int ?? -1) == 80)
  }

}


extension CliSidebarTests {
  @Test func mixedSplitPinnedTileKeepsTheExistingSelectionSemantics() throws {
    let source = cliStore()
    let (_, ids) = try cliWindow(source)
    try source.dispatch(Command("createSplit", [JSONValue(ids)]))
    var state = source.state
    state.tabs[ids[0]]!.pinned = true
    state.tabs[ids[0]]!.pinnedAsRow = false
    let store = Store(state: state)
    let result = try store.cliSidebar(cliRequest("group.create", ["name": "Tile", "tabs": JSONValue([ids[0]]), "dryRun": true]))
    #expect(result["changes"]?.array?.first?.string == "Create group Tile with tabs \(ids[0])")
  }

  @Test func fallbackAndExpandedLegacyIdentifiersCannotBypassLimits() throws {
    let source = cliStore()
    let (window, ids) = try cliWindow(source)
    try source.dispatch(Command("createSplit", [JSONValue([ids[0], ids[1]])]))
    for badId in [String(repeating: "x", count: 257), "invalid id"] {
      var state = source.state
      var tab = state.tabs[ids[0]]!
      state.tabs[ids[0]] = nil
      tab.id = badId
      state.tabs[badId] = tab
      state.windows[window]!.tabIds = [badId, ids[1], ids[2]]
      state.windows[window]!.activeTabIds[tab.profileId] = badId
      let split = state.splits.values.first!
      state.splits[split.id]!.tabIds = [badId, ids[1]]
      let store = Store(state: state)
      try cliRejected(store, cliRequest("group.create", ["name": "Fallback", "windowId": .string(window)]))
      try cliRejected(store, cliRequest("group.create", ["name": "Expanded", "tabs": JSONValue([ids[1]])]))
    }
  }
}


extension CliSidebarTests {
  @Test func existingIdentifiersAtTheLengthLimitRemainEditable() throws {
    let source = cliStore()
    let (window, ids) = try cliWindow(source)
    for length in [255, 256] {
      var state = source.state
      let id = "aZ09._:@-" + String(repeating: "x", count: length - 9)
      var tab = state.tabs[ids[0]]!
      state.tabs[ids[0]] = nil
      tab.id = id
      state.tabs[id] = tab
      state.windows[window]!.tabIds = [id, ids[1], ids[2]]
      state.windows[window]!.activeTabIds[tab.profileId] = id
      let store = Store(state: state)
      try store.cliSidebar(cliRequest("tab.rename", ["id": .string(id), "title": "Boundary", "dryRun": true]))
      #expect(store.displayState.tabs[id]?.customTitle == nil)
      try store.cliSidebar(cliRequest("tab.rename", ["id": .string(id), "title": "Boundary"]))
      #expect(store.state.tabs[id]?.customTitle == "Boundary")
    }
  }
}
