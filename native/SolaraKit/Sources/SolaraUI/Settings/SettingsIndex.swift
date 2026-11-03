import Foundation

public struct SettingEntry: Hashable, Sendable, Identifiable {
  public let id: String
  public let pane: SettingsPane
  public let section: String
  public let title: String
  public let description: String?
  public let caption: String?
  public let keywords: [String]
  public let liquidGlassOnly: Bool

  public var paneTitle: String { pane.title }
  public var displayCaption: String? { caption ?? description }
}

public struct SettingsIndex: Sendable {
  public let appName: String
  public let entries: [SettingEntry]
  private let byId: [String: SettingEntry]

  public init(appName: String) {
    self.appName = appName
    entries = SettingsIndex.rows(app: appName)
    byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
  }

  public subscript(id: String) -> SettingEntry {
    guard let entry = byId[id] else { preconditionFailure("no setting \(id)") }
    return entry
  }

  public func entry(_ id: String) -> SettingEntry? { byId[id] }

  private struct Row {
    let key: String
    let title: String
    var description: String? = nil
    var caption: String? = nil
    var keywords: [String] = []
    var liquidGlassOnly = false
  }

  private struct Section {
    let section: String
    let rows: [Row]
  }

  private static func rows(app: String) -> [SettingEntry] {
    let sections = table(app: app)
    return SettingsPane.allCases.flatMap { pane in
      (sections[pane] ?? []).flatMap { section in
        section.rows.map { row in
          SettingEntry(
            id: "\(pane.rawValue).\(row.key)",
            pane: pane,
            section: section.section,
            title: row.title,
            description: row.description,
            caption: row.caption,
            keywords: row.keywords,
            liquidGlassOnly: row.liquidGlassOnly
          )
        }
      }
    }
  }

  private static func table(app: String) -> [SettingsPane: [Section]] {
    let cli = app.lowercased()
    return [
      .general: [
        Section(section: "General", rows: [
          Row(key: "defaultBrowser", title: "Default browser", description: "Make \(app) your default browser.", keywords: ["default", "set as default", "links"]),
          Row(key: "openAtLogin", title: "Open \(app) at login", keywords: ["startup", "launch", "login items", "boot"]),
          Row(key: "warnBeforeQuitting", title: "Warn before quitting", description: "Asks before \(app) quits with ⌘Q.", keywords: ["quit", "confirm", "cmd q"]),
          Row(
            key: "warnBeforeClosingWindow",
            title: "Warn before closing a window with multiple tabs",
            description: "Asks before ⇧⌘W or the close button closes its tabs.",
            keywords: ["close window", "confirm"]
          ),
          Row(key: "openLinksFrom", title: "Open links from other apps in", keywords: ["little solara", "little \(cli)", "external links", "mini window", "discord", "slack", "mail"]),
          Row(key: "littleSolaraNewTabLinks", title: "Open new-tab links from Little \(app) in", keywords: ["little solara", "little \(cli)", "target blank", "new tab", "links", "mini window"]),
        ]),
        Section(section: "When quitting \(app):", rows: [
          Row(
            key: "windowsAndTabs",
            title: "Windows and tabs",
            description: "What you see the next time you open it. Closed windows stay in History › Recently Closed.",
            caption: "What you see the next time you open it.",
            keywords: ["restore", "session", "reopen", "preserve tabs", "start fresh"]
          ),
        ]),
        Section(section: "Command bar", rows: [
          Row(key: "commandBarPreference", title: "When input looks like a website", keywords: ["omnibox", "address", "url", "search", "website first"]),
        ]),
        Section(section: "Downloads", rows: [
          Row(key: "downloadsFolder", title: "Downloads folder", description: "Where downloaded files are saved.", keywords: ["download location", "save to", "path", "folder"]),
          Row(key: "askWhereToSave", title: "Ask where to save each file", keywords: ["download location", "save as", "prompt", "choose folder"]),
          Row(
            key: "downloadsAllProfiles",
            title: "Use these settings for every profile",
            description: "Gives every profile this folder and choice.",
            keywords: ["all profiles", "global", "download location"]
          ),
        ]),
        Section(section: "Import", rows: [
          Row(
            key: "importBrowser",
            title: "Import from another browser",
            description: "Bookmarks, history, passwords, tabs and Arc spaces from Chrome, Arc, Safari, Firefox and more.",
            caption: "Import bookmarks, history, passwords, tabs and Arc spaces from another browser.",
            keywords: ["migrate", "switch", "transfer"]
          ),
        ]),
      ],
      .profiles: [
        Section(section: "New windows open with", rows: [
          Row(key: "defaultProfile", title: "Default profile", description: "Used for new windows. Links from other apps open in the profile you used last.", keywords: ["new window"]),
        ]),
        Section(section: "Profiles", rows: [
          Row(key: "list", title: "Profiles", description: "Drag to reorder. ⌃1–⌃9 switch to the first nine.", keywords: ["create profile", "new profile", "delete profile", "reorder", "work", "personal"]),
        ]),
      ],
      .sync: [
        Section(section: "Sync", rows: [
          Row(
            key: "sync",
            title: "Sync",
            description: "Sync your profiles, bookmarks, history, tabs, passwords, extensions and settings across your Macs.",
            caption: "Sync your browsing data and settings across your Macs.",
            keywords: ["icloud", "recovery phrase", "devices", "turn on sync", "end to end", "encrypted"]
          ),
          Row(key: "folder", title: "Sync folder", keywords: ["icloud drive", "dropbox", "folder"]),
        ]),
      ],
      .tabs: [
        Section(section: "Tab layout", rows: [
          Row(key: "layout", title: "Tab layout", description: "In the sidebar or across the top of the window.", keywords: ["vertical tabs", "horizontal tabs", "top tabs", "sidebar"]),
        ]),
        Section(section: "Tab layout", rows: [
          Row(
            key: "hideToolbarWhileScrolling",
            title: "Hide toolbar while scrolling",
            description: "Scrolling down tucks the toolbar into a thin strip with the site's name. Scroll up, or click the strip, to bring it back.",
            caption: "Scrolling down tucks the toolbar into a thin strip; scroll up to bring it back.",
            keywords: ["auto hide", "compact"]
          ),
          Row(key: "showSidebarButton", title: "Show sidebar button", description: "⌘S and View › Auto-Hide Tabs still hide and show the sidebar.", keywords: ["toggle sidebar"]),
          Row(
            key: "showClearButton",
            title: "Show Clear button",
            description: "The ↓ Clear between your pinned tabs and your tabs. ⇧⌘K and File › Close All Tabs still clear them.",
            caption: "Shows ↓ Clear between your pinned tabs and your tabs.",
            keywords: ["clear unpinned tabs", "close all tabs", "clear today", "divider", "arc"]
          ),
          Row(
            key: "balancedTopApps",
            title: "Grow Top Apps as the sidebar widens",
            description: "As in Arc: up to four tiles across in balanced rows, and a wider sidebar makes them larger. Off, as in Dia, each row fills with as many tiles as fit.",
            caption: "Shows up to four tiles across in balanced rows that grow as the sidebar widens.",
            keywords: ["pinned tiles", "favorites", "grid", "columns", "rows", "arc"]
          ),
          Row(
            key: "classicPinnedTabs",
            title: "Make the pinned tab you're on stand out",
            description: "The Top App you're on is raised, with a faint tint and ring in its icon's colors, and the others sit flat. Off, every Top App is raised glass, as before.",
            caption: "Raises the selected Top App and tints it in its icon's colors; the others sit flat.",
            keywords: ["dia", "liquid glass", "top apps", "pinned tabs", "favicon", "colour", "color", "icon ring", "tint", "selected tile", "active", "flat", "raised"]
          ),
          Row(
            key: "fadeUnloadedTabs",
            title: "Fade icons of unloaded tabs",
            description: "A tab whose page isn't loaded, like a closed pinned tab or one restored after a relaunch, shows its icon faded, as sleeping tabs do. Clicking it loads the page.",
            caption: "Fades icons of tabs whose pages aren't loaded; clicking a tab loads its page.",
            keywords: ["unloaded", "asleep", "sleeping", "discarded", "dim", "grey", "gray", "inactive", "pinned", "closed"]
          ),
        ]),
        Section(section: "General", rows: [
          Row(
            key: "newTabOpens",
            title: "New tab opens",
            description: "With Command Bar, ⌘T and New Tab open the command bar over the page, as in Arc. The tab appears when you pick a result; Esc leaves everything as it was.",
            caption: "With Command Bar, ⌘T opens the command bar; the tab appears when you pick a result.",
            keywords: ["new tab page", "command bar", "cmd t"]
          ),
          Row(
            key: "newTabPosition",
            title: "Add new tabs",
            description: "Where ⌘T and + New Tab put the new tab. Next to the current tab, it joins that tab's group (from a pinned tab, it goes first in the list), and closing it brings you back. Links open next to their page either way.",
            caption: "Where ⌘T and + New Tab put the new tab. Links open next to their page either way.",
            keywords: ["new tab position", "next to current tab", "after current tab", "beside", "right of", "below", "adjacent", "end", "left", "top", "bottom", "order", "cmd t"]
          ),
          Row(
            key: "newTabButtonPosition",
            title: "New Tab button",
            description: "Where + New Tab sits in the sidebar, whatever Add new tabs says. At the top it stays above your tabs and scrolls with them; at the bottom it follows your last tab and stays at the sidebar's bottom edge once the tabs fill it.",
            caption: "Where + New Tab sits in the sidebar, whatever Add new tabs says.",
            keywords: ["new tab button", "plus", "+", "top", "bottom", "sticky", "docked", "position"]
          ),
          Row(
            key: "shareTabsAcrossWindows",
            title: "Share tabs across windows",
            description: "Every window of a profile lists the same tabs, as in Arc. A tab is live in one window at a time: selecting it in another brings it there, and the first window shows it grayed until you click it. Each window keeps its own selected tab.",
            caption: "Every window of a profile lists the same tabs; each tab is live in one window at a time.",
            keywords: ["arc", "multiple windows", "same tabs", "sync windows", "shared sidebar", "unpinned"]
          ),
          Row(key: "tabReorderHaptics", title: "Haptic feedback when reordering tabs", keywords: ["trackpad", "vibration", "drag"]),
          Row(key: "extendWebsiteColor", title: "Extend website color into tab bar", keywords: ["theme color", "tint", "colour"]),
          Row(
            key: "sidebarMediaControls",
            title: "Show media controls in the sidebar",
            description: "When a tab you're not looking at plays sound, a player appears at the bottom of the sidebar. Pinned tabs that are playing show one when you hover them.",
            caption: "When another tab plays sound, a player appears at the bottom of the sidebar.",
            keywords: ["music", "player", "audio", "now playing"]
          ),
          Row(
            key: "autoPictureInPicture",
            title: "Automatic Picture in Picture",
            description: "A video or call you're watching pops out when you switch tabs or leave the window, and returns when you come back.",
            caption: "Pops out the video or call you're watching when you switch tabs or leave the window.",
            keywords: ["pip", "video", "floating", "mini player"]
          ),
          Row(
            key: "videoUpscaling",
            title: "Video upscaling",
            description: "Sharpens low-resolution videos shown larger than they are, on Apple silicon. Only in the tab you're watching, never in the background, in Low Power Mode or when the Mac runs hot.",
            caption: "Sharpens low-resolution videos shown larger than they are, on Apple silicon.",
            keywords: ["super resolution", "sharpen", "video quality"]
          ),
        ]),
        Section(section: "Links", rows: [
          Row(
            key: "peekModifier",
            title: "Peek a link with",
            description: "Opens the link in a preview over the page. Open as Tab or Split View keeps it; Esc closes it.",
            caption: "Opens the link in a preview over the page; Esc closes it.",
            keywords: ["peek", "preview", "shift click", "option click", "arc"]
          ),
          Row(
            key: "splitLinkModifier",
            title: "Open a link in split view with",
            description: "Opens the link in a pane beside the page. ⌥⌘-click splits too, and so does ⌥⇧-click when ⌥-click is chosen. A link that downloads still downloads.",
            caption: "Opens the link in a pane beside the page.",
            keywords: ["split view", "split screen", "side by side", "option click", "alt click", "option shift click", "download", "dia"]
          ),
        ]),
        Section(section: "Tab groups", rows: [
          Row(
            key: "warnBeforeClosingTabGroup",
            title: "Warn before closing a tab group",
            description: "Asks before Close Group closes a group and its tabs. A pinned group's − unloads its tabs instead, and keeps the group.",
            caption: "Asks before Close Group closes a group and its tabs.",
            keywords: ["confirm", "close group", "folder", "accidentally"]
          ),
          Row(key: "cmdClickCreatesTabGroup", title: "⌘-clicking links creates tab groups", keywords: ["command click", "cmd click"]),
          Row(
            key: "optShiftClickOpensInGroup",
            title: "⌥⇧-click opens tab in group",
            description: "⌥⇧-click a tab to open it in a group with the current tab. (⌥⇧-clicking a link opens it in a split.)",
            caption: "⌥⇧-click a tab to open it in a group with the current tab.",
            keywords: ["option shift click", "split"]
          ),
          Row(key: "autoGroupMeetingTabs", title: "Automatically group tabs for meetings", keywords: ["calendar", "zoom", "meet", "call"]),
        ]),
        Section(section: "Clean up", rows: [
          Row(
            key: "cleanUp",
            title: "Clean up tabs I haven't used in",
            description: "Closes tabs you haven't used (and duplicates) automatically, like the tab menu's Clean Up Daily.",
            caption: "Automatically closes tabs you haven't used and duplicates.",
            keywords: ["archive", "auto close", "inactive tabs", "duplicates"]
          ),
        ]),
      ],
      .appearance: [
        Section(section: "Appearance Theme", rows: [
          Row(key: "theme", title: "Appearance Theme", description: "Also in View › Appearance. Incognito windows are always dark.", keywords: ["dark mode", "light mode", "automatic", "night", "system"]),
          Row(
            key: "spacesFollowAppearance",
            title: "Profile themes follow this appearance",
            description: "Every profile goes light or dark with this choice, even when its theme (like one imported from an Arc space) says Light. In dark mode a light theme's colours are darkened so white text reads.",
            caption: "Every profile goes light or dark with this choice, even if its theme says Light.",
            keywords: ["space", "profile theme", "arc theme", "follow system"]
          ),
        ]),
        Section(section: "Address Bar", rows: [
          Row(key: "addressBar", title: "Address Bar", description: "In the toolbar or in the sidebar.", keywords: ["url bar", "location bar", "toolbar"]),
          Row(
            key: "commandBarPlacement",
            title: "⌘L opens the command bar",
            description: "In the centre, ⌘L and a click on the address show it over the middle of the page, as in Arc.",
            caption: "In the centre, ⌘L and a click on the address show the command bar over the page.",
            keywords: ["cmd l", "command bar", "centred", "centered", "arc", "url bar", "location bar"]
          ),
        ]),
        Section(section: "Selected Tab", rows: [
          Row(
            key: "selectedTabGlow",
            title: "Glow around the selected tab",
            description: "The soft light around the selected tab in the sidebar. Full is Dia's.",
            caption: "The soft light around the selected tab in the sidebar.",
            keywords: ["glow", "shadow", "halo", "highlight", "selected tab", "active tab"]
          ),
        ]),
        Section(section: "Scroll Bars", rows: [
          Row(
            key: "pageScrollBars",
            title: "Scroll bars",
            description: "Follow macOS uses System Settings › Appearance › Show scroll bars. Thin shows slim scroll bars over the page only while you scroll, even with a mouse.",
            caption: "Follow macOS uses your system setting; Thin shows scroll bars only while you scroll.",
            keywords: ["scrollbar", "scroll bar", "overlay", "thin", "mouse", "trackpad"]
          ),
        ]),
        Section(section: "App Icon", rows: [
          Row(key: "appIcon", title: "App Icon", description: "Shown in the Dock and the app switcher. The Dock keeps it after you quit.", keywords: ["dock icon", "logo"]),
        ]),
      ],
      .privacy: [
        Section(section: "Content blocking", rows: [
          Row(key: "blockAds", title: "Block ads", keywords: ["ad blocker", "adblock", "ublock origin", "easylist"]),
          Row(key: "blockTrackers", title: "Block trackers", keywords: ["tracking", "easyprivacy", "fingerprinting"]),
          Row(key: "blockCookieBanners", title: "Block cookie banners", keywords: ["cookies", "consent", "gdpr", "popups"]),
          Row(
            key: "filterLists",
            title: "Advanced Settings",
            description: "Block common components found across the web by using additional rules and filters.",
            keywords: ["filter lists", "annoyances", "malware", "regional", "ad block settings"]
          ),
        ]),
        Section(section: "Site permissions", rows: [
          Row(
            key: "sitePermissions",
            title: "Site permissions",
            description: "Pop-ups, camera, location and other permissions you've set for sites.",
            keywords: ["camera", "microphone", "location", "notifications", "popups", "cookies", "javascript", "clear site data", "website settings"]
          ),
        ]),
        Section(section: "Apps allowed to open links", rows: [
          Row(key: "appLinks", title: "Apps allowed to open links", description: "Sites that open another app without asking first.", keywords: ["external apps", "protocol handlers", "zoom links"]),
        ]),
      ],
      .passwords: [
        Section(section: "Passwords", rows: [
          Row(
            key: "offerToSave",
            title: "Offer to save and fill passwords",
            description: "Offers to save a login after you sign in, and suggests saved ones when you click a login field.",
            caption: "Offers to save logins after sign-in and suggests saved ones in login fields.",
            keywords: ["password manager", "logins", "credentials", "keychain"]
          ),
          Row(key: "importPasswords", title: "Import passwords", description: "From a CSV exported by Chrome, Safari, Firefox, 1Password, Bitwarden…", keywords: ["csv", "logins"]),
          Row(key: "exportPasswords", title: "Export passwords", description: "To a CSV file. Anyone who can open the file can read your passwords.", keywords: ["csv", "backup", "logins"]),
          Row(key: "managerApps", title: "Password manager apps", keywords: ["1password", "bitwarden", "keepassxc", "proton pass"]),
        ]),
      ],
      .autofill: [
        Section(section: "Autofill", rows: [
          Row(key: "addresses", title: "Save and fill addresses", description: "Names, addresses, email addresses and phone numbers.", keywords: ["forms", "contact", "phone", "email"]),
          Row(key: "cards", title: "Save and fill credit cards", description: "Filling in or showing a card number asks for Touch ID or your password.", keywords: ["payment", "debit card", "forms"]),
        ]),
        Section(section: "Addresses", rows: [Row(key: "addressList", title: "Addresses", keywords: ["add address", "saved addresses"])]),
        Section(section: "Credit Cards", rows: [Row(key: "cardList", title: "Credit Cards", keywords: ["add card", "saved cards", "payment"])]),
      ],
      .extensions: [
        Section(section: "Extensions", rows: [
          Row(key: "installed", title: "Extensions", description: "Add features to \(app) with extensions from the Chrome Web Store. Each profile has its own.", caption: "Add features to \(app) with extensions from the Chrome Web Store.", keywords: ["add ons", "plugins", "installed"]),
        ]),
        Section(section: "Add extensions", rows: [
          Row(key: "webStore", title: "Chrome Web Store", description: "Browse the store; its Add to \(app) button installs here.", keywords: ["install extension"]),
          Row(key: "addLink", title: "Add from a link", description: "Paste a Chrome Web Store link or extension ID.", keywords: ["install extension", "url"]),
          Row(key: "unpacked", title: "Load unpacked extension", description: "For developers: load an extension folder with a manifest.json.", keywords: ["developer mode"]),
        ]),
      ],
      .search: [
        Section(section: "Default search engine", rows: [
          Row(key: "defaultEngine", title: "Default search engine", description: "Used by the command bar and the New Tab page.", keywords: ["google", "duckduckgo", "bing", "kagi", "ecosia"]),
        ]),
        Section(section: "Other search engines", rows: [
          Row(key: "otherEngines", title: "Other search engines", description: "Type a shortcut and press Tab in the command bar to search a site directly.", keywords: ["custom search", "site search", "keyword"]),
        ]),
        Section(section: "Suggestions", rows: [
          Row(key: "suggestions", title: "Show search suggestions", description: "Sends what you type to your search engine to suggest searches.", keywords: ["autocomplete"]),
        ]),
        Section(section: "Text selection", rows: [
          Row(
            key: "showSelectionSearch",
            title: "Show search button when selecting text",
            description: "Shows a Search button above text you select on a page.",
            keywords: ["selection", "selected text", "popover", "popup", "highlight"]
          ),
        ]),
      ],
      .shortcuts: [
        Section(section: "Keyboard Shortcuts", rows: [
          Row(
            key: "undoReopensClosedTab",
            title: "⌘Z reopens closed tabs",
            description: "Outside text fields, as in Arc; press it again for the tab closed before. In a text field ⌘Z still undoes typing.",
            caption: "Outside text fields, reopens closed tabs; in text fields, undoes typing.",
            keywords: ["undo", "undo close tab", "reopen", "restore tab", "arc", "cmd z"]
          ),
          Row(key: "actions", title: "Customize keyboard shortcuts", keywords: ["hotkeys", "keybindings", "remap", "menu shortcuts"]),
        ]),
        Section(section: "Extensions", rows: [
          Row(key: "extensionShortcuts", title: "Extension shortcuts", description: "Shortcuts that extensions add, like opening their popup.", keywords: ["hotkeys"]),
        ]),
      ],
      .liveFolders: [
        Section(section: "Live folders", rows: [
          Row(key: "folders", title: "Live folders", description: "Live folders refresh every few minutes; items open as tabs that stay in the folder.", keywords: ["new live folder", "hidden", "refresh"]),
          Row(key: "groupStacks", title: "Group stacked pull requests", description: "Pull requests based on each other's branches sit together under one row.", keywords: ["stack", "stacked pull requests"]),
          Row(key: "showCompleted", title: "Show completed pull requests", description: "Merged, closed and reviewed pull requests stay listed for a day under Completed.", keywords: ["completed", "merged", "closed"]),
        ]),
        Section(section: "Pull Requests", rows: [
          Row(key: "github", title: "GitHub", description: "Your open pull requests and the ones waiting for your review, with checks and conflicts.", keywords: ["pull requests", "connect"]),
        ]),
        Section(section: "Documents", rows: [
          Row(key: "notion", title: "Notion", description: "Pages recently edited in your workspace.", keywords: ["documents", "connect"]),
          Row(key: "gdrive", title: "Google Drive", description: "Documents recently changed in your Drive.", keywords: ["documents", "docs", "connect"]),
        ]),
      ],
      .calendar: [
        Section(section: "Live Calendar", rows: [
          Row(key: "access", title: "Calendar access", keywords: ["connect calendar", "google calendar", "outlook", "icloud"]),
        ]),
        Section(section: "Meeting alerts", rows: [
          Row(key: "nextAlert", title: "Show next meeting alert", keywords: ["reminder", "notification", "join"]),
          Row(key: "alertCondition", title: "Show alerts", description: "With Always, alerts also appear in Notification Center while you're in another app.", keywords: ["notifications"]),
        ]),
        Section(section: "Pinned calendar", rows: [
          Row(key: "preview", title: "Show calendar preview", description: "Hover a pinned calendar tab to see the rest of your day.", keywords: ["hover"]),
          Row(key: "timeToNext", title: "Show time to next meeting", description: "A badge on the pinned calendar tab within the hour before a meeting.", keywords: ["countdown", "badge"]),
        ]),
        Section(section: "Meetings", rows: [
          Row(
            key: "autoGroup",
            title: "Automatically group tabs for meetings",
            description: "Joining a call makes a tab group for it; links you open from the meeting join the group.",
            keywords: ["zoom", "meet", "call", "tab groups"]
          ),
        ]),
      ],
      .engines: [
        Section(section: "Default engine", rows: [
          Row(
            key: "defaultEngine",
            title: "Open pages in",
            description: "New pages open in this engine unless a website rule says otherwise.",
            keywords: ["engine", "webkit", "chromium", "safari", "drm", "netflix", "fairplay", "widevine"]
          ),
          Row(
            key: "recommendedDefault",
            title: "Use Recommended Default",
            description: "Chromium runs extensions and the ad blocker. Sites that need protected video can still open in WebKit.",
            caption: "Chromium runs extensions and the ad blocker.",
            keywords: ["reset", "recommended", "chromium"]
          ),
          Row(
            key: "protectedVideo",
            title: "Open streaming sites in WebKit",
            description: "Netflix, Disney+, Max, Prime Video, Hulu, Apple TV+, Spotify and other sites whose video is protected open in WebKit, which plays it. A website rule wins.",
            caption: "Protected video sites open in WebKit unless a website rule says otherwise.",
            keywords: ["drm", "netflix", "disney", "hbo", "max", "prime video", "hulu", "spotify", "apple tv", "fairplay", "widevine", "streaming"]
          ),
        ]),
        Section(section: "Website rules", rows: [
          Row(
            key: "websiteRules",
            title: "Website rules",
            description: "Sites that always open in a chosen engine. Links opened from a page stay on that page's engine.",
            caption: "Sites that always open in a chosen engine.",
            keywords: ["opens in", "site engine", "rule", "webkit", "chromium"]
          ),
        ]),
        Section(section: "How engines differ", rows: [
          Row(
            key: "separateData",
            title: "Separate sign-ins",
            description: "Each engine keeps its own cookies and site data in every profile. Spaces, tabs, history and settings are shared.",
            caption: "Each engine keeps its own cookies and site data in every profile.",
            keywords: ["cookies", "site data", "sign in", "logged out"]
          ),
          Row(
            key: "chromiumOnly",
            title: "Extensions and ad blocking are Chromium only",
            description: "WebKit pages run without extensions or the ad blocker for now.",
            keywords: ["extensions", "ad blocker", "ublock", "content blocker"]
          ),
          Row(
            key: "passkeys",
            title: "Passkeys",
            description: "WebKit pages can't use passkeys until Apple grants \(app) its browser passkey entitlement. Sign in with a passkey in Chromium meanwhile.",
            caption: "WebKit pages can't use passkeys yet; sign in with a passkey in Chromium.",
            keywords: ["passkey", "webauthn", "icloud keychain", "passwords app", "security key"]
          ),
        ]),
      ],
      .advanced: [
        Section(section: "Browsing", rows: [
          Row(key: "showFullUrl", title: "Show full URL in the address bar", description: "Instead of the site alone.", keywords: ["address", "url", "https"]),
          Row(key: "warnMovingTabs", title: "Warn before moving tabs between profiles", description: "Some site data doesn't come along.", keywords: ["confirm"]),
          Row(key: "bookmarksImport", title: "Show the Import bookmarks button", description: "On an empty bookmarks bar.", keywords: ["bookmarks bar"]),
          Row(
            key: "developerMode",
            title: "Developer Mode sites",
            description: "Developer Mode adds console, network and inspect buttons and a reload menu. localhost is on until you turn it off.",
            caption: "Adds console, network and inspect buttons and a reload menu.",
            keywords: ["developer mode", "dev mode", "reset", "localhost", "console"]
          ),
        ]),
        Section(section: "Performance", rows: [
          Row(key: "batterySaver", title: "Battery Saver", keywords: ["energy", "low power mode", "performance", "power"]),
        ]),
        Section(section: "Data", rows: [
          Row(key: "history", title: "History", description: "Every page you visited, by day.", keywords: ["browsing history"]),
          Row(key: "downloads", title: "Downloads", description: "Files you downloaded, with where they're saved.", keywords: ["files"]),
        ]),
        Section(section: "Command line", rows: [
          Row(key: "cliControl", title: "Let the \(cli) command control \(app)", keywords: ["cli", "terminal", "devtools", "automation", "remote debugging"]),
          Row(key: "cliInstall", title: "The \(cli) command", keywords: ["cli", "terminal", "install"]),
        ]),
        Section(section: "Web engine", rows: [
          Row(key: "chromium", title: "Chromium", keywords: ["engine", "version", "solaracore"]),
          Row(key: "widevine", title: "Widevine (protected video)", keywords: ["drm", "netflix", "disney", "spotify"]),
        ]),
        Section(section: "Licenses", rows: [
          Row(key: "licenses", title: "Licenses", description: "Every open-source part of the engine, with its copyright and license.", keywords: ["credits", "legal"]),
        ]),
      ],
      .about: [
        Section(section: app, rows: [
          Row(key: "version", title: "\(app) version", keywords: ["version", "build", "about", "bug report", "channel"]),
          Row(key: "chromium", title: "Chromium", keywords: ["chromium", "engine", "version", "chrome"]),
          Row(key: "macOS", title: "macOS", keywords: ["os", "system", "version", "architecture", "apple silicon", "intel"]),
          Row(key: "copy", title: "Copy version information", description: "For bug reports.", keywords: ["copy", "bug report", "version", "support"]),
        ]),
        Section(section: "Updates", rows: [
          Row(key: "updateChecks", title: "Check for updates automatically", keywords: ["update", "sparkle"]),
          Row(key: "autoUpdate", title: "Automatically update \(app)", description: "Downloads updates in the background and installs them the next time it restarts.", keywords: ["update", "install"]),
          Row(key: "updateChannel", title: "Update channel", description: "Nightly gets every fix first. Switching back to Stable never downgrades.", keywords: ["nightly", "stable", "beta"]),
          Row(key: "checkNow", title: "Check for updates now", keywords: ["version", "update", "about"]),
        ]),
        Section(section: "License", rows: [
          Row(key: "license", title: "License", description: "\(app) is free software under the GNU General Public License v3.", keywords: ["gpl", "license", "open source", "legal"]),
          Row(key: "source", title: "Source code", keywords: ["github", "open source"]),
          Row(key: "copyright", title: "Copyright", keywords: ["credits", "notice", "legal", "author"]),
        ]),
      ],
    ]
  }
}
