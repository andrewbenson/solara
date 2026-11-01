import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
private final class ClearDelivery {
  var pending: [@MainActor () -> Void] = []
  var clears: [PageIssueGuard] = []
  var commands: [PageCommand] = []

  func flush() {
    let queued = pending
    pending.removeAll()
    for work in queued { work() }
  }
}

@MainActor
@Suite struct PageIssueClearTests {
  @Test func delayedClearRetainsConsumedContextAndFullNavigation() throws {
    for host in [PageHost.pooled, .reactNative] {
      let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: false)
      let creation = try store.dispatch(Command("createWindow", [["url": "https://page.example/"]]))
      let window = try #require(creation.result?.string)
      let first = store.state.windows[window]?.tabIds.first
      let id = try #require(first)
      let delivery = ClearDelivery()
      let issuer = PageIssuer(store: store, registry: PageRegistry(), deliver: { delivery.pending.append($0) })
      let sequence = store.state.tabs[id]?.navigation.flatMap { Int(exactly: $0.seq) }
      let attached = issuer.attach(tabId: id, engine: .chromium, host: host, owner: delivery,
        context: PageHostContext(navigationSeq: sequence, contextRevision: 7, wasNewTab: true,
          newTabShownUrl: "https://page.example/"),
        onClearNewTabShown: { _, consumed in delivery.clears.append(consumed) },
        perform: { command, finish in delivery.commands.append(command); finish(.success(.null)) })
      let binding = try #require(attached)
      delivery.flush()
      let accepted = issuer.follow(binding)
      #expect(accepted)
      let beforeDelivery = delivery.clears
      #expect(beforeDelivery.isEmpty)
      let updated = issuer.updateContext(binding, context: PageHostContext(navigationSeq: sequence,
        contextRevision: 8, wasNewTab: true, newTabShownUrl: "https://new-overlay.example/"))
      #expect(updated)
      try store.dispatch(Command("navigate", [.string(id), "https://next.example/"]))
      _ = issuer.preview(binding)
      delivery.flush()
      let clears = delivery.clears
      #expect(clears.count == 1)
      let consumed = try #require(clears.first)
      #expect(consumed.contextRevision == 7)
      #expect(consumed.navigation?.seq == sequence)
      #expect(consumed.navigation?.url == "https://page.example/")
      #expect(consumed.navigation?.userInitiated == true)
      let current = binding.context
      #expect(current.contextRevision == 8)
      #expect(current.navigationSeq != sequence)
      #expect(current.newTabShownUrl == "https://new-overlay.example/")
    }
  }
}
