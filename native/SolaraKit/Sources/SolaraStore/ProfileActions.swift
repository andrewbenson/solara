import Foundation
import SolaraModel

let profileColors = ["blue", "green", "orange", "purple", "red", "yellow", "pink"]

func dataIdOf(_ p: Profile) -> String { p.dataId ?? p.id }
func engineIdOf(_ p: Profile) -> String { dataIdOf(p) == Settings.defaultProfileID ? "" : dataIdOf(p) }

func unusedProfileColor(_ profiles: Table<Profile>) -> String {
  profileColors.first { c in !profiles.values.contains { $0.color == c } } ?? "blue"
}

func sharingProfiles(_ s: BrowserState, _ id: String) -> [String] {
  guard let p = s.profiles[id] else { return [] }
  return s.profileOrder.filter { other in !other.jsEquals(id) && s.profiles[other].map { dataIdOf($0).jsEquals(dataIdOf(p)) } ?? false }
}

extension Session {
  public func createProfile(name: String, color: String?, icon: String?, shareWith: String?) throws -> String {
    guard !config.safeMode else {
      throw CommandError("Profiles can't be created in safe mode. Quit and open Solara normally to create one.")
    }
    let s = state
    let source = shareWith.flatMap { $0.isEmpty ? nil : s.profiles[$0] }
    if let source {
      try requireGeneratedProfileIdentity(source, key: shareWith)
      try refusePendingProfileData(engineIdOf(source))
    }
    let trimmed = name.jsTrim()
    let deleted = try ProfileDataTombstones.read(config.profileDataTombstones, pending: s.orphanedProfileData, live: s.profiles.values.map(engineIdOf))
    func candidate() -> String { config.profileDataTombstones == nil ? newId("p") : "p-\(UUID().uuidString.lowercased())-1" }
    var id = candidate()
    while s.profiles[id] != nil || s.profiles.values.contains(where: { engineIdOf($0).jsEquals(id) })
      || profileDataPending(s, id, launch: memory.ids.launch) || deleted.contains(where: { $0.jsEquals(id) }) { id = candidate() }
    var profile = Profile(
      id: id, name: trimmed.isEmpty ? "Profile \(s.profileOrder.count + 1)" : trimmed, color: color ?? unusedProfileColor(s.profiles),
      icon: icon, createdAt: now)
    if let source { profile.dataId = dataIdOf(source) }
    try requireGeneratedProfileIdentity(profile)
    var next = s
    next.profiles[profile.id] = profile
    next.profileOrder.append(profile.id)
    emit(.profileCreated(profileId: profile.id, sharedWith: source?.id))
    set(next)
    return profile.id
  }

  public func updateProfile(_ id: String, _ patch: TabUpdate) throws {
    guard !config.safeMode else {
      throw CommandError("Profile edits can't be saved in safe mode while the saved session and launch appearance are kept unchanged. Open Solara normally to edit profiles.")
    }
    var next = state
    guard let p = next.profiles[id] else {
      set(next)
      return
    }
    var json = p.json
    for (key, value) in patch.set { json[key] = value }
    for key in patch.unset { json.removeValue(forKey: key) }
    if let updated = try? Profile(json: json) {
      if memory.fromSyncDepth > 0 || fromSyncOrigin { try requireGeneratedProfileIdentity(updated, key: id) }
      if !updated.id.jsEquals(p.id) || !dataIdOf(updated).jsEquals(dataIdOf(p)) {
        try requireGeneratedProfileIdentity(updated, key: id)
        try refusePendingProfileData(engineIdOf(updated))
      }
      next.profiles[id] = updated
    }
    set(next)
  }

  public func deleteProfile(_ id: String) throws {
    guard !config.safeMode else {
      throw CommandError("Profiles can't be deleted in safe mode. Quit and open Solara normally to delete one.")
    }
    guard state.profiles[id] != nil, state.profileOrder.count > 1 else { return }
    let deleting = engineIdOf(state.profiles[id]!)
    if !state.profiles.values.contains(where: { !$0.id.jsEquals(id) && engineIdOf($0).jsEquals(deleting) }) {
      try ProfileDataTombstones.insert(deleting, at: config.profileDataTombstones, pending: state.orphanedProfileData, live: state.profiles.values.map(engineIdOf))
    }
    for w in state.windows.values where w.incognito && w.originalProfileId?.jsEquals(id) == true { closeWindow(w.id) }
    var s = state
    let profileOrder = s.profileOrder.filter { !$0.jsEquals(id) }
    let fallback = s.settings.defaultProfileId.jsEquals(id) ? profileOrder[0] : s.settings.defaultProfileId
    var neverTranslate = s.settings["neverTranslateSites"]?.object ?? [:]
    neverTranslate.removeValue(forKey: id)
    var developerMode = s.settings["developerMode"]?.object ?? [:]
    developerMode.removeValue(forKey: id)
    let settings = s.settings.merging([
      "defaultProfileId": .string(fallback), "neverTranslateSites": .object(neverTranslate), "developerMode": .object(developerMode),
    ])
    let shared = !sharingProfiles(s, id).isEmpty
    let engine = engineIdOf(s.profiles[id]!)
    let orphaned =
      profileOrder.contains(where: { engineIdOf(s.profiles[$0]!).jsEquals(engine) }) || s.orphanedProfileData.contains(where: { $0.jsEquals(engine) })
      ? s.orphanedProfileData : s.orphanedProfileData + [engine]
    for w in s.windows.values where w.profileId.jsEquals(id) {
      if let other = w.tabIds.first(where: { s.tabs[$0]?.profileId.jsEquals(id) != true }) {
        s = activated(s, w.activeTabIds[s.tabs[other]!.profileId] ?? other)
      } else {
        var o = NewTabOptions()
        o.profileId = fallback
        o.background = true
        let (next, tab) = withNewTab(s, w.id, o)
        s = activated(next, tab)
      }
    }
    s = removeTabs(s, s.tabs.values.filter { $0.profileId.jsEquals(id) }.map(\.id), record: false)
    var windows = s.windows
    windows.touch()
    for w in windows.values where w.activeTabIds[id] != nil {
      var changed = w
      changed.activeTabIds.removeValue(forKey: id)
      windows[w.id] = changed
    }
    var next = s
    next.windows = windows
    next.profiles.remove([id])
    next.profileOrder = profileOrder
    next.orphanedProfileData = orphaned
    next.settings = settings
    next.groups = s.groups.filtered { !$0.profileId.jsEquals(id) }
    next.closedTabs = s.closedTabs.filter { !$0.tab.profileId.jsEquals(id) }
    next.cleanedTabs = s.cleanedTabs.filter { !$0.tab.profileId.jsEquals(id) }
    next.closedGroups = s.closedGroups.filter { $0.tabs.allSatisfy { !$0.profileId.jsEquals(id) } }
    next.deletedGroups = s.deletedGroups.filter { $0.tabs.allSatisfy { !$0.profileId.jsEquals(id) } }
    next.closedWindows = s.closedWindows.map { c in
      var kept = c
      kept.tabs = c.tabs.filter { !$0.snapshot.profileId.jsEquals(id) }
      return kept
    }.filter { !$0.tabs.isEmpty }
    next.parkedPins.remove([id])
    emit(.profileDeleted(profileId: id, shared: shared))
    set(next)
    for w in state.windows.values where state.viewTabIds(w.id).isEmpty { _ = newTab(w.id) }
  }

  public func reorderProfiles(_ ids: [String]) throws {
    guard !config.safeMode else {
      throw CommandError("Profile edits can't be saved in safe mode while the saved session and launch appearance are kept unchanged. Open Solara normally to edit profiles.")
    }
    var next = state
    let known = ids.filter { next.profiles[$0] != nil }
    next.profileOrder = known + next.profileOrder.filter { !known.contains($0) }
    set(next)
  }

  public func setDefaultProfile(_ id: String) {
    var next = state
    if next.profiles[id] != nil { next.settings = next.settings.merging(["defaultProfileId": .string(id)]) }
    set(next)
  }

  public func profileDataDeleted(_ engineId: String) {
    var next = state
    if next.orphanedProfileData.contains(engineId) { next.orphanedProfileData = next.orphanedProfileData.filter { $0 != engineId } }
    set(next)
  }

  public func setFocusedWindow(_ id: String) {
    let s = state
    guard let w = s.windows[id] else { return }
    let lastProfileId = linkProfileOf(s, w) ?? s.ui.lastProfileId
    if s.ui.focusedWindowId == id && s.ui.lastProfileId == lastProfileId { return }
    var next = s
    next.ui.focusedWindowId = id
    next.ui.focusOrder = [id] + s.ui.focusOrder.filter { $0 != id }
    next.ui.lastProfileId = lastProfileId
    set(next)
  }

  public func updateSettings(_ patch: JSONObject, fromSync: Bool) {
    var next = state
    next.settings = next.settings.updated(patch, fromSync: fromSync)
    set(next)
  }

  func downloadSession(_ s: BrowserState, _ d: Download) -> String? {
    if d.offTheRecord { return d.profile ?? "" }
    guard let profile = d.profile, !profile.isEmpty, Ids.isIncognitoProfile(profile) else { return nil }
    return s.privateSession(profile)
  }

  func downloadVisibleIn(_ s: BrowserState, _ d: Download, _ window: BrowserWindow?) -> Bool {
    guard let window else { return false }
    let session = downloadSession(s, d)
    if window.incognito { return session != nil && session == s.privateSession(window.profileId) }
    return session == nil && (d.profile ?? "") == s.engineProfile(window.profileId)
  }

  func privateSessionOpen(_ s: BrowserState, _ session: String) -> Bool {
    s.windows.values.contains { $0.incognito && s.privateSession($0.profileId) == session }
  }

  public func upsertDownload(_ d: Download) {
    var next = state
    let exists = next.downloads.contains { $0.id == d.id }
    let session = downloadSession(next, d)
    if !exists, let session, !privateSessionOpen(next, session) || memory.endedPrivateDownloads.contains(d.id) {
      memory.endedPrivateDownloads.insert(d.id)
      set(next)
      return
    }
    if exists {
      next.downloads = next.downloads.map { $0.id == d.id ? d : $0 }
    } else {
      next.downloads = [d] + next.downloads
      if !config.safeMode { next.downloads = Array(next.downloads.prefix(Download.maxKept)) }
      if let focused = next.ui.focusedWindowId, downloadVisibleIn(next, d, next.windows[focused]) { next.openDownloads(focused) }
    }
    set(next)
  }

  public func removeDownload(_ id: String) {
    var next = state
    next.downloads = next.downloads.filter { $0.id != id }
    set(next)
  }

  public func clearDownloads(_ windowId: String?) {
    var next = state
    let s = next
    next.downloads = s.downloads.filter { d in d.isDownloading || (windowId != nil && !downloadVisibleIn(s, d, s.windows[windowId!])) }
    set(next)
  }

  public func forgetDownloads(_ profile: String) {
    let s = state
    let session = s.privateSession(profile)
    func gone(_ d: Download) -> Bool { session != nil ? downloadSession(s, d) == session : d.profile == profile }
    if session != nil { for d in s.downloads where gone(d) { memory.endedPrivateDownloads.insert(d.id) } }
    var next = s
    if s.downloads.contains(where: gone) { next.downloads = s.downloads.filter { !gone($0) } }
    set(next)
  }
}
