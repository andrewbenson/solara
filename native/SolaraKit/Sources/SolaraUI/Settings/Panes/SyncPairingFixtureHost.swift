#if DEBUG
import AppKit
import Foundation

@MainActor
protocol SyncPairingFixtureSession: AnyObject {
  func drive(_ action: String, argument: String?) -> [String: Any]
  func destroy()
  func mountedState() -> [String: Any]
}

extension SyncPairingFixtureSession {
  func mountedState() -> [String: Any] { ["fixture": true, "mounted": true] }
}

@MainActor
public final class SyncPairingFixtureHost {
  private let environment: [String: String]
  private let makeSession: @MainActor (NSWindow) -> any SyncPairingFixtureSession
  private var session: (any SyncPairingFixtureSession)?

  init(environment: [String: String], makeSession: @escaping @MainActor (NSWindow) -> any SyncPairingFixtureSession) {
    self.environment = environment
    self.makeSession = makeSession
  }

  public func drive(_ action: String, argument: String? = nil, settingsWindow: NSWindow?) -> [String: Any] {
    guard SettingsDevActionAdmission.admits("pairingFixture", environment: environment) else { destroy(); return ["error": "test instances only"] }
    if action == "mount" {
      guard let settingsWindow else { return ["error": "open Settings first"] }
      destroy()
      session = makeSession(settingsWindow)
      if let argument, ["longName", "confusable"].contains(argument) { _ = session?.drive(argument, argument: nil) }
      return session?.mountedState() ?? ["error": "no mounted fixture"]
    }
    if action == "destroy" {
      destroy()
      return ["fixture": true, "mounted": false]
    }
    let allowed = ["state", "select", "ready", "check", "uncheck", "allow", "space", "return", "enter", "escape", "saveTarget", "pressSaved", "inspect", "hide", "show", "remount", "present", "snapshot", "light", "dark", "longName", "confusable"]
    guard allowed.contains(action) else { return ["error": "unknown fixture action"] }
    guard let session else { return ["error": "no mounted fixture"] }
    return session.drive(action, argument: argument)
  }

  public var isMounted: Bool { session != nil }

  public func destroy() {
    let old = session
    session = nil
    old?.destroy()
  }
}
#endif

#if DEBUG
import SwiftUI

@MainActor
public final class SyncPairingFixturePane: SettingsPaneProvider {
  public init() {}
  public func isLoaded(_ place: SettingsPlace) -> Bool { true }
  public func prepare(_ place: SettingsPlace) async {}
  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(Text("Pairing display fixture. This view cannot access synced data or authorize a connection.").padding())
  }

  public static func select(environment: [String: String], production: () -> any SettingsPaneProvider) -> any SettingsPaneProvider {
    guard environment["SOLARA_SYNC_PAIRING_FIXTURE"] == "1" else { return production() }
    return SyncPairingFixturePane()
  }
}
#endif
