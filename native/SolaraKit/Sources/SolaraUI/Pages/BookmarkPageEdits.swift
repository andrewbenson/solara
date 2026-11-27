import Foundation
import SolaraEngine
import SolaraModel
import SolaraStore

public enum BookmarkPageEdits {
  public static func moves(_ ids: [String], to target: BookmarkDrop, listed: [String]) -> [BookmarkMutation]? {
    let moving = Set(ids)
    guard !ids.isEmpty, moving.count == ids.count else { return nil }
    switch target {
    case .into(let folder):
      return ids.map { .init(method: "moveBookmark", args: [.string($0), .string(folder)]) }
    case .at(let parent, let index):
      guard (0...listed.count).contains(index), moving.isSubset(of: Set(listed)) else { return nil }
      let rest = listed.filter { !moving.contains($0) }
      let insertion = listed.prefix(index).filter { !moving.contains($0) }.count
      let desired = Array(rest.prefix(insertion)) + ids + Array(rest.dropFirst(insertion))
      guard desired != listed else { return [] }
      var current = listed
      var next = rest.dropFirst(insertion).first
      return ids.reversed().map { id in
        current.removeAll { $0 == id }
        let index = next.flatMap { current.firstIndex(of: $0) } ?? current.count
        current.insert(id, at: index)
        next = id
        return .init(method: "moveBookmark", args: [.string(id), .string(parent), JSONValue(index)])
      }
    }
  }
}

public struct BookmarkFormTarget: Equatable, Sendable {
  public let windowId: String
  public let profileId: String
  public let engine: String
  private let windowProfile: String

  public static func resolve(windowId: String, state: BrowserState, closing: Set<String>) -> Self? {
    guard !closing.contains(windowId), let window = state.windows[windowId] else { return nil }
    let profile = state.bookmarkProfileId(window)
    return Self(windowId: windowId, profileId: profile, engine: state.engineProfile(profile), windowProfile: window.profileId)
  }

  public func isLive(in state: BrowserState, closing: Set<String>) -> Bool {
    Self.resolve(windowId: windowId, state: state, closing: closing) == self
  }
}
