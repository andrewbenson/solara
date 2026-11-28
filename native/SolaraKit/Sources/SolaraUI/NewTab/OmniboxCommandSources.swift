import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public enum OmniboxCommandSources {
  public static func actions(state s: BrowserState, windowId: String, bookmarked: Bool, shortcuts: CommandShortcutSnapshot) -> [CommandAction] {
    let window = s.windows[windowId]
    let context = CommandContext(state: s, windowId: windowId, env: CommandAddressing())
    let tab = context.activeTab
    let host = tab.flatMap { developerHost($0.url) }
    let hints = shortcuts.hints
    var actions: [CommandAction] = []
    for d in OmniboxCommandCatalog.base {
      switch d.needs {
      case "page": if tab?.url.isEmpty != false { continue }
      case "tab": if tab == nil { continue }
      case "profiles": if window?.incognito == true { continue }
      case "pins": if !context.canTidyPins { continue }
      case "site": if host == nil || tab.map({ Ids.isIncognitoProfile($0.profileId) }) != false { continue }
      default: break
      }
      var title = d.title
      switch d.id {
      case "togglePin": title = tab?.isPinnedRow == true ? "Unpin Tab" : tab?.pinned == true ? "Unpin from Top Apps" : "Move to Top Apps"
      case "togglePin:row": title = tab?.isPinnedRow == true ? "Move to Top Apps" : "Move to Pinned in \(s.profiles[tab?.profileId ?? ""]?.name ?? "Profile")"
      case "toggleMute": title = tab?.muted == true ? "Unmute Site" : "Mute Site"
      case "bookmarkPage": title = bookmarked ? "Remove Bookmark" : "Bookmark This Page"
      case "toggleDeveloperMode":
        guard let host, let tab else { continue }
        title = developerEnabled(host, settings: s.settings, profileId: tab.profileId) ? "Turn off Developer Mode for this site" : "Turn on Developer Mode for this site"
      case "toggleFullUrl": title = s.settings.bool("showFullUrl") ? "Hide Full URL" : "Show Full URL"
      default: break
      }
      actions.append(CommandAction(id: d.id, title: title, keywords: d.keywords, icon: d.icon, hint: hints[JSKey(d.id)]))
    }
    if let window, !window.incognito {
      for id in s.profileOrder where JSKey(id) != JSKey(window.profileId) {
        let name = s.profiles[id]?.name ?? ""
        let action = "switchProfile:\(id)"
        actions.append(CommandAction(id: action, title: "Switch to \(name)", keywords: [name, "profile", "space"], icon: "person.crop.circle", hint: hints[JSKey(action)]))
      }
    }
    actions += organize(state: s, windowId: windowId, context: context)
    return actions
  }

  public static func extensionProfile(state: BrowserState, windowId: String) -> String {
    guard let window = state.windows[windowId] else { return "" }
    return state.privateSession(window.profileId) ?? state.engineProfile(window.profileId)
  }

  public static func extensions(state: BrowserState, windowId: String, displayed: [JSONObject]) -> [ExtensionCandidate] {
    let priv = state.windows[windowId]?.incognito == true
    return displayed.compactMap { x in
      guard x["enabled"]?.truthy == true, !priv || (x["incognito"]?.truthy == true && x["incognitoSplit"]?.truthy == true) else { return nil }
      let action = x["hasAction"] != .bool(false)
      let options = x["optionsUrl"]?.truthy == true
      guard action || options else { return nil }
      let icon = x["actionIcon"]?.truthy == true ? x["actionIcon"]?.string : x["icon"]?.truthy == true ? x["icon"]?.string : nil
      return ExtensionCandidate(id: x["id"]?.string ?? "", title: x["name"]?.string ?? "", icon: icon, action: action, options: options)
    }
  }

  public static func isDeveloperURL(_ url: String, settings: Settings, profileId: String) -> Bool {
    developerHost(url).map { developerEnabled($0, settings: settings, profileId: profileId) } ?? false
  }

  private static func developerHost(_ url: String) -> String? {
    guard let parsed = WhatwgURL(url), parsed.protocol == "http:" || parsed.protocol == "https:" else { return nil }
    let host = parsed.hostname.lowercased()
    guard !host.isEmpty else { return nil }
    let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return stripped.isEmpty ? nil : stripped
  }

  private static func defaultHost(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host.hasSuffix(".localhost")
  }

  private static func developerEnabled(_ host: String, settings: Settings, profileId: String) -> Bool {
    let owner = Ids.isIncognitoProfile(profileId) ? Ids.incognitoOriginal(profileId) : profileId
    let raw = settings["developerMode"]?[owner]
    func hosts(_ field: String, defaults: Bool) -> Set<JSKey> {
      var seen = Set<JSKey>()
      let list = (raw?[field]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty && $0.jsLength <= 253 }
        .map { $0.lowercased() }.filter { seen.insert(JSKey($0)).inserted }.filter { defaultHost($0) == defaults }
      return Set(list.suffix(1000).map(JSKey.init))
    }
    return defaultHost(host) ? !hosts("off", defaults: true).contains(JSKey(host)) : hosts("on", defaults: false).contains(JSKey(host))
  }

  private static func organize(state s: BrowserState, windowId: String, context: CommandContext) -> [CommandAction] {
    guard let w = s.windows[windowId], !w.isSmall, let tab = context.activeTab, !context.hiddenEmptyCard else { return [] }
    let split = s.splits.values.first { $0.tabIds.contains { JSKey($0) == JSKey(tab.id) } }
    let room = (split?.tabIds.count ?? 0) < Splits.maxPanes
    let horizontal = split?.orientation == "horizontal"
    let stacked = split.map { Splits.slotsOf($0).contains { $0.count == 2 && $0.contains { JSKey($0) == JSKey(tab.id) } } } ?? false
    let inProfiles = !w.incognito && !Ids.isIncognitoProfile(tab.profileId)
    let otherTab = context.viewTabIds.contains { id in
      JSKey(id) != JSKey(tab.id) && s.tabs[id]?.url.isEmpty == false && !(split?.tabIds.contains { JSKey($0) == JSKey(id) } ?? false)
    }
    var out: [CommandAction] = []
    func add(_ id: String, _ title: String, _ icon: String, _ keywords: [String], _ shows: Bool) {
      if shows { out.append(CommandAction(id: id, title: title, keywords: keywords, icon: icon)) }
    }
    add("split:sideBySide", "Split View Side by Side", "rectangle.split.2x1", ["split view", "side by side", "new split", "vertical split"], split == nil)
    add("split:stacked", "Split View Stacked", "rectangle.split.1x2", ["split view", "stacked", "top and bottom", "horizontal split"], split == nil)
    add("split:withTab", split == nil ? "Split View with Tab…" : "Add Tab to Split View…", "plus.rectangle.on.rectangle", ["split view", "add tab to split", "split with tab", "add pane"], room && otherTab)
    add("split:add", horizontal ? "Add Vertical Split View" : "Add Horizontal Split View", "rectangle.split.3x1", ["split view", "add pane", "new pane"], split != nil && room)
    add("split:cross", horizontal ? "Add Bottom Split" : "Add Right Split", "rectangle.bottomhalf.inset.filled", ["split view", "add pane", "stacked", "side by side"], split != nil && room && !stacked)
    add("split:flip", "Flip Split View", "arrow.left.arrow.right", ["split view", "swap panes"], split != nil)
    add("split:convert", horizontal ? "Convert to Vertical Split View" : "Convert to Horizontal Split View", "rectangle.split.1x2", ["split view", "rotate split", "stacked", "side by side"], split != nil)
    add("split:remove", "Remove from Split View", "rectangle.portrait.and.arrow.right", ["split view", "remove pane", "unsplit tab"], split != nil)
    add("split:exit", "Exit Split View", "rectangle.split.3x1", ["split view", "separate all tabs", "unsplit", "close split view", "end split"], split != nil)
    add("profile:moveTab", "Move Tab to Profile…", "person.crop.circle", ["move tab", "move to profile", "move to space", "send tab to profile"], inProfiles)
    add("profile:rename", "Rename Profile…", "pencil", ["rename profile", "rename space", "profile name"], inProfiles)
    add("profile:edit", "Edit Profiles…", "person.2", ["manage profiles", "reorder profiles", "delete profile", "spaces", "profile settings"], inProfiles)
    if inProfiles {
      for id in s.profileOrder where JSKey(id) != JSKey(tab.profileId) {
        let name = s.profiles[id]?.name ?? ""
        add("moveTabToProfile:\(id)", "Move Tab to \(name)", "arrow.right.circle", [name, "move tab", "move to profile", "move to space"], true)
      }
      add("moveTabToProfile:new", "Move Tab to New Profile", "person.crop.circle.badge.plus", ["move tab", "new profile", "new space"], true)
    }
    return out
  }
}

private struct CommandAddressing: WebAddressing {
  func resolveInput(_ input: String, searchUrlPrefix: String) -> String { SolaraOmnibox.resolveInput(input, search: searchUrlPrefix) }
  func searchUrlPrefix(_ settings: Settings) -> String { SolaraOmnibox.searchUrlPrefix(settings) }
  func parseURL(_ url: String) -> ParsedURL? {
    guard let parsed = WhatwgURL(url) else { return nil }
    return ParsedURL(protocol: parsed.protocol, host: parsed.host, hostname: parsed.hostname)
  }
}
