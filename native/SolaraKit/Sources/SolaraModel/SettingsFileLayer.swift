import Foundation

public struct SettingsFileLayer: Sendable, Hashable {
  public static let shortcutsKey = "shortcuts"
  public static let replicaKey = "fileOwn"

  public var source: String
  public var values: JSONObject
  public var shortcuts: JSONObject
  var own: JSONObject = [:]

  public init(source: String, values: JSONObject = [:], shortcuts: JSONObject = [:]) {
    self.source = source
    var values = values
    values.removeValue(forKey: Self.shortcutsKey)
    for key in Settings.bookkeepingKeys { values.removeValue(forKey: key) }
    self.values = values
    self.shortcuts = shortcuts
  }

  public var isEmpty: Bool { values.isEmpty && shortcuts.isEmpty }

  public var coveredKeys: [String] { values.keys + (shortcuts.isEmpty ? [] : [Self.shortcutsKey]) }

  public func sets(_ key: String) -> Bool { values.contains(key) }

  public func binds(_ shortcutId: String) -> Bool { shortcuts.contains(shortcutId) }

  func effectiveShortcuts(own: JSONValue?) -> JSONValue {
    var merged = own?.object ?? [:]
    for (id, binding) in shortcuts { merged[id] = binding }
    return .object(merged)
  }

  func ownShortcuts(written: JSONValue, previousOwn: JSONValue?) -> JSONValue {
    guard var next = written.object else { return written }
    let before = previousOwn?.object ?? [:]
    for (id, binding) in shortcuts where next[id] == binding {
      if let kept = before[id] { next[id] = kept } else { next.removeValue(forKey: id) }
    }
    return .object(next)
  }

  var replicaValue: JSONValue {
    .object(["covered": JSONValue(coveredKeys.sorted()), "own": .object(own)])
  }
}

public extension Settings {
  var ownValues: JSONObject {
    guard let layer = fileLayer else { return values }
    var out = values
    for key in layer.coveredKeys {
      if let own = layer.own[key] { out[key] = own } else { out.removeValue(forKey: key) }
    }
    return out
  }

  var own: Settings { Settings(values: ownValues) }

  var replicaJSON: JSONValue {
    guard let layer = fileLayer, !layer.isEmpty else { return json }
    var out = values
    out[SettingsFileLayer.replicaKey] = layer.replicaValue
    return .object(out)
  }

  var replicaFileOwn: JSONValue? {
    guard let layer = fileLayer, !layer.isEmpty else { return nil }
    return layer.replicaValue
  }

  func fileSource(_ key: String) -> String? {
    guard let layer = fileLayer, layer.sets(key) else { return nil }
    return layer.source
  }

  func fileSource(shortcut id: String) -> String? {
    guard let layer = fileLayer, layer.binds(id) else { return nil }
    return layer.source
  }

  func applyingFile(_ layer: SettingsFileLayer?) -> Settings {
    let base = ownValues
    guard var layer, !layer.isEmpty else { return Settings(values: base) }
    var values = base
    layer.own = [:]
    for key in layer.coveredKeys {
      if let own = base[key] { layer.own[key] = own }
    }
    for (key, value) in layer.values { values[key] = value }
    if !layer.shortcuts.isEmpty { values[SettingsFileLayer.shortcutsKey] = layer.effectiveShortcuts(own: base[SettingsFileLayer.shortcutsKey]) }
    return Settings(values: values, fileLayer: layer)
  }

  func replacingValues(_ written: JSONObject) -> Settings {
    var incoming = written
    let seenCovered = written[SettingsFileLayer.replicaKey]?["covered"]?.array?.compactMap(\.string) ?? []
    let covered = Set(fileLayer?.coveredKeys ?? [])
    for key in seenCovered where !covered.contains(key) {
      if let current = self.values[key] { incoming[key] = current } else { incoming.removeValue(forKey: key) }
    }
    guard var layer = fileLayer else { return Settings(values: incoming) }
    var values = incoming
    values.removeValue(forKey: SettingsFileLayer.replicaKey)
    for (key, value) in layer.values {
      if incoming[key] != value { layer.own[key] = incoming[key] }
      values[key] = value
    }
    if !layer.shortcuts.isEmpty {
      let written = incoming[SettingsFileLayer.shortcutsKey] ?? .object([:])
      let own = layer.ownShortcuts(written: written, previousOwn: layer.own[SettingsFileLayer.shortcutsKey])
      layer.own[SettingsFileLayer.shortcutsKey] = own
      values[SettingsFileLayer.shortcutsKey] = layer.effectiveShortcuts(own: own)
    }
    return Settings(values: values, fileLayer: layer)
  }

  internal func routedThroughFile(_ patch: JSONObject) -> (patch: JSONObject, layer: SettingsFileLayer?) {
    guard var layer = fileLayer else { return (patch, nil) }
    var routed = patch
    for (key, value) in patch {
      if let fileValue = layer.values[key] {
        layer.own[key] = value
        routed[key] = fileValue
      } else if key == SettingsFileLayer.shortcutsKey, !layer.shortcuts.isEmpty {
        let own = layer.ownShortcuts(written: value, previousOwn: layer.own[key])
        layer.own[key] = own
        routed[key] = layer.effectiveShortcuts(own: own)
      }
    }
    return (routed, layer)
  }
}
