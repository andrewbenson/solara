public enum RNPageCallPolicy {
  public static func allowsUnattachedFallback(ownsWorkspace: Bool, transferKey: String?, propsReady: Bool) -> Bool {
    !ownsWorkspace || (propsReady && transferKey == nil)
  }
}
