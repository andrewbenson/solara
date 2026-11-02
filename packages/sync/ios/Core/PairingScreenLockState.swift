import Foundation

enum PairingScreenLockState {
  case locked, unlocked, unknown

  static func from(session: [String: Any]?) -> Self {
    guard let session else { return .unknown }
    guard session["kCGSSessionOnConsoleKey"] as? Bool == true else { return .locked }
    guard let value = session["CGSSessionScreenIsLocked"] else { return .unlocked }
    guard let locked = value as? Bool else { return .unknown }
    return locked ? .locked : .unlocked
  }
}
