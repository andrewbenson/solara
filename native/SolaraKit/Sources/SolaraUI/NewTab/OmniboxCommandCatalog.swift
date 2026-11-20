import SolaraOmnibox

struct OmniboxCommandDefinition {
  let id: String
  let title: String
  let icon: String
  let keywords: [String]?
  let needs: String
}

enum OmniboxCommandCatalog {
  static let base: [OmniboxCommandDefinition] = [
    OmniboxCommandDefinition(id: "newTab", title: "New Tab", icon: "plus", keywords: ["open tab"], needs: "always"),
    OmniboxCommandDefinition(id: "newWindow", title: "New Window", icon: "macwindow", keywords: nil, needs: "always"),
    OmniboxCommandDefinition(id: "newIncognitoWindow", title: "New Incognito Window", icon: "eyeglasses", keywords: ["private window", "incognito"], needs: "always"),
    OmniboxCommandDefinition(id: "closeTab", title: "Close Tab", icon: "xmark", keywords: nil, needs: "tab"),
    OmniboxCommandDefinition(id: "closeAllTabs", title: "Close All Tabs", icon: "xmark.square", keywords: ["clear unpinned tabs", "close unpinned tabs", "clear today"], needs: "always"),
    OmniboxCommandDefinition(id: "reopenClosedTab", title: "Reopen Closed Tab", icon: "arrow.uturn.backward", keywords: ["undo close", "restore tab"], needs: "always"),
    OmniboxCommandDefinition(id: "togglePin", title: "Move to Top Apps", icon: "pin", keywords: ["pin", "unpin", "pin tab", "unpin tab", "remove from top apps", "favorites"], needs: "tab"),
    OmniboxCommandDefinition(id: "togglePin:row", title: "Move to Pinned", icon: "list.bullet", keywords: ["pin", "pinned tabs", "pin as row", "move to pinned", "favorites"], needs: "tab"),
    OmniboxCommandDefinition(id: "duplicateTab", title: "Duplicate Tab", icon: "plus.square.on.square", keywords: nil, needs: "tab"),
    OmniboxCommandDefinition(id: "renameTab", title: "Rename Tab", icon: "pencil", keywords: nil, needs: "tab"),
    OmniboxCommandDefinition(id: "searchTabs", title: "Search Tabs", icon: "magnifyingglass", keywords: nil, needs: "always"),
    OmniboxCommandDefinition(id: "cleanUpTabs", title: "Clean Up Tabs", icon: "sparkles", keywords: ["tidy tabs"], needs: "always"),
    OmniboxCommandDefinition(id: "tidyPins", title: "Tidy Pins", icon: "sparkles", keywords: ["tidy pinned tabs", "organize pins", "pinned folders", "remove duplicate pins"], needs: "pins"),
    OmniboxCommandDefinition(id: "newGroupWithTabs", title: "New Group with Tab", icon: "folder.badge.plus", keywords: ["tab group"], needs: "tab"),
    OmniboxCommandDefinition(id: "reload", title: "Reload Page", icon: "arrow.clockwise", keywords: ["refresh"], needs: "page"),
    OmniboxCommandDefinition(id: "forceReload", title: "Force Reload Page", icon: "arrow.clockwise", keywords: ["hard reload", "hard refresh"], needs: "page"),
    OmniboxCommandDefinition(id: "toggleMute", title: "Mute Site", icon: "speaker.slash", keywords: ["mute", "unmute", "silence"], needs: "page"),
    OmniboxCommandDefinition(id: "copyUrl", title: "Copy URL", icon: "link", keywords: ["copy link"], needs: "page"),
    OmniboxCommandDefinition(id: "copyUrlAsMarkdown", title: "Copy URL as Markdown", icon: "link", keywords: ["markdown link"], needs: "page"),
    OmniboxCommandDefinition(id: "findInPage", title: "Find in Page", icon: "text.magnifyingglass", keywords: nil, needs: "page"),
    OmniboxCommandDefinition(id: "bookmarkPage", title: "Bookmark This Page", icon: "bookmark", keywords: ["add bookmark", "bookmark"], needs: "page"),
    OmniboxCommandDefinition(id: "print", title: "Print", icon: "printer", keywords: nil, needs: "page"),
    OmniboxCommandDefinition(id: "share", title: "Share", icon: "square.and.arrow.up", keywords: ["airdrop", "share link", "send link"], needs: "page"),
    OmniboxCommandDefinition(id: "zoomIn", title: "Zoom In", icon: "plus.magnifyingglass", keywords: nil, needs: "page"),
    OmniboxCommandDefinition(id: "zoomOut", title: "Zoom Out", icon: "minus.magnifyingglass", keywords: nil, needs: "page"),
    OmniboxCommandDefinition(id: "zoomReset", title: "Actual Size", icon: "1.magnifyingglass", keywords: ["reset zoom"], needs: "page"),
    OmniboxCommandDefinition(id: "devTools", title: "Developer Tools", icon: "hammer", keywords: ["inspect", "devtools", "console"], needs: "page"),
    OmniboxCommandDefinition(id: "toggleDeveloperMode", title: "Turn on Developer Mode for this site", icon: "hammer", keywords: ["developer mode", "dev mode", "localhost", "devtools"], needs: "site"),
    OmniboxCommandDefinition(id: "toggleFullUrl", title: "Show Full URL", icon: "text.alignleft", keywords: nil, needs: "always"),
    OmniboxCommandDefinition(id: "toggleSidebar", title: "Auto-Hide Tabs", icon: "sidebar.left", keywords: ["toggle sidebar", "hide sidebar", "show sidebar", "focus mode"], needs: "always"),
    OmniboxCommandDefinition(id: "toggleBookmarksBar", title: "Toggle Bookmarks Bar", icon: "menubar.rectangle", keywords: ["bookmarks bar"], needs: "always"),
    OmniboxCommandDefinition(id: "downloads", title: "Downloads", icon: "arrow.down.circle", keywords: ["show downloads", "dl"], needs: "always"),
    OmniboxCommandDefinition(id: "showHistory", title: "History", icon: "clock", keywords: ["show history"], needs: "always"),
    OmniboxCommandDefinition(id: "manageBookmarks", title: "Bookmarks", icon: "book", keywords: ["manage bookmarks", "show bookmarks"], needs: "always"),
    OmniboxCommandDefinition(id: "openSettings", title: "Settings", icon: "gearshape", keywords: ["preferences", "prefs", "options"], needs: "always"),
    OmniboxCommandDefinition(id: "clearBrowsingData", title: "Clear Browsing Data", icon: "trash", keywords: ["clear history", "clear cache", "clear cookies"], needs: "always"),
    OmniboxCommandDefinition(id: "importBrowserData", title: "Import Browser Data", icon: "square.and.arrow.down", keywords: ["import bookmarks", "import passwords"], needs: "always"),
    OmniboxCommandDefinition(id: "keyboardShortcuts", title: "Keyboard Shortcuts", icon: "keyboard", keywords: ["shortcuts", "hotkeys"], needs: "always"),
    OmniboxCommandDefinition(id: "reportBug", title: "Report a Bug", icon: "ladybug", keywords: ["bug", "report bug", "file an issue", "crash"], needs: "always"),
    OmniboxCommandDefinition(id: "mergeAllWindows", title: "Merge All Windows", icon: "rectangle.stack", keywords: nil, needs: "profiles"),
    OmniboxCommandDefinition(id: "newProfile", title: "New Profile", icon: "person.crop.circle.badge.plus", keywords: ["create profile"], needs: "profiles"),
    OmniboxCommandDefinition(id: "setAppearance:dark", title: "Dark Appearance", icon: "moon", keywords: ["dark mode"], needs: "always"),
    OmniboxCommandDefinition(id: "setAppearance:light", title: "Light Appearance", icon: "sun.max", keywords: ["light mode"], needs: "always"),
    OmniboxCommandDefinition(id: "setAppearance:auto", title: "Use System Appearance", icon: "circle.lefthalf.filled", keywords: ["auto appearance", "system appearance"], needs: "always"),
  ]
}
