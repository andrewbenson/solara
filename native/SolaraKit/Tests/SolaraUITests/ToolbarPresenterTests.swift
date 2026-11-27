import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

struct ToolbarPresenterTests {
  private func browser(_ url: String) -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.windows["w"] = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    state.windows["w"]?.activeTabIds["default"] = "a"
    state.tabs["a"] = Tab(id: "a", windowId: "w", profileId: "default", url: url, now: 0)
    return state
  }

  @Test func addressFormattingMatchesTheToolbar() {
    let web = ToolbarPresenter.address("https://www.example.com:8443/path/", title: "Page", fullURL: true, insecure: nil)
    #expect(web.host == "example.com:8443")
    #expect(web.rest == "/path")
    #expect(web.hover == "/path/")
    let insecure = ToolbarPresenter.address("http://example.com/path/", title: "", fullURL: false, insecure: "warning")
    #expect(insecure.host == "http://example.com")
    #expect(insecure.rest == "/path/")
    #expect(ToolbarPresenter.address("file:///tmp/a%20b", title: "", fullURL: false, insecure: nil).hover == " /tmp/a b")
    #expect(ToolbarPresenter.address("file:///tmp/a%2G%20b", title: "", fullURL: false, insecure: nil).hover == " /tmp/a%2G%20b")
    #expect(ToolbarPresenter.address("solara://settings", title: "Settings", fullURL: false, insecure: nil).rest == " / Settings")
    #expect(ToolbarPresenter.developerAddress("http://localhost:8080/") == "http://localhost:8080")
    #expect(ToolbarPresenter.developerAddress("http://localhost/path/") == "http://localhost/path/")
  }

  @Test func pageFactsAndTargetOwnership() throws {
    var state = browser("http://localhost/")
    state.live["a"] = PageLiveFacts(isLoading: true, canGoBack: true, canGoForward: false)
    let page = try #require(ToolbarPresenter.page(windowId: "w", tabId: "a", state: state))
    #expect(page.loading)
    #expect(page.back)
    #expect(!page.forward)
    #expect(page.developer)
    #expect(page.bookmarkProfile == "default")
    #expect(ToolbarPresenter.page(windowId: "other", tabId: "a", state: state) == nil)
    state.tabs["a"]?.windowId = "other"
    #expect(ToolbarPresenter.page(windowId: "w", tabId: "a", state: state) == nil)
    state.tabs["a"] = nil
    #expect(ToolbarPresenter.page(windowId: "other", tabId: "a", state: state) == nil)
  }

  @Test func placementAndExtensionRoom() {
    #expect(ToolbarPresenter.urlRight(inSplit: false, extensionsWidth: 32) == 44)
    #expect(ToolbarPresenter.urlRight(inSplit: true, extensionsWidth: 32) == 100)
    #expect(ToolbarPresenter.onFrame(rail: true, focused: true, top: false, fullscreen: false, sidebarOpen: true))
    #expect(!ToolbarPresenter.onFrame(rail: true, focused: false, top: false, fullscreen: false, sidebarOpen: true))
    #expect(!ToolbarPresenter.onFrame(rail: true, focused: true, top: true, fullscreen: false, sidebarOpen: true))
    #expect(!ToolbarPresenter.onFrame(rail: true, focused: true, top: false, fullscreen: true, sidebarOpen: true))
    #expect(!ToolbarPresenter.onFrame(rail: true, focused: true, top: false, fullscreen: false, sidebarOpen: false))
  }

  @Test func projectionKeepsControlsAndTransientContributions() throws {
    var state = browser("http://localhost/path/")
    state.live["a"] = PageLiveFacts(isLoading: true, canGoBack: true)
    let input = try JSONDecoder().decode(ToolbarPresenter.Input.self, from: Data("""
    {"windowId":"w","tabId":"a","bare":false,"windowToolbar":true,"fullscreenTabs":[],
     "geometry":{"sidebarButton":21,"back":57,"forward":93,"reload":129,"urlLeft":145},
     "palette":{"text":"#000000","secondary":"#222222","icon":"#111111","iconDisabled":"#555555",
       "hover":"#CCCCCC","pressed":"#AAAAAA","pill":"#EEEEEE","divider":"#333333"},
     "accent":"#FF0000","dark":false,"hints":{"back":"⌘[","reload":"⌘R"},
     "insecure":"dangerous","editing":true,"editRequest":3,"popups":1,"popover":"popups",
     "progress":0.25,"newTabShown":false,"backToNewTab":false,"historyKnown":false}
    """.utf8))
    let page = try #require(ToolbarPresenter.page(windowId: "w", tabId: "a", state: state))
    let toolbar = try #require(ToolbarPresenter.present(input, state: state, page: page, shell: false, fullscreen: false,
      engineBack: false, bookmarked: true, extensions: [], extensionsWidth: 30))
    #expect(toolbar.geometry.urlRight == 42)
    #expect(toolbar.url?.host == "http://localhost")
    #expect(toolbar.url?.developer?.text == "http://localhost/path/")
    #expect(toolbar.url?.developer?.request == 3)
    #expect(toolbar.url?.hoverButtons.first?.icon == "bookmark.fill")
    #expect(toolbar.url?.trailing.last?.active == true)
    #expect(toolbar.left.first { $0.id == "back" }?.tooltip == "Go Back (⌘[)")
    #expect(toolbar.left.first { $0.id == "back" }?.enabled == true)
    #expect(toolbar.left.first { $0.id == "reload" }?.tooltip == "Stop Loading This Page")
    #expect(toolbar.progress == 0.25)
  }

  @Test func bookmarkProfileBelongsToTheTabWindow() throws {
    var state = browser("https://example.com/")
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 0)
    state.windows["w"]?.profileId = "work"
    #expect(ToolbarPresenter.page(windowId: "w", tabId: "a", state: state) == nil)
    state.tabs["a"]?.profileId = "work"
    #expect(ToolbarPresenter.page(windowId: "w", tabId: "a", state: state)?.bookmarkProfile == "work")
    state.windows["w"]?.incognito = true
    state.windows["w"]?.originalProfileId = "work"
    state.windows["w"]?.profileId = "incognito:w@work"
    state.tabs["a"]?.profileId = "incognito:w@work"
    #expect(ToolbarPresenter.page(windowId: "w", tabId: "a", state: state)?.bookmarkProfile == "work")
  }

}
