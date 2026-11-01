import SolaraUI
import Testing

@Suite struct RNPageCallPolicyTests {
  @Test func unattachedWorkspacePageCannotCallDirectly() {
    for propsReady in [false, true] {
      #expect(!RNPageCallPolicy.allowsUnattachedFallback(ownsWorkspace: true,
        transferKey: "workspace-tab", propsReady: propsReady))
      #expect(!RNPageCallPolicy.allowsUnattachedFallback(ownsWorkspace: true,
        transferKey: "", propsReady: propsReady))
    }
  }

  @Test func unappliedPropsDoNotProvePageIsUnowned() {
    #expect(!RNPageCallPolicy.allowsUnattachedFallback(ownsWorkspace: true,
      transferKey: nil, propsReady: false))
  }

  @Test func appliedKeylessPageIsUnowned() {
    #expect(RNPageCallPolicy.allowsUnattachedFallback(ownsWorkspace: true,
      transferKey: nil, propsReady: true))
  }

  @Test func nativeStoreOffAllowsLegacyCalls() {
    let keys: [String?] = [nil, "", "workspace-tab"]
    for key in keys {
      for propsReady in [false, true] {
        #expect(RNPageCallPolicy.allowsUnattachedFallback(ownsWorkspace: false,
          transferKey: key, propsReady: propsReady))
      }
    }
  }
}
