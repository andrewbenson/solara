import Foundation
import SolaraLive
import SolaraModel
import SolaraStore

public enum LiveWorkspace {
  public static func closeFolderTabs(_ folderId: String, in store: Store) throws {
    try store.sequence {
      let ids = store.state.tabs.values
        .filter { $0.liveItem?["folderId"]?.string == folderId }
        .map(\.id)
        .sorted()
      if !ids.isEmpty {
        try store.dispatch(Command("closeTabs", [JSONValue(ids)]))
      }
    }
  }
}

@MainActor
public final class LiveBrowserAuth: LiveAuthPresenter {
  private let store: () -> Store?
  private let focus: (String) -> Void
  private let timeout: Duration

  public init(store: @escaping () -> Store?, focus: @escaping (String) -> Void, timeout: Duration = .seconds(600)) {
    self.store = store
    self.focus = focus
    self.timeout = timeout
  }

  public func authorize(url: String, redirectPrefix: String) async throws -> String {
    try Task.checkCancellation()
    guard let source = store() else {
      throw LiveAuthError("Live Folders are paused because this session saves nothing")
    }
    let state = source.state
    guard let window = (state.ui.focusOrder + state.windowOrder).lazy.compactMap({ state.windows[$0] })
      .first(where: { !$0.incognito && !$0.isSmall }) else {
      throw LiveAuthError("Open a browser window first")
    }
    guard let tabId = try source.dispatch(Command("newTab", [
      .string(window.id), ["url": .string(url), "profileId": .string(window.profileId)],
    ])).result?.string, !tabId.isEmpty else {
      throw LiveAuthError("Couldn't open the Google sign-in tab")
    }

    let (events, reply) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let observe: @Sendable (BrowserState) -> Void = { snapshot in
      guard snapshot.windows[window.id]?.incognito == false,
            let tab = snapshot.tabs[tabId], tab.windowId == window.id, tab.profileId == window.profileId else {
        reply.finish(throwing: LiveAuthError("Sign-in was cancelled"))
        return
      }
      if GoogleAuth.matchesRedirect(tab.url, redirect: redirectPrefix) {
        reply.yield(tab.url)
        reply.finish()
      }
    }
    let listener = source.subscribe { observe($0.state) }
    let lifecycle = NativeStoreHandle.subscribeLifecycle { [store] in
      if store() !== source { reply.finish(throwing: LiveAuthError("Sign-in was cancelled")) }
    }
    defer {
      reply.finish()
      source.unsubscribe(listener)
      NativeStoreHandle.unsubscribeLifecycle(lifecycle)
      if store() === source, source.state.tabs[tabId] != nil {
        _ = try? source.dispatch(Command("closeTabs", [JSONValue([tabId])]))
      }
    }

    observe(source.state)
    focus(window.id)
    let timeout = self.timeout
    let redirect = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        for try await redirect in events { return redirect }
        throw LiveAuthError("Sign-in was cancelled")
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw LiveAuthError("Live authorization timed out")
      }
      defer { group.cancelAll() }
      guard let redirect = try await group.next() else { throw LiveAuthError("Sign-in was cancelled") }
      return redirect
    }
    try Task.checkCancellation()
    guard store() === source, source.state.windows[window.id]?.incognito == false,
          let tab = source.state.tabs[tabId], tab.windowId == window.id,
          tab.profileId == window.profileId, tab.url == redirect else {
      throw LiveAuthError("Sign-in was cancelled")
    }
    return redirect
  }
}
