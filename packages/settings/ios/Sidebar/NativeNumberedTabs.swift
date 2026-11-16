import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeNumberedTabs {
  static func register() {
    NativeWorkspaceCommands.install()
    TabNumberHintMonitor.isEligible = { windowId in
      guard NativeStoreHandle.ownsWorkspace, let state = NativeStoreHandle.store?.state,
        let window = state.windows[windowId], window.kind != "small"
      else { return false }
      return state.settings["showTabNumberHints"]?.bool != false
    }
  }
}
