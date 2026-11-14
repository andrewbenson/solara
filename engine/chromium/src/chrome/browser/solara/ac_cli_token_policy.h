// Copyright 2026 Solara. Apache-2.0.

#ifndef CHROME_BROWSER_SOLARA_AC_CLI_TOKEN_POLICY_H_
#define CHROME_BROWSER_SOLARA_AC_CLI_TOKEN_POLICY_H_

#include <cstdint>
#include <memory>

#include "solara/core/ac_content_hooks.h"  // nogncheck

namespace content {
class DevToolsAgentHost;
class DevToolsAgentHostClient;
class RenderFrameHost;
}

namespace solara {

uint64_t CliControlGeneration();

std::unique_ptr<SolaraDevToolsTokenClient> CreateTokenClient(
    content::DevToolsAgentHostClient* client,
    content::DevToolsAgentHost* host);

bool TokenClientMayAttach(content::DevToolsAgentHostClient* root_client,
                          content::DevToolsAgentHost* host);

bool TokenClientMayInput(content::DevToolsAgentHostClient* root_client,
                         content::RenderFrameHost* frame);

}

#endif
