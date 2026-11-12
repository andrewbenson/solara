import SolaraModel
import SolaraShell
import SolaraStore

@MainActor
enum NativeNumberedTabs {
  static func register() {
    NativeMenuCommands.argumentHandlers["selectTab"] = { arg, windowId in
      guard let number = arg.flatMap(Int.init) else { return false }
      return select(number, windowId: windowId)
    }
    NativeMenuCommands.argumentHandlers["selectLastTab"] = { _, windowId in select(9, windowId: windowId) }
    TabNumberHintMonitor.isEligible = { windowId in
      guard NativeStoreHandle.ownsWorkspace, let state = NativeStoreHandle.store?.state,
        let window = state.windows[windowId], window.kind != "small"
      else { return false }
      return state.settings["showTabNumberHints"]?.bool != false
    }
  }

  private static func select(_ number: Int, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store, let windowId,
      let window = store.state.windows[windowId], window.kind != "small"
    else { return false }
    do {
      try store.dispatch(Command("activateNumberedTab", [.string(windowId), .number(Double(number))]), origin: .native)
    } catch {
      return true
    }
    return true
  }
}
