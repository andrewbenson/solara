import Foundation
import SolaraModel

public struct ImportDiaProfile: Sendable, Equatable {
  public let id: String
  public let name: String
  public let pinned: [ImportTabRow]
  public let tabs: [ImportTabRow]

  public init(id: String, name: String, pinned: [ImportTabRow], tabs: [ImportTabRow]) {
    self.id = id
    self.name = name
    self.pinned = pinned
    self.tabs = tabs
  }
}

public struct ImportDiaRead: Sendable, Equatable {
  public let profiles: [ImportDiaProfile]
  public let windowCount: Int
  public let favicons: [ImportFaviconRow]

  public init(profiles: [ImportDiaProfile], windowCount: Int, favicons: [ImportFaviconRow]) {
    self.profiles = profiles
    self.windowCount = windowCount
    self.favicons = favicons
  }
}

extension ImportRunner {
  static let diaSafeModeNote = "Tab import is unavailable in safe mode."
  static let diaUnreadNote = "Read Dia's tabs again before importing."

  func importDia(_ read: ImportDiaRead?, profileIds: [String], target: String, pinned: Bool, open: Bool) async -> ImportRunOutcome {
    let kinds: [ImportKind] = (open ? [.tabs] : []) + (pinned ? [.pinnedTabs] : [])
    let selected = read?.profiles.filter { profileIds.contains($0.id) } ?? []
    var total = ImportCounts()
    func failed(from index: Int, _ note: String?) -> ImportRunOutcome {
      ImportRunOutcome(
        status: Dictionary(kinds.map { ($0, ImportStatus.failed) }, uniquingKeysWith: { a, _ in a }),
        failures: kinds.map { ImportFailure(kind: $0, profiles: selected.dropFirst(index).map(\.name)) },
        counts: total,
        notes: note.map { [$0] } ?? []
      )
    }
    if engine.safeMode {
      engine.transientImportRefused()
      return failed(from: 0, Self.diaSafeModeNote)
    }
    guard let read else { return failed(from: 0, Self.diaUnreadNote) }
    for (index, profile) in selected.enumerated() {
      let destination: String
      switch await self.destination(target, index, profile.name, nil, stopped: { false }) {
      case .profile(let id) where !cancelled():
        destination = id
      case .unavailable where !cancelled():
        return failed(from: index, Self.noDestinationNote(profile.name))
      default:
        return .cancelledRun
      }
      let openTabs = open ? profile.tabs : []
      let pinnedTabs = pinned ? profile.pinned : []
      runs.traceStep("favicons")
      let chosen = ImportFavicons.chosen(read.favicons, pages: (pinnedTabs + openTabs).map(\.url))
      let control = ImportRunControl(engine: engine)
      await placeFavicons(chosen, profile: destination, control: control)
      if cancelled() { return .cancelledRun }
      var windows: [JSONValue] = []
      if pinned { windows.append(.object(["tabs": .array(pinnedTabs.map { $0.json() }), "skipExistingOpen": true])) }
      if open { windows.append(.object(["tabs": .array(openTabs.map { $0.json(pinned: false) }), "group": "Imported", "skipExistingOpen": true])) }
      guard !windows.isEmpty else { continue }
      runs.traceStep("workspace")
      guard let added = engine.importWorkspace(profile: destination, windows: windows) else { return failed(from: index, nil) }
      total.tabs += added
    }
    return ImportRunOutcome(status: Dictionary(kinds.map { ($0, ImportStatus.done) }, uniquingKeysWith: { a, _ in a }), counts: total)
  }
}
