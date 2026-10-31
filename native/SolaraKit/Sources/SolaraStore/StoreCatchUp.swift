import SolaraModel

public enum StoreCatchUp: Sendable {
  case patches(rev: Int, patches: [Patch])
  case snapshot(rev: Int, state: BrowserState)
}
