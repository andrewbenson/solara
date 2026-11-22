import Foundation
import Observation

@MainActor @Observable public final class PictureInPictureCenter {
  public static let shared = PictureInPictureCenter()
  public static let didChange = Notification.Name("SolaraPictureInPictureChanged")
  static let webViewChanged = Notification.Name("SolaraCorePictureInPictureDidChange")

  public private(set) var tabID: String?
  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {
    observer = NotificationCenter.default.addObserver(forName: Self.webViewChanged, object: nil, queue: .main) { note in
      let tabID = note.userInfo?["tabID"] as? String ?? ""
      let active = note.userInfo?["active"] as? Bool ?? false
      MainActor.assumeIsolated { PictureInPictureCenter.shared.note(tabID: tabID, active: active) }
    }
  }

  public func enter(tabID: String) async -> Bool {
    guard let view = SolaraCoreWebView.liveView(transferKey: tabID) else { return false }
    return await withCheckedContinuation { continuation in
      view.enterPictureInPicture { opened in continuation.resume(returning: opened) }
    }
  }

  public func minimize() {
    SolaraCoreWebView.minimizePictureInPicture()
  }

  func note(tabID: String, active: Bool) {
    let next: String? = active ? (tabID.isEmpty ? nil : tabID) : (self.tabID == tabID ? nil : self.tabID)
    guard next != self.tabID else { return }
    self.tabID = next
    NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: next.map { ["tabID": $0] } ?? [:])
  }
}
