import AppKit

@MainActor
enum BookmarksBarMenuPresenter {
  static func show(_ items: [BookmarksBarMenuItem], in view: NSView, at point: CGPoint?, selectFirst: Bool = false, choose: @escaping (String) -> Void) {
    guard view.window != nil else { return }
    let menu = make(items, choose: choose)
    if selectFirst {
      menu.popUp(positioning: menu.items.first { $0.isEnabled && !$0.isSeparatorItem }, at: point ?? .zero, in: view)
    } else {
      PageMenuTarget.show(menu, in: view, at: point)
    }
  }

  static func make(_ items: [BookmarksBarMenuItem], choose: @escaping (String) -> Void) -> NSMenu {
    let menu = NSMenu()
    populate(items, in: menu, target: PageMenuTarget(), choose: choose)
    return menu
  }

  fileprivate static func populate(_ rows: [BookmarksBarMenuItem], in menu: NSMenu, target: PageMenuTarget, choose: @escaping (String) -> Void) {
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
      if !row.children.isEmpty || row.symbol == "folder" {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let delegate = BookmarksBarSubmenu(rows: row.children, target: target, choose: choose)
        submenu.delegate = delegate
        objc_setAssociatedObject(submenu, &BookmarksBarSubmenu.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        item.submenu = submenu
      }
      if let choiceId = row.choiceId { item.representedObject = PageMenuAction { choose(choiceId) } }
      menu.addItem(item)
    }
    objc_setAssociatedObject(menu, &PageMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
  }
}

@MainActor
private final class BookmarksBarSubmenu: NSObject, NSMenuDelegate {
  nonisolated(unsafe) static var key = 0
  private var rows: [BookmarksBarMenuItem]?
  private let target: PageMenuTarget
  private let choose: (String) -> Void

  init(rows: [BookmarksBarMenuItem], target: PageMenuTarget, choose: @escaping (String) -> Void) {
    self.rows = rows
    self.target = target
    self.choose = choose
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard let rows else { return }
    self.rows = nil
    BookmarksBarMenuPresenter.populate(rows, in: menu, target: target, choose: choose)
  }
}
