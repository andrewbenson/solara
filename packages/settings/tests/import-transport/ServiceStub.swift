#if DEBUG
import Foundation

public final class ImportService: @unchecked Sendable {
  public static let shared = ImportService()
  static let work = DispatchQueue(label: "import-transport")
  let session: ImportSession

  init() {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    session = ImportSession(importer: Importer(discovery: BrowserDiscovery(applicationSupport: root, locateApp: { _ in nil }, iconFor: { _, _ in nil })))
  }
}
#endif
