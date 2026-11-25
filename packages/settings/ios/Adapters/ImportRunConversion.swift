import Foundation
import SolaraImportAdapter
import SolaraModel
import SolaraUI

extension ImportRunEngine {
  func read(jobId: String, browserId: String, profileId: String, kinds: [SolaraUI.ImportKind], spaceIds: Set<String>?,
            progress: @escaping @MainActor (SolaraUI.ImportKind, Bool) -> Void) async throws -> ImportRead {
    let relay = ImportProgressRelay(progress)
    do {
      let read = try await ImportService.shared.read(jobId: jobId, browserId: browserId, profileId: profileId, kinds: kinds.map(\.rawValue), spaceIds: spaceIds) { kind, ended in
        Task { @MainActor in relay.send(kind, ended) }
      }
      return Self.imported(read)
    } catch let error as SolaraImportAdapter.ImportError where error == .cancelled {
      throw ImportReadFailure.cancelled
    } catch {
      throw ImportReadFailure.failed
    }
  }

  nonisolated static func imported(_ read: ImportService.Read) -> ImportRead {
    ImportRead(
      vaultToken: read.vaultToken,
      profileName: read.profileName,
      profileColor: read.profileColor,
      failed: read.failed.compactMap { SolaraUI.ImportKind(rawValue: $0.rawValue) },
      warnings: read.warnings.map { ImportReadWarning(kind: $0.kind.flatMap { SolaraUI.ImportKind(rawValue: $0.rawValue) }, code: $0.code, message: $0.message) },
      credentials: read.credentials.map { ImportCredential(url: $0.url, username: $0.username, password: $0.password, realm: $0.realm) },
      bookmarks: read.bookmarks.map(Self.bookmark),
      tabs: read.tabs.map(Self.tab),
      favorites: read.favorites.map(Self.tab),
      spaces: read.spaces.map(Self.space),
      history: read.history.map { ImportHistoryRow(url: $0.url, title: $0.title, visits: $0.visits, lastVisit: $0.lastVisit) },
      favicons: read.favicons.map { ImportFaviconRow(page: $0.page, icon: $0.icon, png: $0.png) }
    )
  }

  nonisolated static func bookmark(_ node: SolaraImportAdapter.BookmarkNode) -> ImportBookmarkNode {
    ImportBookmarkNode(isFolder: node.type != .url, title: node.title, url: node.url, dateAdded: node.dateAdded, role: node.role?.isEmpty == true ? nil : node.role,
                       pageTitle: node.pageTitle, children: node.children?.map(bookmark))
  }

  nonisolated static func tab(_ tab: SolaraImportAdapter.ImportedTab) -> ImportTabRow {
    ImportTabRow(url: tab.url, title: tab.title, pinned: tab.pinned, customTitle: tab.customTitle)
  }

  nonisolated static func space(_ space: SolaraImportAdapter.SpaceSuggestion) -> ImportSpaceRow {
    ImportSpaceRow(id: space.id, name: space.name, color: space.color, colors: space.colors, emoji: space.emoji, icon: space.icon,
                   profileId: space.profileId, pinned: space.pinned.map(Self.bookmark), tabs: space.tabs.map(Self.tab), theme: space.theme)
  }

  nonisolated static func profilePayload(name: String, color: String?, icon: String?, shareWith: String?) -> JSONValue {
    var args: JSONObject = ["name": .string(name)]
    if let color { args["color"] = .string(color) }
    if let icon { args["icon"] = .string(icon) }
    if let shareWith { args["shareWith"] = .string(shareWith) }
    return .object(args)
  }
}

final class ImportProgressRelay: @unchecked Sendable {
  private let deliver: @MainActor (SolaraUI.ImportKind, Bool) -> Void

  init(_ deliver: @escaping @MainActor (SolaraUI.ImportKind, Bool) -> Void) { self.deliver = deliver }

  @MainActor func send(_ kind: String, _ ended: Bool) {
    guard let parsed = SolaraUI.ImportKind(rawValue: kind) else { return }
    deliver(parsed, ended)
  }
}
