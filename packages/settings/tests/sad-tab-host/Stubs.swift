import Foundation

@MainActor
enum SettingsAdapters {
  static var calls: [[String]] = []
  static func js(_ name: String, _ windowId: String, _ tabId: String, _ action: String) async -> Bool {
    calls.append([name, windowId, tabId, action])
    return true
  }
}
