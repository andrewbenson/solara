import Foundation

public struct HistoryRow: Sendable, Equatable {
  public var url: String
  public var title: String
  public var favicon: String?
  public var visits: Double
  public var lastVisit: Double

  public init(url: String, title: String, favicon: String?, visits: Double, lastVisit: Double) {
    self.url = url
    self.title = title
    self.favicon = favicon
    self.visits = visits
    self.lastVisit = lastVisit
  }
}

public struct BookmarkRow: Sendable, Equatable {
  public var url: String
  public var title: String
  public var favicon: String?

  public init(url: String, title: String, favicon: String?) {
    self.url = url
    self.title = title
    self.favicon = favicon
  }
}

public struct TabRow: Sendable, Equatable {
  public var id: String
  public var url: String
  public var title: String
  public var favicon: String?

  public init(id: String, url: String, title: String, favicon: String?) {
    self.id = id
    self.url = url
    self.title = title
    self.favicon = favicon
  }
}

public struct SuggestionSource: Sendable {
  public var tabs: [TabRow]
  public var history: [HistoryRow]
  public var bookmarks: [BookmarkRow]

  public init(tabs: [TabRow] = [], history: [HistoryRow] = [], bookmarks: [BookmarkRow] = []) {
    self.tabs = tabs
    self.history = history
    self.bookmarks = bookmarks
  }
}

public struct CommandAction: ActionCandidate, Equatable {
  public var id: String
  public var title: String
  public var keywords: [String]?
  public var icon: String?
  public var hint: String?

  public init(id: String, title: String, keywords: [String]? = nil, icon: String? = nil, hint: String? = nil) {
    self.id = id
    self.title = title
    self.keywords = keywords
    self.icon = icon
    self.hint = hint
  }
}

public enum SearchPreference: String, Sendable, Equatable {
  case website, search
}

public struct SuggestOptions: Sendable {
  public var limit: Int
  public var now: Double?
  public var engine: SearchEngine
  public var preference: SearchPreference
  public var remote: [String]
  public var actions: ActionIndex<CommandAction>?
  public var extensions: [ExtensionCandidate]
  public var currentTabId: String?
  public var currentUrl: String?
  public var scope: SearchScope?
  public var preventInline: Bool
  public var bangs: (any BangTable)?

  public init(
    limit: Int = 8, now: Double? = nil, engine: SearchEngine = builtInEngines[0], preference: SearchPreference = .website, remote: [String] = [],
    actions: ActionIndex<CommandAction>? = nil, extensions: [ExtensionCandidate] = [], currentTabId: String? = nil, currentUrl: String? = nil,
    scope: SearchScope? = nil, preventInline: Bool = false, bangs: (any BangTable)? = nil
  ) {
    self.limit = limit
    self.now = now
    self.engine = engine
    self.preference = preference
    self.remote = remote
    self.actions = actions
    self.extensions = extensions
    self.currentTabId = currentTabId
    self.currentUrl = currentUrl
    self.scope = scope
    self.preventInline = preventInline
    self.bangs = bangs
  }
}

public struct SuggestionResult: Sendable, Equatable {
  public var items: [Suggestion]
  public var completion: String

  public init(items: [Suggestion], completion: String) {
    self.items = items
    self.completion = completion
  }
}

private let day = 86_400_000.0

typealias Bytes = [UInt8]

extension Array where Element == UInt8 {
  init(utf8 units: Units) { self = Array(String(units: units).utf8) }

  func find(_ needle: Bytes) -> Int? {
    let n = needle.count
    if n == 0 { return 0 }
    if n > count { return nil }
    return withUnsafeBufferPointer { hay in
      needle.withUnsafeBufferPointer { pin in
        let base = hay.baseAddress!
        let first = Int32(pin[0])
        var at = 0
        let last = hay.count - n
        while at <= last {
          guard let hit = memchr(base + at, first, last - at + 1) else { return nil }
          let i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
          if n == 1 || memcmp(base + i + 1, pin.baseAddress! + 1, n - 1) == 0 { return i }
          at = i + 1
        }
        return nil
      }
    }
  }

  func has(_ needle: Bytes) -> Bool { find(needle) != nil }

  var mask: UInt64 {
    var m: UInt64 = 0
    for b in self { m |= 1 << UInt64(b & 63) }
    return m
  }

  func starts(_ prefix: Bytes) -> Bool {
    prefix.count <= count && withUnsafeBufferPointer { hay in prefix.withUnsafeBufferPointer { p in p.count == 0 || memcmp(hay.baseAddress!, p.baseAddress!, p.count) == 0 } }
  }
}

final class PageText {
  let url: Units
  let key: Units
  let shown: Units
  let shownLower: Units
  let shownLower8: Bytes
  let titleLower8: Bytes
  let titleWords8: Bytes
  let shownMask: UInt64
  let titleMask: UInt64
  private var shownWordsStore: Bytes?
  private var shownBlankStore: Bool?
  private var hostStore: Units?
  private var originComputed = false
  private var originStore: Units?
  private var hostLowerStore: Bytes?

  init(url: String, title: String) {
    let u = url.units
    self.url = u
    key = pageKey(u)
    shown = displayUrl(u)
    shownLower = JS.lower(shown)
    shownLower8 = Bytes(utf8: shownLower)
    let titleLower = JS.lower(title.units)
    titleLower8 = Bytes(utf8: titleLower)
    titleWords8 = Bytes(utf8: wordsLine(titleLower))
    shownMask = shownLower8.mask
    titleMask = titleLower8.mask
  }

  var shownWords8: Bytes {
    if let w = shownWordsStore { return w }
    let w = Bytes(utf8: wordsLine(shownLower))
    shownWordsStore = w
    return w
  }

  var shownBlank: Bool {
    if let b = shownBlankStore { return b }
    let b = JS.hasSpace(shownLower)
    shownBlankStore = b
    return b
  }

  var host: Units {
    if let h = hostStore { return h }
    let h = hostOf(url)
    hostStore = h
    return h
  }

  var hostLower8: Bytes {
    if let h = hostLowerStore { return h }
    let h = Bytes(utf8: hostPart(shownLower))
    hostLowerStore = h
    return h
  }

  var origin: Units? {
    if originComputed { return originStore }
    originComputed = true
    originStore = webOrigin(url)
    return originStore
  }
}

private func wordsLine(_ lower: Units) -> Units {
  var out: Units = [Unit.space]
  out.reserveCapacity(lower.count + 1)
  var inGap = false
  for c in lower {
    if Unit.isLowerAlnum(c) {
      out.append(c)
      inGap = false
    } else if !inGap {
      out.append(Unit.space)
      inGap = true
    }
  }
  return out
}

private func hostPart(_ shown: Units) -> Units {
  let end = shown.firstIndex { $0 == Unit.slash || $0 == Unit.question || $0 == Unit.hash } ?? shown.count
  return end == shown.count ? shown : Array(shown[..<end])
}

private func webOrigin(_ url: Units) -> Units? {
  let start: Int
  if url.asciiCaseInsensitivePrefix("https://") {
    start = 8
  } else if url.asciiCaseInsensitivePrefix("http://") {
    start = 7
  } else {
    return nil
  }
  var end = start
  while end < url.count && url[end] != Unit.slash && url[end] != Unit.question && url[end] != Unit.hash { end += 1 }
  return end == start ? nil : Array(url[..<end])
}

private let logVisitsTable: [Double] = (0..<1024).map { FdLibm.log2(1 + Double($0)) * 8 }

private func logVisits(_ visits: Double) -> Double {
  if visits >= 0 && visits < 1024, visits == visits.rounded(.towardZero) { return logVisitsTable[Int(visits)] }
  return FdLibm.log2(1 + visits) * 8
}

final class Candidate {
  let url: String
  let title: String
  let favicon: String?
  let visits: Double
  let lastVisit: Double
  let logVisits: Double
  let bookmarked: Bool
  let tabId: String?
  let fresh: Bool
  let text: PageText

  init(url: String, title: String, favicon: String?, visits: Double, lastVisit: Double, logVisits: Double, bookmarked: Bool, tabId: String? = nil, fresh: Bool = false, text: PageText) {
    self.url = url
    self.title = title
    self.favicon = favicon
    self.visits = visits
    self.lastVisit = lastVisit
    self.logVisits = logVisits
    self.bookmarked = bookmarked
    self.tabId = tabId
    self.fresh = fresh
    self.text = text
  }
}

struct ExactKey: Hashable {
  let a: String
  let b: String

  static func == (x: ExactKey, y: ExactKey) -> Bool { sameBytes(x.a, y.a) && sameBytes(x.b, y.b) }

  func hash(into hasher: inout Hasher) {
    var a = a
    var b = b
    a.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    hasher.combine(0xff as UInt8)
    b.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
  }
}

private struct Query {
  let q: Units
  let q8: Bytes
  let length: Int
  let segmentStarts: (Bytes, Bytes)?
  let word: Bool
  let spaced: Bytes
  let tokens: [(text: Bytes, length: Int, word: Bool, spaced: Bytes)]
  let needle: Bytes
  let qMask: UInt64
  let needleMask: UInt64

  init(_ q: Units, _ tokens: [Units]) {
    self.q = q
    q8 = Bytes(utf8: q)
    length = q.count
    let hasDotOrSlash = q.contains { $0 == Unit.dot || $0 == Unit.slash }
    segmentStarts = hasDotOrSlash ? nil : ([UInt8(ascii: ".")] + q8, [UInt8(ascii: "/")] + q8)
    word = !q.isEmpty && q.allSatisfy(Unit.isLowerAlnum)
    spaced = [UInt8(ascii: " ")] + q8
    self.tokens = tokens.map { token in
      let t8 = Bytes(utf8: token)
      return (t8, token.count, !token.isEmpty && token.allSatisfy(Unit.isLowerAlnum), [UInt8(ascii: " ")] + t8)
    }
    needle = Bytes(utf8: tokens.reduce(Units()) { $1.count > $0.count ? $1 : $0 })
    qMask = q8.mask
    needleMask = needle.mask
  }
}

private func matchScore(_ t: PageText, _ query: Query) -> Double {
  let shown = t.shownLower8
  let title = t.titleLower8
  let q = query.q8
  let needleInShown = query.needleMask & ~t.shownMask == 0 && shown.has(query.needle)
  if !needleInShown && !(query.needleMask & ~t.titleMask == 0 && title.has(query.needle)) { return 0 }
  var s: Double = 0
  if t.shownBlank {
    if shown.starts(q) {
      s = 100
    } else if let seg = query.segmentStarts, shown.has(seg.0) || shown.has(seg.1) {
      s = 60
    } else if shown.has(q) {
      s = 30
    }
  }
  if let ti = title.find(q) {
    s += ti == 0 ? 40 : 20
  }
  if s > 0 { return s }
  for token in query.tokens {
    if token.word && t.titleWords8.has(token.spaced) {
      s += 15
    } else if token.word && t.shownWords8.has(token.spaced) {
      s += 10
    } else if token.length >= 3 && (title.has(token.text) || shown.has(token.text)) {
      s += 5
    } else {
      return 0
    }
  }
  return s
}

private func matchScoreWord(_ t: PageText, _ query: Query) -> Double {
  let shown = t.shownLower8
  let title = t.titleLower8
  let q = query.q8
  let si = query.qMask & ~t.shownMask == 0 ? shown.find(q) ?? -1 : -1
  let ti = query.qMask & ~t.titleMask == 0 ? title.find(q) ?? -1 : -1
  if si < 0 && ti < 0 { return 0 }
  var s: Double = 0
  if si == 0 {
    s = 100
  } else if si > 0 {
    if let seg = query.segmentStarts, shown.has(seg.0) || shown.has(seg.1) {
      s = 60
    } else if query.length >= 2 {
      s = 30
    }
  }
  if ti == 0 {
    s += 40
  } else if query.length >= 2 ? ti > 0 : query.word && t.titleWords8.has(query.spaced) {
    s += 20
  }
  return s
}

private struct Matched {
  let q: Units
  let tokens: [Units]
  let pages: [Candidate]
  let scores: [Double]
}

private struct Ranked {
  let c: Candidate
  let tabId: String?
  let m: Double
  let s: Double
}

private struct Ranking {
  var top: TopList
  var onSite: TopList?
  var inline: Ranked?
  let limit: Int
  let now: Double
  let currentKey: Units?
  let completes: Bool
  let bound: Bool
  let q: Units
  let q8: Bytes
  let tabIds: [UnitsKey: String]
  let scopeHost: Units
  let scopeSuffix: Units

  mutating func consider(_ c: Candidate, _ m: Double) {
    let key = c.text.key
    let derank: Double = currentKey != nil && key == currentKey! ? 80 : 0
    let lastVisit = c.fresh ? now : c.lastVisit
    var age: Double = 10
    if lastVisit != 0 && !lastVisit.isNaN {
      let d = (now - lastVisit) / day
      age = d < 0 ? 0 : d > 30 ? 30 : d
    }
    let base = c.logVisits - age + (c.bookmarked ? 20 : 0)
    if !bound && top.floor >= m + base - derank + 7 {
      if !completes { return }
      if let inline, inline.s >= m + base - derank + 7 { return }
      if c.visits <= 0 || !c.text.shownLower8.starts(q8) { return }
    }
    let tabId = c.tabId ?? (tabIds.isEmpty ? nil : tabIds[UnitsKey(key)])
    let s = m + (base + (tabId?.isEmpty == false ? 6 : 0)) - derank
    var r: Ranked?
    if top.floor < s || top.items.count < limit + 1 {
      r = Ranked(c: c, tabId: tabId, m: m, s: s)
      top.offer(r!)
    }
    if onSite != nil {
      let host = c.text.host
      if host == scopeHost || host.hasSuffix(scopeSuffix) { onSite!.offer(r ?? Ranked(c: c, tabId: tabId, m: m, s: s)) }
    }
    if completes && (inline == nil || s > inline!.s) && c.visits > 0 && inlineMatch(c.text, q, q8) { inline = r ?? Ranked(c: c, tabId: tabId, m: m, s: s) }
  }
}

private struct TopList {
  var items: [Ranked] = []
  var floor = -Double.infinity
  let size: Int

  init(_ size: Int) { self.size = size }

  mutating func offer(_ r: Ranked) {
    if items.count == size && items[items.count - 1].s >= r.s { return }
    var i = items.count
    while i > 0 && items[i - 1].s < r.s { i -= 1 }
    items.insert(r, at: i)
    if items.count > size { items.removeLast() }
    if items.count == size { floor = items[items.count - 1].s }
  }
}

private func pageSuggestion(_ c: Candidate, _ tabId: String??) -> Suggestion {
  let id: String? = tabId ?? c.tabId
  return .page(url: c.url, title: c.title, favicon: c.favicon, tabId: id?.isEmpty == false ? id : nil, bookmarked: c.bookmarked, visited: c.visits > 0)
}

private struct Output {
  var items: [Suggestion] = []
  var seen = Set<UnitsKey>()
  let limit: Int

  init(_ limit: Int) { self.limit = limit }

  mutating func push(_ rows: [Suggestion]) {
    for row in rows {
      let key = UnitsKey(suggestionKeyUnits(row))
      if items.count >= limit || seen.contains(key) { continue }
      seen.insert(key)
      items.append(row)
    }
  }

  mutating func push(_ row: Suggestion) { push([row]) }
}

private func dedupeSuggestions(_ remote: [String], _ query: Units) -> [String] {
  var seen: Set<Units> = [JS.lower(JS.trim(query))]
  return remote.filter { s in
    let key = JS.lower(JS.trim(s.units))
    if key.isEmpty || seen.contains(key) { return false }
    seen.insert(key)
    return true
  }
}

private func typedIsPage(_ t: PageText, _ q8: Bytes) -> Bool { q8 == t.shownLower8 || q8 == t.hostLower8 }

private func inlineMatch(_ t: PageText, _ q: Units, _ q8: Bytes) -> Bool {
  if t.hostLower8.starts(q8) && t.origin != nil { return true }
  return q.contains(Unit.slash) && !t.shown.contains(where: { $0 == Unit.question || $0 == Unit.hash }) && t.shownLower8.starts(q8)
}

private func inlineTarget(_ q: Units, _ c: Candidate) -> (text: Units, url: String, favicon: String?) {
  let host = hostPart(c.text.shown)
  if let origin = c.text.origin, JS.lower(host).hasPrefix(q) { return (host, (origin + [Unit.slash]).string, c.favicon) }
  return (c.text.shown, c.url, c.favicon)
}

private func isSpaceRun(_ s: Units) -> Bool {
  var i = 0
  while i < s.count && !JS.isSpace(s[i]) { i += 1 }
  if i == 0 || i == s.count { return false }
  while i < s.count && JS.isSpace(s[i]) { i += 1 }
  return i < s.count
}

private func stripScheme(_ query: Units) -> Units {
  guard let first = query.first, first == 0x68 || first == 0x48 else { return query }
  let length: Int
  if query.asciiCaseInsensitivePrefix("https://") {
    length = 8
  } else if query.asciiCaseInsensitivePrefix("http://") {
    length = 7
  } else {
    return query
  }
  guard length < query.count, !JS.isSpace(query[length]) else { return query }
  return Array(query[length...])
}

public final class SuggestionIndex {
  private let history: [HistoryRow]
  private let bookmarks: [BookmarkRow]
  private var baseList: [Candidate] = []
  private var baseByKey: [UnitsKey: Candidate] = [:]
  private var baseKeys = Set<UnitsKey>()
  private var bookmarkCursor = 0
  private var baseDone = false
  private var list: [Candidate] = []
  private var historyByKey: [UnitsKey: Candidate] = [:]
  private var historyCursor = 0
  private var baseMergeCursor = 0
  private var ready = false
  private var texts: [ExactKey: PageText] = [:]
  private var chain: [Matched] = []
  private static let matchedKept = 8
  private static let sliceCheck = 64

  public init(history: [HistoryRow], bookmarks: [BookmarkRow], reusing previous: SuggestionIndex? = nil) {
    self.history = history
    self.bookmarks = bookmarks
    if let previous { texts = previous.texts }
  }

  public convenience init(_ source: SuggestionSource, reusing previous: SuggestionIndex? = nil) {
    self.init(history: source.history, bookmarks: source.bookmarks, reusing: previous)
  }

  private var lastTabs: [TabRow] = []
  private var lastTabTexts: [PageText?] = []
  private var lastCurrentTabId: String?
  private var lastTabIds: [UnitsKey: String] = [:]
  private var lastExtra: [Candidate] = []

  private func sameTabs(_ tabs: [TabRow], _ currentTabId: String?) -> Bool {
    guard tabs.count == lastTabs.count, (currentTabId == nil) == (lastCurrentTabId == nil) else { return false }
    if let currentTabId, !sameBytes(currentTabId, lastCurrentTabId!) { return false }
    for (a, b) in zip(tabs, lastTabs) {
      guard sameBytes(a.id, b.id), sameBytes(a.url, b.url), sameBytes(a.title, b.title), (a.favicon == nil) == (b.favicon == nil) else { return false }
      if let fa = a.favicon, !sameBytes(fa, b.favicon!) { return false }
    }
    return true
  }

  private func tabsOver(_ tabs: [TabRow], currentTabId: String?) -> ([UnitsKey: String], [Candidate]) {
    if !lastTabTexts.isEmpty || !lastTabs.isEmpty, sameTabs(tabs, currentTabId) { return (lastTabIds, lastExtra) }
    var tabIds: [UnitsKey: String] = [:]
    tabIds.reserveCapacity(tabs.count)
    var extra: [Candidate] = []
    var tabTexts: [PageText?] = []
    tabTexts.reserveCapacity(tabs.count)
    for (at, t) in tabs.enumerated() {
      if t.url.isEmpty || (currentTabId.map(t.id.sameUnits) ?? false) {
        tabTexts.append(nil)
        continue
      }
      let text = tabText(at, t)
      tabTexts.append(text)
      let key = UnitsKey(text.key)
      if tabIds[key] != nil { continue }
      tabIds[key] = t.id
      if !has(text.key) {
        extra.append(Candidate(url: t.url, title: t.title, favicon: t.favicon, visits: 0, lastVisit: 0, logVisits: 0, bookmarked: false, tabId: t.id, fresh: true, text: text))
      }
    }
    lastTabs = tabs
    lastTabTexts = tabTexts
    lastCurrentTabId = currentTabId
    lastTabIds = tabIds
    lastExtra = extra
    return (tabIds, extra)
  }

  private func tabText(_ at: Int, _ t: TabRow) -> PageText {
    if at < lastTabs.count, let text = lastTabTexts[at] {
      let last = lastTabs[at]
      if sameBytes(last.url, t.url) && sameBytes(last.title, t.title) { return text }
    }
    return pageText(url: t.url, title: t.title)
  }

  private func pageText(url: String, title: String) -> PageText {
    let key = ExactKey(a: url, b: title)
    if let t = texts[key] { return t }
    let t = PageText(url: url, title: title)
    texts[key] = t
    return t
  }

  public var isPrepared: Bool { ready }

  @discardableResult
  public func prepare(deadline: ContinuousClock.Instant? = nil) -> Bool {
    if ready { return true }
    var n = 0
    let late = { () -> Bool in
      n += 1
      guard let deadline, n % SuggestionIndex.sliceCheck == 0 else { return false }
      return ContinuousClock.now > deadline
    }
    while !baseDone && bookmarkCursor < bookmarks.count {
      let row = bookmarks[bookmarkCursor]
      bookmarkCursor += 1
      let text = pageText(url: row.url, title: row.title)
      let key = UnitsKey(text.key)
      baseKeys.insert(key)
      if baseByKey[key] == nil {
        let c = Candidate(url: row.url, title: row.title, favicon: row.favicon, visits: 0, lastVisit: 0, logVisits: 0, bookmarked: true, text: text)
        baseList.append(c)
        baseByKey[key] = c
      }
      if late() { return false }
    }
    baseDone = true
    while historyCursor < history.count {
      let h = history[historyCursor]
      historyCursor += 1
      let text = pageText(url: h.url, title: h.title)
      let key = UnitsKey(text.key)
      if historyByKey[key] == nil {
        let c = Candidate(
          url: h.url, title: h.title, favicon: h.favicon, visits: h.visits, lastVisit: h.lastVisit, logVisits: logVisits(h.visits),
          bookmarked: baseKeys.contains(key), text: text
        )
        list.append(c)
        historyByKey[key] = c
      }
      if late() { return false }
    }
    while baseMergeCursor < baseList.count {
      let c = baseList[baseMergeCursor]
      baseMergeCursor += 1
      if historyByKey[UnitsKey(c.text.key)] == nil { list.append(c) }
      if late() { return false }
    }
    ready = true
    return true
  }

  private func lookup(_ key: Units) -> Candidate? {
    let k = UnitsKey(key)
    return historyByKey[k] ?? baseByKey[k]
  }

  private func has(_ key: Units) -> Bool {
    let k = UnitsKey(key)
    return historyByKey[k] != nil || baseByKey[k] != nil
  }

  private func narrowing(_ q: Units, _ tokens: [Units]) -> Matched? {
    for last in chain.reversed() {
      if !q.hasPrefix(last.q) { continue }
      let i = last.tokens.count - 1
      let word = last.tokens[i]
      if i == 0 || (i < tokens.count && word == tokens[i]) || word.count >= 3 { return last }
    }
    return nil
  }

  private func remember(_ q: Units, _ tokens: [Units], _ pages: [Candidate], _ scores: [Double]) {
    while let last = chain.last, !q.hasPrefix(last.q) { chain.removeLast() }
    if q.count < 2 {
      chain.removeAll()
      return
    }
    if chain.last?.q == q { chain.removeLast() }
    chain.append(Matched(q: q, tokens: tokens, pages: pages, scores: scores))
    if chain.count > SuggestionIndex.matchedKept { chain.removeFirst() }
  }

  public func suggest(_ raw: String, tabs: [TabRow], options: SuggestOptions = SuggestOptions()) -> SuggestionResult {
    suggest(raw.units, tabs: tabs, options: options)
  }

  func suggest(_ rawUnits: Units, tabs: [TabRow], options: SuggestOptions) -> SuggestionResult {
    let limit = options.limit
    let now = options.now ?? Date().timeIntervalSince1970 * 1000
    let engine = options.engine
    let scope = options.scope
    let query = JS.trim(rawUnits)
    if query.isEmpty { return SuggestionResult(items: [], completion: "") }
    let bare = stripScheme(query)
    let q = JS.lower(bare)
    let tokens = JS.splitSpaces(q)
    let queryText = query.string

    if scope == nil, let bang = findBang(queryText, options.bangs) {
      return bangSuggestions(bang, tabs: tabs, options: options, limit: limit)
    }

    if scope == nil && query.first == Unit.question {
      let text = JS.trim(Array(query[1...]))
      if text.isEmpty { return SuggestionResult(items: [], completion: "") }
      var out = Output(limit)
      let template = engine.url.units
      out.push(.search(query: text.string, url: searchUrlFor(template, text).string, engine: engine.name))
      out.push(dedupeSuggestions(options.remote, text).prefix(4).map { .search(query: $0, url: searchUrlFor(template, $0.units).string, engine: engine.name, suggested: true) })
      return SuggestionResult(items: out.items, completion: "")
    }

    prepare()
    let (tabIds, extra) = tabsOver(tabs, currentTabId: options.currentTabId)
    let currentKey = options.currentUrl.map { pageKey($0.units) }
    let known = { (url: Units) -> Suggestion? in
      let key = pageKey(url)
      guard let c = self.lookup(key) ?? extra.first(where: { $0.text.key == key }) else { return nil }
      return pageSuggestion(c, .some(nil))
    }

    let websiteFirst = options.preference == .website
    let oneWord = tokens.count == 1
    let noInline = options.preventInline || (oneWord && rawUnits.count != query.count && (rawUnits.last.map(JS.isSpace) ?? false))
    let completes = websiteFirst && scope == nil && oneWord && !noInline
    let from = narrowing(q, tokens)
    let pages = from?.pages ?? list
    let again = from != nil && from!.q == q
    let parsed = Query(q, tokens)
    var matched: [Candidate] = again ? from!.pages : []
    var scores: [Double] = again ? from!.scores : []
    let score = oneWord ? matchScoreWord : matchScore
    let scopeHost = scope?.host.units ?? []
    var ranking = Ranking(
      top: TopList(limit + 1), onSite: scope != nil ? TopList(4) : nil, inline: nil, limit: limit, now: now, currentKey: currentKey,
      completes: completes, bound: scope != nil, q: q, q8: parsed.q8, tabIds: tabIds, scopeHost: scopeHost, scopeSuffix: [Unit.dot] + scopeHost
    )
    if again {
      for at in pages.indices where scores[at] > 0 { ranking.consider(pages[at], scores[at]) }
    } else {
      for c in pages {
        let m = score(c.text, parsed)
        if m <= 0 { continue }
        matched.append(c)
        scores.append(m)
        ranking.consider(c, m)
      }
    }
    for c in extra {
      let m = score(c.text, parsed)
      if m > 0 { ranking.consider(c, m) }
    }
    remember(q, tokens, matched, scores)
    let ranked = ranking.top.items
    let inline = ranking.inline

    var out = Output(limit)
    let remoteRows = { (url: (Units) -> Units, name: String) -> [Suggestion] in
      dedupeSuggestions(options.remote, query).prefix(4).map { .search(query: $0, url: url($0.units).string, engine: name, suggested: true) }
    }

    if let scope {
      let defaultTemplate = engine.url.units
      let scopedUrl = { (text: Units) in scopedSearchUrl(scope, text, defaultTemplate) }
      out.push(.search(query: queryText, url: scopedUrl(query).string, engine: scope.name))
      out.push(remoteRows(scopedUrl, scope.name))
      out.push(ranking.onSite!.items.map { pageSuggestion($0.c, $0.tabId) })
      return SuggestionResult(items: out.items, completion: "")
    }

    let template = engine.url.units
    let search = Suggestion.search(query: queryText, url: searchUrlFor(template, query).string, engine: engine.name)
    let typedUrl = fixupUrl(query)
    let calc = calculate(queryText)
    let creates = matchQuickCreate(JS.trimStart(rawUnits))
    let actionRows = query.count >= 4 ? 4 : 2
    let actionMatches = (options.actions?.match(queryText, limit: actionRows) ?? []).filter { $0.exact || $0.score >= 50 }
    let extensionMatches = extensionSuggestions(queryText, options.extensions)

    let best = ranked.first
    let target = inline.map { inlineTarget(q, $0.c) }
    let completion = target.map { Array($0.text.dropFirst(bare.count)) } ?? []

    let first: Suggestion
    if !creates.isEmpty && isSpaceRun(query) {
      first = createRow(creates[0])
    } else if let action = actionMatches.first, action.exact {
      first = actionRow(action.action)
    } else if let target, !completion.isEmpty {
      first = known(target.url.units) ?? .page(url: target.url, title: "", favicon: target.favicon)
    } else if let typedUrl {
      first = known(typedUrl) ?? .page(url: typedUrl.string, title: "", favicon: nil)
    } else if extensionMatches.exact {
      first = extensionMatches.rows[0]
    } else if websiteFirst, let best, best.m >= 40, !noInline || typedIsPage(best.c.text, parsed.q8) {
      first = pageSuggestion(best.c, best.tabId)
    } else {
      first = search
    }

    out.push(first)
    out.push(search)
    if let calc { out.push(.calc(expression: calc.expression, value: calc.display, url: searchUrlFor(template, calc.expression.units).string)) }
    out.push(actionMatches.map { actionRow($0.action) })
    out.push(extensionMatches.rows)
    out.push(creates.map(createRow))
    let pageRows = ranked.map { pageSuggestion($0.c, $0.tabId) }
    out.push(Array(pageRows.prefix(3)))
    out.push(remoteRows({ searchUrlFor(template, $0) }, engine.name))
    out.push(Array(pageRows.dropFirst(3)))
    return SuggestionResult(items: out.items, completion: completion.string)
  }

  private func bangSuggestions(_ match: BangMatch, tabs: [TabRow], options: SuggestOptions, limit: Int) -> SuggestionResult {
    let bang = match.bang
    var out = Output(limit)
    if match.query.isEmpty {
      out.push(.page(url: bang.home, title: bang.name, favicon: nil))
      return SuggestionResult(items: out.items, completion: "")
    }
    out.push(.search(query: match.query, url: match.url, engine: bang.name, bang: true))
    var scoped = options
    scoped.scope = SearchScope(kind: .site, name: bang.name, host: hostOf(bang.home), url: bang.template)
    scoped.remote = []
    scoped.bangs = nil
    out.push(Array(suggest(match.query.units, tabs: tabs, options: scoped).items.dropFirst()))
    return SuggestionResult(items: out.items, completion: "")
  }
}

private func createRow(_ c: QuickCreate) -> Suggestion { .create(id: c.id, title: c.title, url: c.url, site: c.site) }

private func actionRow(_ a: CommandAction) -> Suggestion {
  .action(id: a.id, title: a.title, icon: a.icon?.isEmpty == false ? a.icon : nil, hint: a.hint?.isEmpty == false ? a.hint : nil)
}

public func buildSuggestions(_ raw: String, _ source: SuggestionSource, _ options: SuggestOptions = SuggestOptions()) -> SuggestionResult {
  SuggestionIndex(source).suggest(raw, tabs: source.tabs, options: options)
}

public func prepareSuggestions(_ index: SuggestionIndex, deadline: ContinuousClock.Instant) -> Bool {
  index.prepare(deadline: deadline)
}
