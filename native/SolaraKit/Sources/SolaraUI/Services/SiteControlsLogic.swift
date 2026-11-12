import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public enum SiteControlsAction: Equatable, Sendable {
  case expand(String)
  case developer(JSONValue)
  case blocker
  case enginePicker
  case clear
  case fullURL(Bool)
  case zoom(Int)
  case permission(String)
  case shared(String)
  case keepAwake(JSONValue)
  case sleepSettings(String?)
  case contribution
  case none
}

public enum SiteControlsLogic {
  public static func action(_ event: SitePanelEvent, context: JSONValue) -> SiteControlsAction {
    let id: String
    switch event {
    case .press(let value, _), .menu(let value, _), .toggle(let value, _), .zoom(let value, _): id = value
    }
    if id.hasPrefix("ext:") || id.hasPrefix("translate:") { return .contribution }
    if case .zoom(_, let step) = event { return id == "zoom" ? .zoom(step == 0 ? 0 : step > 0 ? 1 : -1) : .none }
    if case .toggle(_, let on) = event, id == "full-url" { return .fullURL(on) }
    guard case .press = event else { return .none }
    switch id {
    case "connection", "more": return .expand(id)
    case "developer":
      guard let changed = developerSettings(context: context, on: !developerEnabled(context: context)) else { return .none }
      return .developer(changed)
    case "blocker": return .blocker
    case "engine": return .enginePicker
    case "clear": return .clear
    case "sleep": return sleepAction(context: context)
    case "share", "copy", "find", "cast", "pip", "other-engine": return .shared(id)
    default:
      guard id.hasPrefix("perm:") else { return .none }
      let type = String(id.dropFirst(5))
      return permissionList(context).contains { $0.id == type } ? .permission(type) : .none
    }
  }

  private static let permissions: [(id: String, title: String, icon: String, badge: String)] = [
    ("camera", "Camera", "video", "video.fill"),
    ("microphone", "Microphone", "mic", "mic.fill"),
    ("location", "Location", "location", "location.fill"),
    ("notifications", "Notifications", "bell", "bell.fill"),
    ("popups", "Pop-ups and Redirects", "macwindow.on.rectangle", "macwindow.on.rectangle"),
    ("sound", "Sound", "speaker.wave.2", "speaker.wave.2.fill"),
  ]

  private static let protectedVideoHosts = [
    "netflix.com", "disneyplus.com", "max.com", "hbomax.com", "primevideo.com", "hulu.com", "tv.apple.com", "music.apple.com", "open.spotify.com",
    "peacocktv.com", "paramountplus.com", "crunchyroll.com", "hotstar.com", "jiohotstar.com",
  ]

  public static func context(state: BrowserState, tabId: String, pageEngine: String, input: JSONValue) -> JSONValue? {
    guard let tab = state.tabs[tabId] else { return nil }
    var c = input.object ?? [:]
    c["tabId"] = .string(tab.id)
    c["windowId"] = .string(tab.windowId)
    c["url"] = .string(tab.url)
    c["title"] = .string(tab.title)
    c["customTitle"] = JSONValue(tab.customTitle)
    c["label"] = .string(ScriptState.tabLabel(tab))
    c["favicon"] = JSONValue(tab.favicon)
    c["profileId"] = .string(tab.profileId)
    c["profile"] = .string(state.engineProfile(tab.profileId))
    c["privatePage"] = .bool(Ids.isIncognitoProfile(tab.profileId))
    c["pageEngine"] = .string(pageEngine)
    c["muted"] = .bool(tab.muted)
    c["zoom"] = .number(tab.zoom)
    c["showFullUrl"] = state.settings["showFullUrl"] ?? false
    c["developerMode"] = state.settings["developerMode"] ?? [:]
    c["sleepInactiveTabs"] = state.settings["sleepInactiveTabs"] ?? true
    c[KeepAwakeSites.settingKey] = state.settings[KeepAwakeSites.settingKey] ?? []
    let site = origin(tab.url)?.lowercased()
    c["engineRule"] = site.flatMap { state.settings["websiteEngines"]?[$0] } ?? .null
    let protectedSite = site?.hasPrefix("https://") == true && protectedVideoHosts.contains { host(tab.url) == $0 || host(tab.url).hasSuffix("." + $0) }
    let streaming = state.settings["protectedVideoInWebKit"] == true && protectedSite
    c["streamingSite"] = .bool(streaming)
    c["recommendedEngine"] = .string(streaming || state.settings["pageEngine"] == "webkit" ? "webkit" : "chromium")
    return .object(c)
  }

  public static func origin(_ url: String) -> String? {
    guard let parsed = WhatwgURL(url), ["http:", "https:"].contains(parsed.protocol) else { return nil }
    return parsed.protocol + "//" + parsed.host
  }

  public static func sleepAction(context: JSONValue) -> SiteControlsAction {
    guard context["sleepInactiveTabs"]?.bool != false else { return .sleepSettings(nil) }
    let sites = KeepAwakeSites.sites(context[KeepAwakeSites.settingKey])
    switch KeepAwakeSites.cover(of: host(context["url"]?.string ?? ""), in: sites) {
    case .parent(let site): return .sleepSettings(KeepAwakeSites.detailPrefix + site)
    case .exact(let site): return .keepAwake(JSONValue(sites.filter { $0 != site }))
    case .none:
      guard let site = KeepAwakeSites.normalized(host(context["url"]?.string ?? "")) else { return .none }
      return .keepAwake(JSONValue(KeepAwakeSites.adding(site, to: sites)))
    }
  }

  public static func host(_ url: String) -> String {
    guard origin(url) != nil else { return "" }
    return WhatwgURL(url)?.hostname ?? ""
  }

  public static func permissionChoices(_ type: String) -> [String] {
    ["sound", "popups"].contains(type) ? ["allow", "block"] : ["ask", "allow", "block"]
  }

  public static func choiceTitle(_ type: String, _ value: String) -> String {
    if type == "sound" { return value == "block" ? "Muted" : "Allowed" }
    return value == "allow" ? "Allowed" : value == "block" ? "Blocked" : "Ask"
  }

  public static func featuredPermissions(context: JSONValue, settings: JSONValue) -> Set<String> {
    Set(permissionList(context).filter { permission in
      let active = switch permission.id {
      case "camera": context["camera"]?.bool == true
      case "microphone": context["microphone"]?.bool == true
      case "sound": context["muted"]?.bool == true || context["playingAudio"]?.bool == true
      default: false
      }
      return settings[permission.id]?["isDefault"]?.bool != true || active
    }.map(\.id))
  }

  private static func permissionList(_ context: JSONValue) -> [(id: String, title: String, icon: String, badge: String)] {
    context["pageEngine"]?.string == "webkit" ? Array(permissions.prefix(2)) : permissions
  }

  private static func developerHost(_ url: String) -> String? {
    let h = host(url).lowercased()
    guard !h.isEmpty else { return nil }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
  }

  private static func defaultDeveloperHost(_ host: String) -> Bool {
    ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased()) || host.lowercased().hasSuffix(".localhost")
  }

  private static func developerProfile(_ context: JSONValue) -> String {
    let profile = context["profileId"]?.string ?? ""
    return Ids.isIncognitoProfile(profile) ? Ids.incognitoOriginal(profile) : profile
  }

  private static func developerState(_ raw: JSONValue?) -> JSONObject {
    func hosts(_ key: String, defaults: Bool) -> JSONValue {
      var seen: Set<String> = []
      let values = (raw?[key]?.array ?? []).compactMap { value -> String? in
        guard let s = value.string, !s.isEmpty, s.utf16.count <= 253 else { return nil }
        let lower = s.lowercased()
        guard seen.insert(lower).inserted, defaultDeveloperHost(lower) == defaults else { return nil }
        return lower
      }
      return .array(values.suffix(1000).map(JSONValue.string))
    }
    return ["on": hosts("on", defaults: false), "off": hosts("off", defaults: true), "reload": raw?["reload"] == "forceReload" ? "forceReload" : "reload"]
  }

  public static func developerEnabled(context: JSONValue) -> Bool {
    guard let h = developerHost(context["url"]?.string ?? "") else { return false }
    let state = developerState(context["developerMode"]?[developerProfile(context)])
    let defaults = defaultDeveloperHost(h)
    let listed = state[defaults ? "off" : "on"]?.array?.contains(.string(h)) == true
    return defaults ? !listed : listed
  }

  public static func developerSettings(context: JSONValue, on: Bool) -> JSONValue? {
    guard context["privatePage"]?.bool != true, let h = developerHost(context["url"]?.string ?? "") else { return nil }
    let profile = developerProfile(context)
    var all = context["developerMode"]?.object ?? [:]
    var state = developerState(all[profile])
    let key = defaultDeveloperHost(h) ? "off" : "on"
    let listed = key == "on" ? on : !on
    var values = (state[key]?.array ?? []).filter { $0 != .string(h) }
    if listed { values.append(.string(h)) }
    state[key] = .array(Array(values.suffix(1000)))
    all[profile] = .object(state)
    return .object(all)
  }

  private static func engineName(_ engine: String) -> String { engine == "webkit" ? "WebKit" : "Chromium" }
  private static func engineIcon(_ engine: String) -> String { engine == "webkit" ? "safari" : "globe" }
  private static func recommendedTitle(_ c: JSONValue) -> String {
    "\(c["streamingSite"]?.bool == true ? "Recommended" : "Default") (\(engineName(c["recommendedEngine"]?.string ?? "chromium")))"
  }

  public static func engineChoices(context c: JSONValue) -> [(id: String, title: String, checked: Bool)] {
    let privatePage = c["privatePage"]?.bool == true
    let selected = c[privatePage ? "pageEngine" : "engineRule"]?.string
    var choices: [(id: String, title: String, checked: Bool)] = []
    if !privatePage { choices.append(("default", recommendedTitle(c), selected == nil)) }
    choices += ["chromium", "webkit"].map { ($0, engineName($0), selected == $0) }
    return choices
  }

  public static func state(context c: JSONValue, expanded: String?, featured: Set<String>?, settings: JSONValue?, blocker: JSONValue?, cleared: String?) -> SitePanelState? {
    let url = c["url"]?.string ?? ""
    let webkit = c["pageEngine"]?.string == "webkit"
    let engine = webkit ? "webkit" : "chromium"
    let hasOrigin = origin(url) != nil
    let video = c["video"]?.bool == true || c["pip"]?.bool == true
    let pip = c["pip"]?.bool == true
    let castTile = !video && hasOrigin
    let lowerUrl = url.lowercased()
    let shareable = lowerUrl.hasPrefix("http:") || lowerUrl.hasPrefix("https:")
    let findable = shareable || lowerUrl.hasPrefix("file:")
    var tiles: [[String: Any]] = []
    if shareable { tiles.append(["id": "share", "icon": "square.and.arrow.up", "label": "Share…"]) }
    tiles.append(["id": "copy", "icon": "link", "label": "Copy Clean Link"])
    if findable { tiles.append(["id": "find", "icon": "text.magnifyingglass", "label": "Find on Page"]) }
    if video { tiles.append(["id": "pip", "icon": pip ? "pip.exit" : "pip.enter", "label": pip ? "Exit Picture in Picture" : "Picture in Picture", "active": pip]) }
    else if castTile { tiles.append(["id": "cast", "icon": "tv.and.mediabox", "label": "Cast…"]) }
    var items: [[String: Any]] = [["kind": "tiles", "tiles": tiles]]
    items += dictionaries(c["extensions"]).map { item in
      guard item["kind"] as? String == "extensions" else { return item }
      var adjusted = item
      adjusted["columns"] = tiles.count == 3 ? 3 : 4
      return adjusted
    }
    let list = permissionList(c)
    let shown = list.filter { featured?.contains($0.id) == true }
    let other = list.filter { featured?.contains($0.id) != true }
    func value(_ id: String) -> String { settings == nil ? "…" : choiceTitle(id, settings?[id]?["value"]?.string ?? "ask") }
    func setting(_ id: String, _ icon: String, _ title: String, _ value: String, _ on: Bool, _ pressable: Bool) -> [String: Any] {
      ["kind": "setting", "id": id, "icon": icon, "title": title, "value": value, "on": on, "pressable": pressable]
    }
    if hasOrigin {
      let enabled = blocker?["enabled"]?.bool == true
      let allowed = blocker?["allowed"]?.bool == true
      let blocked = c["blocked"]?.int ?? 0
      let unavailable = webkit && blocker?["error"]?.string != nil
      let partial = webkit && blocker?["unsupportedLists"]?.array?.isEmpty == false
      let preparing = webkit && blocker?["preparing"]?.bool == true
      let blockerValue = unavailable ? "Unavailable · reload to retry" : preparing ? "Preparing…" : webkit && blocker?["ready"]?.bool != true ? "Preparing…" : blocker == nil ? "…" : !enabled ? "Off in Settings" : allowed ? "Off for this site" : !webkit && blocked > 0 ? "On · \(blocked) blocked on this page" : partial ? "On · some lists unavailable" : "On"
      items.append(["kind": "section", "title": "Settings", "tight": true])
      items.append(setting("blocker", "shield.lefthalf.filled", "Block Ads & Trackers", blockerValue, enabled && !allowed && !unavailable && !preparing, blocker != nil && !unavailable && !preparing && (!webkit || blocker?["ready"]?.bool == true)))
      let developer = developerEnabled(context: c)
      items.append(setting("developer", "hammer.fill", "Developer Mode", developer ? "On" : "Off", developer, c["privatePage"]?.bool != true && developerHost(url) != nil))
      let opensIn = c["privatePage"]?.bool == true ? engineName(engine) : c["engineRule"]?.string.map(engineName) ?? recommendedTitle(c)
      items.append(setting("engine", engineIcon(engine), "Opens in", opensIn, c["engineRule"]?.string != nil, true))
      let sleeps = c["sleepInactiveTabs"]?.bool != false
      let cover = KeepAwakeSites.cover(of: host(url), in: KeepAwakeSites.sites(c[KeepAwakeSites.settingKey]))
      let sleepValue: String
      switch cover {
      case _ where !sleeps: sleepValue = "Off"
      case .none: sleepValue = "On"
      case .exact: sleepValue = "Never"
      case .parent(let site): sleepValue = "Never · via \(site)"
      }
      items.append(setting("sleep", "moon.zzz", "Sleep When Inactive", sleepValue, sleeps && cover == .none, true))
      for p in shown { items.append(setting("perm:" + p.id, p.badge, p.title, value(p.id), settings?[p.id]?["value"] == "allow", true)) }
    }
    let look = connection(c["security"])
    if expanded == "connection" {
      items.append(["kind": "separator"])
      items.append(["kind": "header", "title": hasOrigin ? displayHost(host(url)) : c["label"]?.string ?? "", "detail": c["title"]?.string ?? "", "favicon": ["url": url, "favicon": c["favicon"]?.string as Any? ?? NSNull(), "profileId": c["profileId"]?.string ?? ""]])
      var row: [String: Any] = ["kind": "row", "id": "connection-row", "icon": look.icon, "title": look.title]
      if let color = look.color ?? c["theme"]?["icon"]?.string { row["iconColor"] = color }
      if let detail = look.detail { row["detail"] = detail }
      items.append(row)
      if let cert = c["security"]?["certificate"], !cert.isNull { items.append(["kind": "certificate", "rows": certificateRows(c["security"] ?? [:])]) }
    }
    if expanded == "more" {
      items.append(["kind": "separator"])
      items.append(["kind": "row", "id": "zoom", "icon": "plus.magnifyingglass", "title": "Zoom", "accessory": ["kind": "zoom", "zoom": c["zoom"]?.number ?? 1]])
      if hasOrigin && !castTile { items.append(["kind": "row", "id": "cast", "icon": "tv.and.mediabox", "title": "Cast…", "pressable": true]) }
      if hasOrigin {
        let otherEngine = webkit ? "chromium" : "webkit"
        items.append(["kind": "row", "id": "other-engine", "icon": engineIcon(otherEngine), "title": "Open Page in \(engineName(otherEngine))", "pressable": true])
        items.append(["kind": "separator"])
        items += dictionaries(c["translate"])
        for p in other { items.append(["kind": "row", "id": "perm:" + p.id, "icon": p.icon, "title": p.title, "accessory": ["kind": "value", "title": value(p.id)]]) }
        if !other.isEmpty { items.append(["kind": "separator"]) }
        var clear: [String: Any] = ["kind": "row", "id": "clear", "icon": "trash", "title": "Clear Cookies and Site Data…", "pressable": true]
        if let cleared { clear["detail"] = cleared }
        items.append(clear)
      }
      items.append(["kind": "row", "id": "full-url", "icon": "text.alignleft", "title": "Show Full URL", "accessory": ["kind": "toggle", "value": c["showFullUrl"]?.bool == true]])
    }
    var chip: [String: Any] = ["icon": look.icon, "title": look.chip, "open": expanded == "connection"]
    if let color = look.color { chip["color"] = color }
    items.append(["kind": "footer", "top": hasOrigin ? 8 : 14, "chip": chip, "moreOpen": expanded == "more"])
    guard let themeData = (c["theme"] ?? [:]).text().data(using: .utf8), let theme = try? JSONSerialization.jsonObject(with: themeData) else { return nil }
    let state: [String: Any] = ["items": items, "dark": c["dark"]?.bool == true, "theme": theme]
    guard let data = try? JSONSerialization.data(withJSONObject: state) else { return nil }
    return try? JSONDecoder().decode(SitePanelState.self, from: data)
  }

  private static func dictionaries(_ value: JSONValue?) -> [[String: Any]] {
    guard let value, let data = value.text().data(using: .utf8) else { return [] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
  }

  private static func connection(_ security: JSONValue?) -> (icon: String, chip: String, color: String?, title: String, detail: String?) {
    let level = security?["level"]?.string ?? "none"
    let secure = level == "secure"
    let local = ["local", "none"].contains(level)
    let mixed = level == "mixed"
    let icon = secure ? "lock.fill" : local ? "info.circle" : "lock.open.trianglebadge.exclamationmark.fill"
    let chip = secure ? "Secure" : local ? "Local Page" : mixed ? "Not Fully Secure" : "Not Secure"
    let color: String? = secure || local ? nil : mixed ? "#F2B33D" : "#FF6B63"
    let title = secure ? "Connection is secure" : local ? "This is a local or internal page" : "Connection is not secure"
    let detail: String?
    switch level {
    case "certificateError": detail = "The site's certificate isn't valid. Don't enter passwords or payment details."
    case "mixed": detail = "Parts of this page aren't secure (such as images)."
    case "insecure": detail = "Don't enter sensitive information on this site."
    case "secure" where security?["certificate"]?.object != nil:
      let issuer = security?["certificate"]?["issuer"]
      let organization = issuer?["organizations"]?.array?.first?.string ?? ""
      detail = "Certificate issued by \(organization.isEmpty ? issuer?["commonName"]?.string ?? "" : organization)"
    default: detail = nil
    }
    return (icon, chip, color, title, detail)
  }

  private static func certificateRows(_ security: JSONValue) -> [[String]] {
    let cert = security["certificate"] ?? [:]
    func name(_ part: String) -> String {
      let common = cert[part]?["commonName"]?.string ?? ""
      return common.isEmpty ? cert[part]?["displayName"]?.string ?? "" : common
    }
    func date(_ key: String) -> String {
      let formatter = DateFormatter()
      formatter.setLocalizedDateFormatFromTemplate("yMMMd")
      return formatter.string(from: Date(timeIntervalSince1970: (cert[key]?.number ?? 0) / 1000))
    }
    let organizations = cert["subject"]?["organizations"]?.array?.compactMap(\.string).joined(separator: ", ") ?? ""
    var rows = [["Issued to", name("subject")], ["Organization", organizations.isEmpty ? "—" : organizations], ["Issued by", name("issuer")], ["Valid from", date("validFrom")], ["Expires", date("validUntil")]]
    if let proto = security["protocol"]?.string, !proto.isEmpty { rows.append(["Protocol", proto]) }
    if let sha = cert["sha256"]?.string, !sha.isEmpty {
      let clean = Array(sha.filter { $0.isASCII && $0.isHexDigit })
      let pairs = stride(from: 0, to: clean.count, by: 2).map { String(clean[$0..<min($0 + 2, clean.count)]) }
      rows.append(["SHA-256", String(pairs.joined(separator: " ").prefix(47)) + "…"])
    }
    return rows
  }
}

public struct SiteControlsSession: Sendable {
  public private(set) var featured: Set<String>?
  private var key: [String]?
  private var generation = 0

  public init() {}

  public mutating func beginRefresh(context: JSONValue) -> Int? {
    guard let origin = SiteControlsLogic.origin(context["url"]?.string ?? "") else {
      invalidate()
      return nil
    }
    let next = [origin, context["profile"]?.string ?? "", context["pageEngine"]?.string ?? "chromium"]
    guard next != key else { return nil }
    key = next
    generation += 1
    return generation
  }

  public func accepts(token: Int) -> Bool { key != nil && token == generation }

  public mutating func receivePermissions(context: JSONValue, settings: JSONValue, token: Int) -> Bool {
    guard accepts(token: token) else { return false }
    if featured == nil { featured = SiteControlsLogic.featuredPermissions(context: context, settings: settings) }
    return true
  }

  public mutating func invalidate() {
    key = nil
    generation += 1
  }
}
