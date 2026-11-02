import Foundation

final class PairingAdmissionEpoch {
  private let lock = NSRecursiveLock()
  private var value: UInt64 = 0
  var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
  @discardableResult func advance() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
  func admit(_ expected: UInt64, _ body: () -> Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard value == expected else { return false }
    return body()
  }
}
