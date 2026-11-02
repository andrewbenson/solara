import AppKit
import SolaraCore
import ExpoModulesCore
import SolaraImportAdapter
import Security

public class SyncModule: Module {
  private let state = KeyState()
  private let owner = DeviceOwnerCheck()
  private let creation = SyncCreationAdmission.shared
  private static let work = DispatchQueue(label: "solara.sync", qos: .utility)
  private static let sealed = SealedPasswords()

  public func definition() -> ModuleDefinition {
    Name("SolaraSyncAdapter")

    OnCreate { Self.work.async { Self.removeTemporaryKits() } }

    AsyncFunction("folderInfo") { (path: String?) -> [String: Any] in
      let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
      return [
        "path": url.path,
        "defaultPath": Self.defaultFolder.path,
        "iCloudAvailable": Self.testFolder != nil || SyncFolder.iCloudDriveAvailable,
        "inICloud": SyncFolder.isInICloudDrive(url),
        "exists": exists,
        "writable": exists && FileManager.default.isWritableFile(atPath: url.path),
        "hasSyncData": exists && SyncFolder.hasSyncData(url),
      ]
    }.runOnQueue(Self.work)

    AsyncFunction("chooseFolder") { (current: String?, promise: Promise) in
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      panel.prompt = "Use Folder"
      panel.message = "Choose a folder that syncs between your Macs, like one in iCloud Drive or Dropbox, or on a NAS or USB drive."
      if let current { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
      panel.begin { response in promise.resolve(response == .OK ? panel.url?.path : nil) }
    }.runOnQueue(.main)

    Function("newDeviceId") { SyncKeys.newFileId() }

    Function("deviceName") { Host.current().localizedName ?? "This Mac" }

    AsyncFunction("inspectCreation") { (folder: String, promise: Promise) in
      self.creation.discover(folder: URL(fileURLWithPath: folder, isDirectory: true)) { inspection in
        promise.resolve(["id": inspection.id, "folder": inspection.folder, "candidates": inspection.candidates, "completeness": inspection.completeness])
      }
    }.runOnQueue(Self.work)

    AsyncFunction("createSync") { (folder: String, inspectionID: String?) throws -> String? in
      guard !SolaraCoreHost.safeMode else { return nil }
      let url = URL(fileURLWithPath: folder, isDirectory: true)
      let finish = try self.creation.admit(folder: url, inspectionID: inspectionID)
      defer { finish() }
      let account = SyncKeys.newFileId()
      let entropy = RecoveryPhrase.generateEntropy()
      guard Self.keyStore.save(entropy, account: account) else { return nil }
      do {
        try self.creation.commit(folder: url, reservation: finish) {
          let vault = SyncVault(folder: url, keys: SyncKeys(entropy: entropy))
          guard !vault.chainExists() else { throw SyncCreationAdmission.Failure.changed }
          try vault.createChain()
        }
      } catch {
        Self.keyStore.delete(account: account)
        throw SyncCreationAdmission.Failure.changed
      }
      self.owner.revoke()
      self.state.set(entropy)
      return account
    }.runOnQueue(Self.work)

    AsyncFunction("createPhrase") { (_: String) -> Bool in false }.runOnQueue(Self.work)

    AsyncFunction("enterPhrase") { (account: String, text: String, folder: String) -> [String: Any] in
      guard !SolaraCoreHost.safeMode else { return ["error": "safe mode"] }
      let entropy: Data
      do {
        entropy = try RecoveryPhrase.entropy(from: text)
      } catch let problem as RecoveryPhrase.Problem {
        switch problem {
        case .wordCount(let n): return ["error": "wordCount", "count": n]
        case .unknownWord(let word): return ["error": "unknownWord", "word": word]
        case .checksum: return ["error": "checksum"]
        }
      }
      let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
      if !SyncVault(folder: folderURL, keys: SyncKeys(entropy: entropy)).chainExists() {
        return ["error": SyncFolder.hasSyncData(folderURL) ? "mismatch" : "noData"]
      }
      guard Self.keyStore.save(entropy, account: account) else { return ["error": "keychain"] }
      self.owner.revoke()
      self.state.set(entropy)
      return ["ok": true]
    }.runOnQueue(Self.work)

    AsyncFunction("unlock") { (account: String) -> Bool in
      guard let entropy = Self.keyStore.load(account: account), entropy.count == 32 else { return false }
      self.state.set(entropy)
      return true
    }.runOnQueue(Self.work)

    AsyncFunction("forget") { (account: String) in
      guard !SolaraCoreHost.safeMode else { return }
      Self.keyStore.delete(account: account)
      self.state.set(nil)
      self.owner.revoke()
      Self.removeTemporaryKits()
    }.runOnQueue(Self.work)

    AsyncFunction("phraseUnavailable") { () -> String? in DeviceOwnerCheck.unavailable()?.rawValue }.runOnQueue(.main)

    AsyncFunction("chainStatus") { (folder: String) throws -> String in
      let vault = try self.vault(folder)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return "unavailable" }
      return vault.chainExists() ? "ok" : "missing"
    }.runOnQueue(Self.work)

    AsyncFunction("createChain") { (_: String) throws -> Void in
      throw SyncCreationAdmission.Failure.invalidPermit
    }.runOnQueue(Self.work)

    AsyncFunction("write") { (folder: String, scope: String, payload: String) throws -> String in
      let vault = try self.vault(folder)
      guard Self.sealed.latched else { return try vault.write(scope: scope, payload: Data(payload.utf8)) }
      return try vault.write(scope: scope, payload: Data(try Self.refusing { try SealedPasswords.folderPayload(payload, keys: vault.keys) }.utf8))
    }.runOnQueue(Self.work)

    AsyncFunction("read") { (folder: String, scope: String, known: [String]) throws -> [String: Any] in
      let vault = try self.vault(folder)
      let read = vault.read(scope: scope, skipping: Set(known))
      let listing = Self.sealed.latched ? SealedPasswords.folderListing(read, keys: vault.keys) : read
      return [
        "files": listing.files.map { ["id": $0.id, "payload": String(decoding: $0.payload, as: UTF8.self)] },
        "pending": listing.pending,
        "damaged": listing.damaged.map { ["id": $0.id, "age": $0.age * 1000] },
        "present": listing.present,
      ]
    }.runOnQueue(Self.work)

    AsyncFunction("remove") { (folder: String, scope: String, ids: [String]) throws in
      try self.vault(folder).remove(scope: scope, ids: ids)
    }.runOnQueue(Self.work)

    AsyncFunction("deleteChain") { (folder: String) throws in
      try self.vault(folder).deleteChain()
    }.runOnQueue(Self.work)

    AsyncFunction("sealLocal") { (text: String, kind: String?, part: String?) throws -> String in
      guard let keys = self.state.keys else { throw Exception(name: "locked", description: "Sync isn't set up on this Mac.") }
      guard Self.sealed.latched else {
        return try keys.seal(Data(text.utf8), scopeTag: "local", fileId: LocalDocuments.legacyFileId(part: part)).base64EncodedString()
      }
      guard let kind = kind.flatMap(LocalDocuments.Kind.init(rawValue:)) else { throw Self.refusal("the local document's kind is needed once passwords are sealed") }
      return try Self.refusing { try LocalDocuments.seal(text, kind, part: part, keys: keys) }.base64EncodedString()
    }.runOnQueue(Self.work)

    AsyncFunction("openLocal") { (sealed: String, kind: String?, part: String?) -> String? in
      guard let keys = self.state.keys, let data = Data(base64Encoded: sealed) else { return nil }
      guard Self.sealed.latched else {
        return (try? keys.open(data, scopeTag: "local", fileId: LocalDocuments.legacyFileId(part: part))).map { String(decoding: $0, as: UTF8.self) }
      }
      guard let kind = kind.flatMap(LocalDocuments.Kind.init(rawValue:)) else { return nil }
      return LocalDocuments.open(data, kind, part: part, keys: keys)
    }.runOnQueue(Self.work)

    Function("useSealedPasswords") { Self.sealed.latch() }

    AsyncFunction("checkSealed") { (values: [[String: Any]]) -> [Bool] in
      guard let keys = self.state.keys else { return values.map { _ in false } }
      return values.map { SealedPasswords.opens($0, keys: keys) }
    }.runOnQueue(Self.work)

    AsyncFunction("saveSealedPassword") { (engineProfile: String, origin: String, username: String, sealed: String, replacing: Bool, promise: Promise) in
      guard Self.sealed.latched, let keys = self.state.keys, let password = try? keys.openPassword(sealed, origin: origin, username: username) else {
        return promise.resolve(false)
      }
      let ok = { (result: [String: Any]?) in result != nil && result?["error"] == nil }
      let save = {
        SolaraCoreServices.savePassword(profile: engineProfile, origin: origin, username: username, password: password) { promise.resolve(ok($0)) }
      }
      DispatchQueue.main.async {
        guard replacing else { return save() }
        SolaraCoreServices.deletePassword(profile: engineProfile, origin: origin, username: username) { deleted in
          guard ok(deleted) else { return promise.resolve(false) }
          save()
        }
      }
    }.runOnQueue(Self.work)

    AsyncFunction("migrateLedger") { (ledger: String, scopes: [String: String], state: String) -> String? in
      guard Self.sealed.latched, let keys = self.state.keys, LedgerMigration.needsMigration(ledger) else { return nil }
      do {
        return try LedgerMigration.migrate(ledger, keys: keys) { engineProfile in
          LedgerMigration.Profile(
            logins: Self.loginData(engineProfile).map(LedgerMigration.logins),
            records: scopes[engineProfile].map { LedgerMigration.records(fromState: state, scope: $0, keys: keys) } ?? [:])
        }
      } catch {
        NSLog("[sync] migrating the password ledger: \(error)")
        return nil
      }
    }.runOnQueue(Self.work)

    AsyncFunction("recoveryWords") { (promise: Promise) in
      self.disclose(promise, on: Self.work) { words in words }
    }.runOnQueue(Self.work)

    AsyncFunction("qrCode") { (promise: Promise) in
      self.disclose(promise, on: Self.work) { words -> String? in
        guard let image = RecoveryKit.qrCode(words: words), let png = RecoveryKit.png(image) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
      }
    }.runOnQueue(Self.work)

    AsyncFunction("recoveryKitPreview") { (width: Double) throws -> String? in
      _ = try self.words()
      return Self.preview(width: CGFloat(width))
    }.runOnQueue(.main)

    AsyncFunction("saveRecoveryKit") { (format: String, promise: Promise) in
      guard !SolaraCoreHost.safeMode else { return promise.reject("safe mode", "Sync is paused in safe mode.") }
      guard (try? self.words()) != nil else { return promise.reject("locked", "Sync isn't set up on this Mac.") }
      let panel = NSSavePanel()
      let text = format == "text"
      panel.nameFieldStringValue = text ? RecoveryKit.textName : RecoveryKit.pdfName
      panel.allowedContentTypes = [text ? .plainText : .pdf]
      panel.canCreateDirectories = true
      panel.begin { response in
        guard response == .OK, let url = panel.url else { return promise.resolve(nil) }
        self.disclose(promise, on: .main) { words -> String? in
          try Self.kit(words, text: text).write(to: url, options: [.atomic])
          return url.path
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("copyRecoveryKit") { (promise: Promise) in
      self.disclose(promise, on: .main) { words -> Bool in
        let url = try Self.temporaryKit(words)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        return true
      }
    }.runOnQueue(.main)

    AsyncFunction("shareRecoveryKit") { (promise: Promise) in
      self.disclose(promise, on: .main) { words -> Bool in
        let presenting = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.attachedSheet != nil }?.attachedSheet
          ?? NSApp.windows.first { $0.isVisible && $0.title == "Settings" } ?? NSApp.windows.first(where: \.isVisible)
        guard let window = presenting, let view = window.contentView else { return false }
        let url = try Self.temporaryKit(words)
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
        return true
      }
    }.runOnQueue(.main)

    AsyncFunction("copyRecoveryPhrase") { (promise: Promise) in
      self.disclose(promise, on: .main) { words -> Bool in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString(words.joined(separator: " "), forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        return true
      }
    }.runOnQueue(.main)

    AsyncFunction("revealFolder") { (path: String) in
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[sync] background instance, not revealing %@", path) }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }.runOnQueue(.main)

    AsyncFunction("readPasswordsWithMark") { (engineProfile: String) -> [String: Any]? in
      do {
        let sealing = Self.sealed.latched
        let keys = self.state.keys
        if sealing && keys == nil { return nil }
        let key = ChromiumCrypto.deriveKey(secret: try Self.safeStorageSecret())
        let read = try ChromiumSecrets.loginsForSync(profile: Self.profileDirectory(engineProfile), key: key)
        if read.undecryptable > 0 {
          NSLog("[sync] \(read.undecryptable) saved passwords didn't decrypt; not syncing passwords now")
          return nil
        }
        let logins: [[String: Any]] = try read.logins.compactMap { l in
          let c = l.credential
          var login: [String: Any]
          if sealing, let keys {
            guard let origin = SealedPasswords.origin(of: c.realm ?? c.url) else { return nil }
            login = ["origin": origin, "username": c.username, "s": try keys.sealPassword(c.password, origin: origin, username: c.username), "created": c.created ?? 0]
          } else {
            login = ["origin": c.realm ?? c.url, "url": c.url, "username": c.username, "password": c.password, "created": c.created ?? 0]
          }
          if let modified = l.modified { login["modified"] = modified }
          return login
        }
        return ["logins": logins, "mark": read.mark ?? NSNull()]
      } catch ImportError.notFound(_) {
        return ["logins": [] as [[String: Any]], "mark": NSNull()]
      } catch {
        NSLog("[sync] reading passwords: \(error)")
        return nil
      }
    }.runOnQueue(Self.work)

    AsyncFunction("readPasswords") { (engineProfile: String) -> [[String: Any]]? in
      guard !Self.sealed.latched else { return nil }
      do {
        let key = ChromiumCrypto.deriveKey(secret: try Self.safeStorageSecret())
        let result = try ChromiumSecrets.logins(profile: Self.profileDirectory(engineProfile), key: key)
        if result.undecryptable > 0 {
          NSLog("[sync] \(result.undecryptable) saved passwords didn't decrypt; not syncing passwords now")
          return nil
        }
        return result.items.map { c in
          ["origin": c.realm ?? c.url, "url": c.url, "username": c.username, "password": c.password, "created": c.created ?? 0]
        }
      } catch ImportError.notFound(_) {
        return []
      } catch {
        NSLog("[sync] reading passwords: \(error)")
        return nil
      }
    }.runOnQueue(Self.work)
  }

  private func disclose<T>(_ promise: Promise, on queue: DispatchQueue, _ reveal: @escaping ([String]) throws -> T?) {
    guard state.entropy != nil else { return promise.reject("locked", "Sync isn't set up on this Mac.") }
    owner.disclose(reason: "show your sync recovery phrase", current: { self.state.entropy }) { entropy in
      queue.async {
        guard let entropy, self.state.entropy == entropy else { return promise.resolve(nil) }
        do {
          promise.resolve(try reveal(RecoveryPhrase.words(for: entropy)))
        } catch {
          promise.reject(error)
        }
      }
    }
  }

  private static func refusal(_ reason: String) -> Exception {
    Exception(name: "sealedPasswords", description: reason)
  }

  private static func refusing<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let refused as PasswordValues.Refused {
      throw refusal(refused.description)
    }
  }

  private static func loginData(_ engineProfile: String) -> [(realm: String, username: String, password: String)]? {
    do {
      let key = ChromiumCrypto.deriveKey(secret: try safeStorageSecret())
      let read = try ChromiumSecrets.logins(profile: profileDirectory(engineProfile), key: key)
      guard read.undecryptable == 0 else { return nil }
      return read.items.map { ($0.realm ?? $0.url, $0.username, $0.password) }
    } catch ImportError.notFound(_) {
      return []
    } catch {
      return nil
    }
  }

  private func vault(_ folder: String) throws -> SyncVault {
    guard !SolaraCoreHost.safeMode else { throw Exception(name: "safe mode", description: "Sync is paused in safe mode.") }
    guard let keys = state.keys else { throw Exception(name: "locked", description: "Sync isn't set up on this Mac.") }
    return SyncVault(folder: URL(fileURLWithPath: folder, isDirectory: true), keys: keys)
  }

  private func words() throws -> [String] {
    guard let entropy = state.entropy else { throw Exception(name: "locked", description: "Sync isn't set up on this Mac.") }
    return RecoveryPhrase.words(for: entropy)
  }

  private static func kit(_ words: [String], text: Bool) -> Data {
    let device = Host.current().localizedName ?? "this Mac"
    return text ? Data(RecoveryKit.text(words: words, created: Date(), device: device).utf8)
      : RecoveryKit.pdf(words: words, created: Date(), device: device)
  }

  private static let temporaryKitFolder = FileManager.default.temporaryDirectory.appendingPathComponent(RecoveryKit.title, isDirectory: true)

  private static func removeTemporaryKits() {
    try? FileManager.default.removeItem(at: temporaryKitFolder)
  }

  private static func temporaryKit(_ words: [String]) throws -> URL {
    let dir = temporaryKitFolder
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = dir.appendingPathComponent(RecoveryKit.pdfName)
    try kit(words, text: false).write(to: url, options: [.atomic])
    return url
  }

  private static let hiddenWords = Array(repeating: "••••••", count: 24)

  private static func preview(width: CGFloat) -> String? {
    let pdf = kit(hiddenWords, text: false)
    guard let page = NSImage(data: pdf) else { return nil }
    let scale = (NSScreen.main?.backingScaleFactor ?? 2)
    let size = NSSize(width: width, height: width * page.size.height / page.size.width)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    page.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return "data:image/png;base64," + png.base64EncodedString()
  }

  private static let environment = ProcessInfo.processInfo.environment
  private static let dataDirectory = environment["SOLARA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
  private static let testFolder = environment["SOLARA_SYNC_DEFAULT_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }

  private static let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Solara"

  static var defaultFolder: URL {
    if let testFolder { return testFolder }
    if let dataDirectory { return dataDirectory.appendingPathComponent("\(productName) Sync", isDirectory: true) }
    return SyncFolder.iCloudDrive.appendingPathComponent("\(productName) Sync", isDirectory: true)
  }

  static let keyStore: SyncKeyStore = dataDirectory.map { FileKeyStore(directory: $0) } ?? KeychainKeyStore(service: KeychainKeyStore.service(info: Bundle.main.infoDictionary))

  static func profileDirectory(_ engineProfile: String) -> URL {
    let root = dataDirectory?.appendingPathComponent("Chromium", isDirectory: true)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "network.benson.solara.unbundled", isDirectory: true)
      .appendingPathComponent("Chromium", isDirectory: true)
    return root.appendingPathComponent(engineProfile.isEmpty ? "Default" : "Profile \(engineProfile)", isDirectory: true)
  }

  static func safeStorageSecret() throws -> Data {
    if !SolaraCoreHost.chromeUsesRealKeychain {
      return SafeStorageRekeyGate.testKeychainSecret(environment: ProcessInfo.processInfo.environment, chromeUsesRealKeychain: false)
        ?? Data("mock_password".utf8)
    }
    return try SafeStorageKeychain.secret(service: "\(productName) Safe Storage", account: productName)
  }

}

private final class KeyState {
  private let lock = NSLock()
  private var _entropy: Data?
  private var _keys: SyncKeys?

  func set(_ entropy: Data?) {
    lock.lock()
    defer { lock.unlock() }
    _entropy = entropy
    _keys = entropy.map(SyncKeys.init(entropy:))
  }

  var entropy: Data? {
    lock.lock()
    defer { lock.unlock() }
    return _entropy
  }

  var keys: SyncKeys? {
    lock.lock()
    defer { lock.unlock() }
    return _keys
  }
}
