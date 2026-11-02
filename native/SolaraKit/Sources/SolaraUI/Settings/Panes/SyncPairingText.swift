import Foundation

enum SyncPairingText {
  static let intent = "Only continue if you just started connecting your other Mac."
  static let preparing = "Preparing a secure connection…"
  static let title = "Another Mac wants to join sync"
  static let authority = "Allow only if all six characters match on the Mac you’re connecting. This grants ongoing access to everything available with your recovery phrase, including synced passwords."
  static let claimQualification = "Matching codes authenticate only this connection’s claim to this name. They do not verify the Mac’s system name, hardware, legal identity or Apple account ownership."
  static let sent = "Approval sent; installation not confirmed"
  static let nameWarning = "This name may look like another name. Compare all six code characters."
  static let persistenceFailure = "Couldn't save your pairing preference. Pairing requests will stay hidden until you try again."
  static let instructions = "On the new Mac, open Solara and choose Use Solara from your other Mac. Then arm this Mac to compare the codes and approve."
  static let authReason = "allow your other Mac to access your synced data, including passwords"

  static func ended(_ reason: TrustedEndReason) -> String {
    switch reason {
    case .mismatch: "The codes don't match. Nothing was connected."
    case .verificationFailed: "This connection couldn't be verified. Nothing was connected."
    case .folderUnavailable: "The sync folder isn't available."
    case .persistenceFailure: "Couldn't finish saving sync on this Mac."
    case .authorizationFailed: "Couldn’t authorize this connection. Use Touch ID or this Mac’s login password and start again."
    case .noLoginPassword: "Set a login password in System Settings › Users & Groups, then start this connection again."
    case .rateLimited: "Too many pairing requests. Try again or use your recovery phrase."
    case .invalidLocalName: "Enter a display form of this Mac’s real name to start a new connection."
    default: "This request ended. Start again on the other Mac."
    }
  }
}
