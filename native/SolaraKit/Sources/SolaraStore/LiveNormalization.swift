import SolaraModel

func normalizePageState(_ state: inout BrowserState, memory: inout StoreMemory) {
  state.live = state.live.filter { state.tabs[$0.key] != nil }
  memory.pages = memory.pages.filter { state.tabs[$0.key] != nil }
  memory.feedWatermark = memory.feedWatermark.filter { state.tabs[$0.key] != nil }
  memory.pageProducerFence = memory.pageProducerFence.filter { state.tabs[$0.key] != nil }
  for tab in state.tabs.values {
    if tab.unloaded == true {
      state.live[tab.id] = PageLiveFacts()
      memory.pages[tab.id] = nil
    } else if state.live[tab.id] == nil {
      state.live[tab.id] = PageLiveFacts()
    }
  }
  let facts = state.live
  for tab in state.tabs.values where tab.unloaded != true && truthy(tab.pageIn) {
    var seen: Set<String> = [tab.id]
    var holder = tab.pageIn
    var resolved: PageLiveFacts?
    while let id = holder, !id.isEmpty {
      guard seen.insert(id).inserted, let next = state.tabs[id], next.unloaded != true else { break }
      if let parent = next.pageIn, !parent.isEmpty { holder = parent }
      else { resolved = facts[id]; break }
    }
    state.live[tab.id] = resolved ?? PageLiveFacts()
    memory.pages[tab.id] = nil
  }
}

extension Session {
  func settleLive() {
    while liveEffectsAppliedThrough < effects.count {
      let index = liveEffectsAppliedThrough
      liveEffectsAppliedThrough += 1
      guard case .swapTabs(_, let b) = effects[index], state.tabs[b] != nil else { continue }
      state.live[b] = liveEffectSources[index] ?? PageLiveFacts()
      memory.pages[b] = nil
    }
    normalizePageState(&state, memory: &memory)
  }
}
