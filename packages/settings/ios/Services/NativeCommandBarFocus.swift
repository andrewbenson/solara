import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class NativeCommandBarFocus {
  #if DEBUG
  static var presentationDelays: [String: TimeInterval] = [:]
  #endif
  private static var nextEditorRequest = 0
  private static var lifecycle: Int?
  private let editorRequest: Int
  private static var requests: [String: NativeCommandBarFocus] = [:]
  private let plan: CommandBarFocusPlan
  private let store: Store
  private let ownership = NativeStoreHandle.ownershipGeneration
  private weak var window: NSWindow?
  private let generation: Int?
  private let receipt: CommandBarFocusReceipt
  private let source: ObjectIdentifier?
  private let delegate: ObjectIdentifier?
  private var restorePageFocus: FocusMoves.PageFocus?
  private var finished = false
  private var presentedDeveloper = false
  private var listener: Int?
  private let page: PageIdentity?
  private weak var issuer: PageIssuer?

  private init(_ plan: CommandBarFocusPlan, store: Store, window: NSWindow, generation: Int?) {
    let issuer = PageIssuer.shared
    self.issuer = issuer
    page = issuer?.store.sequence { issuer?.binding(tabId: plan.tabId)?.identity }
    Self.nextEditorRequest -= 1
    editorRequest = Self.nextEditorRequest
    receipt = CommandBarFocusReceipt(plan: plan, request: Self.nextEditorRequest, ownership: NativeStoreHandle.ownershipGeneration, deadline: ProcessInfo.processInfo.systemUptime + 0.35)
    self.plan = plan
    self.store = store
    self.window = window
    self.generation = generation
    if let view = TabPoolHost.shared.pageView(plan.tabId) { restorePageFocus = FocusMoves.preparePageFocus?(view) }
    source = window.firstResponder.map(ObjectIdentifier.init)
    delegate = (window.firstResponder as? NSTextView)?.delegate.map { ObjectIdentifier($0) }
  }

  static func cancel(windowId: String?) {
    let id = NativeStoreHandle.store?.state.resolveWindowId(windowId)
    if let id, let previous = requests.removeValue(forKey: id) { DispatchQueue.main.async { previous.retire() } }
  }

  static func perform(windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else {
      #if DEBUG
      FocusMoves.trace("commandBar perform: workspace unavailable")
      #endif
      return true
    }
    if lifecycle == nil {
      lifecycle = NativeStoreHandle.subscribeLifecycle {
        for request in Array(requests.values) where request.ownership != NativeStoreHandle.ownershipGeneration { request.retire() }
      }
    }
    guard let plan = CommandBarFocusCommand.plan(windowId: windowId, state: store.state, closing: store.memory.closingWindows) else {
      #if DEBUG
      FocusMoves.trace("commandBar perform: plan nil")
      #endif
      return true
    }
    guard let window = WindowHost.contentView(plan.windowId)?.window, window.isKeyWindow else {
      #if DEBUG
      FocusMoves.trace("commandBar perform: no key window")
      #endif
      return true
    }
    let previous = requests.removeValue(forKey: plan.windowId)
    let generation = WindowHost.beginCommandFocus("focusCommandBar", windowId: plan.windowId)
    previous?.retire()
    NativeWorkspaceCommands.cancelPendingFindFocus(windowId: plan.windowId)
    NativeWorkspaceCommands.cancelNewTabFocus(windowId: plan.windowId, restoring: true)
    let request = NativeCommandBarFocus(plan, store: store, window: window, generation: generation)
    requests[plan.windowId] = request
    request.listener = store.subscribe { [weak request] commit in
      let valid = plan.isCurrent(state: commit.state, closing: [], gateLive: true)
      if !valid {
        Task { @MainActor in
          #if DEBUG
          request?.trace("store changed: plan not current")
          #endif
          request?.retire()
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak request] in
      guard let request, !request.finished else { return }
      #if DEBUG
      request.trace("timeout")
      #endif
      request.finish(restoring: true)
    }
    let present = {
      guard request.current else {
        #if DEBUG
        request.trace("present: request not current")
        #endif
        return request.finish(restoring: true)
      }
      guard request.sourceUnchanged else {
        #if DEBUG
        request.trace("present: source changed")
        #endif
        return request.finish(restoring: true)
      }
      do {
        if [.panel, .sidebar].contains(plan.destination) {
          NativeOmniboxView.prepareCommandFocus(windowId: plan.windowId, tabId: plan.tabId, profileId: plan.profileId, text: plan.text)
        }
        if !plan.commands.isEmpty { try store.dispatch(plan.commands, origin: .native) }
        FrameUpdates.flush()
        request.attempt()
      } catch {
        #if DEBUG
        request.trace("present: dispatch failed")
        #endif
        request.finish(restoring: true)
      }
    }
    #if DEBUG
    if let delay = presentationDelays.removeValue(forKey: plan.windowId) {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: present)
      request.trace("presentation delayed")
      return true
    }
    #endif
    present()
    return true
  }

  private var sourceUnchanged: Bool {
    (window?.firstResponder.map(ObjectIdentifier.init) == source
      && (window?.firstResponder as? NSTextView)?.delegate.map({ ObjectIdentifier($0) }) == delegate)
      || destinationHasFocus
  }

  private var destinationHasFocus: Bool {
    switch plan.destination {
    case .hero:
      return NativeNewTabView.commandHasFocus(windowId: plan.windowId, tabId: plan.tabId, profileId: plan.profileId)
    case .panel, .sidebar, .newTab:
      return NativeOmniboxView.commandHasFocus(windowId: plan.windowId, tabId: plan.tabId, profileId: plan.profileId,
        newTab: plan.destination == .newTab, text: plan.text)
    case .developer: return false
    }
  }

  #if DEBUG
  private func trace(_ event: String) {
    FocusMoves.trace("commandBar \(editorRequest) \(event) gate=\(generation.map(String.init) ?? "nil") finished=\(finished) pageCurrent=\(pageCurrent) ownership=\(ownership == NativeStoreHandle.ownershipGeneration) latest=\(Self.requests[plan.windowId] === self) planCurrent=\(plan.isCurrent(state: store.state, closing: store.memory.closingWindows, gateLive: true)) gateLive=\(generation.map(WindowHost.commandFocusLive) ?? true) beforeDeadline=\(ProcessInfo.processInfo.systemUptime < receipt.deadline) ownsWorkspace=\(NativeStoreHandle.ownsWorkspace) storeMatches=\(NativeStoreHandle.store === store) windowMatches=\(window != nil && window === WindowHost.contentView(plan.windowId)?.window) key=\(window?.isKeyWindow == true)")
  }
  #endif

  private var pageCurrent: Bool {
    guard let page else { return true }
    guard let issuer, PageIssuer.shared === issuer else { return false }
    return issuer.store.sequence {
      guard let binding = issuer.binding(identity: page) else { return false }
      return issuer.isCurrent(binding)
    }
  }

  private var current: Bool {
    NativeStoreHandle.ownsWorkspace && NativeStoreHandle.store === store
      && window != nil && window === WindowHost.contentView(plan.windowId)?.window && window?.isKeyWindow == true
      && pageCurrent
      && !finished && receipt.allows(request: Self.requests[plan.windowId]?.editorRequest ?? 0,
        ownership: NativeStoreHandle.ownershipGeneration, now: ProcessInfo.processInfo.systemUptime,
        gateLive: generation.map(WindowHost.commandFocusCurrent) ?? true, state: store.state, closing: store.memory.closingWindows)
  }

  static func allowsAutomaticFocus(windowId: String, tabId: String) -> Bool {
    guard let request = requests[windowId], request.plan.tabId == tabId, !request.finished else { return true }
    let allowed = request.current && request.sourceUnchanged
    #if DEBUG
    if !allowed { request.trace("automatic focus refused current=\(request.current) sourceUnchanged=\(request.sourceUnchanged)") }
    #endif
    return allowed
  }

  private func attempt() {
    guard !finished else {
      #if DEBUG
      trace("attempt: already finished")
      #endif
      return
    }
    guard current, window != nil else {
      #if DEBUG
      trace("attempt: request not current")
      #endif
      return finish(restoring: true)
    }
    guard sourceUnchanged else {
      #if DEBUG
      trace("attempt: source changed")
      #endif
      return finish(restoring: true)
    }
    var destination: NSView?
    switch plan.destination {
    case .developer:
      if !presentedDeveloper {
        presentedDeveloper = true
        Task { @MainActor [weak self] in
          guard let self else { return }
          guard self.current else {
            #if DEBUG
            self.trace("developer: request not current")
            #endif
            return self.finish(restoring: true)
          }
          _ = await SettingsAdapters.js("toolbar.presentURL", self.plan.tabId, self.editorRequest)
        }
      }
      #if DEBUG
      trace("attempt: awaiting developer")
      #endif
      return
    case .hero:
      destination = NativeNewTabView.commandFocus(windowId: plan.windowId, tabId: plan.tabId, profileId: plan.profileId)
    case .panel, .sidebar, .newTab:
      destination = NativeOmniboxView.commandFocus(windowId: plan.windowId, tabId: plan.tabId, profileId: plan.profileId, newTab: plan.destination == .newTab, text: plan.text)
    }
    if let destination { return claim(destination) }
    #if DEBUG
    trace("attempt: commandFocus returned nil destination=\(plan.destination)")
    #endif
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.attempt() }
  }

  static func developerAllowed(_ token: Int, field: NSView) -> Bool {
    let allowed = requests.values.contains {
      $0.editorRequest == token && $0.plan.destination == .developer && $0.current
        && field.window === $0.window && !field.isHiddenOrHasHiddenAncestor
        && ($0.sourceUnchanged || $0.developerPageHandoff)
    }
    #if DEBUG
    if !allowed { FocusMoves.trace("commandBar developerAllowed: refused token=\(token)") }
    #endif
    return allowed
  }

  private var developerPageHandoff: Bool {
    guard generation != nil, let window else { return false }
    return plan.allowsPageHandoff(from: source, to: window.firstResponder, page: TabPoolHost.shared.pageView(plan.tabId), in: window)
  }

  static func developerDidFocus(_ token: Int, field: NSView) {
    guard let request = requests.values.first(where: { $0.editorRequest == token }), request.current, field.window === request.window,
      let editor = (field as? NSTextField)?.currentEditor(), request.window?.firstResponder === editor else {
      #if DEBUG
      FocusMoves.trace("commandBar developerDidFocus: request not current or field mismatch")
      #endif
      return
    }
    request.claim(field)
  }

  static func didFocus(windowId: String, tabId: String, profileId: String, destination: NSView, hero: Bool) {
    guard let request = requests[windowId], request.plan.tabId == tabId, request.plan.profileId == profileId,
      hero ? request.plan.destination == .hero : [.panel, .sidebar, .newTab].contains(request.plan.destination) else {
      #if DEBUG
      FocusMoves.trace("commandBar didFocus: no matching request")
      #endif
      return
    }
    request.claim(destination)
  }

  private func claim(_ destination: NSView) {
    guard current, destination.window === window, !destination.isHiddenOrHasHiddenAncestor else {
      #if DEBUG
      trace("claim refused current=\(current) windowMatches=\(destination.window === window) hidden=\(destination.isHiddenOrHasHiddenAncestor)")
      #endif
      return finish(restoring: true)
    }
    #if DEBUG
    trace("claim \(type(of: destination))")
    #endif
    if let generation { FocusMoves.claim(generation, destination: destination) }
    finished = true
    retire()
  }

  private func retire() {
    finish(restoring: true)
    if let listener { store.unsubscribe(listener); self.listener = nil }
    if Self.requests[plan.windowId] === self { Self.requests[plan.windowId] = nil }
  }

  private func finish(restoring: Bool) {
    #if DEBUG
    trace("finish(restoring: \(restoring))")
    #endif
    guard !finished else { return }
    let restore = restoring && sourceCanRestore
    finished = true
    if let listener { store.unsubscribe(listener); self.listener = nil }
    if let generation { WindowHost.cancelCommandFocus(generation, restoring: restore) }
    if restore, canRestoreSource, let restorePageFocus { _ = restorePageFocus { self.canRestoreSource } }
  }

  private var canRestoreSource: Bool {
    Self.requests[plan.windowId] === self && sourceCanRestore
  }

  private var sourceCanRestore: Bool {
    guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      ownership == NativeStoreHandle.ownershipGeneration, let window, window.isKeyWindow,
      window === WindowHost.contentView(plan.windowId)?.window,
      window.firstResponder == nil || window.firstResponder === window,
      store.state.activeTabId(plan.windowId) == plan.tabId, store.state.tabs[plan.tabId]?.profileId == plan.profileId,
      !store.memory.closingWindows.contains(plan.windowId), pageCurrent else { return false }
    return true
  }
}
