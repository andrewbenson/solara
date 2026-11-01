import Foundation
import SolaraModel
import SolaraStore
import Synchronization
import Testing
@testable import SolaraUI

@MainActor
private final class IssuerProducer {
  var commands: [PageCommand] = []
  var created: [Bool] = []
  var clears = 0
  var retries = 0
  var invoke: (@MainActor (PageCommand, @escaping PageRegistry.Completion) -> Void)?

  func perform(_ command: PageCommand, completion: @escaping PageRegistry.Completion) {
    commands.append(command)
    if let invoke { invoke(command, completion) }
    else { completion(.success(.null)) }
  }
}

@MainActor
private struct IssuerFixture {
  let store: Store
  let issuer: PageIssuer
  let producer: IssuerProducer
  let binding: PageHostBinding
  var id: String { binding.tabId }

  init(engine: PageEngine = .chromium, host: PageHost = .pooled, shown: String? = nil) throws {
    store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: false)
    let window = try #require(try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result?.string)
    let id = try #require(store.state.windows[window]?.tabIds.first)
    if engine == .webKit { try store.dispatch(Command("updateTab", [.string(id), ["engine": "webkit"]])) }
    issuer = PageIssuer(store: store, registry: PageRegistry())
    producer = IssuerProducer()
    let producer = producer
    let attached = issuer.attach(tabId: id, engine: engine, host: host, owner: producer,
      context: PageHostContext(navigationSeq: store.state.tabs[id]?.navigation.flatMap { Int(exactly: $0.seq) },
        contextRevision: 1, wasNewTab: false, newTabShownUrl: shown),
      onCreated: { _, recovered in producer.created.append(recovered) },
      onClearNewTabShown: { _, _ in producer.clears += 1 },
      onNeedsFollow: { _ in producer.retries += 1 },
      perform: producer.perform)
    binding = try #require(attached)
  }

  func feed(_ sequence: Int, epoch: Int) -> JSONValue {
    ["type": "keepAlive", "epoch": JSONValue(epoch), "seq": JSONValue(sequence), "handled": 0,
      "keep": ["capturing": false, "newTabShown": false, "pip": false, "displayRequest": false, "media": "none"],
      "reveal": ["fullscreen": false, "crashed": false, "unresponsive": false, "scrolledDown": false, "sharing": false]]
  }
}

@MainActor
@Suite struct PageIssuerTests {
  @Test func inScopeIssueAdmitsNothingBetweenRecheckAndInvoke() throws {
    let fixture = try IssuerFixture()
    let attempting = DispatchSemaphore(value: 0)
    let enqueued = DispatchSemaphore(value: 0)
    let store = fixture.store
    let id = fixture.id
    let generation = fixture.binding.sessionGeneration
    fixture.producer.invoke = { _, finish in
      #expect(attempting.wait(timeout: .now() + 3) == .success)
      #expect(enqueued.wait(timeout: .now() + 0.01) == .timedOut)
      #expect((try? store.pageHostSnapshotInScope(id, generation: generation).facts?.latchedThrough) == 0)
      finish(.success(.null))
    }
    store.sequence {
      DispatchQueue.global().async {
        attempting.signal()
        store.enqueuePageReport(id: id, report: ["type": "latch", "generation": .string(generation), "eventSeq": 9])
        enqueued.signal()
      }
      fixture.issuer.issueInScope(tabId: id, identity: fixture.binding.identity, command: .reload) { _ in }
    }
    #expect(enqueued.wait(timeout: .now() + 3) == .success)
    #expect(store.pageFacts(id)?.latchedThrough == 9)
    #expect(fixture.producer.commands == [.reload])
  }

  @Test func nativeReportPrecedesCallAndAsyncCompletionDoesNotHoldIngress() throws {
    let fixture = try IssuerFixture()
    var pending: PageRegistry.Completion?
    fixture.producer.invoke = { _, finish in
      #expect((try? fixture.store.pageHostSnapshotInScope(fixture.id, generation: fixture.binding.sessionGeneration).state.live[fixture.id]?.playingAudio) == true)
      pending = finish
    }
    fixture.store.enqueuePageReport(id: fixture.id, report: ["type": "media", "generation": .string(fixture.binding.sessionGeneration), "playing": true])
    var completed = false
    fixture.issuer.registry.call(fixture.binding.registration!, command: .evaluate("1")) { _ in completed = true }
    #expect(!completed)
    try fixture.store.dispatch(Command("updateSettings", [["sidebarWidth": 301]]))
    #expect(fixture.store.state.settings["sidebarWidth"] == 301)
    pending?(.success(.string("1")))
    #expect(completed)
  }

  @Test func pendingPageCallsRetireOnceBeforeTheirProducerCompletes() throws {
    for host in [PageHost.pooled, .reactNative] {
      for command in [PageCommand.downloadFavicon("https://slow.example/icon"), .downloadImage("https://slow.example/image", 64)] {
        let fixture = try IssuerFixture(host: host)
        var pending: PageRegistry.Completion?
        fixture.producer.invoke = { _, finish in pending = finish }
        var results: [Result<PageValue, PageRegistryError>] = []
        fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: command) { results.append($0) }
        #expect(fixture.producer.commands == [command])
        #expect(results.isEmpty)
        let finish = try #require(pending)
        fixture.issuer.retire(fixture.binding)
        #expect(results == [.failure(.retired(fixture.binding.registration!))])
        if case .failure(let error)? = results.first { #expect(error.code == "ERR_PAGE_RETIRED") }
        finish(.success(.null))
        #expect(results == [.failure(.retired(fixture.binding.registration!))])
      }
    }
  }

  @Test func pooledReplacementRetiresBothIdentities() throws {
    let fixture = try IssuerFixture()
    let replacement = IssuerProducer()
    let next = try #require(fixture.issuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled, owner: replacement,
      context: fixture.binding.context, perform: replacement.perform))
    #expect(next.sessionGeneration != fixture.binding.sessionGeneration)
    #expect(next.registrationGeneration > fixture.binding.registrationGeneration)
    var error: PageRegistryError?
    fixture.issuer.registry.call(fixture.binding.registration!, command: .reload) { if case .failure(let value) = $0 { error = value } }
    #expect(error == .retired(fixture.binding.registration!))
    #expect(!fixture.issuer.report(fixture.binding, report: ["type": "media", "playing": true]))
    fixture.issuer.retire(fixture.binding)
    #expect(fixture.store.pageFacts(fixture.id)?.generation == next.sessionGeneration)
    #expect(fixture.issuer.registry.descriptor(next.registration!)?.sessionGeneration == next.sessionGeneration)
  }

  @Test func recoveredPageGetsReestablishedEventAndAcceptsNextSeq() throws {
    for engine in [PageEngine.chromium, .webKit] {
      let fixture = try IssuerFixture(engine: engine)
      let epoch = fixture.store.registerKeepAliveRuntime()
      #expect(fixture.issuer.report(fixture.binding, report: ["type": "ready", "browserId": 3]))
      #expect(fixture.issuer.report(fixture.binding, report: fixture.feed(8, epoch: epoch)))
      try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": true]]))
      #expect(!fixture.issuer.report(fixture.binding, report: ["type": "media", "playing": true]))
      try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": false]]))
      #expect(fixture.issuer.ensurePageEstablished(fixture.binding))
      #expect(fixture.producer.created == [false, true])
      #expect(fixture.store.pageFacts(fixture.id)?.generation == fixture.binding.sessionGeneration)
      #expect(fixture.store.pageFacts(fixture.id)?.ready == nil)
      #expect(fixture.store.pageFacts(fixture.id)?.keepAlive == nil)
      #expect(fixture.issuer.report(fixture.binding, report: fixture.feed(8, epoch: epoch)))
      #expect(fixture.store.pageFacts(fixture.id)?.keepAlive == nil)
      #expect(fixture.issuer.report(fixture.binding, report: fixture.feed(9, epoch: epoch)))
      #expect(fixture.store.pageFacts(fixture.id)?.keepAlive?.seq == 9)
      #expect(fixture.producer.commands.isEmpty)
      fixture.issuer.retire(fixture.binding)
      try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": true]]))
      try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": false]]))
      #expect(!fixture.issuer.ensurePageEstablished(fixture.binding))
    }
  }

  @Test func rnIssueFinalizesWithoutLoad() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    fixture.issuer.noteExecuted(fixture.binding, navigationSeq: fixture.binding.context.navigationSeq)
    let preview = try #require(fixture.issuer.preview(fixture.binding))
    #expect(preview.actions == [])
    var accepted: PageValue?
    fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: .finishPageIssue(preview.guardValue)) {
      if case .success(let value) = $0 { accepted = value }
    }
    #expect(accepted == .object(["accepted": .bool(true)]))
    #expect(fixture.producer.commands.isEmpty)
    fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: .finishPageIssue(preview.guardValue)) {
      if case .success(let value) = $0 { accepted = value }
    }
    #expect(accepted == .object(["accepted": .bool(false)]))
    #expect(fixture.producer.commands.isEmpty)
  }

  @Test func changedExecutionMetadataRejectsOldGuard() throws {
    let fixture = try IssuerFixture(host: .reactNative, shown: "https://page.example/")
    let candidate = try #require(fixture.issuer.preview(fixture.binding))
    fixture.issuer.noteExecuted(fixture.binding, navigationSeq: fixture.binding.context.navigationSeq)
    var result: PageValue?
    fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: .finishPageIssue(candidate.guardValue)) {
      if case .success(let value) = $0 { result = value }
    }
    #expect(result == .object(["accepted": .bool(false)]))
    #expect(fixture.producer.commands.isEmpty)
    #expect(fixture.producer.clears == 0)
    #expect(fixture.producer.retries == 1)
  }

  @Test func staleContextCannotPoisonCurrentBinding() throws {
    let fixture = try IssuerFixture()
    let before = fixture.binding.context
    let stale = PageHostContext(navigationSeq: (before.navigationSeq ?? 0) + 1,
      contextRevision: before.contextRevision + 1, wasNewTab: true, newTabShownUrl: "https://stale.example/")
    #expect(!fixture.issuer.updateContext(fixture.binding, context: stale))
    #expect(fixture.binding.context == before)
  }

  @Test func nativeNavigationRefreshDoesNotConsumeTheNextJSContextRevision() throws {
    let fixture = try IssuerFixture()
    let initial = fixture.binding.context
    try fixture.store.dispatch(Command("navigate", [.string(fixture.id), "https://next.example/"]))
    _ = fixture.issuer.preview(fixture.binding)
    #expect(fixture.binding.context.contextRevision == initial.contextRevision)
    let next = PageHostContext(navigationSeq: fixture.store.state.tabs[fixture.id]?.navigation.flatMap { Int(exactly: $0.seq) },
      contextRevision: initial.contextRevision + 1, wasNewTab: false, newTabShownUrl: "https://overlay.example/")
    #expect(fixture.issuer.updateContext(fixture.binding, context: next))
    #expect(fixture.binding.context == next)
  }

  @Test func sameOwnerProfileChangeCreatesFreshPairAndRejectsTransferMetadata() throws {
    let fixture = try IssuerFixture()
    let physicalPage = NSObject()
    fixture.issuer.associateNativePage(fixture.binding, page: physicalPage)
    fixture.issuer.noteExecuted(fixture.binding, navigationSeq: fixture.binding.context.navigationSeq)
    let profile = try #require(try fixture.store.dispatch(Command("createProfile", [["name": "Other"]])).result?.string)
    try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["profileId": .string(profile)]]))
    let next = try #require(fixture.issuer.attach(tabId: fixture.id, engine: .chromium, host: .pooled,
      owner: fixture.producer, context: fixture.binding.context, perform: fixture.producer.perform))
    #expect(next.sessionGeneration != fixture.binding.sessionGeneration)
    #expect(next.registrationGeneration > fixture.binding.registrationGeneration)
    fixture.issuer.transferExecution(from: physicalPage, to: next)
    #expect(next.executedNavigationSeq == nil)
    #expect(fixture.issuer.isCurrent(next))
  }

  @Test func pooledLoadProducesOneLoadingEdgePerLoad() throws {
    let fixture = try IssuerFixture()
    let edges = Mutex<[Bool]>([])
    let observer = fixture.store.observeLive(tabId: fixture.id) { change in
      if change.previous?.isLoading != change.current?.isLoading, let loading = change.current?.isLoading {
        edges.withLock { $0.append(loading) }
      }
    }
    defer { fixture.store.unsubscribe(observer.token) }
    for loading in [true, false, false] {
      let report = try #require(PageNativeReport.report(name: "onNavigationChange", payload: ["url": "https://page.example/",
        "title": "Page", "isLoading": .bool(loading), "canGoBack": false, "canGoForward": false]))
      #expect(fixture.issuer.report(fixture.binding, report: report))
    }
    #expect(edges.withLock { $0 } == [true, false])
  }

  @Test func closingTabRemovesLiveEntryAndNotifiesRemoval() throws {
    let fixture = try IssuerFixture()
    let removed = Mutex(0)
    let observer = fixture.store.observeLive(tabId: fixture.id) { change in
      if change.current == nil { removed.withLock { $0 += 1 } }
    }
    defer { fixture.store.unsubscribe(observer.token) }
    try fixture.store.dispatch(Command("closeTab", [.string(fixture.id)]))
    #expect(fixture.store.state.live[fixture.id] == nil)
    #expect(removed.withLock { $0 } == 1)
    #expect(!fixture.issuer.isCurrent(fixture.binding))
    #expect(fixture.issuer.registry.descriptors.isEmpty)
  }

  @Test func registrySnapshotDrainsAndIncludesNotYetReadyOwnedPair() throws {
    let fixture = try IssuerFixture()
    fixture.store.enqueuePageReport(id: fixture.id, report: ["type": "media", "generation": .string(fixture.binding.sessionGeneration), "playing": true])
    let descriptors = fixture.issuer.registry.descriptors
    #expect(descriptors.count == 1)
    #expect(descriptors.first?.sessionGeneration == fixture.binding.sessionGeneration)
    #expect(fixture.store.state.live[fixture.id]?.playingAudio == true)
    #expect(fixture.store.pageFacts(fixture.id)?.ready == nil)
  }

  @Test func transferPreservesOnlyActuallyExecutedNavigationInBothDirections() throws {
    for engine in [PageEngine.chromium, .webKit] {
      for sourceHost in [PageHost.pooled, .reactNative] {
        let fixture = try IssuerFixture(engine: engine, host: sourceHost)
        let physicalPage = NSObject()
        fixture.issuer.associateNativePage(fixture.binding, page: physicalPage)
        fixture.issuer.noteExecuted(fixture.binding, navigationSeq: fixture.binding.context.navigationSeq)
        let nextProducer = IssuerProducer()
        let next = try #require(fixture.issuer.attach(tabId: fixture.id, engine: engine,
          host: sourceHost == .pooled ? .reactNative : .pooled, owner: nextProducer,
          context: fixture.binding.context, perform: nextProducer.perform))
        fixture.issuer.transferExecution(from: physicalPage, to: next)
        fixture.issuer.associateNativePage(next, page: physicalPage)
        #expect(next.sessionGeneration != fixture.binding.sessionGeneration)
        #expect(next.registrationGeneration > fixture.binding.registrationGeneration)
        #expect(next.executedNavigationSeq == fixture.binding.executedNavigationSeq)
        #expect(fixture.issuer.follow(next))
        #expect(nextProducer.commands.isEmpty)
        #expect(!fixture.issuer.report(fixture.binding, report: ["type": "ready", "browserId": 99]))
        fixture.issuer.retire(fixture.binding)
        #expect(fixture.issuer.isCurrent(next))
      }
    }
  }

  @Test func transferredWebKitNeverTreatsPendingBAsExecutedA() throws {
    for engine in [PageEngine.chromium, .webKit] {
      let fixture = try IssuerFixture(engine: engine, host: .reactNative)
      let physicalPage = NSObject()
      fixture.issuer.associateNativePage(fixture.binding, page: physicalPage)
      fixture.issuer.noteExecuted(fixture.binding, navigationSeq: fixture.binding.context.navigationSeq)
      let executedA = fixture.binding.executedNavigationSeq
      try fixture.store.dispatch(Command("navigate", [.string(fixture.id), "https://pending-b.example/"]))
      let context = PageHostContext(navigationSeq: fixture.store.state.tabs[fixture.id]?.navigation.flatMap { Int(exactly: $0.seq) },
        contextRevision: fixture.binding.context.contextRevision + 1, wasNewTab: false, newTabShownUrl: nil)
      let nextProducer = IssuerProducer()
      let next = try #require(fixture.issuer.attach(tabId: fixture.id, engine: engine, host: .pooled, owner: nextProducer,
        context: context, perform: nextProducer.perform))
      fixture.issuer.transferExecution(from: physicalPage, to: next)
      #expect(next.executedNavigationSeq == executedA)
      #expect(next.executedNavigationSeq != context.navigationSeq)
      #expect(fixture.issuer.follow(next))
      #expect(nextProducer.commands == [.loadUrl("https://pending-b.example/", true)])
      #expect(fixture.issuer.follow(next))
      #expect(nextProducer.commands.count == 1)
    }
  }

  @Test func snapshotClearsOldNavigationButKeepsTriggeringNewFactAfterRecovery() throws {
    let fixture = try IssuerFixture()
    let oldReport = try #require(PageNativeReport.report(name: "onNavigationChange", payload: ["url": "https://old.example/",
      "title": "Old", "isLoading": false, "canGoBack": false, "canGoForward": false]))
    #expect(fixture.issuer.report(fixture.binding, report: oldReport))
    let oldSerial = fixture.binding.establishmentSerial
    try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": true]]))
    try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": false]]))
    #expect(fixture.issuer.ensurePageEstablished(fixture.binding))
    #expect(fixture.binding.establishmentSerial == oldSerial + 1)
    #expect(fixture.issuer.registry.descriptors.first?.navigation == nil)
    let nextReport = try #require(PageNativeReport.report(name: "onNavigationChange", payload: ["url": "https://new.example/",
      "title": "New", "isLoading": false, "canGoBack": false, "canGoForward": false]))
    #expect(fixture.issuer.report(fixture.binding, report: nextReport))
    #expect(fixture.issuer.registry.descriptors.first?.navigation?["url"] == "https://new.example/")
  }

  @Test func finalEngineBoundaryRejectsEarlierCandidates() throws {
    for invalidation in ["navigation", "context", "close"] {
      let fixture = try IssuerFixture(host: .reactNative, shown: "https://page.example/")
      let candidate = try #require(fixture.issuer.preview(fixture.binding))
      switch invalidation {
      case "navigation": try fixture.store.dispatch(Command("navigate", [.string(fixture.id), "https://next.example/"]))
      case "context":
        var context = fixture.binding.context
        context.contextRevision += 1
        context.newTabShownUrl = nil
        #expect(fixture.issuer.updateContext(fixture.binding, context: context))
      default: try fixture.store.dispatch(Command("closeTab", [.string(fixture.id)]))
      }
      var accepted = false
      fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: .finishPageIssue(candidate.guardValue)) {
        if case .success(.object(let fields)) = $0 { accepted = fields["accepted"] == .bool(true) }
      }
      #expect(!accepted)
      #expect(fixture.producer.commands.isEmpty)
      #expect(fixture.producer.clears == 0)
    }
  }

  @Test func retainedPooledMoveToAnotherWindowFollowsWithoutReloadAndTheNextNavigationLoads() throws {
    let fixture = try IssuerFixture()
    #expect(fixture.issuer.follow(fixture.binding))
    let loads = fixture.producer.commands.count
    let other = try #require(try fixture.store.dispatch(Command("createWindow", [])).result?.string)
    let before = fixture.store.state.tabs[fixture.id]?.navigation?.seq
    try fixture.store.dispatch(Command("moveTabsToWindow", [[.string(fixture.id)], .string(other)]))
    #expect(fixture.store.state.tabs[fixture.id]?.windowId == other)
    #expect(fixture.store.state.tabs[fixture.id]?.navigation?.seq != before)
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands.count == loads)
    try fixture.store.dispatch(Command("navigate", [.string(fixture.id), "https://next.example/"]))
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands.count == loads + 1)
    #expect(fixture.producer.commands.last == .loadUrl("https://next.example/", true))
  }

  @Test func anAbandonedMoveIssueDoesNotSuppressASupersedingNavigation() throws {
    let fixture = try IssuerFixture()
    #expect(fixture.issuer.follow(fixture.binding))
    let loads = fixture.producer.commands.count
    let other = try #require(try fixture.store.dispatch(Command("createWindow", [])).result?.string)
    try fixture.store.dispatch(Command("moveTabsToWindow", [[.string(fixture.id)], .string(other)]))
    _ = try #require(fixture.issuer.preview(fixture.binding))
    try fixture.store.dispatch(Command("navigate", [.string(fixture.id), "https://next.example/"]))
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands.count == loads + 1)
    #expect(fixture.producer.commands.last == .loadUrl("https://next.example/", true))
  }

  @Test func sameSequenceContextRetryDoesNotRemainConsumed() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    let candidate = try #require(fixture.issuer.preview(fixture.binding))
    var context = fixture.binding.context
    context.contextRevision += 1
    context.newTabShownUrl = "https://page.example/"
    #expect(fixture.issuer.updateContext(fixture.binding, context: context))
    fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: .finishPageIssue(candidate.guardValue)) { _ in }
    #expect(fixture.producer.commands.isEmpty)
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands == [.loadUrl("https://page.example/", true)])
    #expect(fixture.producer.clears == 1)
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands.count == 1)
    #expect(fixture.producer.clears == 1)
  }

  @Test func sameGenerationResetCannotReusePreparedIssueSerial() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    let candidate = try #require(fixture.issuer.preview(fixture.binding))
    try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": true]]))
    try fixture.store.dispatch(Command("updateTab", [.string(fixture.id), ["unloaded": false]]))
    #expect(fixture.issuer.ensurePageEstablished(fixture.binding))
    let recovered = try #require(fixture.issuer.preview(fixture.binding))
    #expect(recovered.guardValue.sessionGeneration == candidate.guardValue.sessionGeneration)
    #expect(recovered.guardValue.modelSerial > candidate.guardValue.modelSerial)
    var result: PageValue?
    fixture.issuer.issue(tabId: fixture.id, identity: fixture.binding.identity, command: .finishPageIssue(candidate.guardValue)) {
      if case .success(let value) = $0 { result = value }
    }
    #expect(result == .object(["accepted": .bool(false)]))
    #expect(fixture.producer.commands.isEmpty)
  }

  @Test func unknownActualConstructorDoesNotConsumeUnexecutedWebKitNavigation() throws {
    let fixture = try IssuerFixture(engine: .webKit, host: .reactNative)
    #expect(fixture.binding.executedNavigationSeq == nil)
    fixture.issuer.noteExecuted(fixture.binding, navigationSeq: nil)
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands == [.loadUrl("https://page.example/", true)])
  }

  @Test func unknownActualExecutionPreservesAlreadyFollowedModelState() throws {
    let fixture = try IssuerFixture(host: .reactNative)
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands.count == 1)
    fixture.issuer.noteExecuted(fixture.binding, navigationSeq: nil)
    #expect(fixture.issuer.follow(fixture.binding))
    #expect(fixture.producer.commands.count == 1)
    #expect(fixture.binding.executedNavigationSeq == nil)
  }

  @Test func guardedCommandRoundTripsCanonicalArguments() throws {
    let fixture = try IssuerFixture()
    let guardValue = try #require(fixture.issuer.preview(fixture.binding)).guardValue
    let command = PageCommand.finishPageIssue(guardValue)
    #expect(try PageCommand.decode(method: command.method, args: command.arguments) == command)
    #expect(throws: (any Error).self) { try PageIssueGuard(json: ["sessionGeneration": "G", "modelSerial": -1]) }
  }
}
