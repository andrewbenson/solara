import AppKit
import Foundation

public struct ToolbarPaletteState: Decodable, Equatable, Sendable {
  public var background: String?
  public var text: String
  public var secondary: String
  public var icon: String
  public var iconDisabled: String
  public var hover: String
  public var pressed: String
  public var pill: String
  public var divider: String
  public var urlHost: String?
  public var urlPath: String?
}

public struct ToolbarGeometryState: Decodable, Equatable, Sendable {
  public var sidebarButton: Double?
  public var back: Double
  public var forward: Double
  public var reload: Double
  public var urlLeft: Double
  public var urlRight: Double
}

public struct ToolbarBadgeState: Decodable, Equatable, Sendable {
  public var text: String
  public var color: String
  public var textColor: String
}

public struct ToolbarButtonState: Decodable, Equatable, Sendable {
  public var id: String
  public var icon: String
  public var image: String?
  public var imageSize: Double?
  public var dimmed: Bool?
  public var badge: ToolbarBadgeState?
  public var anchor: String?
  public var size: Double?
  public var box: Double?
  public var radius: Double?
  public var weight: String?
  public var color: String?
  public var enabled: Bool?
  public var active: Bool?
  public var tooltip: String?
  public var menu: Bool?
  public var longPress: Bool?
  public var middle: Bool?
  public var plain: Bool?
}

public struct ToolbarDeveloperState: Decodable, Equatable, Sendable {
  public var text: String
  public var editing: Bool
  public var request: Int
}

public struct ToolbarUrlState: Decodable, Equatable, Sendable {
  public var developer: ToolbarDeveloperState?
  public var host: String
  public var restTrail: String
  public var hoverTrail: String
  public var insecure: String?
  public var hoverButtons: [ToolbarButtonState]
  public var trailing: [ToolbarButtonState]
  public var pinned: Bool
}

public struct ToolbarUpdateState: Decodable, Equatable, Sendable {
  public var text: String
  public var short: String
  public var tooltip: String?
}

public struct ToolbarState: Decodable, Equatable, Sendable {
  public var tabId: String
  public var height: Double
  public var bare: Bool
  public var focused: Bool
  public var palette: ToolbarPaletteState
  public var accent: String
  public var geometry: ToolbarGeometryState
  public var left: [ToolbarButtonState]
  public var url: ToolbarUrlState?
  public var right: [ToolbarButtonState]
  public var rightInset: Double
  public var extensions: [ToolbarButtonState]?
  public var extensionsRight: Double?
  public var update: ToolbarUpdateState?
  public var hairline: Bool
  public var progress: Double?
  public var stripes: String?

  public static func decode(_ json: String) -> ToolbarState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ToolbarState.self, from: data)
  }
}

public struct ToolbarClick: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case press, menu, middle, submit, cancel, blur, focus
  }

  public var id: String
  public var kind: Kind
  public var text: String?
  public var meta = false
  public var alt = false
  public var shift = false

  public init(id: String, kind: Kind, flags: NSEvent.ModifierFlags = [], text: String? = nil) {
    self.id = id
    self.kind = kind
    self.text = text
    meta = flags.contains(.command)
    alt = flags.contains(.option)
    shift = flags.contains(.shift)
  }
}

func toolbarColor(_ text: String?) -> NSColor? {
  guard let text, let parsed = CSSColor(text) else { return nil }
  return parsed.ns
}
