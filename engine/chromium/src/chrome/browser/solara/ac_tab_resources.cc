// Copyright 2026 Solara. Apache-2.0.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/strings/string_number_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/solara/ac_engine.h"
#include "chrome/browser/solara/ac_tabs.h"
#include "components/performance_manager/public/graph/frame_node.h"
#include "components/performance_manager/public/graph/graph.h"
#include "components/performance_manager/public/graph/graph_operations.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/graph/process_node.h"
#include "components/performance_manager/public/graph/worker_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "components/performance_manager/public/resource_attribution/frame_context.h"
#include "components/performance_manager/public/resource_attribution/page_context.h"
#include "components/performance_manager/public/resource_attribution/process_context.h"
#include "components/performance_manager/public/resource_attribution/queries.h"
#include "components/performance_manager/public/resource_attribution/query_results.h"
#include "components/performance_manager/public/resource_attribution/resource_types.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"

namespace solara {
namespace {

using performance_manager::PerformanceManager;
using resource_attribution::PageContext;
using resource_attribution::ProcessContext;
using resource_attribution::QueryBuilder;
using resource_attribution::QueryResultMap;
using resource_attribution::ResourceType;

struct TabTarget {
  int id;
  PageContext page;
  content::GlobalRenderFrameHostToken main_frame;
  int64_t navigation_id;
  std::optional<ProcessContext> process;
  bool exclusive;
};

std::optional<std::set<int>> RequestedTabIds(const char* args_json,
                                             Reply& reply) {
  const auto parsed = args_json && *args_json
                          ? base::JSONReader::Read(
                                args_json, base::JSON_PARSE_CHROMIUM_EXTENSIONS)
                          : std::nullopt;
  const base::ListValue* ids =
      parsed && parsed->is_dict() ? parsed->GetDict().FindList("tabIds")
                                  : nullptr;
  if (!ids) {
    reply.Error("tabIds must be a list of integer tab ids");
    return std::nullopt;
  }
  std::set<int> wanted;
  for (const base::Value& value : *ids) {
    if (!value.is_int() && !value.is_double()) {
      reply.Error("tabIds must be a list of integer tab ids");
      return std::nullopt;
    }
    const double id = value.GetDouble();
    if (!std::isfinite(id) || std::trunc(id) != id ||
        id < std::numeric_limits<int>::min() ||
        id > std::numeric_limits<int>::max()) {
      reply.Error("tabIds must be a list of integer tab ids");
      return std::nullopt;
    }
    wanted.insert(static_cast<int>(id));
  }
  return wanted;
}

bool FrameBelongsToPage(const performance_manager::FrameNode* node,
                        const performance_manager::PageNode* page,
                        content::WebContents* contents) {
  content::RenderFrameHost* frame =
      node->GetResourceContext().GetRenderFrameHost();
  return node->GetPageNode() == page && frame && frame->IsActive() &&
         frame->IsRenderFrameLive() &&
         &frame->GetPage() == &contents->GetPrimaryPage();
}

bool WorkerBelongsToPage(const performance_manager::WorkerNode* root,
                         const performance_manager::PageNode* page,
                         content::WebContents* contents) {
  using Worker = performance_manager::WorkerNode;
  std::vector<std::pair<const Worker*, bool>> pending{{root, false}};
  std::set<const Worker*> visiting;
  std::set<const Worker*> validated;
  while (!pending.empty()) {
    const auto [worker, leaving] = pending.back();
    pending.pop_back();
    if (leaving) {
      visiting.erase(worker);
      validated.insert(worker);
      continue;
    }
    if (validated.contains(worker)) {
      continue;
    }
    if (!visiting.insert(worker).second) {
      return false;
    }
    const auto frames = worker->GetClientFrames();
    const auto workers = worker->GetClientWorkers();
    if (frames.empty() && workers.empty()) {
      return false;
    }
    for (const auto* frame : frames) {
      if (!FrameBelongsToPage(frame, page, contents)) {
        return false;
      }
    }
    pending.emplace_back(worker, true);
    for (const auto* client : workers) {
      pending.emplace_back(client, false);
    }
  }
  return true;
}

bool ProcessBelongsToPage(const ProcessContext& process,
                          const PageContext& page) {
  const auto process_node = process.GetWeakProcessNode();
  const auto page_node = page.GetWeakPageNode();
  if (!process_node || !page_node) {
    return false;
  }
  const auto pages = performance_manager::GraphOperations::GetAssociatedPageNodes(
      process_node.get());
  if (pages.size() != 1 || *pages.begin() != page_node.get()) {
    return false;
  }
  content::WebContents* contents = page.GetWebContents();
  if (!contents) {
    return false;
  }
  for (const auto* node : process_node->GetFrameNodes()) {
    if (!FrameBelongsToPage(node, page_node.get(), contents)) {
      return false;
    }
  }
  for (const auto* worker : process_node->GetWorkerNodes()) {
    if (!WorkerBelongsToPage(worker, page_node.get(), contents)) {
      return false;
    }
  }
  return true;
}

std::vector<TabTarget> CaptureTargets(const std::set<int>& wanted,
                                      bool include_process) {
  std::vector<TabTarget> targets;
  for (const auto* node : PerformanceManager::GetGraph()->GetAllPageNodes()) {
    PageContext page = node->GetResourceContext();
    content::WebContents* contents = page.GetWebContents();
    if (!contents || contents->IsBeingDestroyed() || contents->WasDiscarded()) {
      continue;
    }
    const SessionID session = sessions::SessionTabHelper::IdForTab(contents);
    if (!session.is_valid()) {
      continue;
    }
    const int id = session.id();
    const auto primary = PageContext::FromWebContents(contents);
    if (!wanted.contains(id) || !primary || *primary != page) {
      continue;
    }
    content::RenderFrameHost* frame = contents->GetPrimaryMainFrame();
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() ||
        contents->IsCrashed()) {
      continue;
    }
    auto process = include_process
                       ? ProcessContext::FromRenderProcessHost(frame->GetProcess())
                       : std::nullopt;
    const bool exclusive = process && ProcessBelongsToPage(*process, page);
    targets.push_back({id, std::move(page), frame->GetGlobalFrameToken(),
                       frame->GetNavigationId(), std::move(process), exclusive});
  }
  std::sort(targets.begin(), targets.end(),
            [](const TabTarget& a, const TabTarget& b) { return a.id < b.id; });
  return targets;
}

content::WebContents* CurrentContents(const TabTarget& target) {
  content::WebContents* contents = target.page.GetWebContents();
  if (!contents || contents->IsBeingDestroyed() || contents->IsCrashed() ||
      contents->WasDiscarded()) {
    return nullptr;
  }
  const auto page = PageContext::FromWebContents(contents);
  content::RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  if (!page || *page != target.page || !frame || !frame->IsActive() ||
      !frame->IsRenderFrameLive() ||
      frame->GetGlobalFrameToken() != target.main_frame ||
      frame->GetNavigationId() != target.navigation_id ||
      sessions::SessionTabHelper::IdForTab(contents).id() != target.id) {
    return nullptr;
  }
  return contents;
}

struct MeasurementClock {
  base::Time wall = base::Time::Now();
  base::TimeTicks ticks = base::TimeTicks::Now();

  double At(base::TimeTicks measured) const {
    return (wall - (ticks - measured)).InMillisecondsFSinceUnixEpochIgnoringNull();
  }
};

base::ListValue MemoryTabs(const std::vector<TabTarget>& targets,
                           const QueryResultMap& results) {
  base::ListValue tabs;
  const MeasurementClock clock;
  for (const TabTarget& target : targets) {
    content::WebContents* contents = CurrentContents(target);
    if (!contents) {
      continue;
    }
    const resource_attribution::MemorySummaryResult* memory = nullptr;
    const char* source = "attribution";
    const auto page_result = results.find(target.page);
    if (page_result != results.end() && page_result->second.memory_summary_result) {
      memory = &*page_result->second.memory_summary_result;
    } else if (target.exclusive && target.process &&
               ProcessBelongsToPage(*target.process, target.page)) {
      const auto current_process = ProcessContext::FromRenderProcessHost(
          contents->GetPrimaryMainFrame()->GetProcess());
      if (!current_process || *current_process != *target.process) {
        continue;
      }
      const auto process_result = results.find(*target.process);
      if (process_result != results.end() &&
          process_result->second.memory_summary_result) {
        memory = &*process_result->second.memory_summary_result;
        source = "footprint";
      }
    }
    if (memory) {
      tabs.Append(base::DictValue()
                      .Set("tabId", target.id)
                      .Set("bytes", static_cast<double>(
                                        memory->private_footprint.InBytes()))
                      .Set("source", source)
                      .Set("at", clock.At(memory->metadata.measurement_time)));
    }
  }
  return tabs;
}

base::ListValue CpuTabs(const std::vector<TabTarget>& targets,
                        const QueryResultMap& results) {
  base::ListValue tabs;
  const MeasurementClock clock;
  for (const TabTarget& target : targets) {
    if (!CurrentContents(target)) {
      continue;
    }
    const auto result = results.find(target.page);
    if (result == results.end() || !result->second.cpu_time_result) {
      continue;
    }
    const auto& cpu = *result->second.cpu_time_result;
    const double cpu_ms = cpu.cumulative_cpu.InMillisecondsF();
    const double elapsed_ms =
        (cpu.metadata.measurement_time - cpu.start_time).InMillisecondsF();
    if (!std::isfinite(cpu_ms) || !std::isfinite(elapsed_ms) || cpu_ms < 0 ||
        elapsed_ms < 0) {
      continue;
    }
    tabs.Append(
        base::DictValue()
            .Set("tabId", target.id)
            .Set("cpuMs", cpu_ms)
            .Set("elapsedMs", elapsed_ms)
            .Set("measurementId",
                 target.page.ToString() + ":" +
                     base::NumberToString(
                         cpu.start_time.since_origin().InMicroseconds()))
            .Set("source", "attribution")
            .Set("at", clock.At(cpu.metadata.measurement_time)));
  }
  return tabs;
}

void MeasureTabs(const std::set<int>& wanted,
                 ResourceType type,
                 base::OnceCallback<void(base::ListValue)> callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (wanted.empty() || !PerformanceManager::IsAvailable()) {
    std::move(callback).Run(base::ListValue());
    return;
  }
  auto targets = CaptureTargets(wanted, type == ResourceType::kMemorySummary);
  QueryBuilder builder;
  builder.AddResourceType(type).AddAllContextsOfType<PageContext>();
  if (type == ResourceType::kMemorySummary) {
    builder.AddAllContextsOfType<ProcessContext>();
  }
  builder.QueryOnce(base::BindOnce(
      [](base::OnceCallback<void(base::ListValue)> callback,
         std::vector<TabTarget> targets, ResourceType type,
         const QueryResultMap& results) {
        DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
        base::ListValue tabs = type == ResourceType::kMemorySummary
                                   ? MemoryTabs(targets, results)
                                   : CpuTabs(targets, results);
        std::move(callback).Run(std::move(tabs));
      },
      std::move(callback), std::move(targets), type));
}

void QueryTabs(const char* args_json,
               ac_engine_reply_t reply,
               void* context,
               ResourceType type) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  Reply out(reply, context);
  auto wanted = RequestedTabIds(args_json, out);
  if (!wanted) {
    return;
  }
  if (wanted->empty()) {
    out.Send(base::DictValue().Set("tabs", base::ListValue()));
    return;
  }
  if (!PerformanceManager::IsAvailable()) {
    out.Error("performance manager unavailable");
    return;
  }
  MeasureTabs(
      *wanted, type,
      base::BindOnce(
          [](Reply out, base::ListValue tabs) {
            out.Send(base::DictValue().Set("tabs", std::move(tabs)));
          },
          std::move(out)));
}

}

void QueryTabMemory(const std::set<int>& tab_ids,
                    base::OnceCallback<void(base::ListValue)> callback) {
  MeasureTabs(tab_ids, ResourceType::kMemorySummary, std::move(callback));
}

}

AC_ENGINE_CALL(ac_tabs_memory) {
  solara::QueryTabs(args_json, reply, context,
                   resource_attribution::ResourceType::kMemorySummary);
}

AC_ENGINE_CALL(ac_tabs_cpu) {
  solara::QueryTabs(args_json, reply, context,
                   resource_attribution::ResourceType::kCPUTime);
}
