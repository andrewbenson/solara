import Foundation
import SolaraModel

public struct ImportWorkspaceWritten: Sendable, Equatable {
  public let tabs: Int
  public let skipped: Int

  public init(tabs: Int, skipped: Int) {
    self.tabs = tabs
    self.skipped = skipped
  }
}

enum ImportSidebarFailure: Error {
  case unavailable(String)
  case workspace(String)
  case halted
}

enum ImportSidebarPlacement {
  static func link(_ node: ImportBookmarkNode) -> JSONValue {
    var value: JSONObject = ["url": .string(node.url ?? ""), "title": .string(node.pageTitle ?? node.title)]
    if let pageTitle = node.pageTitle, !pageTitle.isEmpty { value["customTitle"] = .string(node.title) }
    return .object(value)
  }

  static func liveSources(_ nodes: [ImportBookmarkNode]) -> [String] {
    var sources: [String] = []
    func visit(_ nodes: [ImportBookmarkNode]) {
      for node in nodes {
        if node.role == "liveGitHubPullRequests", !sources.contains("github") { sources.append("github") }
        visit(node.children ?? [])
      }
    }
    visit(nodes)
    return sources
  }

  static func drafts(_ nodes: [ImportBookmarkNode]) -> [JSONValue] {
    nodes.filter { $0.role != "liveGitHubPullRequests" }.map { node in
      node.isFolder ? .object(["title": .string(node.title), "children": .array(drafts(node.children ?? []))]) : link(node)
    }
  }

  static func windows(_ space: ImportSpaceRow) -> [JSONValue] {
    let rows = space.pinned.filter { !$0.isFolder && !($0.url ?? "").isEmpty }.map { node -> JSONValue in
      var row = link(node).object!
      row["pinned"] = true
      row["row"] = true
      return .object(row)
    }
    return [
      .object(["tabs": .array(rows)]),
      .object(["tabs": .array(space.tabs.map { $0.json(pinned: false) }), "group": "Imported", "drafts": .array(drafts(space.pinned.filter(\.isFolder)))])
    ]
  }

  static func skippedNote(_ count: Int, name: String) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    let number = formatter.string(from: NSNumber(value: count)) ?? String(count)
    return "\(number) \(count == 1 ? "link" : "links") in \(name)'s folders weren't imported: each folder brings up to 5,000 links."
  }
}

extension ImportRunner {
  func admitsDestination(_ profile: String, control: ImportRunControl, transient: Bool = true) -> Bool {
    !cancelled() && !control.stopped && engine.profileExists(profile) && !engine.isPrivateProfile(profile) && (!transient || !engine.safeMode)
  }

  func requireDestination(_ profile: String, name: String, control: ImportRunControl) throws {
    if cancelled() || control.stopped { throw ImportSidebarFailure.halted }
    if !admitsDestination(profile, control: control) { throw ImportSidebarFailure.unavailable(name) }
  }

  func placeFavicons(_ favicons: [ImportFaviconRow], profile: String, control: ImportRunControl) async {
    guard !favicons.isEmpty, admitsDestination(profile, control: control) else { return }
    await engine.adoptFavicons(profile: profile, favicons: favicons)
    guard admitsDestination(profile, control: control) else { return }
    let engineProfile = engine.engineProfile(profile)
    runs.track { [self] in
      guard admitsDestination(profile, control: control), engine.engineProfile(profile) == engineProfile else { return }
      await engine.storeFavicons(profile: profile, engineProfile: engineProfile, favicons: favicons)
    }
  }

  func placeSidebarSpace(_ space: ImportSpaceRow, profile: String, favicons: [ImportFaviconRow], control: ImportRunControl) async -> ImportWorkspaceWritten? {
    themeAdoptionFailed = false
    guard admitsDestination(profile, control: control) else { return nil }
    runs.traceStep("favicons")
    let chosen = ImportFavicons.chosen(favicons, pages: ImportFavicons.links(space.pinned) + space.tabs.map(\.url))
    await placeFavicons(chosen, profile: profile, control: control)
    guard admitsDestination(profile, control: control) else { return nil }
    for source in ImportSidebarPlacement.liveSources(space.pinned) {
      guard admitsDestination(profile, control: control) else { return nil }
      runs.track { [self] in
        guard admitsDestination(profile, control: control) else { return }
        await engine.importPullRequestsFolder(profile: profile, source: source)
      }
    }
    guard admitsDestination(profile, control: control) else { return nil }
    var theme = space.theme.flatMap(ImportArcTheme.parse)
    if theme != nil {
      let acknowledgement = ImportThemeAcknowledgement()
      let adoption = runs.track { [self] in
        guard admitsDestination(profile, control: control) else { return }
        do { acknowledgement.accepted = try await engine.adoptProfileTheme(profile: profile) }
        catch { acknowledgement.accepted = false }
      }
      let deadline: Duration
      #if DEBUG
      deadline = runs.themeAdoptionDeadline
      #else
      deadline = .seconds(10)
      #endif
      let completed = await runs.settle(adoption, within: deadline, until: control)
      guard admitsDestination(profile, control: control) else { return nil }
      if !completed || !acknowledgement.accepted {
        theme = nil
        themeAdoptionFailed = true
      }
    }
    guard admitsDestination(profile, control: control) else { return nil }
    runs.traceStep("workspace")
    return engine.placeWorkspace(profile: profile, windows: ImportSidebarPlacement.windows(space), theme: theme)
  }
}

@MainActor
public enum ImportFaviconWrites {
  public static func persist(profile: String, engineProfile: String, favicons: [ImportFaviconRow],
                             binding: () -> String?, load: (String) async -> Bool,
                             store: (String, String, ImportFaviconRow) async -> Void) async {
    guard binding() == engineProfile else { return }
    guard await load(engineProfile), binding() == engineProfile else { return }
    for entry in ImportFavicons.byPage(favicons) {
      guard binding() == engineProfile else { return }
      await store(engineProfile, entry.page, entry.favicon)
    }
  }
}
