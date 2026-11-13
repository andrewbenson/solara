# Setting Solara up from files

Solara reads settings, keyboard shortcuts and profile themes from plain JSON files, so you can keep them in your
dotfiles and get the same browser on every Mac. It applies them when it opens, before the first window draws, and
again every time you save one. Solara only ever reads these files; it never writes to them.

## Where

| File | Holds |
| --- | --- |
| `~/.config/solara/config.json` | settings, keybindings, which theme each profile uses |
| `~/.config/solara/themes/<name>.json` | one theme's colours, named in `config.json` |

The folder can be a symlink (into a dotfiles checkout, say). Solara doesn't create it; make it yourself:

```sh
mkdir -p ~/.config/solara/themes
```

Solara reads no files in safe mode. A test instance (one started with `SOLARA_DATA_DIR` or `SOLARA_BACKGROUND=1`) reads
the folder `SOLARA_CONFIG_DIR` names, and nothing at all without it, so tests never see your real files.

## What the file decides

A setting, shortcut or theme set in the file wins over Settings. Settings shows it greyed out with "Set in
~/.config/solara/config.json" under it, so the two never fight. Anything the file leaves out works exactly as it
does without a file, and you change it in Settings as usual.

What you chose in Settings is kept underneath. Take a key out of the file and Solara goes back to your Settings
choice. Values from the file are never saved into Solara's own data and never sync to your other Macs through
iCloud. Each Mac follows its own file.

## config.json

```json
{
  "settings": {
    "appearance": "dark",
    "sidebarWidth": 240,
    "showTabNumberHints": false,
    "newTabPosition": "nextToCurrent",
    "bookmarksBar": "newTab"
  },
  "keybindings": {
    "newLittleSolara": "cmd+alt+shift+n",
    "toggleSidebar": "⌘S",
    "print": ""
  },
  "theme": "ocean",
  "profiles": {
    "Work": { "theme": "forest" }
  }
}
```

Every part is optional, and `{}` is a valid file. The top level can hold only these keys:

- `settings`: setting names and values (see "Settings" below).
- `keybindings`: shortcut names and keys (see "Keybindings" below).
- `theme`: a theme for every profile.
- `profiles`: one theme per profile, by profile name (any case) or id. A profile entry wins over `theme`. An entry
  for a profile that doesn't exist yet takes effect when you create it.
- `$schema`: ignored, for editors.

### Settings

Setting names are the names Solara's settings store uses. Each value must have the type shown below.

| Key | Value |
| --- | --- |
| `warnBeforeQuitting` | true or false |
| `warnBeforeClosingWindow` | true or false |
| `restoreSession` | true or false |
| `loadAllProfilesAtLaunch` | true or false |
| `searchEngine` | a search engine id, such as `"google"`, `"duckduckgo"`, `"bing"` |
| `customSearchUrl` | a string |
| `customSearchEngines` | a list of `{ "id", "name", "keyword", "url" }` |
| `searchSuggestions` | true or false |
| `showSelectionSearch` | true or false |
| `commandBarPreference` | `"website"`, `"search"` |
| `tabLayout` | `"sidebar"`, `"top"` |
| `hideToolbarWhileScrolling` | true or false |
| `newTabPosition` | `"top"`, `"bottom"`, `"nextToCurrent"` |
| `newTabButtonPosition` | `"top"`, `"bottom"` |
| `newTabOpens` | `"page"`, `"commandBar"` |
| `warnBeforeClosingLastTab` | true or false |
| `undoReopensClosedTab` | true or false |
| `showTabNumberHints` | true or false |
| `warnBeforeMovingTabsToProfile` | true or false |
| `shareTabsAcrossWindows` | true or false |
| `tabReorderHaptics` | true or false |
| `extendWebsiteColor` | true or false |
| `cmdClickCreatesTabGroup` | true or false |
| `optShiftClickOpensInGroup` | true or false |
| `peekModifier` | `"shift"`, `"alt"`, `"off"` |
| `pinnedLinkTarget` | `"peek"`, `"tab"`, `"littleSolara"` |
| `splitLinkModifier` | `"altShift"`, `"alt"` |
| `autoGroupMeetingTabs` | true or false |
| `cleanUpInactiveTabsAfterHours` | hours from 1 to 8760, or null for never |
| `mutedSites` | a list of sites, like `["example.com"]` |
| `neverTranslateSites` | an object of language codes and sites |
| `autoPictureInPicture` | true or false |
| `videoUpscaling` | true or false |
| `sidebarMediaControls` | true or false |
| `hoverCardMemoryUsage` | true or false |
| `sidebarWidth` | points from 140 to 600 |
| `sidebarIconsOnly` | true or false |
| `showSidebarButton` | true or false |
| `showClearButton` | true or false |
| `balancedTopApps` | true or false |
| `pinnedTabIconRing` | true or false |
| `classicPinnedTabs` | true or false |
| `selectedTabGlow` | `"full"`, `"soft"`, `"off"` |
| `pageScrollBars` | `"system"`, `"thin"` |
| `fadeUnloadedTabs` | true or false |
| `showUnreadBadges` | true or false |
| `sleepInactiveTabs` | true or false |
| `sleepTabsAfterMinutes` | minutes from 1 to 10080 |
| `keepAwakeSites` | a list of sites |
| `warnBeforeClosingTabGroup` | true or false |
| `batterySaverWhen` | `"lowBattery"`, `"unplugged"`, `"never"` |
| `extensionSidePanelWidth` | points from 200 to 1200 |
| `showFullUrl` | true or false |
| `bookmarksBar` | `"always"`, `"newTab"`, `"never"` |
| `hideBookmarksBarImport` | true or false |
| `appearance` | `"auto"`, `"light"`, `"dark"` |
| `addressBar` | `"toolbar"`, `"sidebar"` |
| `commandBarPlacement` | `"field"`, `"centred"` |
| `spacesFollowAppearance` | true or false |
| `shortcutPrecedence` | an object of shortcut names and `"solara"`, `"website"` or `"both"` |
| `openLinksInLittleSolara` | true or false |
| `littleSolaraKeepsNewTabLinks` | true or false |
| `littleSolaraSize` | `[width, height]`, each from 200 to 10000 |
| `pageEngine` | `"chromium"`, `"webkit"` |
| `websiteEngines` | an object of sites and `"chromium"` or `"webkit"` |
| `protectedVideoInWebKit` | true or false |

The file can't set these. `allowJavaScriptFromAppleEvents` and `cliControl` let other apps and programs drive the
browser, so you can turn them on only in Settings. `shortcuts` goes under `keybindings`. `developerMode`,
`defaultProfileId` and `extensionSearchEngines` belong to a profile or an extension. Solara keeps `chosen`,
`inferred`, `migrations` and `keepAwakeAdoptedProfiles` itself.

### Keybindings

Keybindings use the same names and keys as Settings › Keyboard Shortcuts. To get an action's name, right-click its
row there and choose **Copy Name for config.json**. Write the keys in either of these forms:

- readable: `"cmd+shift+t"`, `"ctrl+alt+k"`, `"cmd+left"`, `"cmd+return"`, `"F5"`. The modifiers are `cmd`, `ctrl`,
  `alt` (or `opt`), `shift` and `fn`. Named keys are `tab`, `return`, `space`, `delete`, `forwarddelete`, `escape`,
  `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown` and `F1` to `F20`.
- as Settings shows them: `"⇧⌘T"`, `"⌥⌘W"`.

Use `""` or `"none"` to remove a shortcut. As in Settings, a shortcut needs ⌘ or ⌃ unless it's a function key. A
binding replaces that one action's shortcut. The file can't change Chrome's fixed shortcuts.

## Themes

A theme file sets the colours Solara's profile themes already have: the gradient, its angle, grain and texture, and
how strongly it tints. It can also give a separate look for dark mode.

`~/.config/solara/themes/ocean.json`:

```json
{
  "mode": "auto",
  "colors": ["#3366FF", "#00CCAA"],
  "angle": 135,
  "intensity": 0.6,
  "grain": 0.2,
  "texture": "grain",
  "translucency": 1,
  "dark": { "colors": ["#1A2A66", "#006655"], "intensity": 0.8 }
}
```

| Key | Value | Default |
| --- | --- | --- |
| `colors` | one to three hex colours, `"#RRGGBB"` or `"#RRGGBBAA"` | required |
| `mode` | `"auto"` (follow the app), `"light"`, `"dark"` | `"auto"` |
| `angle` | gradient angle in degrees | 135 |
| `intensity` | 0 to 1 | 0.6 |
| `grain` | 0 to 1 | 0 |
| `texture` | `"grain"`, `"sand"`, `"denim"`, `"tweed"` | `"grain"` |
| `translucency` | 0 to 1 | 1 |
| `dark` | the same keys except `mode`, for the dark look | none |

In place of `colors` you can write `stops`, as Solara stores them:
`[{ "color": { "r": 0.2, "g": 0.4, "b": 1, "a": 1 }, "x": 0.8, "y": 0.6 }]`.

A profile that takes its theme from a file shows it in Settings › Profiles with "Set in
~/.config/solara/themes/ocean.json". Its theme editor is greyed out. The theme you made in Settings comes back when
the file stops naming a theme for that profile.

## Errors

A file with a mistake never breaks Solara. Solara keeps the last config that worked and tells you, once per save,
what's wrong:

- a banner at the top of Settings lists each problem with its file, line, key and what's wrong. For example:
  `~/.config/solara/config.json, line 3: settings.sidebarWidth: expected a number from 140 to 600`;
- a single notification says the same, if notifications are on for Solara.

A file is applied whole or not at all. While any problem remains, nothing else in the file changes either. Fix it and
save, and the banner goes away and the new config applies at once. A missing theme file is a problem too. Deleting
`config.json` takes every file value away.

## For other tools

`hooks.json`, in the same folder, uses the same folder watcher and the same error banner and notification
(`ConfigDirectory` and `ConfigProblems` in SolaraModel).
