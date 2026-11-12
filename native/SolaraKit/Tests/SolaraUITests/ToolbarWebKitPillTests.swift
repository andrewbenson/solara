import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarWebKitPillTests {
  static let pill = #"{"id":"webkit","icon":"safari","label":"WebKit","size":12,"box":24,"tooltip":"This page is open in WebKit","info":{"title":"This page is open in WebKit","message":"Extensions, password autofill and casting don't run here.","action":"Open Page in Chromium","actionId":"webkit:openInChromium"}}"#
  static let palette = ##"{"text":"#000000CC","secondary":"#00000080","icon":"#000000D4","iconDisabled":"#0000006E","hover":"#0000000F","pressed":"#0000001A","pill":"#0000000A","divider":"#0000001A"}"##

  static func state(extensions: String) -> ToolbarState {
    let json = """
      {"tabId":"t1","height":42,"bare":false,"focused":true,"palette":\(palette),"accent":"#0A84FF",
       "geometry":{"back":40,"forward":70,"reload":100,"urlLeft":130,"urlRight":40},"left":[],"right":[],"rightInset":8,
       "url":{"host":"example.com","restTrail":"","hoverTrail":"","hoverButtons":[],"trailing":[],"pinned":false},
       "extensions":[\(extensions)],"extensionsRight":8,"hairline":false}
      """
    return ToolbarState.decode(json)!
  }

  static func buttons(in view: NSView) -> [ToolbarButtonView] {
    view.subviews.flatMap { ($0 as? ToolbarButtonView).map { [$0] } ?? buttons(in: $0) }
  }

  static func fieldIn(_ view: NSView) -> ToolbarUrlFieldView? {
    for sub in view.subviews {
      if let field = sub as? ToolbarUrlFieldView { return field }
      if let found = fieldIn(sub) { return found }
    }
    return nil
  }

  @Test func theStateDecodesALabelAndItsInfo() throws {
    let button = try JSONDecoder().decode(ToolbarButtonState.self, from: Data(Self.pill.utf8))
    #expect(button.label == "WebKit")
    #expect(button.info?.action == "Open Page in Chromium")
    #expect(button.info?.actionId == "webkit:openInChromium")
  }

  @Test func aLabelledButtonIsAPillWiderThanItsBox() throws {
    let state = try JSONDecoder().decode(ToolbarButtonState.self, from: Data(Self.pill.utf8))
    let button = ToolbarButtonView(state: state, palette: Self.state(extensions: "").palette)
    let text = ceil(("WebKit" as NSString).size(withAttributes: [.font: ToolbarButtonView.labelFont]).width)
    #expect(button.width == text + 12 + 4 + 20)
    #expect(button.width > button.box)
  }

  @Test func inTheToolbarThePillTakesTheExtensionsPlaceAndTheAddressStopsBeforeIt() {
    let toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 42))
    toolbar.update(Self.state(extensions: Self.pill))
    toolbar.layoutSubtreeIfNeeded()
    let pill = Self.buttons(in: toolbar).first { $0.state.id == "webkit" }
    let field = Self.fieldIn(toolbar)
    #expect(pill != nil)
    #expect(pill?.frame.maxX == 592)
    #expect(pill?.frame.width == pill?.width)
    #expect((field?.frame.maxX ?? .infinity) <= (pill?.frame.minX ?? 0) - 6)
  }

  @Test func withoutThePillTheAddressKeepsItsWidth() {
    let toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 42))
    toolbar.update(Self.state(extensions: ""))
    toolbar.layoutSubtreeIfNeeded()
    #expect(Self.fieldIn(toolbar)?.frame.maxX == 560)
  }

  @Test func pressingThePillOpensItsInfoAndItsButtonAsksForChromium() {
    let toolbar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 42))
    var clicks: [String] = []
    toolbar.onClick = { clicks.append($0.id) }
    toolbar.update(Self.state(extensions: Self.pill))
    toolbar.layoutSubtreeIfNeeded()
    let pill = Self.buttons(in: toolbar).first { $0.state.id == "webkit" }
    pill?.onClick(ToolbarClick(id: "webkit", kind: .press))
    #expect(clicks.isEmpty)
    #expect(ToolbarInfoPopover.describe()?["action"] as? String == "Open Page in Chromium")
    #expect(ToolbarInfoPopover.pressAction())
    #expect(clicks == ["webkit:openInChromium"])
    #expect(ToolbarInfoPopover.describe() == nil)
  }

  @Test func theInfoContentShowsTheTitleMessageAndAction() throws {
    let info = try JSONDecoder().decode(ToolbarButtonState.self, from: Data(Self.pill.utf8)).info!
    let content = ToolbarInfoContent(info: info) {}
    _ = content.view
    #expect(content.titleField.stringValue == "This page is open in WebKit")
    #expect(content.messageField.stringValue.contains("Extensions, password autofill and casting"))
    #expect(content.button.title == "Open Page in Chromium")
    #expect(content.preferredContentSize.width == ToolbarInfoPopover.width)
  }

  @Test func inTheSidebarFieldThePillSitsAtTheRightEdgeAtItsOwnWidth() throws {
    let field = ToolbarUrlFieldView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
    let url = Self.state(extensions: "").url!
    let pill = try JSONDecoder().decode(ToolbarButtonState.self, from: Data(Self.pill.utf8))
    field.update(url, palette: Self.state(extensions: "").palette, accessory: [pill])
    field.layoutSubtreeIfNeeded()
    let shown = Self.buttons(in: field).first { $0.state.id == "webkit" }
    #expect(shown?.frame.width == shown?.width)
    #expect((shown?.frame.maxX ?? 0) <= 240 - 3)
  }
}
