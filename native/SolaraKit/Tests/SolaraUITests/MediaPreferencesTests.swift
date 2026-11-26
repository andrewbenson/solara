import Testing
@testable import SolaraUI

@MainActor
struct MediaPreferencesTests {
  @Test func defaultsAndIndependentChanges() {
    var pip: [Bool] = []
    var upscaling: [Bool] = []
    let feed = MediaPreferences(autoPictureInPicture: { pip.append($0) }, videoUpscaling: { upscaling.append($0) })
    feed.update(autoPictureInPicture: nil, videoUpscaling: nil)
    feed.update(autoPictureInPicture: true, videoUpscaling: true)
    #expect(pip == [true])
    #expect(upscaling == [true])
    feed.update(autoPictureInPicture: false, videoUpscaling: true)
    #expect(pip == [true, false])
    #expect(upscaling == [true])
    feed.update(autoPictureInPicture: false, videoUpscaling: false)
    #expect(upscaling == [true, false])
  }

  @Test func reattachmentReappliesExplicitFalse() {
    var applied: [Bool] = []
    let feed = MediaPreferences(autoPictureInPicture: { applied.append($0) }, videoUpscaling: { applied.append($0) })
    feed.update(autoPictureInPicture: false, videoUpscaling: false)
    feed.invalidate()
    feed.update(autoPictureInPicture: false, videoUpscaling: false)
    #expect(applied == [false, false, false, false])
  }
}
