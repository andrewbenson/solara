#ifndef CHROME_BROWSER_SOLARA_AC_CLI_SIDEBAR_H_
#define CHROME_BROWSER_SOLARA_AC_CLI_SIDEBAR_H_

#include <cstdint>
#include <cstdlib>
#include <memory>
#include <string>

#include "public/ac_engine.h"

namespace solara {

struct CliSidebarResponse {
  std::string json;
  std::string error;
};

class CliSidebarChannel {
 public:
  void Register(ac_cli_sidebar_handler_v1_t handler) { handler_ = handler; }

  CliSidebarResponse Invoke(const std::string& request,
                            bool browser_root,
                            bool session_specified,
                            uint64_t generation,
                            uint64_t live_generation) const {
    if (!browser_root || session_specified) {
      return {{}, "sidebar control requires the browser connection without a sessionId"};
    }
    if (!generation || generation != live_generation) {
      return {{}, "sidebar control is off or this connection was revoked"};
    }
    if (request.size() > 64 * 1024) {
      return {{}, "sidebar params exceed the limit of 65536 bytes"};
    }
    if (!handler_) {
      return {{}, "sidebar control is unavailable; the native workspace is not connected"};
    }
    std::unique_ptr<char, decltype(&free)> result(handler_(request.c_str()), &free);
    if (!result) {
      return {{}, "sidebar control returned no response"};
    }
    return {std::string(result.get()), {}};
  }

 private:
  ac_cli_sidebar_handler_v1_t handler_ = nullptr;
};

}

#endif
