import AppKit
import SolaraShell
import Foundation
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

  nonisolated static var drivable: Bool { ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" }

  static func drive(_ action: String, _ argument: String?) async -> [String: Any] {
    guard drivable, let model = current else { return withDevFields(["error": "no native import window"], nil) }
    switch action {
    case "select":
      guard let browser = model.browsers.first(where: { $0.id == argument }) else { return ["error": "no browser \(argument ?? "")"] }
      model.choose(browser)
    case "next": await model.next()
    case "unlock": await model.unlock()
    #if DEBUG
    case "kinds":
      model.kinds = Set((argument ?? "").split(separator: ",").compactMap { SolaraUI.ImportKind(rawValue: String($0)) })
    case "cancel":
      model.cancelProgress()
    case "route":
      ImportRuns.shared.forceScript = argument == "js"
    case "profiles":
      model.sourceProfiles = (argument ?? "").split(separator: ",").map(String.init)
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
      "counts": ["cookies": model.counts.cookies, "addresses": model.counts.addresses, "cards": model.counts.cards, "bookmarks": model.counts.bookmarks, "history": model.counts.history, "passwords": model.counts.passwords],
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
    if let model {
      state["sourceProfiles"] = model.sourceProfiles
      state["profileIds"] = model.source?.profiles.map(\.id) ?? []
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
