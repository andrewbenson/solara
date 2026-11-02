import Foundation
import LocalAuthentication

final class OwnerAuthentication {
  private let authorization: PairingSession.Authorization
  private var consumed = false
  private let lock = NSLock()

  fileprivate init(_ authorization: PairingSession.Authorization) {
    self.authorization = authorization
  }

  func consume(matching value: PairingSession.Authorization) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !consumed else { return false }
    consumed = true
    return authorization == value
  }
}

final class PairingAuthenticationAttempt {
  fileprivate let lock = NSRecursiveLock()
  fileprivate var pending = true
  fileprivate var callbackUsed = false
  fileprivate var cancelled = false
  private var evaluating = false

  var panelLive: Bool { lock.lock(); defer { lock.unlock() }; return evaluating && !cancelled }
  fileprivate var invalidateContext: (() -> Void)?

  func cancel() {
    lock.lock()
    cancelled = true
    pending = false
    evaluating = false
    let invalidate = invalidateContext
    invalidateContext = nil
    lock.unlock()
    invalidate?()
  }

  fileprivate func isPending() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending && !cancelled && !callbackUsed
  }

  fileprivate func attach(_ invalidate: @escaping () -> Void) -> Bool {
    lock.lock()
    guard pending && !cancelled && !callbackUsed else {
      lock.unlock()
      invalidate()
      return false
    }
    invalidateContext = invalidate
    lock.unlock()
    return true
  }

  fileprivate func takeCallback(replied: () -> Void = {}) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard pending && !cancelled && !callbackUsed else { return false }
    pending = false
    evaluating = false
    callbackUsed = true
    replied()
    return true
  }

  fileprivate func evaluateIfPending(_ evaluate: () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard pending && !cancelled && !callbackUsed else { return }
    evaluating = true
    evaluate()
  }

  fileprivate func endUnavailable(_ completion: (OwnerAuthentication?) -> Void) {
    guard takeCallback() else { return }
    lock.lock()
    let invalidate = invalidateContext
    invalidateContext = nil
    lock.unlock()
    invalidate?()
    completion(nil)
  }
}

protocol PairingOwnerAuthenticating: AnyObject {
  @discardableResult
  func authenticate(_ tuple: PairingSession.Authorization, validate: @escaping (PairingSession.Authorization) -> Bool, replyBegan: @escaping () -> Void, replied: @escaping (@escaping () -> Void) -> Void, completion: @escaping (OwnerAuthentication?) -> Void) -> PairingAuthenticationAttempt
}

final class FreshPairingOwnerAuthenticator: PairingOwnerAuthenticating {
  static let reason = "allow your other Mac to access your synced data, including passwords"

  #if SWIFT_PACKAGE && DEBUG && SOLARA_PAIRING_TESTING
  private var testMakeContext: (() -> LAContext)?
  private var testSchedule: ((@escaping () -> Void) -> Void)?
  private var testScheduleReply: ((@escaping () -> Void) -> Void)?

  static func testing(makeContext: @escaping () -> SyntheticPairingAuthenticationContext, schedule: @escaping (@escaping () -> Void) -> Void = { $0() }, scheduleReply: @escaping (@escaping () -> Void) -> Void = { $0() }) -> FreshPairingOwnerAuthenticator {
    let authenticator = FreshPairingOwnerAuthenticator()
    authenticator.testMakeContext = { SyntheticPairingLAContext(makeContext()) }
    authenticator.testSchedule = schedule
    authenticator.testScheduleReply = scheduleReply
    return authenticator
  }
  #endif

  private func makeContext() -> LAContext {
    #if SWIFT_PACKAGE && DEBUG && SOLARA_PAIRING_TESTING
    if let testMakeContext { return testMakeContext() }
    #endif
    return LAContext()
  }

  private func schedule(_ work: @escaping () -> Void) {
    #if SWIFT_PACKAGE && DEBUG && SOLARA_PAIRING_TESTING
    if let testSchedule { testSchedule(work); return }
    #endif
    DispatchQueue.main.async(execute: work)
  }

  private func scheduleReply(_ work: @escaping () -> Void) {
    #if SWIFT_PACKAGE && DEBUG && SOLARA_PAIRING_TESTING
    if let testScheduleReply { testScheduleReply(work); return }
    #endif
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
  }

  @discardableResult
  func authenticate(_ tuple: PairingSession.Authorization, validate: @escaping (PairingSession.Authorization) -> Bool, replyBegan: @escaping () -> Void = {}, replied: @escaping (@escaping () -> Void) -> Void = { $0() }, completion: @escaping (OwnerAuthentication?) -> Void) -> PairingAuthenticationAttempt {
    let attempt = PairingAuthenticationAttempt()
    schedule {
      guard attempt.isPending() else { return }
      guard validate(tuple) else { attempt.endUnavailable(completion); return }
      guard attempt.isPending() else { return }
      let context = self.makeContext()
      context.touchIDAuthenticationAllowableReuseDuration = 0
      guard attempt.attach({ context.invalidate() }) else { return }
      var error: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { attempt.endUnavailable(completion); return }
      guard attempt.isPending(), validate(tuple), attempt.isPending() else { attempt.endUnavailable(completion); return }
      attempt.evaluateIfPending {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Self.reason) { success, error in
          guard attempt.takeCallback(replied: replyBegan) else { return }
          replied {
            self.scheduleReply {
              let valid = success && error == nil && validate(tuple)
              attempt.lock.lock()
              guard !attempt.cancelled else { attempt.lock.unlock(); return }
              let capability = valid ? OwnerAuthentication(tuple) : nil
              let invalidate = attempt.invalidateContext
              attempt.invalidateContext = nil
              attempt.lock.unlock()
              invalidate?()
              completion(capability)
            }
          }
        }
      }
    }
    return attempt
  }
}

#if SWIFT_PACKAGE && DEBUG && SOLARA_PAIRING_TESTING
protocol SyntheticPairingAuthenticationContext: AnyObject {
  var touchIDAuthenticationAllowableReuseDuration: TimeInterval { get set }
  func canEvaluatePolicy(_ policy: LAPolicy) -> Bool
  func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void)
  func invalidate()
}

private final class SyntheticPairingLAContext: LAContext {
  private let context: SyntheticPairingAuthenticationContext

  init(_ context: SyntheticPairingAuthenticationContext) {
    self.context = context
    super.init()
  }

  override var touchIDAuthenticationAllowableReuseDuration: TimeInterval {
    get { context.touchIDAuthenticationAllowableReuseDuration }
    set { context.touchIDAuthenticationAllowableReuseDuration = newValue }
  }

  override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
    context.canEvaluatePolicy(policy)
  }

  override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void) {
    context.evaluatePolicy(policy, localizedReason: localizedReason, reply: reply)
  }

  override func invalidate() { context.invalidate() }
}

final class SyntheticPairingOwnerAuthenticator: PairingOwnerAuthenticating {
  private let authenticator: FreshPairingOwnerAuthenticator

  init(makeContext: @escaping () -> SyntheticPairingAuthenticationContext, schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
    authenticator = .testing(makeContext: makeContext, schedule: schedule)
  }

  static func authenticated(_ tuple: PairingSession.Authorization) -> OwnerAuthentication {
    OwnerAuthentication(tuple)
  }

  @discardableResult
  func authenticate(_ tuple: PairingSession.Authorization, validate: @escaping (PairingSession.Authorization) -> Bool, replyBegan: @escaping () -> Void = {}, replied: @escaping (@escaping () -> Void) -> Void = { $0() }, completion: @escaping (OwnerAuthentication?) -> Void) -> PairingAuthenticationAttempt {
    authenticator.authenticate(tuple, validate: validate, replyBegan: replyBegan, replied: replied, completion: completion)
  }
}
#endif
