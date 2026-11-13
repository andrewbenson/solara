import Foundation
import SolaraModel

public enum ConfigApply {
  public static func applied(_ contents: ConfigContents?, source: String, to state: BrowserState) -> BrowserState {
    var next = state
    let layer = contents?.layer(source: source)
    if layerChanged(from: next.settings.fileLayer, to: layer) { next.settings = next.settings.applyingFile(layer) }
    for id in next.profiles.keys {
      guard let profile = next.profiles[id] else { continue }
      let theme = contents?.theme(for: profile)
      let updated = theme.map { profile.applyingFileTheme($0.look, name: $0.name, source: source) } ?? profile.own
      if updated != profile { next.profiles[id] = updated }
    }
    return next
  }

  static func layerChanged(from current: SettingsFileLayer?, to next: SettingsFileLayer?) -> Bool {
    current?.values != next?.values || current?.shortcuts != next?.shortcuts || current?.source != next?.source
  }

  public static func needsApply(_ contents: ConfigContents?, source: String, to state: BrowserState) -> Bool {
    let layer = contents?.layer(source: source)
    if layerChanged(from: state.settings.fileLayer, to: layer) { return true }
    for profile in state.profiles.values {
      let theme = contents?.theme(for: profile)
      if profile.fileTheme?.name != theme?.name || (theme != nil && profile.theme != theme?.look) { return true }
    }
    return false
  }
}

extension Store {
  @discardableResult
  public func applyConfig(_ contents: ConfigContents?, source: String) throws -> Bool {
    guard ConfigApply.needsApply(contents, source: source, to: state) else { return false }
    try transact { session in
      let next = ConfigApply.applied(contents, source: source, to: session.state)
      if next.settings != session.state.settings || next.profiles != session.state.profiles { session.set(next) }
    }
    return true
  }
}
