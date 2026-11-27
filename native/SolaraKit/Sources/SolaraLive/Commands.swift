import Foundation

public enum LiveCommand: Codable, Sendable, Equatable {
  case createFolder(LiveAnyJSON)
  case newProfileLiveFolder(LiveAnyJSON)
  case importFolder(LiveAnyJSON)
  case updateFolder(LiveAnyJSON)
  case removeFolder(LiveAnyJSON)
  case removeProfile(LiveAnyJSON)
  case arrangeFolders(LiveAnyJSON)
  case markRead(LiveAnyJSON)
  case markUnread(LiveAnyJSON)
  case hideItems(LiveAnyJSON)
  case unhide(LiveAnyJSON)
  case setExpandedStack(LiveAnyJSON)
  case updateConfig(LiveAnyJSON)
  case updateCalendarSettings(LiveAnyJSON)
  case setCalendarHidden(LiveAnyJSON)
  case dismissAlert(LiveAnyJSON)
  case setMeetingGroup(LiveAnyJSON)
  case refreshFolder(LiveAnyJSON)
  case manualRefresh(LiveAnyJSON)
  case refreshCalendar(LiveAnyJSON)
  case windowFocused(LiveAnyJSON)
  case appResignedActive(LiveAnyJSON)
  case liveTabDeactivated(LiveAnyJSON)
  case connectCalendar(LiveAnyJSON)
  case connectGithub(LiveAnyJSON)
  case connectNotion(LiveAnyJSON)
  case connectGoogleDrive(LiveAnyJSON)
  case disconnect(LiveAnyJSON)
  case startGithubDeviceFlow(LiveAnyJSON)
  case finishGithubDeviceFlow(LiveAnyJSON)
  case cancelGithubDeviceFlow(LiveAnyJSON)
  case offerAlertsForPinnedTab(LiveAnyJSON)
  case answerAlertOffer(LiveAnyJSON)
#if DEBUG
  case applyFetch(LiveAnyJSON)
  case setStatus(LiveAnyJSON)
#endif

  public init(from decoder: Decoder) throws {
    let wire = try Wire(from: decoder)
    switch wire.name {
    case "createFolder": self = .createFolder(wire.payload)
    case "newProfileLiveFolder": self = .newProfileLiveFolder(wire.payload)
    case "importFolder": self = .importFolder(wire.payload)
    case "updateFolder": self = .updateFolder(wire.payload)
    case "removeFolder": self = .removeFolder(wire.payload)
    case "removeProfile": self = .removeProfile(wire.payload)
    case "arrangeFolders": self = .arrangeFolders(wire.payload)
    case "markRead": self = .markRead(wire.payload)
    case "markUnread": self = .markUnread(wire.payload)
    case "hideItems": self = .hideItems(wire.payload)
    case "unhide": self = .unhide(wire.payload)
    case "setExpandedStack": self = .setExpandedStack(wire.payload)
    case "updateConfig": self = .updateConfig(wire.payload)
    case "updateCalendarSettings": self = .updateCalendarSettings(wire.payload)
    case "setCalendarHidden": self = .setCalendarHidden(wire.payload)
    case "dismissAlert": self = .dismissAlert(wire.payload)
    case "setMeetingGroup": self = .setMeetingGroup(wire.payload)
    case "refreshFolder": self = .refreshFolder(wire.payload)
    case "manualRefresh": self = .manualRefresh(wire.payload)
    case "refreshCalendar": self = .refreshCalendar(wire.payload)
    case "windowFocused": self = .windowFocused(wire.payload)
    case "appResignedActive": self = .appResignedActive(wire.payload)
    case "liveTabDeactivated": self = .liveTabDeactivated(wire.payload)
    case "connectCalendar": self = .connectCalendar(wire.payload)
    case "connectGithub": self = .connectGithub(wire.payload)
    case "connectNotion": self = .connectNotion(wire.payload)
    case "connectGoogleDrive": self = .connectGoogleDrive(wire.payload)
    case "disconnect": self = .disconnect(wire.payload)
    case "startGithubDeviceFlow": self = .startGithubDeviceFlow(wire.payload)
    case "finishGithubDeviceFlow": self = .finishGithubDeviceFlow(wire.payload)
    case "cancelGithubDeviceFlow": self = .cancelGithubDeviceFlow(wire.payload)
    case "offerAlertsForPinnedTab": self = .offerAlertsForPinnedTab(wire.payload)
    case "answerAlertOffer": self = .answerAlertOffer(wire.payload)
#if DEBUG
    case "applyFetch": self = .applyFetch(wire.payload)
    case "setStatus": self = .setStatus(wire.payload)
#endif
    default: throw LiveError(.other, "Unknown Live command: \(wire.name)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    let wire: Wire
    switch self {
    case .createFolder(let payload): wire = Wire(name: "createFolder", payload: payload)
    case .newProfileLiveFolder(let payload): wire = Wire(name: "newProfileLiveFolder", payload: payload)
    case .importFolder(let payload): wire = Wire(name: "importFolder", payload: payload)
    case .updateFolder(let payload): wire = Wire(name: "updateFolder", payload: payload)
    case .removeFolder(let payload): wire = Wire(name: "removeFolder", payload: payload)
    case .removeProfile(let payload): wire = Wire(name: "removeProfile", payload: payload)
    case .arrangeFolders(let payload): wire = Wire(name: "arrangeFolders", payload: payload)
    case .markRead(let payload): wire = Wire(name: "markRead", payload: payload)
    case .markUnread(let payload): wire = Wire(name: "markUnread", payload: payload)
    case .hideItems(let payload): wire = Wire(name: "hideItems", payload: payload)
    case .unhide(let payload): wire = Wire(name: "unhide", payload: payload)
    case .setExpandedStack(let payload): wire = Wire(name: "setExpandedStack", payload: payload)
    case .updateConfig(let payload): wire = Wire(name: "updateConfig", payload: payload)
    case .updateCalendarSettings(let payload): wire = Wire(name: "updateCalendarSettings", payload: payload)
    case .setCalendarHidden(let payload): wire = Wire(name: "setCalendarHidden", payload: payload)
    case .dismissAlert(let payload): wire = Wire(name: "dismissAlert", payload: payload)
    case .setMeetingGroup(let payload): wire = Wire(name: "setMeetingGroup", payload: payload)
    case .refreshFolder(let payload): wire = Wire(name: "refreshFolder", payload: payload)
    case .manualRefresh(let payload): wire = Wire(name: "manualRefresh", payload: payload)
    case .refreshCalendar(let payload): wire = Wire(name: "refreshCalendar", payload: payload)
    case .windowFocused(let payload): wire = Wire(name: "windowFocused", payload: payload)
    case .appResignedActive(let payload): wire = Wire(name: "appResignedActive", payload: payload)
    case .liveTabDeactivated(let payload): wire = Wire(name: "liveTabDeactivated", payload: payload)
    case .connectCalendar(let payload): wire = Wire(name: "connectCalendar", payload: payload)
    case .connectGithub(let payload): wire = Wire(name: "connectGithub", payload: payload)
    case .connectNotion(let payload): wire = Wire(name: "connectNotion", payload: payload)
    case .connectGoogleDrive(let payload): wire = Wire(name: "connectGoogleDrive", payload: payload)
    case .disconnect(let payload): wire = Wire(name: "disconnect", payload: payload)
    case .startGithubDeviceFlow(let payload): wire = Wire(name: "startGithubDeviceFlow", payload: payload)
    case .finishGithubDeviceFlow(let payload): wire = Wire(name: "finishGithubDeviceFlow", payload: payload)
    case .cancelGithubDeviceFlow(let payload): wire = Wire(name: "cancelGithubDeviceFlow", payload: payload)
    case .offerAlertsForPinnedTab(let payload): wire = Wire(name: "offerAlertsForPinnedTab", payload: payload)
    case .answerAlertOffer(let payload): wire = Wire(name: "answerAlertOffer", payload: payload)
#if DEBUG
    case .applyFetch(let payload): wire = Wire(name: "applyFetch", payload: payload)
    case .setStatus(let payload): wire = Wire(name: "setStatus", payload: payload)
#endif
    }
    try wire.encode(to: encoder)
  }

  var changesDocument: Bool {
    switch self {
    case .refreshFolder, .manualRefresh, .refreshCalendar, .windowFocused, .appResignedActive, .liveTabDeactivated, .connectCalendar,
      .startGithubDeviceFlow, .cancelGithubDeviceFlow:
      false
    default: true
    }
  }

  struct Wire: Codable {
    var name: String
    var payload: LiveAnyJSON
  }
}

public struct LiveCommandResult: Codable, Sendable, Equatable {
  public var revision: UInt64
  public var folderId: String?
  public var deviceFlow: GithubDeviceFlowInfo?
  public var boolean: Bool?

  public init(revision: UInt64, folderId: String? = nil, deviceFlow: GithubDeviceFlowInfo? = nil, boolean: Bool? = nil) {
    self.revision = revision
    self.folderId = folderId
    self.deviceFlow = deviceFlow
    self.boolean = boolean
  }
}

public struct GithubDeviceFlowInfo: Codable, Sendable, Equatable {
  public var id: String
  public var userCode: String
  public var verificationUri: String
  public var expiresAt: Double
}

private enum Fields {
  static func object(_ value: LiveAnyJSON, allowed: Set<String>, required: Set<String> = []) throws -> [String: LiveAnyJSON] {
    guard case .object(let fields) = value, Set(fields.keys).isSubset(of: allowed), required.isSubset(of: Set(fields.keys)) else {
      throw LiveError(.other, "Malformed Live command payload")
    }
    return fields
  }

  static func decode<T: Decodable>(_ type: T.Type, _ value: LiveAnyJSON?) throws -> T {
    guard let value else { throw LiveError(.other, "Missing Live command field") }
    do { return try LiveJSON.decode(type, from: LiveJSON.encode(value)) }
    catch { throw LiveError(.other, "Malformed Live command field: \(error)") }
  }

  static func optional<T: Decodable>(_ type: T.Type, _ value: LiveAnyJSON?) throws -> T? {
    guard let value, value != .null else { return nil }
    return try decode(type, value)
  }

  static func nonnull<T: Decodable>(_ type: T.Type, _ fields: [String: LiveAnyJSON], _ key: String) throws -> T? {
    guard let value = fields[key] else { return nil }
    return try decode(type, value)
  }

  static func patch(_ raw: LiveAnyJSON) throws -> FolderPatch {
    let v = try object(raw, allowed: ["name", "icon", "collapsed", "sources", "filters", "groupStacks", "showCompleted", "createdAt", "after"])
    var patch = FolderPatch()
    patch.name = try nonnull(String.self, v, "name")
    if let icon = v["icon"] { patch.icon = icon == .null ? .some(nil) : .some(try decode(String.self, icon)) }
    patch.collapsed = try nonnull(Bool.self, v, "collapsed")
    patch.sources = try nonnull([LiveSourceId].self, v, "sources")
    if let filters = v["filters"] {
      _ = try object(filters, allowed: ["authored", "reviewRequests"], required: ["authored", "reviewRequests"])
    }
    patch.filters = try nonnull(LiveFilters.self, v, "filters")
    patch.groupStacks = try nonnull(Bool.self, v, "groupStacks")
    patch.showCompleted = try nonnull(Bool.self, v, "showCompleted")
    patch.createdAt = try nonnull(Double.self, v, "createdAt")
    if let after = v["after"] { patch.after = after == .null ? .some(nil) : .some(try decode(String.self, after)) }
    return patch
  }

  static func config(_ raw: LiveAnyJSON) throws -> ConfigPatch {
    let v = try object(raw, allowed: ["githubClientId", "googleClientId"])
    return try ConfigPatch(
      githubClientId: nonnull(String.self, v, "githubClientId"),
      googleClientId: nonnull(String.self, v, "googleClientId"))
  }

  static func calendar(_ raw: LiveAnyJSON) throws -> CalendarSettingsPatch {
    let v = try object(raw, allowed: ["alertLead", "alertCondition", "showPreview", "showTimeToNext", "hiddenCalendarIds", "prompted"])
    return try CalendarSettingsPatch(
      alertLead: nonnull(String.self, v, "alertLead"), alertCondition: nonnull(AlertCondition.self, v, "alertCondition"),
      showPreview: nonnull(Bool.self, v, "showPreview"), showTimeToNext: nonnull(Bool.self, v, "showTimeToNext"),
      hiddenCalendarIds: nonnull([String].self, v, "hiddenCalendarIds"), prompted: nonnull(Bool.self, v, "prompted"))
  }
}

extension LiveEngine {
  public func perform(_ command: LiveCommand) async throws -> LiveCommandResult {
    if let loadError, command.changesDocument { throw LiveError(.other, loadError) }
    var folderId: String?
    var deviceFlow: GithubDeviceFlowInfo?
    var boolean: Bool?
    switch command {
    case .createFolder(let payload), .newProfileLiveFolder(let payload), .importFolder(let payload):
      let v = try Fields.object(payload, allowed: ["profileId", "kind", "sources", "source"], required: ["profileId", "kind"])
      let profileId = try Fields.decode(String.self, v["profileId"])
      let kind = try Fields.decode(LiveFolderKind.self, v["kind"])
      let sources = try Fields.nonnull([LiveSourceId].self, v, "sources")
      let source = try Fields.optional(LiveSourceId.self, v["source"])
      if case .importFolder = command {
        guard kind == .pullRequests, let source, sources == nil else { throw LiveError(.other, "Malformed import folder") }
        folderId = state.folders.values.first { $0.profileId == profileId && $0.kind == kind && $0.sources.contains(source) }?.id
        if folderId == nil { folderId = newProfileLiveFolder(profileId: profileId, kind: kind, sources: [source]) }
      } else if case .newProfileLiveFolder = command {
        folderId = newProfileLiveFolder(profileId: profileId, kind: kind, sources: sources)
      } else {
        folderId = createFolder(profileId: profileId, kind: kind, sources: sources)
      }
    case .updateFolder(let payload):
      let v = try Fields.object(payload, allowed: ["folderId", "patch"], required: ["folderId", "patch"])
      let id = try folder(v)
      let patch = try Fields.patch(v["patch"]!)
      updateFolder(id, patch)
    case .removeFolder(let payload):
      let id = try folder(Fields.object(payload, allowed: ["folderId"], required: ["folderId"]))
      try await effects.closeFolderTabs(id)
      removeFolder(id)
    case .removeProfile(let payload):
      guard !effects.environment.safeMode else { throw LiveError(.other, "Profile deletion is disabled in safe mode") }
      let v = try Fields.object(payload, allowed: ["profileId"], required: ["profileId"])
      let profileId = try Fields.decode(String.self, v["profileId"])
      for id in state.folders.values.filter({ $0.profileId == profileId }).map(\.id) { removeFolder(id) }
    case .arrangeFolders(let payload):
      let v = try Fields.object(payload, allowed: ["placed"], required: ["placed"])
      let raw = try Fields.decode([LiveAnyJSON].self, v["placed"])
      let placed = try raw.map { item -> FolderPlacement in
        let p = try Fields.object(item, allowed: ["id", "after"], required: ["id", "after"])
        let id = try Fields.decode(String.self, p["id"])
        try requireFolder(id)
        let after = try Fields.optional(String.self, p["after"])
        return FolderPlacement(id: id, after: after)
      }
      arrangeFolders(placed)
    case .markRead(let payload):
      let v = try Fields.object(payload, allowed: ["folderId", "itemIds"], required: ["folderId"])
      markRead(try folder(v), try Fields.optional([String].self, v["itemIds"]))
    case .markUnread(let payload):
      let v = try Fields.object(payload, allowed: ["folderId", "itemId"], required: ["folderId", "itemId"])
      let id = try folder(v)
      let itemId = try Fields.decode(String.self, v["itemId"])
      markUnread(id, itemId)
    case .hideItems(let payload):
      let v = try Fields.object(payload, allowed: ["folderId", "items"], required: ["folderId", "items"])
      hideItems(try folder(v), try Fields.decode([LiveItem].self, v["items"]))
    case .unhide(let payload):
      let id = try folder(Fields.object(payload, allowed: ["folderId"], required: ["folderId"]))
      mutate { $0.unhide(id) }
    case .setExpandedStack(let payload):
      let v = try Fields.object(payload, allowed: ["key", "expanded"], required: ["key", "expanded"])
      setExpandedStack(try Fields.decode(String.self, v["key"]), try Fields.decode(Bool.self, v["expanded"]))
    case .updateConfig(let payload):
      let v = try Fields.object(payload, allowed: ["patch"], required: ["patch"])
      updateConfig(try Fields.config(v["patch"]!))
    case .updateCalendarSettings(let payload):
      let v = try Fields.object(payload, allowed: ["patch"], required: ["patch"])
      updateCalendarSettings(try Fields.calendar(v["patch"]!))
    case .setCalendarHidden(let payload):
      let v = try Fields.object(payload, allowed: ["id", "hidden"], required: ["id", "hidden"])
      setCalendarHidden(try Fields.decode(String.self, v["id"]), hidden: try Fields.decode(Bool.self, v["hidden"]))
    case .dismissAlert(let payload):
      let v = try Fields.object(payload, allowed: ["occurrence"], required: ["occurrence"])
      let occurrence = try Fields.decode(String.self, v["occurrence"])
      mutate { $0.dismissAlert(occurrence) }
      if selectedJobs.contains(.alerts) {
        await effects.notifier.remove(ids: ["meeting:\(occurrence)"])
        if meetingAlert?.occurrence == occurrence { meetingAlert = nil; emit() }
        await checkAlerts()
      }
    case .setMeetingGroup(let payload):
      let v = try Fields.object(payload, allowed: ["group", "groupId"], required: ["group"])
      if let group = try Fields.optional(MeetingGroup.self, v["group"]) { setMeetingGroup(group) }
      else {
        let id = try Fields.decode(String.self, v["groupId"])
        setMeetingGroup(nil, groupId: id)
      }
    case .refreshFolder(let payload), .manualRefresh(let payload):
      let id = try folder(Fields.object(payload, allowed: ["folderId"], required: ["folderId"]))
      if case .manualRefresh = command { await manualRefresh(id).value }
      else { await refreshFolder(id).value }
    case .refreshCalendar(let payload):
      _ = try Fields.object(payload, allowed: [])
      await refreshCalendar().value
    case .windowFocused(let payload):
      _ = try Fields.object(payload, allowed: [])
      windowFocused()
    case .appResignedActive(let payload):
      _ = try Fields.object(payload, allowed: [])
      appResignedActive()
    case .liveTabDeactivated(let payload):
      let id = try folder(Fields.object(payload, allowed: ["folderId"], required: ["folderId"]))
      liveTabDeactivated(folderId: id)
    case .connectCalendar(let payload):
      _ = try Fields.object(payload, allowed: [])
      boolean = await connectCalendar()
    case .connectGithub(let payload):
      let v = try Fields.object(payload, allowed: ["token"], required: ["token"])
      try await connectGithub(token: Fields.decode(String.self, v["token"]))
    case .connectNotion(let payload):
      let v = try Fields.object(payload, allowed: ["token"], required: ["token"])
      try await connectNotion(token: Fields.decode(String.self, v["token"]))
    case .connectGoogleDrive(let payload):
      let v = try Fields.object(payload, allowed: ["clientId", "clientSecret"], required: ["clientId", "clientSecret"])
      try await connectGoogleDrive(clientId: Fields.decode(String.self, v["clientId"]), clientSecret: Fields.decode(String.self, v["clientSecret"]))
    case .disconnect(let payload):
      let v = try Fields.object(payload, allowed: ["source"], required: ["source"])
      try await disconnect(Fields.decode(LiveSourceId.self, v["source"]))
    case .startGithubDeviceFlow(let payload):
      let v = try Fields.object(payload, allowed: ["clientId"], required: ["clientId"])
      let flow = try await startGithubDeviceFlow(clientId: Fields.decode(String.self, v["clientId"]))
      let id = UUID().uuidString
      deviceFlows[id] = flow
      deviceFlow = GithubDeviceFlowInfo(id: id, userCode: flow.userCode, verificationUri: flow.verificationUri, expiresAt: flow.expiresAt)
    case .finishGithubDeviceFlow(let payload):
      let v = try Fields.object(payload, allowed: ["id"], required: ["id"])
      let id = try Fields.decode(String.self, v["id"])
      guard let flow = deviceFlows[id] else { throw LiveError(.other, "Unknown device flow") }
      defer { deviceFlows[id] = nil }
      try await flow.done.value
    case .cancelGithubDeviceFlow(let payload):
      let v = try Fields.object(payload, allowed: ["id"], required: ["id"])
      let id = try Fields.decode(String.self, v["id"])
      guard let flow = deviceFlows.removeValue(forKey: id) else { throw LiveError(.other, "Unknown device flow") }
      flow.cancel()
    case .offerAlertsForPinnedTab(let payload):
      let v = try Fields.object(payload, allowed: ["url"], required: ["url"])
      boolean = offerAlertsForPinnedTab(url: try Fields.decode(String.self, v["url"]))
    case .answerAlertOffer(let payload):
      let v = try Fields.object(payload, allowed: ["confirmed"], required: ["confirmed"])
      await answerAlertOffer(confirmed: try Fields.decode(Bool.self, v["confirmed"]))
#if DEBUG
    case .applyFetch(let payload):
      let v = try Fields.object(payload, allowed: ["folderId", "items", "gone"], required: ["folderId", "items", "gone"])
      let id = try folder(v)
      applyFetch(id, try Fields.decode([LiveItem].self, v["items"]), gone: try Fields.decode([String: CompletionState].self, v["gone"]))
    case .setStatus(let payload):
      let v = try Fields.object(payload, allowed: ["folderId", "status"], required: ["folderId", "status"])
      let id = try folder(v)
      let patch = try Fields.object(v["status"]!, allowed: ["state", "lastFetch", "error"])
      let status = try Fields.optional(FolderStatus.State.self, patch["state"])
      let lastFetch = try Fields.optional(Double.self, patch["lastFetch"])
      let error = try Fields.optional(FolderError.self, patch["error"])
      mutate { $0.setStatus(id, state: status, lastFetch: patch["lastFetch"] == nil ? .none : .some(lastFetch), error: patch["error"] == nil ? .none : .some(error)) }
#endif
    }
    return LiveCommandResult(revision: revision, folderId: folderId, deviceFlow: deviceFlow, boolean: boolean)
  }

  func requireFolder(_ id: String) throws {
    guard state.folders[id] != nil else { throw LiveError(.other, "Unknown Live folder: \(id)") }
  }

  func folder(_ fields: [String: LiveAnyJSON]) throws -> String {
    let id = try Fields.decode(String.self, fields["folderId"])
    try requireFolder(id)
    return id
  }
}
