import AppKit
import SolaraEngine
import Testing
@testable import SolaraUI

@MainActor
struct BookmarkRecoveryPageTests {
  @Test func recoveryNoticeKeepsNavigationAndRefusesEditEvents() {
    let model = BookmarksPageModel()
    model.apply(snapshot: BookmarkSnapshot(ready: true, readyForSync: false, recoveryMessage: "Read-only recovery", editsPaused: true, recoveryConflictCount: 2))
    var events: [BookmarksPageEvent] = []
    model.onEvent = { events.append($0) }
    model.emit(.open("https://saved.test/", .current))
    model.emit(.delete(["saved"]))
    model.emit(.edit("saved"))
    model.emit(.addBookmark(nil))
    model.emit(.importBookmarks)
    #expect(events == [.open("https://saved.test/", .current)])
    #expect(model.recoveryMessage == "Read-only recovery")
    #expect(model.recoveryConflictCount == 2)
  }
  @Test func barShowsRecoveryNoticeAlongsideOpenableBookmarks() {
    let bar = BookmarksBarView(favicons: PageFavicons(load: { _, _, _, _ in nil }))
    bar.frame = CGRect(x: 0, y: 0, width: 600, height: 30)
    let snapshot = BookmarksBarSnapshot(profileId: "p", items: [BookmarksBarItem(id: "saved", kind: .url, title: "Saved", url: "https://saved.test/")], hasOther: false, hideBookmarksBarImport: true, theme: [:])
    bar.update(snapshot, recoveryMessage: "Bookmarks are read-only")
    bar.layoutSubtreeIfNeeded()
    let controls = bar.subviews.filter { !$0.isHidden && $0.accessibilityRole() == .button }
    #expect(controls.contains { $0.accessibilityLabel() == "Saved" })
    #expect(controls.contains { $0.accessibilityLabel() == "Bookmark recovery" && $0.toolTip == "Bookmarks are read-only" })
  }
}
