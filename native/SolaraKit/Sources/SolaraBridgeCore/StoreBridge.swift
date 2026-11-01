import Foundation
import SolaraModel
import SolaraStore

public final class StoreBridge: Sendable {
  public typealias CatchUpEncoder = @Sendable (StoreCatchUp, JSONObject) -> JSONObject

  public let store: Store
  private let encoder: CatchUpEncoder

  public init(store: Store, encodeCatchUp: @escaping CatchUpEncoder = { StoreBridge.encode($0, into: $1) }) {
    self.store = store
    encoder = encodeCatchUp
  }

  public static func data(_ state: BrowserState) -> JSONValue {
    .object(state.stateJSON)
  }

  public func snapshot() -> JSONValue {
    let (rev, state) = store.snapshot
    let encoded = encoder(.snapshot(rev: rev, state: state), [:])
    return ["rev": encoded["rev"] ?? JSONValue(rev), "data": encoded["snapshot"] ?? .null]
  }

  public func snapshotJSON() -> String { snapshot().text() }

  public func dispatch(_ commandJSON: String, sinceRev: Int) -> String {
    dispatch(json: commandJSON, sinceRev: sinceRev).text()
  }

  public func dispatch(json commandJSON: String, sinceRev: Int, prepare: ([Command]) throws -> [Command] = { $0 }) -> JSONValue {
    var response = JSONObject()
    do {
      let parsed = try JSONValue.parse(commandJSON)
      let fromSync = parsed["fromSync"]?.truthy ?? false
      let listed = parsed["commands"].map { $0.array ?? [$0] } ?? parsed.array ?? [parsed]
      let commands = try listed.map(Command.init(json:))
      let commit = try store.sequence {
        let isolated = commands.contains { $0.name == "syncPinsApply" || $0.name == "settlePinChoices" }
        let prepared: [Command]
        if fromSync || isolated { prepared = commands }
        else { prepared = try prepare(commands) }
        return try store.dispatch(prepared, origin: .bridge, fromSync: fromSync)
      }
      if let result = commit.result { response["result"] = result }
      if !commit.effects.isEmpty { response["effects"] = .array(commit.effects.map(\.json)) }
    } catch is StoreBusy {
      response["busy"] = true
    } catch {
      response["error"] = .string("\(error)")
    }
    return .object(catchUp(sinceRev: sinceRev, into: response))
  }

  public func catchUp(sinceRev: Int, into response: JSONObject = JSONObject()) -> JSONObject {
    let captured = store.catchUp(sinceRev: sinceRev)
    return encoder(captured, response)
  }

  public static func encode(_ captured: StoreCatchUp, into response: JSONObject) -> JSONObject {
    var response = response
    switch captured {
    case .patches(let rev, let patches):
      response["rev"] = JSONValue(rev)
      response["patches"] = .array(patches.map(\.json))
    case .snapshot(let rev, let state):
      response["rev"] = JSONValue(rev)
      response["snapshot"] = data(state)
    }
    return response
  }

  @discardableResult
  public func observeForeignCommits(_ handler: @escaping @Sendable (String) -> Void) -> Int {
    store.subscribe { commit in
      guard commit.origin != .bridge, !commit.changes.isEmpty || !commit.effects.isEmpty else { return }
      var event: JSONObject = ["rev": JSONValue(commit.rev), "patch": commit.patch.json]
      if !commit.effects.isEmpty { event["effects"] = .array(commit.effects.map(\.json)) }
      handler(JSONValue.object(event).text())
    }
  }
}
