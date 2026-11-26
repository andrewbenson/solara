import AppKit
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeOmniboxExtensionActions {
  private static var requests: [String: UUID] = [:]
  private struct Details: Sendable {
    let enabled: Bool
    let incognito: Bool
    let incognitoSplit: Bool
  }

  static func open(_ suggestion: SolaraOmnibox.Suggestion, model: HeroBarModel, view: NSView?) {
    guard case .extension(let id, _, _, let mode) = suggestion,
      NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let window = store.state.windows[model.windowId], current(model, store: store) else { return }
    if mode != .options {
      NativeExtensionActionPopup.activate(windowId: model.windowId, extensionId: id, tabId: model.tabId, anchor: anchor(view, windowId: model.windowId), nativeSidePanel: true)
      return
    }
    let generation = NativeStoreHandle.ownershipGeneration
    let profile = OmniboxCommandSources.extensionProfile(state: store.state, windowId: model.windowId)
    let sequence = store.state.tabs[model.tabId]?.navigation?.seq
    let sourceURL = store.state.tabs[model.tabId]?.url
    let request = UUID()
    requests[model.windowId] = request
    Task { @MainActor in
      defer { if requests[model.windowId] == request { requests.removeValue(forKey: model.windowId) } }
      do {
        let list = try await ExtensionsAdapter().listExtensions(profile: profile)
        guard valid(model, store: store, generation: generation, sequence: sequence, url: sourceURL, request: request),
          let ext = list.first(where: { $0.id == id && $0.enabled }), !window.incognito || ext.incognito else { return }
        let details = await details(id: id, profile: profile)
        guard valid(model, store: store, generation: generation, sequence: sequence, url: sourceURL, request: request),
          details.enabled, !window.incognito || (details.incognito && details.incognitoSplit) else { return }
        if mode == .options {
          guard let url = ext.optionsUrl, extensionURL(url, id: id) else { return }
          _ = try store.dispatch(Command("newTab", [.string(model.windowId), ["url": .string(url), "profileId": .string(model.profileId)]]), origin: .native)
          return
        }
      } catch {
        NSLog("[omnibox] opening extension failed: %@", String(describing: error))
      }
    }
  }

  private static func details(id: String, profile: String) async -> Details {
    await EngineCalls.result({ done in SolaraCoreServices.listExtensions(profile: profile) { done($0) } }) { result in
      let row = (result["extensions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
      return Details(enabled: row?["enabled"] as? Bool == true, incognito: row?["incognito"] as? Bool == true,
        incognitoSplit: row?["incognitoSplit"] as? Bool == true)
    }
  }

  private static func valid(_ model: HeroBarModel, store: Store, generation: Int, sequence: Double?, url: String?, request: UUID) -> Bool {
    NativeStoreHandle.ownershipGeneration == generation && current(model, store: store)
      && requests[model.windowId] == request
      && store.state.tabs[model.tabId]?.navigation?.seq == sequence && store.state.tabs[model.tabId]?.url == url
  }

  private static func current(_ model: HeroBarModel, store: Store) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      let window = store.state.windows[model.windowId], let tab = store.state.tabs[model.tabId] else { return false }
    return window.profileId == model.profileId && tab.profileId == model.profileId && tab.windowId == model.windowId
      && store.state.activeTabId(model.windowId) == model.tabId
  }

  private static func extensionURL(_ text: String, id: String) -> Bool {
    guard let url = URLComponents(string: text) else { return false }
    return url.scheme == "chrome-extension" && url.host == id
  }

  static func page(in view: NSView?) -> SolaraCoreWebView? {
    guard let view else { return nil }
    if let web = view as? SolaraCoreWebView { return web }
    for child in view.subviews { if let found = page(in: child) { return found } }
    return nil
  }

  private static func anchor(_ view: NSView?, windowId: String) -> CGRect {
    guard let window = ShellDrag.window(windowId), let root = window.contentView else { return .zero }
    guard let view, view.window === window else { return CGRect(x: max(0, root.bounds.width - 48), y: 48, width: 30, height: 30) }
    let rect = view.convert(CGRect(x: max(0, view.bounds.maxX - 30), y: view.bounds.minY, width: 30, height: 30), to: root)
    return root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
  }
}
