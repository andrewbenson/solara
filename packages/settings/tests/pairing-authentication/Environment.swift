import AppKit
import Foundation
@MainActor enum HarnessEnvironment { static var foreground = true; static var hidden = false }
@MainActor enum OnboardingPairingServices { static var joining: ((URL) -> OnboardingPairingBridge)?; static var committedJoinToken: (() -> String?)? }
final class PairingJoiningAdapter { init(folder: URL) {} }
final class OnboardingPairingBridge { init(_ adapter: PairingJoiningAdapter) {} }
