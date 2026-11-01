import SolaraModel

extension Session {
  func nextPageModelSerial() throws -> Int {
    guard memory.nextPageModelSerial < pageMaximumSafeInteger else { throw CommandError("page model serial exhausted") }
    memory.nextPageModelSerial += 1
    return memory.nextPageModelSerial
  }

  public func registerKeepAliveRuntime() throws -> Int {
    guard memory.currentEpoch < pageMaximumSafeInteger else { throw CommandError("keepAlive epoch exhausted") }
    memory.currentEpoch += 1
    for id in memory.pages.keys { memory.pages[id]?.keepAlive = nil }
    return memory.currentEpoch
  }

  func pageIsEligible(_ tab: Tab) -> Bool {
    tab.unloaded != true && !truthy(tab.pageIn) && state.windows[tab.windowId] != nil &&
      (tab.navigation == nil || pageNavigation(tab) != nil)
  }

  func pageContext(_ report: JSONValue, tab: Tab) throws -> PageIssueContext {
    guard let rawSequence = report["navigationSeq"], let revision = pageSafeInteger(report["contextRevision"]),
      let wasNewTab = report["wasNewTab"]?.bool, let shown = report["newTabShownUrl"],
      shown.isNull || shown.string != nil else { throw CommandError("pageReport: malformed context") }
    let sequence = rawSequence.isNull ? nil : pageSafeInteger(rawSequence)
    guard rawSequence.isNull || sequence != nil else { throw CommandError("pageReport: invalid navigationSeq") }
    return PageIssueContext(navigationSeq: sequence, revision: revision, wasNewTab: wasNewTab, newTabShownUrl: shown.string)
  }

  func contextMatchesNavigation(_ context: PageIssueContext, _ tab: Tab) -> Bool {
    context.navigationSeq == pageNavigation(tab)?.seq
  }

  func contextIsCurrent(_ context: PageIssueContext, _ page: PageReportMemory) -> Bool {
    context.revision > page.contextRevision || (context.revision == page.contextRevision &&
      context.wasNewTab == page.wasNewTab && context.newTabShownUrl == page.newTabShownUrl)
  }

  func makePageMemory(_ tab: Tab, generation: String?, context: PageIssueContext, engine: String?, handoff: Int?, reestablished: Bool) throws -> PageReportMemory {
    let facts = reestablished ? (state.live[tab.id] ?? PageLiveFacts()) : PageLiveFacts(themeColor: state.live[tab.id]?.themeColor)
    return PageReportMemory(model: TabPageModel(navigation: pageNavigation(tab),
      adoptedUrl: truthy(tab.adoptId) ? tab.url : nil, handoffSeq: handoff,
      webkitWithoutHandoff: engine == "webkit" && handoff == nil && !reestablished, wasNewTab: context.wasNewTab),
      live: PageLive(facts: facts), generation: generation, modelSerial: try nextPageModelSerial(),
      wasNewTab: context.wasNewTab, newTabShownUrl: context.newTabShownUrl, contextRevision: context.revision)
  }

  public func preparePageIssue(id: String, report: JSONValue) throws -> PreparedPageIssue? {
    guard let tab = state.tabs[id], pageIsEligible(tab), let page = memory.pages[id],
      let generation = page.generation, report["generation"]?.string == generation,
      let fence = memory.pageProducerFence[id], fence.generation == generation, !fence.retired else { return nil }
    let context = try pageContext(report, tab: tab)
    guard contextMatchesNavigation(context, tab), contextIsCurrent(context, page) else { return nil }
    guard let rawNavigation = report["navigation"], let startedEarly = report["startedEarly"]?.bool else {
      throw CommandError("pageReport: malformed issued request")
    }
    let navigation: TabNavigationRequest?
    if rawNavigation.isNull { navigation = nil }
    else {
      guard let url = rawNavigation["url"]?.string, let seq = pageSafeInteger(rawNavigation["seq"]),
        rawNavigation["userInitiated"] == nil || rawNavigation["userInitiated"]?.bool != nil else { throw CommandError("pageReport: malformed issued navigation") }
      navigation = TabNavigationRequest(seq: seq, url: url, userInitiated: rawNavigation["userInitiated"]?.bool ?? false)
    }
    guard navigation == pageNavigation(tab) else { return nil }
    if let move = report["sameProfileMove"], move.bool == nil { throw CommandError("pageReport: malformed move flag") }
    let sameProfileMove = report["sameProfileMove"]?.bool ?? false
    var model = page.model
    if sameProfileMove { model.moved(sameProfile: true) }
    var effects = model.issued(navigation, newTabShown: context.newTabShownUrl != nil, startedEarly: startedEarly)
    if navigation != nil, context.newTabShownUrl != nil, !effects.contains(.clearNewTabShown) {
      effects.insert(.clearNewTabShown, at: 0)
    }
    let actions: JSONValue = .array(effects.compactMap { effect in
      switch effect {
      case .clearNewTabShown: return ["type": "clearNewTabShown"]
      case .load(let url, let userInitiated): return ["type": "load", "url": .string(url), "userInitiated": .bool(userInitiated)]
      default: return nil
      }
    })
    return PreparedPageIssue(actions: actions, guardValue: PageIssueGuard(sessionGeneration: generation,
      navigation: navigation, contextRevision: context.revision, modelSerial: page.modelSerial,
      startedEarly: startedEarly, sameProfileMove: sameProfileMove), profileId: tab.profileId,
      engineProfile: state.engineProfile(tab.profileId), engine: tabEngine(state, id), windowId: tab.windowId, context: context, model: model)
  }

  public func consumePageIssue(id: String, prepared: PreparedPageIssue) throws -> Bool {
    let guardValue = prepared.guardValue
    guard let tab = state.tabs[id], pageIsEligible(tab), tab.windowId == prepared.windowId,
      tab.profileId == prepared.profileId, state.engineProfile(tab.profileId) == prepared.engineProfile,
      tabEngine(state, id) == prepared.engine, pageNavigation(tab) == guardValue.navigation,
      var page = memory.pages[id], page.generation == guardValue.sessionGeneration,
      page.modelSerial == guardValue.modelSerial, contextMatchesNavigation(prepared.context, tab),
      contextIsCurrent(prepared.context, page), let fence = memory.pageProducerFence[id],
      fence.generation == guardValue.sessionGeneration, !fence.retired else { return false }
    page.modelSerial = try nextPageModelSerial()
    page.model = prepared.model
    page.wasNewTab = prepared.context.wasNewTab
    page.contextRevision = prepared.context.revision
    page.newTabShownUrl = prepared.actions.array?.contains { $0["type"]?.string == "clearNewTabShown" } == true ? nil : prepared.context.newTabShownUrl
    memory.pages[id] = page
    return true
  }

  func applyPageFeed(_ id: String, _ report: JSONValue, type: String, page: inout PageReportMemory) {
    if type == "latch" {
      guard let sequence = pageSafeInteger(report["eventSeq"]) else { return }
      page.latchedThrough = max(page.latchedThrough, sequence)
      memory.pages[id] = page
      return
    }
    guard let generation = page.generation, let epoch = pageSafeInteger(report["epoch"], minimum: 1), epoch == memory.currentEpoch,
      let sequence = pageSafeInteger(report["seq"], minimum: 1), let handled = pageSafeInteger(report["handled"]),
      let keep = report["keep"], let reveal = report["reveal"],
      let capturing = keep["capturing"]?.bool, let newTabShown = keep["newTabShown"]?.bool,
      let pip = keep["pip"]?.bool, let displayRequest = keep["displayRequest"]?.bool,
      let mediaName = keep["media"]?.string, let media = KeepAliveMedia(rawValue: mediaName),
      let fullscreen = reveal["fullscreen"]?.bool, let crashed = reveal["crashed"]?.bool,
      let unresponsive = reveal["unresponsive"]?.bool, let scrolledDown = reveal["scrolledDown"]?.bool,
      let sharing = reveal["sharing"]?.bool else { return }
    if let watermark = memory.feedWatermark[id], watermark.epoch == epoch, watermark.generation == generation,
      sequence <= watermark.seq { return }
    page.keepAlive = KeepAliveFacts(epoch: epoch, seq: sequence, handled: handled,
      keep: KeepAliveKeep(capturing: capturing, newTabShown: newTabShown, pip: pip, displayRequest: displayRequest, media: media),
      reveal: KeepAliveReveal(fullscreen: fullscreen, crashed: crashed, unresponsive: unresponsive, scrolledDown: scrolledDown, sharing: sharing))
    memory.feedWatermark[id] = FeedWatermark(epoch: epoch, generation: generation, seq: sequence)
    memory.pages[id] = page
  }

  public func pageReport(_ id: String, _ report: JSONValue) throws {
    guard let type = report["type"]?.string else { throw CommandError("pageReport: missing type") }
    let known: Set<String> = ["created", "context", "issued", "navigation", "media", "download", "discarded", "ready", "failed", "loadError", "moved", "restore", "advance", "gone", "keepAlive", "latch"]
    guard known.contains(type) else { throw CommandError("pageReport: unknown type \(type)") }
    if type == "issued" { result = ["actions": [], "guard": .null] }
    let generation = report["generation"]?.string
    if type == "gone", let generation, var fence = memory.pageProducerFence[id], fence.generation == generation {
      fence.retired = true
      memory.pageProducerFence[id] = fence
    }
    guard let tab = state.tabs[id], pageIsEligible(tab) else { return }
    if type == "gone" {
      guard let generation, let fence = memory.pageProducerFence[id], fence.generation == generation,
        memory.pages[id]?.generation == nil || memory.pages[id]?.generation == generation else { return }
      memory.pages[id] = nil
      if state.live[id] != PageLiveFacts() { update { $0.live[id] = PageLiveFacts() } }
      return
    }
    if type == "created" {
      guard let generation, !generation.isEmpty, let engine = report["engine"]?.string,
        engine == "chromium" || engine == "webkit" else { throw CommandError("pageReport: malformed created") }
      let context = try pageContext(report, tab: tab)
      guard contextMatchesNavigation(context, tab) else { return }
      let reestablished = report["reestablished"]?.bool ?? false
      if let raw = report["reestablished"], raw.bool == nil { throw CommandError("pageReport: malformed recovery flag") }
      if reestablished {
        guard let fence = memory.pageProducerFence[id], fence.generation == generation, !fence.retired,
          memory.pages[id]?.generation == nil || memory.pages[id]?.generation == generation else { return }
      } else if let fence = memory.pageProducerFence[id], fence.generation == generation {
        guard !fence.retired else { return }
        if memory.pages[id]?.generation == generation { return }
        return
      }
      if memory.pages[id]?.generation == generation { return }
      let handoff: Int?
      if let raw = report["handoffSeq"], !raw.isNull {
        guard let sequence = pageSafeInteger(raw) else { throw CommandError("pageReport: malformed handoff") }
        handoff = sequence
      } else { handoff = nil }
      guard engine == tabEngine(state, id) else { return }
      var page = try makePageMemory(tab, generation: generation, context: context, engine: engine, handoff: handoff, reestablished: reestablished)
      if let restored = memory.pages[id], restored.generation == nil { page.live = restored.live }
      memory.pageProducerFence[id] = PageProducerFence(generation: generation, retired: false)
      if memory.feedWatermark[id]?.generation != generation { memory.feedWatermark[id] = nil }
      memory.pages[id] = page
      if state.live[id] != page.live.facts { update { $0.live[id] = page.live.facts } }
      return
    }
    if type == "restore" {
      let themes = (report["themes"]?.array ?? []).filter { $0["tab"]?.string == id }.compactMap { value -> PageLiveRestoredTheme? in
        guard let key = value["page"]?.string, let color = value["color"]?.string else { return nil }
        return PageLiveRestoredTheme(page: key, color: color)
      }
      var page: PageReportMemory
      if let old = memory.pages[id] { page = old }
      else {
        page = try makePageMemory(tab, generation: nil, context: PageIssueContext(navigationSeq: pageNavigation(tab)?.seq,
          revision: 0, wasNewTab: false, newTabShownUrl: nil), engine: nil, handoff: nil, reestablished: false)
      }
      _ = page.live.restore(tabURL: tab.url, themes: themes)
      memory.pages[id] = page
      if state.live[id] != page.live.facts { update { $0.live[id] = page.live.facts } }
      return
    }
    guard let generation, var page = memory.pages[id], page.generation == generation else { return }
    guard let fence = memory.pageProducerFence[id], fence.generation == generation, !fence.retired else { return }
    if type == "keepAlive" || type == "latch" { applyPageFeed(id, report, type: type, page: &page); return }
    if type == "issued" {
      let prepared = try preparePageIssue(id: id, report: report)
      result = ["actions": prepared?.actions ?? [], "guard": prepared?.guardValue.json ?? .null]
      return
    }
    if type == "context" {
      let context = try pageContext(report, tab: tab)
      guard contextMatchesNavigation(context, tab), context.revision > page.contextRevision else { return }
      page.modelSerial = try nextPageModelSerial()
      page.contextRevision = context.revision
      page.wasNewTab = context.wasNewTab
      page.newTabShownUrl = context.newTabShownUrl
      memory.pages[id] = page
      return
    }
    if let raw = report["eventSeq"] {
      guard let sequence = pageSafeInteger(raw) else { throw CommandError("pageReport: invalid eventSeq") }
      page.newestEventSeq = max(page.newestEventSeq, sequence)
    }
    var effects: [TabPageEffect] = []
    switch type {
    case "navigation":
      guard let url = report["url"]?.string, let title = report["title"]?.string,
        let loading = report["isLoading"]?.bool, let back = report["canGoBack"]?.bool,
        let forward = report["canGoForward"]?.bool else { throw CommandError("pageReport: malformed navigation") }
      if let theme = report["themeColor"], !theme.isNull && theme.string == nil { throw CommandError("pageReport: malformed theme") }
      if let accessed = report["initialDocumentAccessed"], accessed.bool == nil { throw CommandError("pageReport: malformed initial document") }
      if let committed = report["committedInitial"], committed.bool == nil { throw CommandError("pageReport: malformed initial commit") }
      page.modelSerial = try nextPageModelSerial()
      effects = page.model.reported(TabNavigationReport(url: url, title: title, isLoading: loading, canGoBack: back,
        canGoForward: forward, initialDocumentAccessed: report["initialDocumentAccessed"]?.bool ?? false,
        committedInitial: report["committedInitial"]?.bool), TabPageContext(navigationUrl: tab.navigation?.url,
          prewarmOnly: tab.navigation == nil && !truthy(tab.adoptId), openedByAdoption: truthy(tab.openerId) && truthy(tab.adoptId),
          newTabShownUrl: page.newTabShownUrl))
    case "media":
      if let muted = report["muted"], muted.bool == nil { throw CommandError("pageReport: malformed media mute") }
      guard let playing = report["playing"]?.bool else { throw CommandError("pageReport: malformed media") }
      _ = page.live.media(playing: playing)
    case "download":
      if let skipped = report["skipped"], skipped.bool == nil { throw CommandError("pageReport: malformed download") }
      if let url = report["committedUrl"], !url.isNull && url.string == nil { throw CommandError("pageReport: malformed download URL") }
      page.modelSerial = try nextPageModelSerial()
      let others = state.windows[tab.windowId]?.tabIds.contains { $0 != id && state.tabs[$0]?.profileId == tab.profileId } ?? false
      effects = page.model.downloadNavigation(committedUrl: report["committedUrl"]?.string, skipped: report["skipped"]?.bool ?? false,
        context: TabDownloadContext(currentUrl: tab.url, hasOtherProfileTab: others, hasOpener: truthy(tab.openerId),
          hasAdoptId: truthy(tab.adoptId), wasNewTab: page.wasNewTab, canGoBack: page.live.facts?.canGoBack ?? false))
    case "discarded":
      guard let url = report["url"]?.string else { throw CommandError("pageReport: malformed discard") }
      page.modelSerial = try nextPageModelSerial()
      effects = page.model.discarded(url)
    case "ready":
      guard let browserId = pageSafeInteger(report["browserId"]) else { throw CommandError("pageReport: malformed ready") }
      let tabId: Int?
      if let raw = report["tabId"] {
        guard let value = pageSafeInteger(raw) else { throw CommandError("pageReport: malformed ready tab") }
        tabId = value
      } else { tabId = nil }
      page.ready = PageReadyFacts(browserId: browserId, tabId: tabId)
      page.live.ready()
    case "failed", "loadError":
      page.modelSerial = try nextPageModelSerial()
      page.model.loadFailed()
    case "moved":
      guard let sameProfile = report["sameProfile"]?.bool else { throw CommandError("pageReport: malformed move") }
      page.modelSerial = try nextPageModelSerial()
      page.model.moved(sameProfile: sameProfile)
    case "advance": _ = page.live.advance(to: now)
    default: break
    }
    for effect in effects {
      switch effect {
      case .markLoading: _ = page.live.markLoading()
      case .navigated(let url, let title, let loading, let back, let forward):
        _ = page.live.navigation(url: url, isLoading: loading, canGoBack: back, canGoForward: forward,
          themeColor: report["themeColor"]?.string, now: now)
        memory.pages[id] = page
        updateTab(id, TabUpdate(set: ["url": .string(url), "title": .string(title)]), live: page.live.facts)
      case .keepNewTabShown:
        let url = report["initialDocumentAccessed"]?.bool == true && report["committedInitial"]?.bool == true ? "about:blank" : report["url"]?.string ?? ""
        _ = page.live.navigation(url: url, isLoading: report["isLoading"]?.bool ?? false,
          canGoBack: report["canGoBack"]?.bool ?? false, canGoForward: report["canGoForward"]?.bool ?? false,
          themeColor: report["themeColor"]?.string, now: now)
      case .adoptNavigation(let url):
        memory.pages[id] = page
        updateTab(id, TabUpdate(set: ["navigation": navigationTo(url).jsonValue]), live: page.live.facts)
      case .clearNewTabShown: page.newTabShownUrl = nil
      case .stopLoading: _ = page.live.download()
      case .updateURL(let url):
        memory.pages[id] = page
        updateTab(id, TabUpdate(set: ["url": .string(url)]), live: page.live.facts)
      case .closeTab: closeTab(id)
      case .resetToNewTab:
        memory.pages[id] = page
        updateTab(id, TabUpdate(set: ["url": "", "title": "", "favicon": .null]), live: page.live.facts)
      case .discarded: _ = page.live.discard()
      default: break
      }
    }
    if state.tabs[id] != nil {
      memory.pages[id] = page
      if state.live[id] != page.live.facts { update { $0.live[id] = page.live.facts } }
    } else { memory.pages[id] = nil }
  }
}
