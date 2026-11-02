import Foundation
internal import SolaraBridgeCore
internal import SolaraStore
internal import SolaraModel
import SolaraPersistence

extension NativeStore {
  public static func pairingRevision() -> Int? {
    guard !safeMode, unavailableReason == nil, let owner = shared else { return nil }
    return owner.bridge.store.rev
  }

  public static func pairingCheckpoint(operation: [String: Any], links: [String: Any]) throws -> Any {
    guard !Thread.isMainThread, !safeMode, unavailableReason == nil, let owner = shared, let writer = owner.writer,
      let key = operation["key"] as? String, let disposition = operation["disposition"] as? String,
      let desired = operation["desired"], let expected = operation["localValue"],
      JSONSerialization.isValidJSONObject([desired, expected, links]) else { throw PairingCheckpointFailure.unavailable }
    guard let folder = dataFolder() else { throw PairingCheckpointFailure.unavailable }
    let documentURL = folder.appendingPathComponent("sync.json")
    let before = try Data(contentsOf: documentURL)
    guard before.count <= 4 * 1024 * 1024, let document = try JSONSerialization.jsonObject(with: before) as? [String: Any],
      let bootstrap = document["bootstrap"] as? [String: Any],
      document["v"] as? Int == 2, document["enabled"] as? Bool == true,
      document["joinTransaction"] as? String == operation["transaction"] as? String,
      bootstrap["generation"] as? NSNumber == operation["generation"] as? NSNumber,
      let actualLinks = document["profiles"] as? [String: Any],
      NSDictionary(dictionary: actualLinks).isEqual(to: links) else { throw PairingCheckpointFailure.unavailable }
    let optedOut = (document["types"] as? [String: Any])?["settings"] as? Bool == false
    let desiredValue = try JSONValue.parse(JSONSerialization.data(withJSONObject: desired, options: [.fragmentsAllowed]))
    let expectedValue = try JSONValue.parse(JSONSerialization.data(withJSONObject: expected, options: [.fragmentsAllowed]))
    let linkValues = try JSONValue.parse(JSONSerialization.data(withJSONObject: links))
    let value = try writer.pairingCheckpoint(key: key, desired: desiredValue, expected: expectedValue, disposition: disposition, links: linkValues, settingsOptedOut: optedOut)
    guard try Data(contentsOf: documentURL) == before else { throw PairingCheckpointFailure.changed }
    return try JSONSerialization.jsonObject(with: Data(value.text().utf8), options: [.fragmentsAllowed])
  }
}
