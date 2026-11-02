import Foundation
import Security
import Darwin

enum PairingKeyLookup: Equatable {
  case absent
  case found(Data)
  case failure
}

protocol PairingInstallationKeyStoring {
  func pairingLookup(account: String) -> PairingKeyLookup
  func pairingInsert(_ secret: Data, account: String) -> Bool
}

extension KeychainKeyStore: PairingInstallationKeyStoring {
  func pairingLookup(account: String) -> PairingKeyLookup {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { return .absent }
    guard status == errSecSuccess, let bytes = item as? Data, bytes.count == 32 else { return .failure }
    return .found(bytes)
  }

  func pairingInsert(_ secret: Data, account: String) -> Bool {
    guard secret.count == 32 else { return false }
    var q = query(account)
    q[kSecValueData as String] = secret
    q[kSecAttrLabel as String] = service
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }
}

extension FileKeyStore: PairingInstallationKeyStoring {
  private func validPairingAccount(_ account: String) -> Bool {
    !account.isEmpty && account.utf8.count <= 128 && account.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
  }

  func pairingLookup(account: String) -> PairingKeyLookup {
    guard validPairingAccount(account) else { return .failure }
    let fd = open(url(account).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if fd < 0 { return errno == ENOENT ? .absent : .failure }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == 32 else { return .failure }
    var bytes = Data(count: 32)
    guard bytes.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, 32, 0) }) == 32 else { return .failure }
    return .found(bytes)
  }

  func pairingInsert(_ secret: Data, account: String) -> Bool {
    guard secret.count == 32, validPairingAccount(account) else { return false }
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { return false }
    let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { return false }
    defer { close(parent) }
    let fd = openat(parent, "sync-key-\(account)", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var offset = 0
    while offset < secret.count {
      let count = secret.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), secret.count - offset) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return false }
      offset += count
    }
    return fsync(fd) == 0 && fsync(parent) == 0
  }
}
