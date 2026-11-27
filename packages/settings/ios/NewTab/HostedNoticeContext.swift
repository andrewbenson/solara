import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class HostedNoticeContext {
  private let windowId: String
  private let explicitPage: Bool
  private var store: Store?
  private var subscription: Int?
  private var lifecycle: Int?
  private var identity: NewTabIdentity?
  private var sourceReceipt: UUID?
  private var presentationId = UUID().uuidString
  private var tabId: String?
  private var onboarding = false
  var onChange: () -> Void = {}

  init(windowId: String, explicitPage: Bool = false) {
    self.windowId = windowId
    self.explicitPage = explicitPage
  }

  private var workspace: Store? {
    guard NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen else { return nil }
    return NativeStoreHandle.store
  }

  func observe() {
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.bind() }
  }

  private func bind() {
    let next = workspace
    if store !== next {
      if let subscription { store?.unsubscribe(subscription) }
      identity = nil
      store = next
      subscription = next?.subscribe { [weak self, windowId] commit in
        let changes = commit.changes
        guard changes.windows.upserted.contains(windowId) || changes.windows.removed.contains(windowId)
          || changes.lists.contains("ui") || !changes.tabs.isEmpty || !changes.profiles.isEmpty else { return }
        DispatchQueue.main.async { self?.onChange() }
      }
    }
    onChange()
  }

  func project(_ payload: JSONObject, receipt: UUID, receiptKey: String, postcard: Bool = false) -> String? {
    tabId = payload["tabId"]?.string
    onboarding = payload["onboarding"]?.bool == true
    guard let store, store === workspace, let tabId, !onboarding,
      !NativeOnboarding.isActive(in: windowId) else { identity = nil; return nil }
    let state = store.state
    guard let context = NewTabNoticeContext.resolve(state, windowId: windowId, tabId: tabId,
      explicitPage: explicitPage, closing: store.memory.closingWindows) else { identity = nil; return nil }
    if identity != context.identity || sourceReceipt != receipt {
      presentationId = UUID().uuidString
      identity = context.identity
      sourceReceipt = receipt
    }
    var result = payload
    result["profileId"] = .string(context.identity.profileId)
    result["focusContext"] = .string(context.focusContext)
    result[receiptKey] = .string(presentationId)
    if postcard {
      let profile = state.profiles[context.identity.profileId]
      result["colors"] = .array(ThemeScopeProjection.postcardColors(profile).map(JSONValue.string))
    }
    return JSONValue.object(result).text()
  }

  var canRestoreFocus: Bool {
    guard let store, store === workspace else { return false }
    return store.state.ui.focusedWindowId.map { $0 == windowId } ?? true
  }

  func current(_ receipt: String) -> NewTabNoticeContext? {
    guard let store, store === workspace, let tabId, receipt == presentationId, !onboarding,
      !NativeOnboarding.isActive(in: windowId),
      let current = NewTabNoticeContext.resolve(store.state, windowId: windowId, tabId: tabId,
        explicitPage: explicitPage, closing: store.memory.closingWindows), current.identity == identity else { return nil }
    return current
  }

  func stop() {
    if let subscription { store?.unsubscribe(subscription) }
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    store = nil
    subscription = nil
    lifecycle = nil
    identity = nil
    onChange = {}
  }
}
