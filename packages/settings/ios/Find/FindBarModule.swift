import AppKit
import ExpoModulesCore
import Foundation
import SolaraStore
import SolaraUI

public class FindBarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraFindBar")

    View(NativeFindBarView.self) {
      Events("onFindEvent")

      Prop("state") { (view: NativeFindBarView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeFindBarView: ExpoView {
  let onFindEvent = EventDispatcher()
  let bar = FindBarView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    bar.autoresizingMask = [.width, .height]
    bar.frame = bounds
    bar.onEvent = { [weak self] event in
      switch event {
      case .query(let text): self?.onFindEvent(["kind": "query", "text": text])
      case .step(let backwards): self?.onFindEvent(["kind": "step", "backwards": backwards])
      case .close: self?.onFindEvent(["kind": "close"])
      case .replacement(let text): self?.onFindEvent(["kind": "replacement", "text": text])
      case .replace(let all): self?.onFindEvent(["kind": "replace", "all": all])
      case .focused:
        guard let self else { return }
        if let request = self.bar.state?.focusRequest { NativeWorkspaceCommands.findDidFocus(self, request: request) }
        self.onFindEvent(["kind": "focused"])
      }
    }
    bar.allowsFocus = { request in NativeWorkspaceCommands.findFocusAllowed(request) }
    addSubview(bar)
  }

  func setState(_ next: String) {
    guard next != json, let state = FindBarState.decode(next) else { return }
    json = next
    bar.update(state)
  }
}
