#!/usr/bin/env python3
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--scratch", required=True)
args = parser.parse_args()
source = (Path(__file__).resolve().parents[1] / "ios/Menus.swift").read_text()
state = source[:source.index("protocol Rebindable")]
build = source[source.index("  private static func buildBookmarkMenus"):source.index("  private static func buildExtensions")]
folders = source[source.index("  private static func emptyItem"):source.index("  static func dockMenu")]
marker = "private final class BookmarkMenuUpdate"
delegate = source[source.index(marker):] if marker in source else ""
support = r'''
final class CommandItem: NSMenuItem {
  let command: String
  let arg: String?
  init(_ title: String, _ command: String, arg: String? = nil) {
    self.command = command
    self.arg = arg
    super.init(title: title, action: nil, keyEquivalent: "")
  }
  required init(coder: NSCoder) { fatalError() }
}
enum MainMenu {
  private static var bookmarkToFolder = NSMenu(title: "Add Bookmark to Folder")
  private static var bookmarks = NSMenu(title: "Bookmarks")
  private static var bookmarksFixedCount = 3
  static func prepare() {
    for index in 0..<3 { bookmarks.addItem(NSMenuItem(title: "Fixed \(index)", action: nil, keyEquivalent: "")) }
  }
  static func refresh() { buildBookmarkMenus(MenuState.current) }
  static var root: NSMenu { bookmarks }
  static var destinations: NSMenu { bookmarkToFolder }
'''
checks = r'''
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { print("FAIL: \(message)"); exit(1) }
}
func update(_ menu: NSMenu) {
  check(menu.delegate != nil, "lazy menu retains its delegate")
  menu.delegate?.menuNeedsUpdate?(menu)
}
func link(_ id: String, _ title: String) -> [String: Any] {
  ["id": id, "title": title, "url": "https://fixture.example/\(id)"]
}
func fixture(_ recent: String) -> [String: Any] {
  ["bookmarkFolders": [["id": "bulk", "title": "Large"]], "recentBookmarks": [link("recent", recent)],
   "bookmarksBar": [
    ["id": "holder", "title": "Space (Arc)", "children": [["id": "group", "title": "Group", "children": [link("web", "Web")]]]],
    ["id": "bulk", "title": "Large", "children": (0..<3000).map { link("n\($0)", "Bookmark \($0)") }],
    ["id": "empty", "title": "Empty folder", "children": [[String: Any]]()],
    link("fallback", "")], "otherBookmarks": [[String: Any]]()]
}
MainMenu.prepare()
MenuState.setBookmarks(fixture("Old recent"))
MainMenu.refresh()
check(MainMenu.root.numberOfItems == 3, "closed Bookmarks keeps only its fixed commands")
check(MainMenu.destinations.numberOfItems == 0, "closed destinations remains unmaterialized")
MenuState.setBookmarks(fixture("Latest recent"))
MainMenu.refresh()
let root = MainMenu.root
update(root)
check(root.items.map(\.title) == ["Fixed 0", "Fixed 1", "Fixed 2", "", "Recent Bookmarks", "Latest recent", "", "Bookmarks Bar", "Other Bookmarks"], "root reads latest snapshot and keeps fixed commands and sections")
update(root)
check(root.numberOfItems == 9, "repeated callback is idempotent")
update(MainMenu.destinations)
check(MainMenu.destinations.items.map(\.title) == ["Large", "", "New Folder…"], "destinations keeps folder order and footer")
let bar = root.items[7].submenu!
check(bar.numberOfItems == 0, "bar descendants stay unmaterialized")
update(bar)
check(bar.items.map(\.title) == ["Space (Arc)", "Large", "Empty folder", "https://fixture.example/fallback"], "folder ordering and untitled URL are preserved")
let holder = bar.items[0].submenu!
check(holder.numberOfItems == 0, "nested descendants stay unmaterialized")
update(holder)
check(holder.items.map(\.title) == ["Group", "", "Add to Sidebar as Group", "Restore Arc Folders as Groups"], "Arc holder footers are preserved")
check((holder.items.last as? CommandItem)?.command == "restoreArcFolders" && (holder.items.last as? CommandItem)?.arg == "holder", "Arc action retains command and identity")
let group = holder.items[0].submenu!
update(group)
check((group.items.first as? CommandItem)?.command == "openBookmark" && (group.items.first as? CommandItem)?.arg == "web", "leaf action retains command and identity")
let empty = bar.items[2].submenu!
update(empty)
check(empty.items.map(\.title) == ["Empty"] && !empty.items[0].isEnabled, "empty folder remains disabled placeholder")
let bulk = bar.items[1].submenu!
check(bulk.numberOfItems == 0, "3000 native leaves are deferred until folder opens")
update(bulk)
check(bulk.numberOfItems == 3002, "large folder and footer populate when requested")
let previous = ObjectIdentifier(root.items[7])
MenuState.setBookmarks(["bookmarksBar": [link("new-profile", "New profile")], "otherBookmarks": [[String: Any]]()])
MainMenu.refresh()
check(ObjectIdentifier(root.items[7]) == previous, "an edit does not rebuild closed native menus")
update(root)
let changed = root.items[4].submenu!
update(changed)
check(changed.items.map(\.title) == ["New profile"], "reopened root follows current profile snapshot")
NativeBookmarkMenuSource.read = { profile in
  check(profile == "native-profile", "native metadata preserves profile identity")
  return fixture("Native recent")
}
MenuState.setBookmarks(["bookmarkNative": ["profileId": "native-profile", "revision": 1]])
MainMenu.refresh()
update(root)
check(root.items[5].title == "Native recent", "native metadata resolves the authoritative menu source")
NativeBookmarkMenuSource.read = nil
MenuState.setBookmarks(["bookmarkNative": ["profileId": "not-ready", "revision": 2]])
MainMenu.refresh()
update(root)
check(!root.items.contains { $0.title == "Native recent" }, "unavailable native source clears the old profile menu")
print("PASS: native bookmark menus defer root and descendants, retain actions and refresh latest state")
'''
Path(args.scratch).mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="bookmark-menus-", dir=args.scratch) as directory:
    work = Path(directory)
    path = work / "main.swift"
    path.write_text(state + support + build + folders + "}\n" + delegate + checks)
    subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(work / "modules"), str(path), "-o", str(work / "test")], check=True, timeout=90)
    subprocess.run([str(work / "test")], check=True, timeout=30)
