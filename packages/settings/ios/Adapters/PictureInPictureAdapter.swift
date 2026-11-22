import SolaraCore
import SolaraUI

extension PictureInPictureCenter: PictureInPictureControlling {}

@MainActor enum PictureInPictureAdapter {
  static func install() {
    MediaStackPiP.center = PictureInPictureCenter.shared
  }
}
