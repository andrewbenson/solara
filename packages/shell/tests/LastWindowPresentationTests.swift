import AppKit
import XCTest
@testable import SolaraShellCore

final class LastWindowPresentationTests: XCTestCase {
  func testRetainedWindowIsExcludedFromWindowMenuMissionControlAndCycling() {
    let presentation = LastWindowPresentation(collection: [.managed, .participatesInCycle], excluded: false)
    XCTAssertTrue(presentation.retainedExcluded)
    XCTAssertTrue(presentation.retainedCollection.contains(.transient))
    XCTAssertTrue(presentation.retainedCollection.contains(.ignoresCycle))
    XCTAssertFalse(presentation.retainedCollection.contains(.managed))
    XCTAssertFalse(presentation.retainedCollection.contains(.participatesInCycle))
    XCTAssertEqual(presentation.collection, [.managed, .participatesInCycle])
    XCTAssertFalse(presentation.excluded)
  }

  func testHiddenFlagsPreserveFullScreenAndSpaceConfiguration() {
    let original: NSWindow.CollectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces, .managed, .participatesInCycle]
    let presentation = LastWindowPresentation(collection: original, excluded: false)
    XCTAssertTrue(presentation.retainedCollection.contains(.fullScreenPrimary))
    XCTAssertTrue(presentation.retainedCollection.contains(.canJoinAllSpaces))
    XCTAssertEqual(presentation.collection, original)
  }

  func testWindowOriginallyExcludedFromMenuStaysExcludedWhenRestored() {
    let original: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    let presentation = LastWindowPresentation(collection: original, excluded: true)
    XCTAssertTrue(presentation.retainedExcluded)
    XCTAssertTrue(presentation.excluded)
    XCTAssertEqual(presentation.collection, original)
  }
}
