import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeBrowserServiceCommands {
  private static var requests: [String: UUID] = [:]
  #if DEBUG
  private static var capturing = false
  private static var completion: (([String]) -> Void)?
  private static var effects: [String] = []
  private static var suggestionsShown = false
  static func probe(_ action: String, urls: [String]) -> [String] {
    if action == "begin" { capturing = true; effects = []; requests = [:]; completion = nil; suggestionsShown = false }
    if action == "shown" { suggestionsShown = true }
    if action == "refused" { suggestionsShown = false }
    if action == "complete" { let finish = completion; completion = nil; finish?(urls) }
    if action == "end" { capturing = false; completion = nil; requests = [:] }
    return effects
  }
  #endif

  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let plan = BrowserServiceCommand.plan(command, arg: arg, windowId: windowId, state: store.state, closing: store.memory.closingWindows) else { return true }
    let ownership = NativeStoreHandle.ownershipGeneration
    let key = plan.route.windowId ?? ""
    requests = requests.filter { $0.key.isEmpty || store.state.windows[$0.key] != nil }
    let request = UUID()
    requests[key] = request
    let issuer = PageIssuer.shared
    let identity: PageIdentity? = issuer?.store.sequence {
      guard let tabId = plan.tabId, let binding = issuer?.binding(tabId: tabId), issuer?.ensurePageEstablished(binding) == true,
        issuer?.isCurrent(binding) == true else { return nil }
      return binding.identity
    }
    let receipt = BrowserServiceReceipt(plan: plan, ownership: ownership, identity: identity)
    func current() -> Bool {
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, requests[key] == request else { return false }
      func accepts(_ live: PageIdentity?) -> Bool {
        receipt.accepts(ownership: NativeStoreHandle.ownershipGeneration, identity: live, state: store.state, closing: store.memory.closingWindows)
      }
      guard let issuer else { return PageIssuer.shared == nil && accepts(nil) }
      guard PageIssuer.shared === issuer else { return false }
      return issuer.store.sequence {
        guard let tabId = plan.tabId else { return accepts(nil) }
        let binding = issuer.binding(tabId: tabId)
        if let binding { return issuer.isCurrent(binding) && accepts(binding.identity) }
        return accepts(nil)
      }
    }
    func materialize(_ body: () throws -> Void) {
      let before = store.state
      do { try body() } catch { NSLog("[commands] %@ failed: %@", command, String(describing: error)) }
      NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
      FrameUpdates.flush()
    }
    if command == "openFile" {
      if plan.route.kind == .littleSolara || plan.route.kind == .peekPromote {
        materialize {
          if let target = try BrowserServiceCommand.promote(plan, store: store) { ShellScripting.showWindow(target) }
        }
        return true
      }
      let finish: ([String]) -> Void = { urls in
        guard current() else { return }
        materialize { try BrowserServiceCommand.open(urls, plan: plan, store: store) }
      }
      #if DEBUG
      if capturing { effects.append("picker"); completion = finish; return true }
      #endif
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = true
      panel.canChooseDirectories = false
      panel.begin { response in finish(response == .OK ? panel.urls.map(\.absoluteString) : []) }
      return true
    }
    var shown = false
    if let issuer, let identity {
      shown = issuer.store.sequence {
        guard current(), let binding = issuer.binding(tabId: identity.tabId), binding.engine == .chromium,
          let browser = store.pageFacts(identity.tabId)?.ready?.browserId, let browserId = Int32(exactly: browser) else { return false }
        #if DEBUG
        if capturing { effects.append(plan.passwords ? "passwords" : "field"); return suggestionsShown }
        #endif
        return SolaraCoreHost.showAutofillSuggestions(browserId: browserId, passwords: plan.passwords)
      }
    }
    guard current(), let pane = BrowserServiceCommand.settingsPane(plan, shown: shown), NativeSettingsWindow.enabled else { return true }
    #if DEBUG
    if capturing { effects.append("settings:\(pane):\(plan.settingsProfile)"); return true }
    #endif
    NativeSettingsWindow.navigate(pane: pane, profileId: plan.settingsProfile, detail: nil)
    WindowHost.openAuxiliary(id: NativeSettingsWindow.windowId, kind: "settings", title: "Settings")
    return true
  }
}
