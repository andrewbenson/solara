import AppKit

@MainActor
enum BookmarksBarMenuPresenter {
  static func show(_ items: [BookmarksBarMenuItem], in view: NSView, at point: CGPoint?, choose: @escaping (String) -> Void) {
    guard view.window != nil else { return }
    PageMenuTarget.show(make(items, choose: choose), in: view, at: point)
  }

  static func make(_ items: [BookmarksBarMenuItem], choose: @escaping (String) -> Void) -> NSMenu {
    let target = PageMenuTarget()
    func build(_ rows: [BookmarksBarMenuItem]) -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      for row in rows {
        if row.separator {
          menu.addItem(.separator())
          continue
        }
        let item = NSMenuItem(title: row.title, action: row.action != nil ? #selector(PageMenuTarget.run(_:)) : nil, keyEquivalent: "")
        item.target = target
        item.isEnabled = row.enabled
        item.state = row.checked ? .on : .off
        if let symbol = row.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if !row.children.isEmpty || row.symbol == "folder" { item.submenu = build(row.children) }
        if let choiceId = row.choiceId { item.representedObject = PageMenuAction { choose(choiceId) } }
        menu.addItem(item)
      }
      objc_setAssociatedObject(menu, &PageMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }
    return build(items)
  }
}
