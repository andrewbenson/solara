@MainActor
public final class MediaPreferences {
  private let autoPictureInPicture: (Bool) -> Void
  private let videoUpscaling: (Bool) -> Void
  private var appliedPictureInPicture: Bool?
  private var appliedUpscaling: Bool?

  public init(autoPictureInPicture: @escaping (Bool) -> Void, videoUpscaling: @escaping (Bool) -> Void) {
    self.autoPictureInPicture = autoPictureInPicture
    self.videoUpscaling = videoUpscaling
  }

  public func update(autoPictureInPicture: Bool?, videoUpscaling: Bool?) {
    let pictureInPicture = autoPictureInPicture ?? true
    let upscaling = videoUpscaling ?? true
    if appliedPictureInPicture != pictureInPicture {
      appliedPictureInPicture = pictureInPicture
      self.autoPictureInPicture(pictureInPicture)
    }
    if appliedUpscaling != upscaling {
      appliedUpscaling = upscaling
      self.videoUpscaling(upscaling)
    }
  }

  public func invalidate() {
    appliedPictureInPicture = nil
    appliedUpscaling = nil
  }
}
