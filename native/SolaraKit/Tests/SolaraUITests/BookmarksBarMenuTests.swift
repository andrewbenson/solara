import AppKit
import Foundation
import Testing
@testable import SolaraUI

struct BookmarksBarMenuTests {
  private let link = BookmarksBarItem(id: "url:one", kind: .url, title: "Example", url: "https://example.test/?utm_source=test", cleanUrl: "https://example.test/")

  private func snapshot(_ items: [BookmarksBarItem], mode: String = "newTab", other: BookmarksBarItem? = nil) -> BookmarksBarSnapshot {
    BookmarksBarSnapshot(profileId: "p", items: items, otherId: other?.id, hasOther: other != nil, hideBookmarksBarImport: false, theme: [:], barId: "bar", otherFolder: other, bookmarksBar: mode)
  }

  @Test func overflowPreservesRequestedOrderMissingIdsAndTheFirstDuplicate() {
    let duplicate = BookmarksBarItem(id: link.id, kind: .url, title: "Later duplicate", url: "https://later.example/")
    let other = BookmarksBarItem(id: "other", kind: .url, title: "Other", url: "https://other.example/")
    let model = BookmarksBarMenu(snapshot: snapshot([link, duplicate, other]), overflowIds: ["other", "missing", link.id, link.id])
    #expect(model.items(trigger: "overflow", id: nil).map(\.title) == ["Other", "Example", "Example"])
  }

  @Test func overflowLookupGrowsLinearlyWithTheBar() {
    func fastest(_ count: Int) -> Double {
      let items = (0..<count).map { BookmarksBarItem(id: "n\($0)", kind: .url, title: "Bookmark \($0)", url: "https://fixture.example/\($0)") }
      let model = BookmarksBarMenu(snapshot: snapshot(items), overflowIds: items.map(\.id))
      var fastest = Double.infinity
      for _ in 0..<3 {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let rows = model.items(trigger: "overflow", id: nil)
        fastest = min(fastest, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000)
        #expect(rows.count == count)
      }
      return fastest
    }
    let small = fastest(1000)
    let large = fastest(4000)
    #expect(large / max(small, 0.1) < 7, "Four times the bookmarks took \(large / max(small, 0.1)) times as long")
  }

  @Test func urlAndBlankMenusMatchTheReactNativeDefinitions() {
    let model = BookmarksBarMenu(snapshot: snapshot([link]), overflowIds: [])
    let items = model.items(trigger: "item", id: link.id)
    #expect(items.map(\.title) == ["Open in New Tab", "Open in New Window", "Open in Incognito Window", "Open in Split View", "", "Edit…", "Copy Link", "Delete", "", "Add Page…", "Add Folder…", "", "Manage Bookmarks", "Show Bookmarks Bar"])
    #expect(items.filter(\.separator).count == 3)
    #expect(items[0].choiceId == "tab:url:one")
    #expect(items[9].choiceId == "addPage:url:one")
    #expect(items.allSatisfy { $0.enabled })
    let blank = model.items(trigger: "blank", id: nil)
    #expect(blank.map(\.title) == ["Add Page…", "Add Folder…", "", "Manage Bookmarks", "Show Bookmarks Bar"])
    #expect(blank.last?.children.map(\.title) == ["Always", "On New Tab Only", "Never"])
    #expect(blank.last?.children.map(\.checked) == [false, true, false])
    #expect(blank.last?.children.map(\.choiceId) == ["bar:always", "bar:newTab", "bar:never"])
  }

  @Test func folderContextUsesPrecomputedFlagsAndOptionalRestore() {
    let folder = BookmarksBarItem(id: "f", kind: .folder, title: "Folder", children: [], folderLinks: 0, makesGroup: false, restorableArcHolder: true)
    let items = BookmarksBarMenu(snapshot: snapshot([folder]), overflowIds: []).items(trigger: "item", id: "f")
    #expect(items.map(\.title) == ["Open All (0)", "Open All in New Window", "Open All in Incognito Window", "Add to Sidebar as Group", "Restore Arc Folders as Groups", "", "Rename…", "Delete", "", "Add Page…", "Add Folder…", "", "Manage Bookmarks", "Show Bookmarks Bar"])
    #expect(items.prefix(4).allSatisfy { !$0.enabled })
    #expect(items[4].enabled)
    #expect(items[6].choiceId == "rename:f")
  }

  @Test func folderTreesPreserveOrderSymbolsEmptyAndFooterAndOverflowHasNoFooter() {
    let empty = BookmarksBarItem(id: "empty-folder", kind: .folder, title: "Empty folder", children: [])
    let folder = BookmarksBarItem(id: "f", kind: .folder, title: "Folder", children: [link, empty], folderLinks: 3, makesGroup: true)
    let model = BookmarksBarMenu(snapshot: snapshot([folder, link], other: folder), overflowIds: [link.id])
    let tree = model.items(trigger: "folder", id: "f")
    #expect(tree.map(\.title) == ["Example", "Empty folder", "", "Open All (3)", "Open All in New Window", "Open All in Incognito Window", "Add to Sidebar as Group"])
    #expect(tree.prefix(2).map(\.symbol) == ["globe", "folder"])
    #expect(tree[0].choiceId == "open:url:one")
    #expect(tree[1].children.map(\.title) == ["Empty"])
    #expect(tree[1].children.first?.enabled == false)
    #expect(tree[1].children.first?.choiceId == "empty")
    #expect(tree.last?.enabled == true)
    #expect(model.items(trigger: "other", id: nil) == tree)
    #expect(model.items(trigger: "overflow", id: nil).map(\.title) == ["Example"])
    #expect(model.items(trigger: "import", id: nil).map(\.title) == ["Hide Import Bookmarks Button"])
    #expect(model.items(trigger: "folder", id: "missing").isEmpty)
    #expect(model.choice(trigger: "folder", id: "f", choiceId: "empty") == nil)
    #expect(model.choice(trigger: "folder", id: "f", choiceId: "open:url:one")?.id == "url:one")
  }

  @Test func depthEightFolderSubmenusStayEmpty() {
    var child = BookmarksBarItem(id: "depth-8", kind: .folder, title: "8", children: [])
    for depth in (0..<8).reversed() {
      child = BookmarksBarItem(id: "depth-\(depth)", kind: .folder, title: "\(depth)", children: [child])
    }
    let items = BookmarksBarMenu(snapshot: snapshot([child]), overflowIds: [child.id]).items(trigger: "overflow", id: nil)
    var deepest = items[0]
    for _ in 0..<8 { deepest = deepest.children[0] }
    #expect(deepest.title == "8")
    #expect(deepest.children.isEmpty)
  }

  @Test func folderPressStartsItsDepthLimitOneLevelBelowOverflow() {
    var child = BookmarksBarItem(id: "depth-9", kind: .folder, title: "9", children: [link], folderLinks: 1, makesGroup: true)
    for depth in (0..<9).reversed() {
      child = BookmarksBarItem(id: "depth-\(depth)", kind: .folder, title: "\(depth)", children: [child], folderLinks: 1, makesGroup: true)
    }
    let model = BookmarksBarMenu(snapshot: snapshot([child]), overflowIds: [child.id])
    var overflow = model.items(trigger: "overflow", id: nil)[0]
    for _ in 0..<8 { overflow = overflow.children[0] }
    #expect(overflow.title == "8")
    #expect(overflow.children.isEmpty)
    var pressed = model.items(trigger: "folder", id: child.id)[0]
    for _ in 0..<8 { pressed = pressed.children[0] }
    #expect(pressed.title == "9")
    #expect(pressed.children.isEmpty)
  }

  @Test func allBarModesHaveExactlyOneCheckmarkAndDisabledChoicesAreRejected() {
    let empty = BookmarksBarItem(id: "empty", kind: .folder, title: "Empty", children: [])
    for (mode, checks) in [("always", [true, false, false]), ("newTab", [false, true, false]), ("never", [false, false, true])] {
      let model = BookmarksBarMenu(snapshot: snapshot([empty], mode: mode), overflowIds: [])
      #expect(model.items(trigger: "blank", id: nil).last?.children.map(\.checked) == checks)
      #expect(model.choice(trigger: "item", id: "empty", choiceId: "openAll:empty") == nil)
      #expect(model.choice(trigger: "item", id: "empty", choiceId: "addGroup:empty") == nil)
      #expect(model.choice(trigger: "blank", id: nil, choiceId: "show") == nil)
    }
  }

  @Test @MainActor func submenusMaterializeOnDemandOnceAndRetainNestedActions() throws {
    let nested = BookmarksBarItem(id: "nested", kind: .folder, title: "Nested", children: [link], folderLinks: 1, makesGroup: true)
    let many = (0..<3000).map { BookmarksBarItem(id: "large-\($0)", kind: .url, title: "Bookmark \($0)", url: "https://fixture.example/\($0)") }
    let folder = BookmarksBarItem(id: "large", kind: .folder, title: "Large", children: [nested] + many, folderLinks: 3001, makesGroup: true)
    let rows = BookmarksBarMenu(snapshot: snapshot([folder]), overflowIds: [folder.id]).items(trigger: "overflow", id: nil)
    var choices: [String] = []
    var menu: NSMenu? = BookmarksBarMenuPresenter.make(rows) { choices.append($0) }
    let submenu = try #require(menu?.items.first?.submenu)
    #expect(submenu.numberOfItems == 0)
    let delegate = try #require(submenu.delegate)
    delegate.menuNeedsUpdate?(submenu)
    #expect(submenu.numberOfItems == 3006)
    #expect(submenu.items.first?.title == "Nested")
    #expect(submenu.items.last?.title == "Add to Sidebar as Group")
    delegate.menuNeedsUpdate?(submenu)
    #expect(submenu.numberOfItems == 3006)
    let child = try #require(submenu.items.first?.submenu)
    #expect(child.numberOfItems == 0)
    menu = nil
    let childDelegate = try #require(child.delegate)
    childDelegate.menuNeedsUpdate?(child)
    #expect(child.items.map(\.title) == ["Example", "", "Open All (1)", "Open All in New Window", "Open All in Incognito Window", "Add to Sidebar as Group"])
    let item = try #require(child.items.first)
    let target = try #require(item.target as? NSObject)
    let action = try #require(item.action)
    _ = target.perform(action, with: item)
    #expect(choices == ["open:url:one"])
  }

  @Test @MainActor func appKitMenuPreservesFlagsSymbolsAndUsesTheChoiceSelector() throws {
    let folder = BookmarksBarItem(id: "f", kind: .folder, title: "Folder", children: [link], folderLinks: 1, makesGroup: false)
    let model = BookmarksBarMenu(snapshot: snapshot([folder]), overflowIds: [folder.id])
    var choices: [String] = []
    let menu = BookmarksBarMenuPresenter.make(model.items(trigger: "overflow", id: nil)) { choices.append($0) }
    #expect(!menu.autoenablesItems)
    let parent = try #require(menu.items.first)
    #expect(parent.title == "Folder")
    #expect(parent.image != nil)
    let submenu = try #require(parent.submenu)
    submenu.delegate?.menuNeedsUpdate?(submenu)
    #expect(submenu.items.map(\.title) == ["Example", "", "Open All (1)", "Open All in New Window", "Open All in Incognito Window", "Add to Sidebar as Group"])
    #expect(submenu.items[0].image != nil)
    #expect(submenu.items[1].isSeparatorItem)
    #expect(!submenu.items[5].isEnabled)
    let target = try #require(submenu.items[0].target as? NSObject)
    let action = try #require(submenu.items[0].action)
    _ = target.perform(action, with: submenu.items[0])
    #expect(choices == ["open:url:one"])
    let blank = BookmarksBarMenuPresenter.make(model.items(trigger: "blank", id: nil)) { _ in }
    let modes = try #require(blank.items.last?.submenu)
    modes.delegate?.menuNeedsUpdate?(modes)
    #expect(modes.items.map(\.state) == [.off, .on, .off])
  }

  @Test @MainActor func debugChoicesEmitTheSameActionAndCaptureCopyWithoutAPasteboard() throws {
    let view = BookmarksBarView(favicons: PageFavicons(load: { _, _, _, _ in nil }))
    view.update(snapshot([link]))
    var events: [(String, [String: Any])] = []
    view.onAction = { events.append(($0, $1)) }
    #expect(view.devChoose(trigger: "item", id: link.id, choiceId: "tab:url:one")["accepted"] as? Bool == true)
    #expect(events.last?.0 == "menuChoice")
    #expect(events.last?.1["action"] as? String == "tab")
    #expect(events.last?.1["id"] as? String == link.id)
    #expect(events.last?.1["profileId"] as? String == "p")
    let copy = view.devChoose(trigger: "item", id: link.id, choiceId: "copy:url:one")
    #expect(copy["copyText"] as? String == "https://example.test/")
    #expect(events.count == 1)
    #expect(view.devChoose(trigger: "blank", id: nil, choiceId: "delete:url:one")["accepted"] as? Bool == false)
  }
}
