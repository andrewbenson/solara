import Foundation
import Observation

@MainActor
@Observable
public final class SettingsNavigation {
  @ObservationIgnored public var willNavigate: (SettingsPlace, SettingsPlace) -> Void = { _, _ in }
  public static let historyLimit = 30

  public private(set) var place: SettingsPlace
  public private(set) var back: [SettingsPlace] = []
  public private(set) var forward: [SettingsPlace] = []

  public init(place: SettingsPlace = SettingsPlace(pane: .general)) {
    self.place = place
  }

  public var pane: SettingsPane { place.pane }
  public var profileId: String? { place.profileId }
  public var detail: String? { place.detail }
  public var canGoBack: Bool { !back.isEmpty }
  public var canGoForward: Bool { !forward.isEmpty }

  public func go(_ pane: SettingsPane, profileId: String? = nil, detail: String? = nil) {
    let next = SettingsPlace(pane: pane, profileId: profileId, detail: detail)
    if next == place { return }
    willNavigate(place, next)
    back = Array((back + [place]).suffix(Self.historyLimit))
    forward = []
    place = next
  }

  public func replace(profileId: String?, detail: String? = nil) {
    let next = SettingsPlace(pane: place.pane, profileId: profileId, detail: detail)
    willNavigate(place, next)
    if back.last == next { back.removeLast() }
    forward = []
    place = next
  }

  public func goBack() {
    guard let previous = back.popLast() else { return }
    willNavigate(place, previous)
    forward.insert(place, at: 0)
    place = previous
  }

  public func goForward() {
    guard !forward.isEmpty else { return }
    let next = forward.removeFirst()
    willNavigate(place, next)
    back.append(place)
    place = next
  }
}
