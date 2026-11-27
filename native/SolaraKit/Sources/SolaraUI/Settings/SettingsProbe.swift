import SwiftUI

@MainActor
public enum SettingsProbe {
  public struct Switch: Sendable {
    public var frame: CGRect
    public var on: Bool
  }

  public static var enabled = false
  public static var switches: [UUID: Switch] = [:]
}

struct SettingsProbeSwitch: ViewModifier {
  let on: Bool
  @State private var id = UUID()

  func body(content: Content) -> some View {
    if SettingsProbe.enabled {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          SettingsProbe.switches[id] = SettingsProbe.Switch(frame: frame, on: on)
        }
        .onChange(of: on) { _, now in SettingsProbe.switches[id]?.on = now }
        .onDisappear { SettingsProbe.switches[id] = nil }
    } else {
      content
    }
  }
}

extension View {
  @ViewBuilder
  func liveSettingsControl(_ key: String) -> some View {
    #if DEBUG
    if LiveSettingsControlProbe.enabled {
      background(LiveSettingsControlAnchor(key: key).allowsHitTesting(false))
    } else {
      self
    }
    #else
    self
    #endif
  }
}

#if DEBUG
@MainActor
public enum LiveSettingsControlProbe {
  private static let views = NSMapTable<NSString, NSView>.strongToWeakObjects()

  static let enabled = {
    let env = ProcessInfo.processInfo.environment
    return env["SOLARA_BACKGROUND"] == "1" && env["SOLARA_DATA_DIR"]?.isEmpty == false && env["SOLARA_LIVE_MOCK"]?.isEmpty == false
  }()

  static func set(_ view: NSView, for key: String) {
    views.setObject(view, forKey: key as NSString)
  }

  public static func view(for key: String) -> NSView? {
    views.object(forKey: key as NSString)
  }
}

private struct LiveSettingsControlAnchor: NSViewRepresentable {
  let key: String

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    LiveSettingsControlProbe.set(view, for: key)
  }
}
#endif
