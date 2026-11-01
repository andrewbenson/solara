import XCTest
@testable import SolaraShellCore

final class OutsideURLRouteTests: XCTestCase {
  let own = "/build/test/Solara.app"
  let id = "network.benson.solara"
  let background = ["SOLARA_BACKGROUND": "1"]

  func route(
    _ environment: [String: String], running: [OutsideURLCandidate] = [], handler: OutsideURLCandidate? = nil,
    installed: [String] = []
  ) -> OutsideURLRoute {
    OutsideURLRoute.choose(
      environment: environment, ownPath: own, ownBundleId: id, running: running, defaultHandler: handler, installed: installed)
  }

  func testAnInstanceThatIsntBackgroundOpensItsLinks() {
    XCTAssertEqual(route([:], handler: OutsideURLCandidate(path: "/Applications/Dia.app", bundleId: "company.thebrowser.dia")), .open)
  }

  func testOptingInKeepsTheLinksInTheBackgroundInstance() {
    let environment = background.merging(["SOLARA_ACCEPT_EXTERNAL_URLS": "1"]) { $1 }
    XCTAssertEqual(route(environment, running: [OutsideURLCandidate(path: "/owner/Solara.app", bundleId: id)]), .open)
  }

  func testARunningCopyThatIsntBackgroundGetsThem() {
    let running = [
      OutsideURLCandidate(path: own, bundleId: id),
      OutsideURLCandidate(path: "/other/test/Solara.app", bundleId: id, testInstance: true),
      OutsideURLCandidate(path: "/owner/Solara.app", bundleId: id),
    ]
    XCTAssertEqual(route(background, running: running), .forward(path: "/owner/Solara.app", newInstance: false))
  }

  func testTheOwnersDefaultSolaraOutsideApplicationsIsLaunchedForThem() {
    let handler = OutsideURLCandidate(path: "/Users/owner/solara/apps/browser/build-solara-engine/Solara.app", bundleId: id)
    XCTAssertEqual(route(background, handler: handler), .forward(path: handler.path, newInstance: true))
  }

  func testAnotherDefaultBrowserGetsThemInItsOwnInstance() {
    let handler = OutsideURLCandidate(path: "/Applications/Dia.app", bundleId: "company.thebrowser.dia")
    XCTAssertEqual(route(background, handler: handler), .forward(path: handler.path, newInstance: false))
  }

  func testWhenThisInstanceIsTheDefaultAnInstalledCopyGetsThem() {
    let handler = OutsideURLCandidate(path: own, bundleId: id)
    XCTAssertEqual(
      route(background, handler: handler, installed: [own, "/Applications/Solara.app"]),
      .forward(path: "/Applications/Solara.app", newInstance: true))
  }

  func testWithNoOtherHandlerTheInstanceOpensThemItself() {
    XCTAssertEqual(route(background, handler: OutsideURLCandidate(path: own, bundleId: id), installed: [own]), .open)
    XCTAssertEqual(route(background), .open)
  }
}
