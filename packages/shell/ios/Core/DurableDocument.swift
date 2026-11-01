import Darwin
import Foundation

enum DurableDocument {
  struct Operations: Sendable {
    let write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    let fileBarrier: @Sendable (Int32) throws -> Void
    let directoryBarrier: @Sendable (Int32) throws -> Void

    static let standard = Operations(
      write: { Darwin.write($0, $1, $2) },
      fileBarrier: { descriptor in
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw DurableDocument.failure() }
      },
      directoryBarrier: { descriptor in
        guard fsync(descriptor) == 0 else { throw DurableDocument.failure() }
      })
  }

  static func write(_ contents: String, to destination: URL, operations: Operations = .standard) throws {
    let folder = destination.deletingLastPathComponent()
    let temporary = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw failure() }
    defer {
      close(descriptor)
      unlink(temporary.path)
    }
    try Data(contents.utf8).withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = operations.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw failure() }
        offset += count
      }
    }
    try operations.fileBarrier(descriptor)
    guard rename(temporary.path, destination.path) == 0 else { throw failure() }
    let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw failure() }
    defer { close(directory) }
    try operations.directoryBarrier(directory)
  }

  private static func failure() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
