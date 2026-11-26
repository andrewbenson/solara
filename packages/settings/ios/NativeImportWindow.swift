import AppKit
import SolaraShell
import Foundation
import SolaraImportAdapter
import SolaraModel
import SolaraUI
import SwiftUI

@MainActor
enum NativeImportWindow {
  static let kind = "import"

  nonisolated static var enabled: Bool {
    NativeSettingsWindow.enabled
  }

  static func makeController() -> NSViewController? {
    guard enabled else { return NativeSettingsWindow.unavailableController() }
    let model = ImportModel(services: ImportAdapter(), appName: Bundle.main.productName)
    current = model
    let controller = ImportHostingController(model: model)
    hosting = controller
    return controller
  }

  static weak var current: ImportModel?
  static weak var hosting: ImportHostingController?

  nonisolated static var drivable: Bool { ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" && !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty }

  static func benchmarkImportBookmarks(_ path: String) async -> Int {
    let runs = ImportRuns.shared
    let session = runs.open()
    let outcome = await runs.importBookmarksFile(path: path, target: "default", session: session, engine: ImportRunEngine.shared)
    guard case .imported(let counts, let failed) = outcome, failed.isEmpty else { return 0 }
    return counts.bookmarks
  }

  static func drive(_ action: String, _ argument: String?) async -> [String: Any] {
    guard drivable, let model = current else { return withDevFields(["error": "no native import window"], nil) }
    switch action {
    case "select":
      #if DEBUG
      ImportRoutingDebug.outcome = nil
      ImportRoutingDebug.route = nil
      #endif
      guard let browser = model.browsers.first(where: { $0.id == argument }) else { return ["error": "no browser \(argument ?? "")"] }
      model.choose(browser)
    case "next": await model.next()
    case "unlock": await model.unlock()
    #if DEBUG
    case "target":
      model.target = argument ?? ""
    case "cancelRun":
      model.services.cancel()
    case "ackRelease":
      SettingsJS.shared.devReleaseImportReply()
    case "themeDeadline":
      if let milliseconds = argument.flatMap(Int.init) { ImportRuns.shared.themeAdoptionDeadline = .milliseconds(milliseconds) }
    case "kinds":
      model.kinds = Set((argument ?? "").split(separator: ",").compactMap { SolaraUI.ImportKind(rawValue: String($0)) })
    case "cancel":
      model.cancelProgress()
    case "close":
      model.close()
    case "traceReset":
      ImportRuns.shared.devTrace = []
    case "profiles":
      model.sourceProfiles = (argument ?? "").split(separator: ",").map(String.init)
    case "spaces":
      model.spaces = (argument ?? "").split(separator: ",").map(String.init)
    case "html":
      ImportService.devChosenFile = argument
      await model.importHTML()
    case "safariExport":
      await model.importSafari(path: argument ?? "")
    case "safariDirect":
      model.safariCookies = argument != "nocookies"
      await model.importSafariDirect()
    #endif
    default: break
    }
    let state: [String: Any] = [
      "step": model.step.rawValue,
      "browsers": model.browsers.map(\.id),
      "source": model.source?.id as Any,
      "target": model.target,
      "targets": model.targets.map(\.id),
      "kinds": model.kinds.map(\.rawValue).sorted(),
      "counts": ["tabs": model.counts.tabs, "cookies": model.counts.cookies, "addresses": model.counts.addresses, "cards": model.counts.cards, "bookmarks": model.counts.bookmarks, "history": model.counts.history, "passwords": model.counts.passwords],
      "failures": model.failures.map { ImportModel.failureLine($0) },
      "notes": model.notes,
      "error": model.error as Any,
    ]
    return withDevFields(state, model)
  }

  static func withDevFields(_ base: [String: Any], _ model: ImportModel?) -> [String: Any] {
    #if DEBUG
    var state = base
    state["vault"] = ImportAdapter.devVaultCount
    state["route"] = ImportRoutingDebug.route as Any? ?? NSNull()
    state["outcome"] = ImportRoutingDebug.snapshot
    state["ackHeld"] = SettingsJS.shared.devImportReplyHeld
    state["trace"] = ImportRuns.shared.devTrace
    state["pendingWrites"] = ImportRuns.shared.pendingWrites
    if let model {
      state["sourceProfiles"] = model.sourceProfiles
      state["profileIds"] = model.source?.profiles.map(\.id) ?? []
      state["profileSpaces"] = Dictionary((model.source?.profiles ?? []).map { ($0.id, $0.spaces.map(\.id)) }, uniquingKeysWith: { a, _ in a })
      state["spaces"] = model.spaces
    }
    return state
    #else
    return base
    #endif
  }
}

@MainActor
final class ImportHostingController: NSHostingController<ImportWindowView> {
  let model: ImportModel
  private weak var observedWindow: NSWindow?

  init(model: ImportModel) {
    self.model = model
    super.init(rootView: ImportWindowView(model: model))
    sizingOptions = []
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard observedWindow == nil, let window = view.window else { return }
    observedWindow = window
    NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
    model.dispose()
  }
}
