import SolaraCore
import Foundation
internal import SolaraModel
internal import SolaraStore
#if DEBUG
internal import SolaraUI
#endif

final class SolaraCoreStripEngine: StripEngine {
  #if DEBUG
  @MainActor static var sentCount = 0
  @MainActor static var sentWhileHeld = 0

  @MainActor static var commandProbe: [String: Any] {
    let drag = TabDragSession.current
    let point = drag.flatMap { $0.point(in: $0.sourceWindow) }
    return ["sent": sentCount, "held": sentWhileHeld,
      "sourceWindow": drag?.sourceWindow as Any? ?? NSNull(), "tabIds": drag?.tabIds ?? [],
      "x": point.map { $0.x as Any } ?? NSNull(), "y": point.map { $0.y as Any } ?? NSNull()]
  }
  #endif

  func observe(_ receive: @escaping (JSONValue) -> Void) -> Int {
    SolaraCoreTabStrip.claimCommands()
    return SolaraCoreTabStrip.addObserver { tx in receive(Self.json(tx)) }
  }

  func stopObserving(_ token: Int) { SolaraCoreTabStrip.removeObserver(token) }

  func snapshot() -> JSONValue { Self.json(SolaraCoreTabStrip.allStrips) }

  func send(id: Int, command: JSONValue) {
    guard let command = Self.foundation(command) as? [String: Any] else { return }
    #if DEBUG
    MainActor.assumeIsolated {
      Self.sentCount += 1
      if TabDragSession.current != nil { Self.sentWhileHeld += 1 }
    }
    #endif
    SolaraCoreTabStrip.command(id, command: command)
  }

  static func json(_ value: Any) -> JSONValue {
    switch value {
    case let n as NSNumber:
      return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
    case let s as String: return .string(s)
    case let a as [Any]: return .array(a.map(json))
    case let d as [String: Any]:
      return .object(JSMap(d.keys.sorted(by: jsKeyPrecedes).map { ($0, json(d[$0]!)) }))
    default: return .null
    }
  }

  static func foundation(_ value: JSONValue) -> Any {
    switch value {
    case .null: NSNull()
    case .bool(let b): b
    case .number(let n): n
    case .string(let s): s
    case .array(let a): a.map(foundation)
    case .object(let o): Dictionary(uniqueKeysWithValues: o.map { ($0.key, foundation($0.value)) })
    }
  }
}
