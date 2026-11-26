import Foundation
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraStore

@MainActor
enum NativeExtensionSearchEngines {
  private static var lifecycle: Int?
  private static var observer: NSObjectProtocol?
  private static var observed: Store?
  private static var refresh = ExtensionSearchRefresh()
  private static var pending: Set<String> = []
  private static var debounce: [String: DispatchWorkItem] = [:]
  private static var reread: [String: DispatchWorkItem] = [:]

  static func start() {
    guard lifecycle == nil else { return }
    observer = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraExtensionListRead"), object: nil, queue: .main) { note in
      guard let profile = note.userInfo?["profile"] as? String else { return }
      MainActor.assumeIsolated { changed(profile) }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { reconcile() }
  }

  private static func reconcile() {
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if observed !== store {
      for item in debounce.values { item.cancel() }
      for item in reread.values { item.cancel() }
      debounce.removeAll()
      reread.removeAll()
      refresh.invalidate()
      observed = store
    }
    guard store != nil else { return }
    let profiles = pending
    pending.removeAll()
    for profile in profiles { changed(profile) }
  }

  private static func changed(_ profile: String) {
    guard let store = observed, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store else {
      pending.insert(profile)
      return
    }
    let delays = refresh.listChanged(profile: profile)
    debounce[profile]?.cancel()
    let item = DispatchWorkItem { MainActor.assumeIsolated { read(profile) } }
    debounce[profile] = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delays[0], execute: item)
    if delays.count > 1 {
      let first = DispatchWorkItem { MainActor.assumeIsolated { read(profile) } }
      reread[profile] = first
      DispatchQueue.main.asyncAfter(deadline: .now() + delays[1], execute: first)
    }
  }

  private static func read(_ profile: String) {
    guard let store = observed, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store else { return }
    let request = refresh.begin(profile: profile)
    let ownership = NativeStoreHandle.ownershipGeneration
    Task { @MainActor in
      let list: JSONValue? = await EngineCalls.result({ done in
        SolaraCoreServices.searchEngineList(profile: profile) { done($0) }
      }) { result in
        guard result["error"] == nil, let raw = result["list"],
          let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONValue.parse(data)
      }
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
        NativeStoreHandle.ownershipGeneration == ownership, refresh.current(request, profile: profile),
        let next = ExtensionSearchRefresh.merge(profile: profile, list: list, current: store.state.settings["extensionSearchEngines"]) else { return }
      do {
        try store.dispatch(Command("updateSettings", [["extensionSearchEngines": next]]), origin: .native)
      } catch {
        NSLog("[extensions] search engines update failed: %@", String(describing: error))
      }
    }
  }
}
