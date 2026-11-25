import AppKit
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI
@MainActor
enum NativeLinkCommands {
  private static var requests: [String: UUID] = [:]
  #if DEBUG
  private static var capturing = false
  private static var copied: [String] = []
  private static var quoteAction: (() -> Void)?
  static func probe(_ action: String) -> [String] {
    if action == "begin" { capturing = true; copied = []; requests = [:]; quoteAction = nil }
    if action == "offer" { return quoteAction == nil ? [] : ["ready"] }
    if action == "quote" { let run = quoteAction; quoteAction = nil; run?() }
    if action == "end" { capturing = false; quoteAction = nil; requests = [:] }
    return copied
  }
  #endif
  private static func copy(_ text: String) {
    #if DEBUG
    if capturing { copied.append(text); return }
    #endif
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return false }
    let decoded = arg.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    if let arg, decoded == nil && !(command == "share" && arg.hasPrefix("via:")) { return true }
    let options = decoded ?? [:]
    for key in ["tabId", "groupId", "via"] where options[key] != nil { if !(options[key] is String) { return true } }
    if options["ids"] != nil && !(options["ids"] is [String]) { return true }
    guard let plan = CopyLinkCommand.plan(command, windowId: windowId ?? (options["tabId"] as? String).flatMap { store.state.tabs[$0]?.windowId }, state: store.state, closing: store.memory.closingWindows,
      tabId: options["tabId"] as? String, ids: options["ids"] as? [String], groupId: options["groupId"] as? String) else { return true }
    requests = requests.filter { store.state.windows[$0.key] != nil }
    let request = UUID()
    requests[plan.windowId] = request
    if command == "share" {
      let title = store.state.tabs[plan.tabId].map { CopyLinkCommand.label($0, fallback: false) }
      let via = options["via"] as? String ?? (arg?.hasPrefix("via:") == true ? String(arg!.dropFirst(4)) : nil)
      if let via { SharePicker.perform(service: via, url: cleanUrl(plan.url), title: title, windowId: plan.windowId) }
      else { SharePicker.show(url: cleanUrl(plan.url), title: title, windowId: plan.windowId, anchor: options["anchor"] as? [Double]) {} }
      return true
    }
    func toast(_ title: String, quote: Bool = false, action: (() -> Void)? = nil) {
      guard let host = WindowHost.contentView(plan.windowId) else { return }
      LinkToast.show(in: host, title: title, quote: quote, action: action)
    }
    if command != "copyQuoteLink" {
      if plan.count > 0 { copy(plan.text) }
      if let title = plan.title { toast(title) }
    }
    guard command == "copyQuoteLink" || plan.offerQuote,
      plan.url.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil,
      let issuer = PageIssuer.shared else { return true }
    let ownership = NativeStoreHandle.ownershipGeneration
    issuer.store.sequence {
      guard let binding = issuer.binding(tabId: plan.tabId), issuer.ensurePageEstablished(binding), issuer.isCurrent(binding) else { return }
      let identity = binding.identity
      @MainActor func current() -> Bool {
        guard requests[plan.windowId] == request, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == ownership,
          !store.memory.closingWindows.contains(plan.windowId), store.state.tabs[plan.tabId]?.url == plan.url,
          let now = CopyLinkCommand.plan("copyQuoteLink", windowId: plan.windowId, state: store.state, closing: store.memory.closingWindows),
          now.tabId == plan.tabId else { return false }
        return issuer.store.sequence { issuer.binding(tabId: plan.tabId).map { $0.identity == identity && issuer.isCurrent($0) } ?? false }
      }
      @MainActor func quote() {
        guard current() else { return }
        issuer.store.sequence {
          issuer.issueInScope(tabId: plan.tabId, identity: identity, command: .evaluate(Self.selectionContext)) { result in
            guard current(), case .success(let value) = result, let text = CopyLinkCommand.quote(value, url: plan.url) else { return }
            copy(text)
            toast("Copied Quote Link")
          }
        }
      }
      if command == "copyQuoteLink" { quote(); return }
      issuer.issueInScope(tabId: plan.tabId, identity: identity, command: .evaluate("post('result', JSON.stringify(!!String(getSelection() || '').trim()))")) { result in
        guard current(), case .success(let value) = result, CopyLinkCommand.hasSelection(value) else { return }
        #if DEBUG
        if capturing { quoteAction = quote }
        #endif
        toast(plan.title ?? "Copied Current URL", quote: true, action: quote)
      }
    }
    return true
  }
  private static let selectionContext = """
  (() => { const sel = getSelection(); if (!sel || sel.isCollapsed || !sel.rangeCount) return post("result", "null"); const range = sel.getRangeAt(0); const block = (node) => { let el = node.nodeType === 1 ? node : node.parentElement; while (el && el !== document.body && !/^(block|list-item|table|table-cell|flex|grid)$/.test(getComputedStyle(el).display)) el = el.parentElement; return el || document.body; }; const text = (from, to) => { const r = document.createRange(); try { r.setStart(...from); r.setEnd(...to); } catch (e) { return ""; } return r.toString(); }; const startBlock = block(range.startContainer), endBlock = block(range.endContainer); post("result", JSON.stringify({ selected: sel.toString(), before: text([startBlock, 0], [range.startContainer, range.startOffset]), after: text([range.endContainer, range.endOffset], [endBlock, endBlock.childNodes.length]), pageText: (document.body.innerText || "").slice(0, 3000000), })); })()
  """
}
