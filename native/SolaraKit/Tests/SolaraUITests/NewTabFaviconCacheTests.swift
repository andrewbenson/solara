import AppKit
import SolaraEngine
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct NewTabFaviconCacheTests {
  let url = "https://example.test/"
  let favicon = "https://example.test/icon.png"

  @Test(arguments: [
    ("profile-a", "profile-b"),
    ("default", "incognito:default-window@default"),
    ("profile-a", "incognito:window-private@profile-a"),
    ("incognito:window-private@profile-a", "profile-a"),
    ("incognito:window-private@profile-a", "incognito:other-window@profile-a"),
  ])
  func imagesStayInTheirProfile(profiles: (String, String)) async {
    let first = NSImage(size: NSSize(width: 16, height: 16))
    let second = NSImage(size: NSSize(width: 32, height: 32))
    var loads = 0
    let favicons = NewTabFavicons { _, _, profile, _ in
      loads += 1
      return profile == profiles.0 ? first : second
    }

    #expect(await favicons.fetch(url, favicon, profileId: profiles.0, dark: false) === first)
    #expect(favicons.cached(url, favicon, profileId: profiles.0, dark: false) === first)
    #expect(favicons.cached(url, favicon, profileId: profiles.1, dark: false) == nil)
    #expect(await favicons.fetch(url, favicon, profileId: profiles.1, dark: false) === second)
    #expect(await favicons.fetch(url, favicon, profileId: profiles.0, dark: false) === first)
    #expect(await favicons.fetch(url, favicon, profileId: profiles.1, dark: false) === second)
    #expect(loads == 2)
  }

  @Test(arguments: [
    ("profile-a", "profile-b"),
    ("default", "incognito:default-window@default"),
    ("profile-a", "incognito:window-private@profile-a"),
    ("incognito:window-private@profile-a", "profile-a"),
  ])
  func aMissingIconDoesNotHideAnotherProfilesImage(profiles: (String, String)) async {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    var loads = 0
    let favicons = NewTabFavicons { _, _, profile, _ in
      loads += 1
      return profile == profiles.0 ? nil : image
    }

    #expect(await favicons.fetch(url, favicon, profileId: profiles.0, dark: false) == nil)
    #expect(await favicons.fetch(url, favicon, profileId: profiles.1, dark: false) === image)
    #expect(await favicons.fetch(url, favicon, profileId: profiles.0, dark: false) == nil)
    #expect(await favicons.fetch(url, favicon, profileId: profiles.1, dark: false) === image)
    #expect(loads == 2)
  }

  @Test func appearanceSelectsSeparateImagesAndMisses() async {
    let light = NSImage(size: NSSize(width: 16, height: 16))
    let darkImage = NSImage(size: NSSize(width: 32, height: 32))
    var loads = 0
    let favicons = NewTabFavicons { page, _, _, dark in
      loads += 1
      if page == "https://missing.test/" { return dark ? darkImage : nil }
      return dark ? darkImage : light
    }

    #expect(await favicons.fetch(url, favicon, profileId: "profile-a", dark: false) === light)
    #expect(favicons.cached(url, favicon, profileId: "profile-a", dark: false) === light)
    #expect(await favicons.fetch("https://missing.test/", nil, profileId: "profile-a", dark: false) == nil)
    #expect(favicons.cached(url, favicon, profileId: "profile-a", dark: true) == nil)
    #expect(await favicons.fetch(url, favicon, profileId: "profile-a", dark: true) === darkImage)
    #expect(favicons.cached(url, favicon, profileId: "profile-a", dark: true) === darkImage)
    #expect(favicons.cached(url, favicon, profileId: "profile-a", dark: false) === light)
    #expect(await favicons.fetch("https://missing.test/", nil, profileId: "profile-a", dark: true) === darkImage)
    #expect(await favicons.fetch(url, favicon, profileId: "profile-a", dark: false) === light)
    #expect(await favicons.fetch("https://missing.test/", nil, profileId: "profile-a", dark: false) == nil)
    #expect(loads == 4)
  }

  @Test func invalidationClearsImagesAndMissesAcrossProfilesAndAppearances() async {
    let before = NSImage(size: NSSize(width: 16, height: 16))
    let after = NSImage(size: NSSize(width: 32, height: 32))
    var invalidated = false
    let favicons = NewTabFavicons { page, _, _, _ in
      if invalidated { return after }
      return page == "https://missing.test/" ? nil : before
    }
    let profiles = ["profile-a", "profile-b", "incognito:window-private@profile-a"]

    for profile in profiles {
      for dark in [false, true] {
        #expect(await favicons.fetch(url, favicon, profileId: profile, dark: dark) === before)
        #expect(await favicons.fetch("https://missing.test/", nil, profileId: profile, dark: dark) == nil)
      }
    }
    invalidated = true
    NotificationCenter.default.post(name: FaviconLibrary.didInvalidate, object: nil)
    for profile in profiles {
      for dark in [false, true] {
        #expect(favicons.cached(url, favicon, profileId: profile, dark: dark) == nil)
      }
    }
    for profile in profiles {
      for dark in [false, true] {
        #expect(await favicons.fetch(url, favicon, profileId: profile, dark: dark) === after)
        #expect(await favicons.fetch("https://missing.test/", nil, profileId: profile, dark: dark) === after)
      }
    }
  }

  @Test func heldPrivateLoadCannotRestoreAMissAfterSessionEnd() async throws {
    let client = HeldUIFaviconClient()
    let library = FaviconLibrary(client: client)
    let profile = "incognito:held-new-tab-\(UUID().uuidString)@profile-a"
    var loads = 0
    let favicons = NewTabFavicons { page, source, profile, dark in
      loads += 1
      let result = await library.favicon(page: page, source: source, engineProfile: profile, appearance: dark)
      return result.map { _ in NSImage(size: NSSize(width: 16, height: 16)) }
    }
    let request = Task { @MainActor in
      let result = await favicons.fetch(url, favicon, profileId: profile, dark: false)
      #expect(result == nil)
      #expect(favicons.cached(url, favicon, profileId: profile, dark: false) == nil)
      #expect(library.cachedCount == 0)
      #expect(loads == 1)
      let retried = await favicons.fetch(url, favicon, profileId: profile, dark: false)
      #expect(retried == nil)
      #expect(loads == 2)
    }
    defer { client.finish(nil) }
    try await client.waitForFetch()

    NotificationCenter.default.post(name: FaviconLibrary.didEndPrivateSession, object: nil, userInfo: ["aliases": [profile]])
    client.finish(Data([9]))
    await request.value
  }
}
