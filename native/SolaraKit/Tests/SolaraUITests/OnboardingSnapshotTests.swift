import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingSnapshotTests {
  static let size = NSSize(width: 1360, height: 860)

  static func render(_ view: some View, _ name: String, size: NSSize = size) async throws {
    guard let directory = Snapshot.directory else { return }
    for dark in [false, true] {
      try await Snapshot.render(
        view.environment(\.onboardingSettled, true).environment(\.onboardingPreviewClock, 0),
        size: size, dark: dark,
        to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
      )
    }
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPreviewGallery() async throws {
    for index in 0..<PreviewGallery.framePages {
      try await Self.render(PreviewGalleryPage(page: .frames(index, addressInSidebar: false)), "gallery-frames-\(index)")
    }
    try await Self.render(PreviewGalleryPage(page: .frames(0, addressInSidebar: true)), "gallery-frames-0-field")
    try await Self.render(PreviewGalleryPage(page: .frames(1, addressInSidebar: true)), "gallery-frames-1-field")
    for index in PreviewGallery.mockPages.indices {
      try await Self.render(PreviewGalleryPage(page: .mocks(index)), "gallery-mocks-\(index)")
    }
  }

  static func page(_ model: OnboardingModel, _ name: String) async throws {
    try await render(
      OnboardingOverlayView(model: model, windowId: "w1").environment(\.onboardingIntroClock, 2.9),
      "step-\(name)"
    )
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersEveryStep() async throws {
    let (model, services, _) = OnboardingFixture.make()
    services.visits = [OnboardingHistoryVisit(url: "https://github.com/", visits: 8), OnboardingHistoryVisit(url: "https://www.figma.com/", visits: 4)]
    model.start()
    try await Self.page(model, "00-intro")
    model.go(.source)
    await model.loadSources()
    try await Self.page(model, "01-source-empty")
    model.chooseSource(.arc)
    try await Self.page(model, "01-source-arc")
    for step in [OnboardingStep.layout, .tabs, .look, .searchPrivacy] {
      model.go(step)
      await model.enter(step)
      for (sub, question) in model.questions(for: step).enumerated() {
        model.go(step, sub: sub)
        if question == .tidy { model.choose(.tidy, "tidy") }
        try await Self.page(model, "\(step.rawValue)-\(sub)-\(question.rawValue)")
      }
    }
    model.go(.pins)
    try await Self.page(model, "pins")
    model.go(.home)
    await model.loadSystem()
    try await Self.page(model, "home-0-default")
    model.go(.home, sub: 1)
    try await Self.page(model, "home-1-links")
    for question in [OnboardingQuestion.source, .tabs, .cmdl, .newTab, .color, .appearance, .engine, .pins] {
      model.confirm(question, patch: [:], picked: model.picked(for: question))
    }
    model.go(.outro)
    try await Self.page(model, "outro")
  }
  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersDiscoveryAndJoinRoutes() async throws {
    let suite = OnboardingPairingTests()
    let (model, _, _, discovery, joining, scheduler) = suite.fixture()
    model.maybeStart()
    try await Self.page(model, "sync-discovering")
    scheduler.advance(.seconds(10))
    try await Self.page(model, "sync-timeout")
    model.discoverSync()
    discovery.emit(.found([
      .init(cid: "first", lastActivity: Date(timeIntervalSince1970: 1_790_000_000)),
      .init(cid: "second", lastActivity: nil),
    ]))
    try await Self.page(model, "sync-choice")
    model.selectSync(cid: "first")
    model.pairWithAnotherMac()
    await suite.settle()
    try await Self.page(model, "sync-preparing")
    joining.emit(.waiting(expires: scheduler.now + .seconds(300)))
    try await Self.page(model, "sync-waiting")
    joining.emit(.comparing(code: "ABC DEF", claimedName: "Office Mac"))
    try await Self.page(model, "sync-comparing")
    joining.emit(.failed(.denied))
    try await Self.page(model, "sync-denied")
    joining.emit(.approved)
    try await Self.page(model, "sync-approved")
    joining.emit(.installed)
    await suite.settle()
    try await Self.page(model, "sync-joined")
  }

}

