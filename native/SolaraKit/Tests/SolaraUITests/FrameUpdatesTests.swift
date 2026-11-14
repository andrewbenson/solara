import AppKit
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct FrameUpdatesTests {
  final class Owner {}

  static func mode(_ name: String = #function) -> CFRunLoopMode {
    let mode = CFRunLoopMode("FrameUpdatesTests.\(name)" as CFString)
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), mode)
    return mode
  }

  static func spin(_ seconds: Double = 0.05, mode: CFRunLoopMode, returnAfterSource: Bool = false) {
    _ = run(mode, seconds, returnAfterSource: returnAfterSource)
  }

  static func run(_ mode: CFRunLoopMode, _ seconds: Double, returnAfterSource: Bool) -> CFRunLoopRunResult {
    var result = CFRunLoopRunInMode(mode, seconds, returnAfterSource)
    for _ in 0..<5 where result == .stopped { result = CFRunLoopRunInMode(mode, seconds, returnAfterSource) }
    return result
  }

  static func runUntil(_ mode: CFRunLoopMode, within seconds: Double = 1, _ done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline { _ = CFRunLoopRunInMode(mode, 0.05, true) }
  }

  static func timer(after seconds: Double, mode: CFRunLoopMode, _ fire: @escaping @MainActor () -> Void) {
    let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + seconds, 0, 0, 0) { _ in MainActor.assumeIsolated { fire() } }
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, mode)
  }

  @Test func severalSchedulesInOneTurnRenderOnceWithTheLatest() {
    let owner = Owner()
    var rendered: [Int] = []
    for value in 1...5 { FrameUpdates.schedule(owner) { rendered.append(value) } }
    #expect(rendered.isEmpty)
    FrameUpdates.flush()
    #expect(rendered == [5])
    FrameUpdates.flush()
    #expect(rendered == [5])
  }

  @Test func ownersRenderInTheOrderTheyFirstScheduled() {
    let first = Owner()
    let second = Owner()
    var order: [String] = []
    FrameUpdates.schedule(second) { order.append("second") }
    FrameUpdates.schedule(first) { order.append("first") }
    FrameUpdates.schedule(second) { order.append("second again") }
    FrameUpdates.flush()
    #expect(order == ["second again", "first"])
  }

  @Test func aRenderThatSchedulesAnotherIsFlushedInTheSameCall() {
    let owner = Owner()
    let follower = Owner()
    var order: [String] = []
    FrameUpdates.schedule(owner) {
      order.append("owner")
      FrameUpdates.schedule(follower) { order.append("follower") }
    }
    FrameUpdates.flush()
    #expect(order == ["owner", "follower"])
  }

  @Test func workLeftAtThePassLimitIsPostedToTheNextIterationWithoutWaiting() {
    let mode = Self.mode()
    let owner = Owner()
    var count = 0
    func again() { FrameUpdates.schedule(owner) { count += 1; if count < FrameUpdates.passLimit + 4 { again() } } }
    again()
    FrameUpdates.flush()
    #expect(count == FrameUpdates.passLimit)
    #expect(Thread.isMainThread)
    var seenInSource: Int?
    let source = Self.source { seenInSource = count }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, mode)
    defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, mode) }
    CFRunLoopSourceSignal(source)
    Self.runUntil(mode) { seenInSource != nil }
    #expect(seenInSource == FrameUpdates.passLimit + 4)
  }

  @Test func aReadOnMainSeesWhatACommitJustScheduled() {
    let owner = Owner()
    var geometry = "before"
    FrameUpdates.schedule(owner) { geometry = "after" }
    let read = FrameUpdates.readOnMain { geometry }
    #expect(read == "after")
  }

  @Test func theRunLoopFlushesBeforeItWaits() {
    let mode = Self.mode()
    let owner = Owner()
    var rendered = false
    FrameUpdates.schedule(owner) { rendered = true }
    #expect(!rendered)
    Self.timer(after: 0.02, mode: mode) {}
    Self.spin(mode: mode)
    #expect(rendered)
  }

  @Test func schedulingAfterTheBeforeWaitingFlushRendersWithoutAnotherEvent() {
    let mode = Self.mode()
    let main = CFRunLoopGetMain()
    let owner = Owner()
    FrameUpdates.schedule(owner) {}
    FrameUpdates.flush()
    var rendered = false
    var renderedAtRescue: Bool?
    let source = Self.source {}
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 1_000_001) { _, _ in
      MainActor.assumeIsolated {
        FrameUpdates.schedule(owner) {
          rendered = true
        }
      }
    }!
    let rescue = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.2, 0, 0, 0) { _ in
      MainActor.assumeIsolated {
        renderedAtRescue = rendered
        CFRunLoopStop(main)
      }
    }!
    CFRunLoopAddSource(main, source, mode)
    CFRunLoopAddObserver(main, observer, mode)
    CFRunLoopAddTimer(main, rescue, mode)
    defer {
      CFRunLoopRemoveSource(main, source, mode)
      CFRunLoopObserverInvalidate(observer)
      CFRunLoopTimerInvalidate(rescue)
    }
    for _ in 0..<5 where renderedAtRescue == nil { _ = CFRunLoopRunInMode(mode, 0.5, false) }
    #expect(rendered)
    #expect(renderedAtRescue == true)
  }

  final class Perform {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
  }

  static func source(_ action: @escaping () -> Void) -> CFRunLoopSource { source(Perform(action)) }

  static func source(_ perform: Perform) -> CFRunLoopSource {
    var context = CFRunLoopSourceContext()
    context.info = Unmanaged.passRetained(perform).toOpaque()
    context.release = { info in Unmanaged<Perform>.fromOpaque(info!).release() }
    context.perform = { info in Unmanaged<Perform>.fromOpaque(info!).takeUnretainedValue().action() }
    return CFRunLoopSourceCreate(nil, 0, &context)!
  }

  @Test func aNestedRunLoopFlushesWhenItExits() {
    let mode = Self.mode()
    let owner = Owner()
    var rendered = false
    var scheduledInside = false
    let perform = Perform {
      FrameUpdates.schedule(owner) { rendered = true }
      scheduledInside = true
    }
    let source = Self.source(perform)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, mode)
    defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, mode) }
    CFRunLoopSourceSignal(source)
    CFRunLoopWakeUp(CFRunLoopGetMain())
    let started = Date()
    Self.runUntil(mode) { scheduledInside }
    #expect(Date().timeIntervalSince(started) < 0.5)
    #expect(scheduledInside)
    #expect(rendered)
  }
}
