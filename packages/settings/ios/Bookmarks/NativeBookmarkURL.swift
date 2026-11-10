import Foundation
import SolaraCore
import SolaraEngine
import SolaraModel
import SolaraStore

enum NativeBookmarkURL {
  static func canonicalize(_ encoded: String) throws -> String {
    let units = BookmarkString.units(encoded)
    let bytes = units.withUnsafeBytes { Data($0) }
    do {
      return BookmarkString.encode(try SolaraCoreEngineBridge.canonicalBookmarkURLUTF16(bytes))
    } catch {
      throw BookmarkWriterError.refused("Chrome could not canonicalize the bookmark URL")
    }
  }
}

extension NativeBookmarkWriter {
  static func prepare(directory: URL, state: BrowserState, cacheDirectory: URL? = nil, readOnly: Bool = false, stampsEnabled: Bool = false) async -> NativeBookmarkOwner {
    await NativeBookmarkOwner.prepare(directory: directory, state: state, cacheDirectory: cacheDirectory, readOnly: readOnly, stampsEnabled: stampsEnabled, canonicalURL: NativeBookmarkURL.canonicalize)
  }
}
