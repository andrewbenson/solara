import AppKit

public struct AreaRecoveryState: Decodable, Equatable, Sendable {
  public var recoveryId: String
  public var fill: Bool
  public var plain: Bool
  public var textPrimary: String
  public var textSecondary: String
  #if DEBUG
    public var detail: String?
  #endif

  public static func decode(_ json: String) -> AreaRecoveryState? {
    guard let data = json.data(using: .utf8),
      let state = try? JSONDecoder().decode(Self.self, from: data), !state.recoveryId.isEmpty
    else { return nil }
    return state
  }
}

@MainActor
public final class AreaRecoveryView: NSView {
  public var onReload: () -> Void = {}
  public var onHeight: (CGFloat) -> Void = { _ in }
  public private(set) var state: AreaRecoveryState?
  private let message = NSTextField(labelWithString: "Something went wrong · ")
  private let reload = PromptPressable(frame: .zero)
  private let reloadLabel = NSTextField(labelWithString: "Reload")
  private let plainLabel = NSTextView(usingTextLayoutManager: false)
  #if DEBUG
    private let scroll = NSScrollView()
    private let detail = NSTextView(usingTextLayoutManager: false)
  #endif
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    message.font = .systemFont(ofSize: 12)
    reloadLabel.font = .systemFont(ofSize: 12, weight: .medium)
    message.isSelectable = false
    reloadLabel.isSelectable = false
    reloadLabel.setAccessibilityElement(false)
    plainLabel.isEditable = false
    plainLabel.isSelectable = false
    plainLabel.drawsBackground = false
    plainLabel.textContainerInset = .zero
    plainLabel.textContainer?.lineFragmentPadding = 0
    plainLabel.textContainer?.widthTracksTextView = false
    plainLabel.layoutManager?.usesFontLeading = false
    plainLabel.setAccessibilityElement(false)
    reload.acceptsFirstClick = true
    reload.setAccessibilityRole(.button)
    reload.setAccessibilityLabel("Reload")
    reload.onPress = { [weak self] in
      guard let self, state != nil, !isHiddenOrHasHiddenAncestor else { return }
      onReload()
    }
    reload.fill = { [weak self] _, pressed in
      guard let self, let state else { return nil }
      reloadLabel.textColor = CSSColor(pressed ? state.textSecondary : state.textPrimary)?.ns
      plainLabel.textColor = CSSColor(pressed ? state.textSecondary : state.textPrimary)?.ns
      return nil
    }
    reload.addSubview(reloadLabel)
    reload.addSubview(plainLabel)
    addSubview(message)
    addSubview(reload)
    #if DEBUG
      scroll.drawsBackground = false
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.borderType = .noBorder
      detail.isEditable = false
      detail.isSelectable = true
      detail.drawsBackground = false
      detail.font = NSFont(name: "Menlo", size: 11)
      detail.textColor = CSSColor("#ff8a8a")?.ns
      detail.textContainerInset = .zero
      detail.textContainer?.lineFragmentPadding = 0
      detail.isVerticallyResizable = true
      detail.isHorizontallyResizable = false
      detail.autoresizingMask = [.width]
      scroll.documentView = detail
      addSubview(scroll)
    #endif
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: AreaRecoveryState?) {
    state = next
    isHidden = next == nil
    guard let next else { return }
    message.textColor = CSSColor(next.textSecondary)?.ns
    reloadLabel.textColor = CSSColor(next.textPrimary)?.ns
    reloadLabel.font = .systemFont(ofSize: 12, weight: next.plain ? .regular : .medium)
    message.isHidden = next.plain
    reloadLabel.isHidden = next.plain
    plainLabel.isHidden = !next.plain
    reloadLabel.stringValue = next.plain ? "Something went wrong · Reload" : "Reload"
    plainLabel.string = "Something went wrong · Reload"
    plainLabel.font = .systemFont(ofSize: 12)
    plainLabel.textColor = CSSColor(next.textPrimary)?.ns
    reload.setAccessibilityHelp("Something went wrong")
    #if DEBUG
      detail.string = next.plain ? "" : next.detail ?? ""
    #endif
    place()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { place() }
  }

  private func place() {
    guard let state, bounds.width > 0 else { return }
    let inset: CGFloat = state.fill ? 16 : 12
    let inner = max(0, bounds.width - inset * 2)
    let messageSize = message.intrinsicContentSize
    let reloadSize = state.plain ? plainTextSize(width: inner) : reloadLabel.intrinsicContentSize
    let messageWidth = state.plain ? 0 : messageSize.width
    let reloadWidth = reloadSize.width
    let lineHeight = state.plain ? reloadSize.height : max(messageSize.height, reloadSize.height)
    var detailHeight: CGFloat = 0
    #if DEBUG
      scroll.isHidden = detail.string.isEmpty
      if !detail.string.isEmpty {
        detail.textContainer?.containerSize = CGSize(width: inner, height: .greatestFiniteMagnitude)
        detail.layoutManager?.ensureLayout(for: detail.textContainer!)
        let textHeight = ceil(detail.layoutManager?.usedRect(for: detail.textContainer!).height ?? 0)
        detail.frame = CGRect(x: 0, y: 0, width: inner, height: textHeight)
        detailHeight = state.fill ? min(320, max(0, bounds.height - inset * 2 - lineHeight - 12)) : min(320, textHeight)
      }
    #endif
    let contentHeight = lineHeight + (detailHeight > 0 ? 12 + detailHeight : 0)
    let top = state.fill ? max(inset, (bounds.height - contentHeight) / 2) : inset
    let left = state.fill ? max(inset, (bounds.width - messageWidth - reloadWidth) / 2) : inset
    message.frame = CGRect(x: left - 2, y: top, width: messageWidth + 4, height: lineHeight)
    reload.frame = CGRect(x: left + messageWidth, y: top, width: reloadWidth, height: lineHeight)
    reloadLabel.frame = CGRect(x: -2, y: 0, width: reloadWidth + 4, height: lineHeight)
    plainLabel.frame = reload.bounds
    #if DEBUG
      scroll.frame = CGRect(x: inset, y: top + lineHeight + 12, width: inner, height: detailHeight)
    #endif
    let height = contentHeight + inset * 2
    if !state.fill, height != reported {
      reported = height
      onHeight(height)
    }
  }

  private func plainTextSize(width: CGFloat) -> CGSize {
    guard let container = plainLabel.textContainer, let manager = plainLabel.layoutManager else { return .zero }
    container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    let size = manager.usedRect(for: container).size
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    return CGSize(width: ceil(ceil(size.width * scale) / scale + 0.001), height: ceil(ceil(size.height * scale) / scale + 0.001))
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard state != nil, !isHidden else { return nil }
    return super.hitTest(point)
  }

  #if DEBUG
    public var reloadControl: NSView { reload }
    public var detailText: String { detail.string }
    public var detailViewportFrame: CGRect { scroll.frame }
    public var detailDocumentHeight: CGFloat { detail.frame.height }
  #endif
}
