import PictureInPictureGeometrySupport
import Testing

@Suite struct PictureInPictureGeometryTests {
  private let baseline = ACPiPSize(width: 284, height: 160)
  private let maximum = ACPiPSize(width: 1920, height: 1080)

  @Test(arguments: [0.25, 9.0 / 16, 1, 16.0 / 9, 4])
  func minimumFollowsVideoAspect(_ aspect: Double) {
    let size = ACPiPMinimumSize(aspect, baseline)
    #expect(abs(size.width / size.height - aspect) < 0.000001)
    #expect(min(size.width, size.height) >= 160)
    #expect(size.width * size.height >= 284 * 160 - 0.000001)
  }

  @Test(arguments: [(0.25, 160.0, 640.0), (0.5625, 160.0, 2560.0 / 9), (1.0, 213.16660151158765, 213.16660151158765), (16.0 / 9, 2560.0 / 9, 160.0), (4.0, 640.0, 160.0)])
  func minimumMatchesExpectedDimensions(_ aspect: Double, _ width: Double, _ height: Double) {
    let size = ACPiPMinimumSize(aspect, baseline)
    #expect(abs(size.width - width) < 0.000001)
    #expect(abs(size.height - height) < 0.000001)
  }

  @Test(arguments: [(0.25, 120.0, 480.0), (4.0, 480.0, 120.0)])
  func minimumFitsTheAvailableMaximum(_ aspect: Double, _ width: Double, _ height: Double) {
    let size = ACPiPMinimumSizeWithinMaximum(aspect, baseline, ACPiPSize(width: 480, height: 480))
    #expect(abs(size.width - width) < 0.000001)
    #expect(abs(size.height - height) < 0.000001)
    #expect(abs(size.width / size.height - aspect) < 0.000001)
  }

  @Test(arguments: [(0.1, 86.0, 864.0), (10.0, 1152.0, 115.0), (16.0 / 9, 285.0, 160.0), (9.0 / 16, 160.0, 285.0)])
  func nativeMinimumRoundsWithinTheAspectMaximum(_ aspect: Double, _ width: Double, _ height: Double) {
    let size = ACPiPNativeMinimumSize(aspect, baseline, ACPiPSize(width: 1152, height: 864))
    #expect(size.width == width)
    #expect(size.height == height)
    #expect(max(size.width, size.height * aspect) <= min(1152, 864 * aspect))
  }

  @Test func minimumWithoutAKnownMaximumKeepsItsIdealSize() {
    let size = ACPiPMinimumSizeWithinMaximum(0.25, baseline, ACPiPSize(width: 0, height: 0))
    #expect(size.width == 160)
    #expect(size.height == 640)
  }

  @Test func portraitAndLandscapeHaveTransposedMinimums() {
    let landscape = ACPiPMinimumSize(16.0 / 9, baseline)
    let portrait = ACPiPMinimumSize(9.0 / 16, baseline)
    #expect(landscape.width == portrait.height)
    #expect(landscape.height == portrait.width)
    #expect(portrait.width == 160)
    #expect(portrait.height < 285)
  }

  @Test func squareUsesTheLandscapeMinimumArea() {
    let size = ACPiPMinimumSize(1, baseline)
    #expect(abs(size.width * size.height - 284 * 160) < 0.000001)
    #expect(size.width == size.height)
  }

  @Test func rememberedSizePreservesAreaWhenOrientationChanges() {
    let size = ACPiPRestoredSize(ACPiPSize(width: 320, height: 180), 9.0 / 16, ACPiPMinimumSize(9.0 / 16, baseline), maximum)
    #expect(size.width == 180)
    #expect(size.height == 320)
  }

  @Test(arguments: [0.25, 9.0 / 16, 1, 16.0 / 9, 4])
  func rememberedSizeIsClampedToAspectMinimum(_ aspect: Double) {
    let size = ACPiPRestoredSize(ACPiPSize(width: 10, height: 10), aspect, ACPiPMinimumSize(aspect, baseline), maximum)
    let minimum = ACPiPMinimumSize(aspect, baseline)
    #expect(abs(size.width - minimum.width) < 0.000001)
    #expect(abs(size.height - minimum.height) < 0.000001)
  }

  @Test func rememberedSizeFitsASmallerDisplay() {
    let size = ACPiPRestoredSize(ACPiPSize(width: 4000, height: 4000), 9.0 / 16, ACPiPMinimumSize(9.0 / 16, baseline), ACPiPSize(width: 800, height: 600))
    #expect(size.width == 337.5)
    #expect(size.height == 600)
  }

  @Test func rememberedSizeFitsWhenTheDisplayIsSmallerThanTheMinimum() {
    let size = ACPiPRestoredSize(ACPiPSize(width: 180, height: 320), 0.25, ACPiPMinimumSize(0.25, baseline), ACPiPSize(width: 300, height: 300))
    #expect(size.width == 75)
    #expect(size.height == 300)
  }

  @Test func invalidRememberedSizeUsesTheAspectMinimum() {
    let minimum = ACPiPMinimumSize(9.0 / 16, baseline)
    let size = ACPiPRestoredSize(ACPiPSize(width: .nan, height: 0), 9.0 / 16, minimum, maximum)
    #expect(size.width == minimum.width)
    #expect(size.height == minimum.height)
  }

  @Test func rememberedSizeRotatesBackToLandscape() {
    let aspect = 16.0 / 9
    let size = ACPiPRestoredSize(ACPiPSize(width: 180, height: 320), aspect, ACPiPMinimumSize(aspect, baseline), maximum)
    #expect(size.width == 320)
    #expect(size.height == 180)
  }

  @Test(arguments: [Double.nan, Double.infinity, 0, -1])
  func invalidAspectUsesTheBaseline(_ aspect: Double) {
    let size = ACPiPMinimumSize(aspect, baseline)
    #expect(abs(size.width - baseline.width) < 0.000001)
    #expect(abs(size.height - baseline.height) < 0.000001)
  }

  @Test func rememberedPortraitSizeStaysSmall() {
    let size = ACPiPRestoredSize(ACPiPSize(width: 180, height: 320), 9.0 / 16, ACPiPMinimumSize(9.0 / 16, baseline), maximum)
    #expect(size.width == 180)
    #expect(size.height == 320)
  }
}
