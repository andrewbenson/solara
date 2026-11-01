import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
private final class NativeCommandPage {
  var commands: [PageCommand] = []

  func perform(_ command: PageCommand, completion: @escaping PageRegistry.Completion) {
    commands.append(command)
    completion(.success(.null))
  }
}

@MainActor
@Suite struct NativePageCommandTests {
  @Test func capturedServiceIdentityCannotIssueAfterQueuedUnload() throws {
    for command in [PageCommand.evaluate("1"), .getSecurityInfo, .focus] {
      let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: false)
      let windowResult = try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result?.string
      let window = try #require(windowResult)
      let tabResult = store.state.windows[window]?.tabIds.first
      let tabId = try #require(tabResult)
      let issuer = PageIssuer(store: store, registry: PageRegistry())
      let page = NativeCommandPage()
      let attached = issuer.attach(tabId: tabId, engine: .chromium, host: .pooled, owner: page,
        context: PageHostContext(navigationSeq: store.state.tabs[tabId]?.navigation.flatMap { Int(exactly: $0.seq) },
          contextRevision: 1, wasNewTab: false, newTabShownUrl: nil), perform: page.perform)
      let binding = try #require(attached)
      let captured = binding.identity
      store.enqueueSequenced(Command("updateTab", [.string(tabId), ["unloaded": true]]))
      var result: Result<PageValue, PageRegistryError>?
      issuer.issue(tabId: tabId, identity: captured, command: command) { result = $0 }
      let rejected = result.map { if case .failure = $0 { true } else { false } }
      let commands = page.commands
      #expect(rejected == true)
      #expect(commands.isEmpty)
    }
  }

  @Test func capturedServiceIdentityCannotUpgradeAfterReplacement() throws {
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: false)
    let windowResult = try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result?.string
    let window = try #require(windowResult)
    let tabResult = store.state.windows[window]?.tabIds.first
    let tabId = try #require(tabResult)
    let issuer = PageIssuer(store: store, registry: PageRegistry())
    let page = NativeCommandPage()
    let replacement = NativeCommandPage()
    let context = PageHostContext(navigationSeq: store.state.tabs[tabId]?.navigation.flatMap { Int(exactly: $0.seq) },
      contextRevision: 1, wasNewTab: false, newTabShownUrl: nil)
    let attached = issuer.attach(tabId: tabId, engine: .chromium, host: .pooled, owner: page,
      context: context, perform: page.perform)
    let binding = try #require(attached)
    let captured = binding.identity
    let replaced = issuer.attach(tabId: tabId, engine: .chromium, host: .pooled, owner: replacement,
      context: context, perform: replacement.perform)
    let current = try #require(replaced)
    var rejected = false
    issuer.issue(tabId: tabId, identity: captured, command: .reload) {
      if case .failure = $0 { rejected = true }
    }
    let before = replacement.commands
    #expect(rejected)
    #expect(before.isEmpty)
    issuer.issue(tabId: tabId, identity: current.identity, command: .reload) { _ in }
    let after = replacement.commands
    #expect(after == [.reload])
  }
}
