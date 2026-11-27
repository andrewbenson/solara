import CoreGraphics
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

struct NewTabContextTests {
  private func fixture() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: [:]))
    state.windows["w"] = BrowserWindow(id: "w", profileId: "home", incognito: false, frame: nil, createdAt: 0)
    state.windows["w"]?.tabIds = ["t"]
    state.windows["w"]?.activeTabIds["home"] = "t"
    state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: "home", url: "", now: 0)
    return state
  }

  @Test func profileSwitchAndPrivateHeading() {
    var state = fixture()
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t")?.identity.profileId == "home")
    state.windows["w"]?.profileId = "private"
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t") == nil)
    state.tabs["t"]?.profileId = "private"
    state.windows["w"]?.incognito = true
    let context = NewTabContext.resolve(state, windowId: "w", tabId: "t")
    #expect(context?.identity.profileId == "private")
    #expect(context?.showsHeading(onboarding: false) == true)
    #expect(context?.showsHeading(onboarding: true) == false)
  }

  @Test func panelAndOnboardingSuppressFieldActions() {
    var state = fixture()
    let initial = NewTabContext.resolve(state, windowId: "w", tabId: "t")
    #expect(initial?.allowsFieldInteraction(onboarding: false) == true)
    #expect(initial?.allowsFieldInteraction(onboarding: true) == false)
    state.windowUi["w"] = WindowUi(json: ["panel": ["open": true]])
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t")?.allowsFieldInteraction(onboarding: false) == false)
    state.closePanel("w")
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t")?.allowsFieldInteraction(onboarding: false) == true)
  }

  @Test func missingClosingMovedAndNavigatedTargetsRefuseContext() {
    var state = fixture()
    #expect(NewTabContext.resolve(state, windowId: "missing", tabId: "t") == nil)
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "missing") == nil)
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t", closing: ["w"]) == nil)
    state.tabs["t"]?.windowId = "elsewhere"
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t") == nil)
    state.tabs["t"]?.windowId = "w"
    state.tabs["t"]?.url = "https://example.com"
    #expect(NewTabContext.resolve(state, windowId: "w", tabId: "t") == nil)
  }

  @Test func introReceiptIsPerTabAcrossRemounts() {
    var receipts = NewTabIntroReceipts()
    let first = receipts.claim(tabId: "t")
    let remount = receipts.claim(tabId: "t")
    let another = receipts.claim(tabId: "another")
    #expect(first)
    #expect(!remount)
    #expect(another)
  }

  @Test func toolbarInsetAndPrivateHeadingDriveNativeLayout() throws {
    var state = fixture()
    state.windows["w"]?.incognito = true
    let context = try #require(NewTabContext.resolve(state, windowId: "w", tabId: "t"))
    let size = CGSize(width: 700, height: 280)
    let heading: CGFloat = context.showsHeading(onboarding: false) ? 30 : 0
    let withHeading = NewTabLayout.frames(size: size, under: 44, headingHeight: heading, barHeight: 112, scale: 2)
    let onboarding = NewTabLayout.frames(size: size, under: 44, headingHeight: 0, barHeight: 112, scale: 2)
    let noInset = NewTabLayout.frames(size: size, under: 0, headingHeight: heading, barHeight: 112, scale: 2)
    #expect(withHeading.bar.minY > onboarding.bar.minY)
    #expect(withHeading.bar.minY - noInset.bar.minY == 44)
  }

  @MainActor @Test func actionUsesTheNativeControllerOnlyForCurrentHeroContext() throws {
    let fixture = self.fixture()
    let store = Store(state: fixture, checksInvariants: false)
    let context = try #require(NewTabContext.resolve(store.state, windowId: "w", tabId: "t"))
    let model = HeroBarModel(windowId: "w", tabId: "t", profileId: context.identity.profileId, incognito: context.incognito, settings: { fixture.settings })
    let controller = OmniboxActionController(ownsWorkspace: { true }, resolve: { store })
    var actions: [String] = []
    controller.performAction = { action, _ in actions.append(action); return true }
    let events = controller.decorate(HeroBarEvents(), model: {
      let current = NewTabContext.resolve(store.state, windowId: "w", tabId: "t", closing: store.memory.closingWindows)
      return current?.accepts(context.identity, onboarding: false) == true ? model : nil
    })
    events.runAction("first")
    try store.dispatch(Command("openPanel", ["w", ""]), origin: .native)
    events.runAction("suppressed")
    try store.dispatch(Command("closePanel", ["w"]), origin: .native)
    events.runAction("second")
    #expect(actions == ["first", "second"])
  }
}
