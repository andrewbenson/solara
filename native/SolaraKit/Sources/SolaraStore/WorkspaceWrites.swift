import Foundation

public enum WorkspaceWrites {
  @MainActor public static var store: Store? {
    guard !NativeStoreHandle.frozen, NativeStoreHandle.ownsWorkspace else { return nil }
    return NativeStoreHandle.store
  }
}
