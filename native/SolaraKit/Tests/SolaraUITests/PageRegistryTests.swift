import Foundation
import Testing

@testable import SolaraUI

@MainActor
private final class DeferredPageDelivery {
  var callbacks: [@MainActor () -> Void] = []

  func hold(_ callback: @escaping @MainActor () -> Void) { callbacks.append(callback) }

  func flush() {
    while !callbacks.isEmpty { callbacks.removeFirst()() }
  }
}

@MainActor
private final class PageCallbackLifetime {
  var calls = 0
}

@MainActor
private final class ControlledPageTimeouts {
  struct Deadline {
    let duration: Duration
    let fire: @MainActor () -> Void
    var cancelled = false
  }

  var deadlines: [Deadline] = []

  func schedule(_ duration: Duration, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let index = deadlines.count
    deadlines.append(Deadline(duration: duration, fire: fire))
    return { [weak self] in self?.deadlines[index].cancelled = true }
  }
}

@MainActor
@Suite struct PageRegistryTests {
  @Test func registeredPageReceivesCommands() {
    let registry = PageRegistry()
    var commands: [PageCommand] = []
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { command, finish in
      commands.append(command)
      finish(.success(.null))
    }
    var results: [Result<PageValue, PageRegistryError>] = []
    registry.call(tabID: "tab", registrationGeneration: token.registrationGeneration, command: .reload) { results.append($0) }
    #expect(commands == [.reload])
    #expect(results == [.success(.null)])
    #expect(registry.descriptor(token)?.registration == token)
    registry.retire(token)
  }

  @Test func retiredRegistrationRejectsLaterCalls() {
    let registry = PageRegistry()
    var commands: [PageCommand] = []
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { command, finish in
      commands.append(command)
      finish(.success(.null))
    }
    registry.retire(token)
    var result: Result<PageValue, PageRegistryError>?
    registry.call(token, command: .reload) { result = $0 }
    #expect(result == .failure(.retired(token)))
    #expect(commands.isEmpty)
    #expect(registry.descriptor(token) == nil)
  }

  @Test func replacementRetiresOldCallsAndSurvivesLateRetirement() {
    let registry = PageRegistry()
    var replies: [PageRegistry.Completion] = []
    let old = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in replies.append(finish) }
    var results: [Result<PageValue, PageRegistryError>] = []
    registry.call(old, command: .reload) { results.append($0) }
    registry.call(old, command: .focus) { results.append($0) }
    let current = registry.register(tabID: "tab", engine: .webKit, host: .reactNative, nativeTag: 42) { _, finish in finish(.success(.null)) }
    #expect(results == [.failure(.retired(old)), .failure(.retired(old))])
    registry.retire(old)
    replies.forEach { $0(.success(.null)) }
    registry.call(old, command: .reload) { results.append($0) }
    #expect(results == [.failure(.retired(old)), .failure(.retired(old)), .failure(.retired(old))])
    #expect(registry.descriptor(current)?.nativeTag == 42)
    var currentResult: Result<PageValue, PageRegistryError>?
    registry.call(current, command: .reload) { currentResult = $0 }
    #expect(currentResult == .success(.null))
    registry.retire(current)
  }

  @Test func registrationGenerationsIncreaseAcrossRegistryInstances() {
    let first = PageRegistry()
    let second = PageRegistry()
    let a = first.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    let b = second.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    first.retire(a)
    let c = first.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    #expect(a.registrationGeneration > 0)
    #expect(a.registrationGeneration < b.registrationGeneration)
    #expect(b.registrationGeneration < c.registrationGeneration)
    #expect(c.registrationGeneration <= 9_007_199_254_740_991)
    #expect(a == PageRegistration(tabID: "tab", registrationGeneration: a.registrationGeneration))
    #expect(a != PageRegistration(tabID: "other", registrationGeneration: a.registrationGeneration))
    #expect(a != b)
    #expect(second.descriptor(a) == nil)
    first.retire(c)
    second.retire(b)
  }

  @Test func configuredDefaultInstanceHoldsEventsAndEveryCompletionInOrder() {
    let delivery = DeferredPageDelivery()
    let registry = PageRegistry()
    #expect(registry.configureDelivery { delivery.hold($0) })
    var order: [String] = []
    var results: [Result<PageValue, PageRegistryError>] = []
    registry.observe { event in
      switch event {
      case .registered: order.append("registered")
      case .retired: order.append("retired")
      }
    }
    func record(_ name: String, _ result: Result<PageValue, PageRegistryError>) {
      order.append(name)
      results.append(result)
    }
    registry.call(tabID: "missing", command: .reload) { record("missing", $0) }
    let token = registry.register(tabID: "tab", engine: .webKit, host: .pooled, nativeTag: 42) { command, finish in
      if command == .reload { finish(.success(.null)) }
    }
    registry.call(token, command: .nativeTag) { record("tag", $0) }
    registry.call(token, command: .reload) { record("reply", $0) }
    registry.call(token, command: .setFrozen(true)) { record("unsupported", $0) }
    registry.call(tabID: "tab", registrationGeneration: token.registrationGeneration, method: "reload", args: [.null]) { record("arguments", $0) }
    registry.call(tabID: "tab", method: "typo", args: []) { record("method", $0) }
    registry.call(token, command: .takeControlPress(0, 0)) { record("press", $0) }
    let cancelled = registry.call(token, command: .focus) { record("cancelled", $0) }
    registry.cancel(cancelled)
    registry.call(token, command: .focus) { record("abandoned", $0) }
    registry.retire(token)
    registry.call(token, command: .reload) { record("stale", $0) }
    let replacement = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    registry.call(replacement, command: .focus) { record("replaced", $0) }
    let current = registry.register(tabID: "tab", engine: .chromium, host: .reactNative) { _, _ in }
    #expect(order.isEmpty)
    #expect(results.isEmpty)
    #expect(delivery.callbacks.count == 1)
    #expect(registry.descriptors.map(\.registration) == [current])
    delivery.flush()
    #expect(order == ["missing", "registered", "tag", "reply", "unsupported", "arguments", "method", "press", "cancelled", "retired", "abandoned", "stale", "registered", "retired", "registered", "replaced"])
    #expect(results == [
      .failure(.noPage("missing")), .success(.number(42)), .success(.null),
      .failure(.unsupported(.webKit, "setFrozen")), .failure(.invalidArguments("reload", 0)),
      .failure(.unknownCommand("typo")), .success(.bool(true)), .failure(.cancelled(token)),
      .failure(.retired(token)), .failure(.retired(token)), .failure(.retired(replacement))
    ])
    registry.retire(current)
    delivery.flush()
  }

  @Test func deliveryConfigurationRefusesQueuedWorkAndPostRegistrationChanges() {
    let delivery = DeferredPageDelivery()
    let registry = PageRegistry()
    #expect(registry.configureDelivery { delivery.hold($0) })
    var completed = false
    var replacedHook = false
    registry.call(tabID: "missing", command: .reload) { result in
      #expect(result == .failure(.noPage("missing")))
      completed = true
      #expect(!registry.configureDelivery { _ in replacedHook = true })
    }
    #expect(!registry.configureDelivery { _ in replacedHook = true })
    #expect(!completed)
    delivery.flush()
    #expect(completed)
    #expect(registry.configureDelivery { delivery.hold($0) })
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    delivery.flush()
    #expect(!registry.configureDelivery { _ in replacedHook = true })
    registry.retire(token)
    delivery.flush()
    #expect(!registry.configureDelivery { _ in replacedHook = true })
    #expect(!replacedHook)
  }

  @Test func unflushedDeliveryReleasesRegistryAndQueuedCallbacks() {
    let delivery = DeferredPageDelivery()
    weak var weakRegistry: PageRegistry?
    weak var weakEvent: PageCallbackLifetime?
    weak var weakCompletion: PageCallbackLifetime?
    var holder: PageRegistry?
    do {
      let registry = PageRegistry()
      #expect(registry.configureDelivery { delivery.hold($0) })
      holder = registry
      weakRegistry = registry
      let event = PageCallbackLifetime()
      let completion = PageCallbackLifetime()
      weakEvent = event
      weakCompletion = completion
      registry.observe { [event] _ in event.calls += 1 }
      registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
      registry.call(tabID: "missing", command: .reload) { [completion] _ in completion.calls += 1 }
    }
    #expect(holder != nil)
    #expect(weakEvent != nil)
    #expect(weakCompletion != nil)
    #expect(delivery.callbacks.count == 1)
    holder = nil
    #expect(weakRegistry == nil)
    #expect(weakEvent == nil)
    #expect(weakCompletion == nil)
    delivery.flush()
    #expect(delivery.callbacks.isEmpty)
  }

  @Test func deliveryThunkIgnoresReplayDuringAndAfterDelivery() throws {
    let delivery = DeferredPageDelivery()
    let registry = PageRegistry(deliver: { delivery.hold($0) })
    var replay: (@MainActor () -> Void)?
    var order: [String] = []
    registry.call(tabID: "first", command: .reload) { _ in
      order.append("first")
      replay?()
      registry.call(tabID: "third", command: .reload) { _ in order.append("third") }
    }
    registry.call(tabID: "second", command: .reload) { _ in order.append("second") }
    let first = try #require(delivery.callbacks.first)
    delivery.callbacks.removeFirst()
    replay = first
    first()
    #expect(order == ["first"])
    #expect(delivery.callbacks.count == 1)
    first()
    #expect(order == ["first"])
    #expect(delivery.callbacks.count == 1)
    let second = try #require(delivery.callbacks.first)
    delivery.callbacks.removeFirst()
    second()
    first()
    #expect(order == ["first", "second"])
    #expect(delivery.callbacks.count == 1)
    delivery.flush()
    second()
    #expect(order == ["first", "second", "third"])
    #expect(delivery.callbacks.isEmpty)
  }

  @Test func replacementQueuesItsWholeBatchBeforeObserverReentry() {
    let registry = PageRegistry()
    var replies: [PageRegistry.Completion] = []
    let old = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in replies.append(finish) }
    var order: [String] = []
    registry.call(old, command: .reload) { result in
      #expect(result == .failure(.retired(old)))
      order.append("first call")
    }
    registry.call(old, command: .focus) { result in
      #expect(result == .failure(.retired(old)))
      order.append("second call")
    }
    var replacement: PageRegistration?
    var nested: PageRegistration?
    let observer = registry.observe { event in
      switch event {
      case .retired(let registration) where registration == old:
        replacement = registry.descriptors.first?.registration
        #expect(registry.descriptor(old) == nil)
        #expect(registry.descriptors.first?.engine == .webKit)
        order.append("retired old")
        registry.call(old, command: .reload) { result in
          #expect(result == .failure(.retired(old)))
          order.append("reentrant call")
        }
        nested = registry.register(tabID: "tab", engine: .chromium, host: .reactNative) { _, finish in finish(.success(.null)) }
        #expect(registry.descriptors.first?.registration == nested)
      case .registered(let descriptor) where descriptor.engine == .webKit:
        order.append("registered replacement")
      case .retired:
        order.append("retired replacement")
      case .registered:
        order.append("registered nested")
      }
    }
    let current = registry.register(tabID: "tab", engine: .webKit, host: .pooled) { _, _ in }
    #expect(replacement == current)
    #expect(order == ["retired old", "registered replacement", "first call", "second call", "reentrant call", "retired replacement", "registered nested"])
    #expect(registry.descriptors.first?.registration == nested)
    registry.retire(current)
    #expect(registry.descriptors.first?.registration == nested)
    replies.forEach { $0(.success(.null)) }
    #expect(order.count == 7)
    registry.removeObserver(observer)
    if let nested { registry.retire(nested) }
  }

  @Test func observerRetirementSeesRegisteredStateBeforeDelivery() {
    let registry = PageRegistry()
    var events: [PageRegistryEvent] = []
    let observer = registry.observe { event in
      events.append(event)
      switch event {
      case .registered(let descriptor):
        #expect(registry.descriptor(descriptor.registration) == descriptor)
        registry.retire(descriptor.registration)
        #expect(registry.descriptor(descriptor.registration) == nil)
        #expect(registry.descriptors.isEmpty)
      case .retired(let registration):
        #expect(registry.descriptor(registration) == nil)
      }
    }
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    #expect(events.count == 2)
    #expect(events.last == .retired(token))
    #expect(registry.descriptors.isEmpty)
    registry.removeObserver(observer)
  }

  @Test func deferredEventsKeepTheirOriginalObservers() {
    let delivery = DeferredPageDelivery()
    let registry = PageRegistry(deliver: { delivery.hold($0) })
    var first: [PageRegistryEvent] = []
    var second: [PageRegistryEvent] = []
    let observer = registry.observe { first.append($0) }
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    registry.removeObserver(observer)
    registry.observe { second.append($0) }
    registry.retire(token)
    delivery.flush()
    #expect(first.count == 1)
    #expect(second == [.retired(token)])
  }

  @Test func immediateDeliveryDoesNotRecurseThroughObserverChanges() {
    let registry = PageRegistry()
    var count = 0
    let observer = registry.observe { event in
      if case .registered = event {
        count += 1
        if count < 2_000 {
          registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
        }
      }
    }
    registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in }
    #expect(count == 2_000)
    registry.removeObserver(observer)
    if let current = registry.descriptors.first?.registration { registry.retire(current) }
  }

  @Test func unsupportedCommandNeverReachesEngine() {
    let registry = PageRegistry()
    var reachedEngine = false
    let token = registry.register(tabID: "tab", engine: .webKit, host: .pooled) { _, _ in reachedEngine = true }
    var result: Result<PageValue, PageRegistryError>?
    registry.call(token, command: .setFrozen(true)) { result = $0 }
    #expect(result == .failure(.unsupported(.webKit, "setFrozen")))
    #expect(!reachedEngine)
    registry.retire(token)
  }

  @Test func webKitAcceptsKeyboardAccessibilityAndMouseControlPresses() {
    let registry = PageRegistry()
    var commands: [PageCommand] = []
    let token = registry.register(tabID: "tab", engine: .webKit, host: .pooled) { command, finish in
      commands.append(command)
      finish(.success(.null))
    }
    let presses: [PageCommand] = [.takeControlPress(0, 0), .takeControlPress(0, 1), .takeControlPress(123, 1)]
    for press in presses {
      #expect(press.supports(engine: .webKit))
      var result: Result<PageValue, PageRegistryError>?
      registry.call(token, command: press) { result = $0 }
      #expect(result == .success(.bool(true)))
      if result == .success(.bool(true)) { registry.call(token, command: .exitPictureInPicture) { _ in } }
    }
    #expect(commands == [.exitPictureInPicture, .exitPictureInPicture, .exitPictureInPicture])
    registry.retire(token)
  }

  @Test func timeoutWaitsForDeliveryAndCompletesOnce() throws {
    let delivery = DeferredPageDelivery()
    let timeouts = ControlledPageTimeouts()
    let registry = PageRegistry(timeout: .seconds(9), deliver: { delivery.hold($0) }, scheduleTimeout: { timeouts.schedule($0, $1) })
    var reply: PageRegistry.Completion?
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in reply = finish }
    delivery.flush()
    var results: [Result<PageValue, PageRegistryError>] = []
    let callID = registry.call(token, command: .reload) { results.append($0) }
    let deadline = try #require(timeouts.deadlines.first)
    #expect(deadline.duration == .seconds(9))
    #expect(!deadline.cancelled)
    deadline.fire()
    #expect(timeouts.deadlines[0].cancelled)
    #expect(results.isEmpty)
    deadline.fire()
    reply?(.success(.null))
    reply?(.success(.null))
    registry.cancel(callID)
    registry.retire(token)
    delivery.flush()
    #expect(results == [.failure(.timedOut(token))])
  }

  @Test func commandsThatCanWaitOnAPrintSheetOrDialogHaveNoDeadlineButStillRetire() throws {
    let timeouts = ControlledPageTimeouts()
    let injectedTestDeadline = Duration.seconds(9)
    let registry = PageRegistry(timeout: injectedTestDeadline, scheduleTimeout: { timeouts.schedule($0, $1) })
    var replies: [PageRegistry.Completion] = []
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in replies.append(finish) }
    let commands: [PageCommand] = [.print, .runPageCommand("systemPrint"), .evaluate("confirm('?')"), .executeJavaScript("alert(1)"), .reload]
    var results = Array(repeating: [Result<PageValue, PageRegistryError>](), count: commands.count)
    for (index, command) in commands.enumerated() {
      registry.call(token, command: command) { results[index].append($0) }
      #expect(timeouts.deadlines.count == (command == .reload ? 1 : 0))
    }
    #expect(commands.map(\.waitsForTheUser) == [true, true, true, true, false])
    #expect(timeouts.deadlines.map(\.duration) == [injectedTestDeadline])
    replies[0](.success(.null))
    #expect(results[0] == [.success(.null)])
    registry.retire(token)
    for index in 1..<commands.count { #expect(results[index] == [.failure(.retired(token))]) }
  }

  @Test func cancellationCompletesOnceAndCancelsItsDeadline() throws {
    let timeouts = ControlledPageTimeouts()
    let registry = PageRegistry(scheduleTimeout: { timeouts.schedule($0, $1) })
    var reply: PageRegistry.Completion?
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in reply = finish }
    var results: [Result<PageValue, PageRegistryError>] = []
    let callID = registry.call(token, command: .reload) { results.append($0) }
    let deadline = try #require(timeouts.deadlines.first)
    #expect(!deadline.cancelled)
    registry.cancel(callID)
    #expect(timeouts.deadlines[0].cancelled)
    registry.cancel(callID)
    reply?(.success(.null))
    reply?(.success(.null))
    deadline.fire()
    registry.retire(token)
    #expect(results == [.failure(.cancelled(token))])
  }

  @Test func deferredSuccessStaysSettledAcrossRetirementAndCancellation() {
    let delivery = DeferredPageDelivery()
    let registry = PageRegistry(deliver: { delivery.hold($0) })
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in finish(.success(.null)) }
    var results: [Result<PageValue, PageRegistryError>] = []
    let callID = registry.call(token, command: .reload) { results.append($0) }
    registry.retire(token)
    registry.cancel(callID)
    #expect(results.isEmpty)
    delivery.flush()
    #expect(results == [.success(.null)])
  }

  @Test func malformedEngineReplyFailsOnce() {
    let registry = PageRegistry()
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in
      finish(.success(.string("bad")))
      finish(.success(.null))
    }
    var results: [Result<PageValue, PageRegistryError>] = []
    registry.call(token, command: .reload) { results.append($0) }
    #expect(results == [.failure(.invalidValue)])
    registry.retire(token)
  }

  @Test func cancellingSwiftCallerCompletesWithoutEngineReply() async {
    let registry = PageRegistry()
    var started: CheckedContinuation<Void, Never>?
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, _ in
      started?.resume()
      started = nil
    }
    var task: Task<PageValue, Error>?
    await withCheckedContinuation { continuation in
      started = continuation
      task = Task { try await registry.call(token, request: PageRequest<PageValue>.evaluate("1")) }
    }
    guard let task else {
      Issue.record("Page call task was not created")
      registry.retire(token)
      return
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled page call succeeded")
    } catch {
      #expect(error as? PageRegistryError == .cancelled(token))
    }
    registry.retire(token)
  }

  @Test func typedRequestsValidateResultShapes() async throws {
    let registry = PageRegistry()
    let token = registry.register(tabID: "tab", engine: .chromium, host: .pooled) { _, finish in
      finish(.success(.object(["data": .string("png"), "frame": .array([0, 0, 20, 10].map { .number(Double($0)) })])))
    }
    let picture = try await registry.call(token, request: .capturePicture(1))
    #expect(picture?.data == "png")
    #expect(picture?.frame == [0, 0, 20, 10])
    registry.retire(token)
  }
}

@MainActor
@Suite struct PageCommandDecodingTests {
  @Test func everySeamCommandDecodes() throws {
    let cases: [(String, [PageValue], PageCommand)] = [
      ("loadUrl", [.string("value"), .bool(true)], .loadUrl("value", true)),
      ("goBack", [], .goBack),
      ("goForward", [], .goForward),
      ("goToOffset", [.number(1)], .goToOffset(1)),
      ("reload", [], .reload),
      ("forceReload", [], .forceReload),
      ("stopLoading", [], .stopLoading),
      ("focus", [], .focus),
      ("setMuted", [.bool(true)], .setMuted(true)),
      ("zoomStep", [.number(1)], .zoomStep(1)),
      ("find", [.string("value"), .bool(true), .bool(true)], .find("value", true, true)),
      ("stopFinding", [.bool(true)], .stopFinding(true)),
      ("print", [], .print),
      ("runPageCommand", [.string("value")], .runPageCommand("value")),
      ("showDevTools", [.null], .showDevTools(nil)),
      ("executeJavaScript", [.string("value")], .executeJavaScript("value")),
      ("evaluate", [.string("value")], .evaluate("value")),
      ("navigationEntries", [], .navigationEntries),
      ("capturePicture", [.number(1)], .capturePicture(1)),
      ("downloadFavicon", [.string("value")], .downloadFavicon("value")),
      ("downloadImage", [.string("value"), .number(1)], .downloadImage("value", 1)),
      ("mediaCommand", [.string("value"), .number(1)], .mediaCommand("value", 1)),
      ("requestPictureInPicture", [.number(1), .number(1)], .requestPictureInPicture(1, 1)),
      ("takeControlPress", [.number(1), .number(1)], .takeControlPress(1, 1)),
      ("exitPictureInPicture", [], .exitPictureInPicture),
      ("getSecurityInfo", [], .getSecurityInfo),
      ("pageCookies", [.array([.string("https://example.test")])], .pageCookies(["https://example.test"])),
      ("openBlockedPopup", [.string("value"), .bool(true)], .openBlockedPopup("value", true)),
      ("clearSiteData", [], .clearSiteData),
      ("resolvePasswordPrompt", [.string("value"), .null, .null], .resolvePasswordPrompt("value", nil, nil)),
      ("resolveAutofillPrompt", [.number(1), .string("value")], .resolveAutofillPrompt(1, "value")),
      ("executeExtensionAction", [.string("value")], .executeExtensionAction("value")),
      ("resolveDisplayMedia", [.string("value"), .null, .bool(true)], .resolveDisplayMedia("value", nil, true)),
      ("mediaCaptureSourceId", [], .mediaCaptureSourceId),
      ("notificationAction", [.string("value"), .string("value")], .notificationAction("value", "value")),
      ("resolveUnresponsive", [.bool(true)], .resolveUnresponsive(true)),
      ("discard", [.bool(true)], .discard(true)),
      ("setFrozen", [.bool(true)], .setFrozen(true)),
      ("nativeTag", [], .nativeTag),
      ("livePage", [], .livePage)
    ]
    #expect(cases.count == 40)
    for (method, arguments, expected) in cases {
      #expect(try PageCommand.decode(method: method, args: arguments) == expected)
      #expect(expected.method == method)
    }
  }

  @Test func missingAndExtraArgumentsFailBeforeDispatch() throws {
    #expect(throws: PageRegistryError.invalidArguments("loadUrl", 0)) {
      try PageCommand.decode(method: "loadUrl", args: [])
    }
    #expect(throws: PageRegistryError.invalidArguments("find", 2)) {
      try PageCommand.decode(method: "find", args: [.string("x"), .bool(true)])
    }
    #expect(throws: PageRegistryError.invalidArguments("takeControlPress", 2)) {
      try PageCommand.decode(method: "takeControlPress", args: [.number(0), .number(1), .number(2)])
    }
    #expect(throws: PageRegistryError.invalidArguments("setMuted", 0)) {
      try PageCommand.decode(method: "setMuted", args: [.string("true")])
    }
    #expect(throws: PageRegistryError.invalidArguments("takeControlPress", 1)) {
      try PageCommand.decode(method: "takeControlPress", args: [.number(0), .bool(true)])
    }
    #expect(throws: PageRegistryError.invalidArguments("capturePicture", 0)) {
      try PageCommand.decode(method: "capturePicture", args: [.number(.nan)])
    }
  }

  @Test func malformedInputsNeverCoerceNumbersIntoBooleans() throws {
    #expect(throws: PageRegistryError.invalidArguments("find", 1)) {
      try PageCommand.decode(method: "find", args: [.string("x"), .number(1), .bool(false)])
    }
    #expect(throws: PageRegistryError.invalidArguments("goToOffset", 0)) {
      try PageCommand.decode(method: "goToOffset", args: [.number(1.5)])
    }
    #expect(throws: PageRegistryError.invalidArguments("goToOffset", 0)) {
      try PageCommand.decode(method: "goToOffset", args: [.number(.infinity)])
    }
    #expect(throws: PageRegistryError.invalidArguments("pageCookies", 0)) {
      try PageCommand.decode(method: "pageCookies", args: [.array([.bool(false)])])
    }
    #expect(throws: PageRegistryError.invalidArguments("reload", 0)) {
      try PageCommand.decode(method: "reload", args: [.null])
    }
    #expect(throws: PageRegistryError.unknownCommand("typo")) {
      try PageCommand.decode(method: "typo", args: [])
    }
    #expect(try PageCommand.decode(method: "loadUrl", args: [.string("https://example.test")]) == .loadUrl("https://example.test", false))
    #expect(try PageCommand.decode(method: "discard", args: []) == .discard(false))
    #expect(try PageCommand.decode(method: "showDevTools", args: [.null]) == .showDevTools(nil))
    #expect(throws: PageRegistryError.invalidValue) { try PageValue(any: Double.nan) }
    #expect(try PageValue(any: true) == .bool(true))
    #expect(try PageValue(any: 1) == .number(1))
  }

  @Test func boxedNilArgumentsFromExpoAreNull() throws {
    let missing: String? = nil
    let args: [Any] = ["save", "ada", missing as Any]
    let values = try args.map { try PageValue(any: $0) }
    #expect(values == [.string("save"), .string("ada"), .null])
    #expect(try PageCommand.decode(method: "resolvePasswordPrompt", args: values) == .resolvePasswordPrompt("save", "ada", nil))
    let nested: [String: Any] = ["source": Optional<Any>.none as Any, "inner": [Optional(Optional<Int>.none) as Any]]
    #expect(try PageValue(any: nested) == .object(["source": .null, "inner": .array([.null])]))
  }
}
