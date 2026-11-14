import AppKit
import SolaraEngine

public struct SidebarFaviconRequest: Hashable, Sendable {
  public var url: String
  public var favicon: String?
  public var profileId: String
  public var dark: Bool
  public var direct = false
}

@MainActor
public final class SidebarFavicons {
  public typealias Loader = @MainActor (SidebarFaviconRequest) async throws -> NSImage?

  public var loader: Loader?
  public var newTabMark: NSImage?
  private var cache: [SidebarFaviconRequest: NSImage] = [:]
  private var missing: Set<SidebarFaviconRequest> = []
  private var pending: [SidebarFaviconRequest: [(NSImage?) -> Void]] = [:]
  nonisolated(unsafe) private var invalidationObserver: NSObjectProtocol?

  public init() {
    invalidationObserver = NotificationCenter.default.addObserver(forName: FaviconLibrary.didInvalidate, object: nil, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.cache.removeAll()
        self?.missing.removeAll()
      }
    }
  }

  deinit { if let invalidationObserver { NotificationCenter.default.removeObserver(invalidationObserver) } }

  public func cached(_ request: SidebarFaviconRequest) -> NSImage?? {
    if let image = cache[request] { return .some(image) }
    if missing.contains(request) { return .some(nil) }
    return nil
  }

  public func load(_ request: SidebarFaviconRequest, _ done: @escaping (NSImage?) -> Void) {
    if let known = cached(request) { return done(known) }
    if pending[request] != nil {
      pending[request]?.append(done)
      return
    }
    guard let loader else { return done(nil) }
    pending[request] = [done]
    Task { @MainActor in
      let loaded = try? await loader(request)
      let image = loaded ?? nil
      if let image { self.cache[request] = image } else if loaded != nil { self.missing.insert(request) }
      if self.cache.count > 2000 { self.cache.removeAll() }
      let waiting = self.pending.removeValue(forKey: request) ?? []
      for callback in waiting { callback(image) }
    }
  }

  public func forget(url: String) {
    for key in cache.keys where key.url == url { cache[key] = nil }
    missing = missing.filter { $0.url != url }
  }
}

struct TabIconSpec: Equatable {
  var url: String
  var favicon: String?
  var customIcon: String?
  var profileId: String
  var size: CGFloat = 16
  var dimmed = false
  var engineSymbol: String?
  var direct = false

  static func engineName(_ symbol: String?) -> String? {
    switch symbol {
    case "safari": "WebKit"
    case "globe": "Chromium"
    default: nil
    }
  }
}

final class TabIconView: NSView {
  private var madeImage: PictureLayer?
  private var madeSymbol: SymbolView?
  private var madeEmoji: NSTextField?
  private var madeInitial: DrawnLetterView?
  private let fallback = CALayer()
  private var badge: NSView?
  private var spec: TabIconSpec?
  private var dark = true
  private var palette: SidebarPalette?
  private var requested: SidebarFaviconRequest?
  private var renderedMark: NSImage?
  private var resolved: (state: FaviconState, image: NSImage?)?
  weak var favicons: SidebarFavicons?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    fallback.cornerCurve = .continuous
    fallback.actions = SurfaceLayer.noActions
    layer?.insertSublayer(fallback, at: 0)
  }

  required init?(coder: NSCoder) { fatalError() }

  private func made<View: NSView>(_ view: inout View?, _ make: () -> View) -> View {
    if let view { return view }
    let made = make()
    if let badge { addSubview(made, positioned: .below, relativeTo: badge) } else { addSubview(made) }
    view = made
    return made
  }

  private var image: PictureLayer {
    if let madeImage { return madeImage }
    let picture = PictureLayer()
    layer?.insertSublayer(picture, above: fallback)
    madeImage = picture
    return picture
  }

  private var symbol: SymbolView { made(&madeSymbol) { SymbolView() } }

  private var emoji: NSTextField { made(&madeEmoji) { Self.centeredLabel() } }

  private var initial: DrawnLetterView { made(&madeInitial) { DrawnLetterView() } }

  private static func centeredLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.alignment = .center
    return label
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ spec: TabIconSpec, palette: SidebarPalette) {
    resolved = nil
    madeImage?.contentsGravity = .resizeAspect
    let same = spec == self.spec && palette.dark == dark && self.palette != nil && renderedMark === favicons?.newTabMark
    self.spec = spec
    self.palette = palette
    dark = palette.dark
    alphaValue = spec.dimmed ? 0.45 : 1
    guard !same else { return }
    render()
  }

  override func layout() {
    super.layout()
    render()
  }

  func setResolved(_ state: FaviconState, image: NSImage?) {
    resolved = (state, image)
    var host = SidebarHostState(profileId: "", dark: state.dark)
    host.theme = ["textSecondary": state.textSecondary]
    palette = SidebarPalette(host)
    dark = state.dark
    spec = TabIconSpec(url: state.url, favicon: nil, customIcon: nil, profileId: "", size: state.size)
    render()
  }

  private func render() {
    guard let spec, let palette else { return }
    renderedMark = favicons?.newTabMark
    let size = spec.size
    let box = NSRect(x: 0, y: 0, width: size, height: size)
    for view in [madeSymbol, madeEmoji, madeInitial] as [NSView?] { view?.isHidden = true }
    madeImage?.isHidden = true
    fallback.isHidden = true
    if let resolved {
      if resolved.state.mode == "fallback" {
        showFallback(spec, initial: resolved.state.initial, textLayout: true)
      } else {
        image.contentsGravity = .resizeAspectFill
        let mark = resolved.state.mode == "newTab"
        let tint = mark ? (dark ? NSColor.white : NSColor.black) : resolved.state.tint.flatMap { CSSColor($0)?.ns }
        image.show(resolved.image, in: box, tint: tint, alpha: mark ? (dark ? 0.28 : 0.3) : 1,
          radius: mark ? 0 : size > 18 ? 4 : 3, scale: window?.backingScaleFactor ?? 2)
      }
      return
    }
    if let icon = spec.customIcon, icon.hasPrefix("symbol:") {
      let name = String(icon.dropFirst("symbol:".count))
      let ink = icon == "symbol:square.stack.fill" ? palette.noGroupIcon : palette.icon
      symbol.frame = box
      symbol.set(name, size: size - 3, weight: .medium, color: ink)
      symbol.isHidden = false
    } else if let icon = spec.customIcon, !icon.isEmpty {
      emoji.font = .systemFont(ofSize: size - 3)
      emoji.stringValue = icon
      let fitting = emoji.fittingSize
      emoji.frame = NSRect(x: (size - fitting.width) / 2, y: (size - fitting.height) / 2, width: fitting.width, height: fitting.height)
      emoji.isHidden = false
    } else if spec.url.isEmpty && (spec.favicon ?? "").isEmpty {
      image.show(favicons?.newTabMark, in: box, tint: dark ? .white : .black, alpha: dark ? 0.28 : 0.3, radius: 0, scale: window?.backingScaleFactor ?? 2)
    } else {
      showFavicon(spec, box: box)
    }
    renderBadge(spec, palette: palette)
  }

  private func showFavicon(_ spec: TabIconSpec, box: NSRect) {
    let request = SidebarFaviconRequest(url: spec.url, favicon: spec.favicon, profileId: spec.profileId, dark: dark, direct: spec.direct)
    let radius: CGFloat = spec.size > 18 ? 4 : 3
    if let known = favicons?.cached(request) {
      if let picture = known {
        image.show(picture, in: box, tint: nil, alpha: 1, radius: radius, scale: window?.backingScaleFactor ?? 2)
      } else {
        showFallback(spec)
      }
      return
    }
    showFallback(spec)
    requested = request
    favicons?.load(request) { [weak self] picture in
      guard let self, picture != nil, self.requested == request else { return }
      self.render()
    }
  }

  private func showFallback(_ spec: TabIconSpec, initial: String? = nil, textLayout: Bool = false) {
    guard let palette else { return }
    let size = spec.size
    let letter = initial ?? Self.hostInitial(spec.url)
    if letter.isEmpty {
      symbol.frame = NSRect(x: 0, y: 0, width: size, height: size)
      symbol.set("globe", size: size - 3, color: palette.textSecondary)
      symbol.isHidden = false
      return
    }
    let tile = (size * 14 / 16).rounded()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fallback.frame = CGRect(x: (size - tile) / 2, y: (size - tile) / 2, width: tile, height: tile)
    fallback.cornerRadius = tile * 0.32
    fallback.backgroundColor = (dark ? NSColor(srgbRed: 247 / 255, green: 245 / 255, blue: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.13)).cgColor
    fallback.isHidden = false
    CATransaction.commit()
    let initial = self.initial
    initial.set(letter, font: .systemFont(ofSize: (tile * 0.64).rounded(), weight: .semibold), color: palette.textSecondary, lineHeight: textLayout ? tile : nil)
    initial.frame = NSRect(x: 0, y: 0, width: size, height: size)
    initial.isHidden = false
  }

  private func renderBadge(_ spec: TabIconSpec, palette: SidebarPalette) {
    guard let name = spec.engineSymbol, spec.size >= 14 else {
      badge?.removeFromSuperview()
      badge = nil
      return
    }
    let box = (spec.size * 0.6).rounded()
    let holder = badge ?? NSView()
    holder.wantsLayer = true
    holder.layer?.cornerRadius = box / 2
    holder.layer?.backgroundColor = (palette.dark ? NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1) : .white).cgColor
    holder.frame = NSRect(x: spec.size - box + box / 3, y: spec.size - box + box / 3, width: box, height: box)
    let mark = (holder.subviews.first as? SymbolView) ?? SymbolView()
    if mark.superview == nil { holder.addSubview(mark) }
    mark.frame = holder.bounds
    mark.set(name, size: box - 3, weight: .semibold, color: palette.icon)
    holder.setAccessibilityElement(true)
    holder.setAccessibilityRole(.image)
    holder.setAccessibilityLabel(TabIconSpec.engineName(name).map { "Opens in \($0)" })
    if holder.superview == nil { addSubview(holder) }
    badge = holder
  }

  static func hostInitial(_ url: String) -> String {
    guard let match = url.range(of: #"^(?:https?|ftp)://(?:[^@/?#]*@)?([^/?#:]+)"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
    var host = String(url[match])
    if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
    if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    host = host.lowercased()
    if host.range(of: #"^[\d.]+$"#, options: .regularExpression) != nil || host.hasPrefix("[") { return "" }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host.first.map { String($0).uppercased() } ?? ""
  }
}

final class DrawnLetterView: NSView {
  private var text = NSAttributedString()
  private var lineHeight: CGFloat?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ letter: String, font: NSFont, color: NSColor, lineHeight: CGFloat? = nil) {
    let next = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: color])
    guard next != text || self.lineHeight != lineHeight else { return }
    self.lineHeight = lineHeight
    text = next
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return }
    let scale = window?.backingScaleFactor ?? 2
    if let lineHeight {
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = lineHeight
      paragraph.maximumLineHeight = lineHeight
      let laidOut = NSMutableAttributedString(attributedString: text)
      let range = NSRange(location: 0, length: laidOut.length)
      laidOut.addAttribute(.paragraphStyle, value: paragraph, range: range)
      let fontLineHeight = ceil(font.ascender + abs(font.descender) + font.leading)
      if lineHeight >= fontLineHeight {
        laidOut.addAttribute(.baselineOffset, value: (lineHeight - fontLineHeight) / 2, range: range)
      }
      let storage = NSTextStorage(attributedString: laidOut)
      let manager = NSLayoutManager()
      manager.usesFontLeading = false
      let container = NSTextContainer(size: NSSize(width: bounds.width, height: .greatestFiniteMagnitude))
      container.lineFragmentPadding = 0
      storage.addLayoutManager(manager)
      manager.addTextContainer(container)
      manager.ensureLayout(for: container)
      let used = manager.usedRect(for: container).size
      let measured = NSSize(width: ceil(used.width * scale) / scale + 0.001, height: ceil(used.height * scale) / scale + 0.001)
      let origin = NSPoint(x: floor((bounds.width - measured.width) / 2 * scale) / scale,
        y: floor((bounds.height - measured.height) / 2 * scale) / scale)
      manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: origin)
      return
    }
    let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
    let x = snap((bounds.width - text.size().width) / 2)
    let y = snap((bounds.height - font.capHeight) / 2 - (font.ascender - font.capHeight))
    text.draw(at: NSPoint(x: x, y: y))
  }
}

final class PictureLayer: CALayer {
  private var shown: (image: NSImage, tint: NSColor?, scale: CGFloat)?

  override init() {
    super.init()
    actions = SurfaceLayer.noActions
    contentsGravity = .resizeAspect
    masksToBounds = true
    minificationFilter = .trilinear
  }

  override init(layer: Any) { super.init(layer: layer) }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ image: NSImage?, in frame: CGRect, tint: NSColor?, alpha: CGFloat, radius: CGFloat, scale: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.frame = frame
    opacity = Float(alpha)
    cornerRadius = radius
    contentsScale = scale
    if let image {
      if shown.map({ $0.image !== image || $0.tint != tint || $0.scale != scale }) ?? true {
        shown = (image, tint, scale)
        let source = tint.map { Self.tinted(image, $0) } ?? image
        contents = source.layerContents(forContentsScale: source.recommendedLayerContentsScale(scale))
      }
    } else {
      shown = nil
      contents = nil
    }
    isHidden = false
    CATransaction.commit()
  }

  private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect)
      color.set()
      rect.fill(using: .sourceIn)
      return true
    }
  }
}

public struct FaviconState: Decodable, Equatable, Sendable {
  public var url: String
  public var size: CGFloat
  public var dark: Bool
  public var textSecondary: String
  public var mode: String
  public var initial: String?
  public var uri: String?
  public var tint: String?
  public var token: Int

  public static func decode(_ json: String) -> FaviconState? {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(Self.self, from: data),
      state.size.isFinite, state.size > 0, state.size <= 512,
      ["fallback", "image", "newTab"].contains(state.mode) else { return nil }
    return state
  }
}

public final class FaviconView: NSView {
  private let icon = TabIconView(frame: .zero)
  public private(set) var state: FaviconState?
  public private(set) var hasImage = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(false)
    addSubview(icon)
  }

  public required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func update(_ state: FaviconState?, image: NSImage?) {
    self.state = state
    hasImage = image != nil
    isHidden = state == nil
    guard let state else { return }
    icon.frame = NSRect(x: 0, y: 0, width: state.size, height: state.size)
    icon.setResolved(state, image: image)
  }
}
