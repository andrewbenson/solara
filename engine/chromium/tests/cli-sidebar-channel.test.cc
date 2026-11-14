#include "../src/chrome/browser/solara/ac_cli_sidebar.h"

#include <cassert>
#include <cstring>
#include <string>

namespace {
int edits = 0;
int invocations = 0;
std::string last_request;
char* Handler(const char* request) {
  ++invocations;
  last_request = request;
  if (std::string(request) == "edit") ++edits;
  return strdup("{\"changes\":[\"renamed\"]}");
}
char* NoReply(const char*) { return nullptr; }

std::string PaddedRequest(size_t bytes, bool dry_run, bool multibyte) {
  std::string request =
      R"({"operation":"tab.rename","tabId":"tab-1","title":"Renamed","dryRun":)";
  request += dry_run ? "true" : "false";
  request += R"(,"ignored":{"padding":"sensitive-padding-)";
  const size_t padding_bytes = bytes - request.size() - 3;
  if (multibyte) {
    for (size_t i = 0; i < padding_bytes / 2; ++i) {
      request += "\xc3\xa9";
    }
    request.append(padding_bytes % 2, 'x');
  } else {
    request.append(padding_bytes, 'x');
  }
  request += "\"}}";
  assert(request.size() == bytes);
  return request;
}

void VerifyRequestBudget(solara::CliSidebarChannel& channel) {
  for (bool dry_run : {false, true}) {
    for (bool multibyte : {false, true}) {
      for (size_t bytes : {65535, 65536, 65537, 8 * 1024 * 1024}) {
        const std::string request = PaddedRequest(bytes, dry_run, multibyte);
        const int before = invocations;
        const auto result = channel.Invoke(request, true, false, 2, 2);
        if (bytes <= 65536) {
          assert(result.error.empty());
          assert(result.json == "{\"changes\":[\"renamed\"]}");
          assert(invocations == before + 1);
          assert(last_request == request);
        } else {
          assert(!result.error.empty() && result.error.size() < 200);
          assert(result.error.find("65536") != std::string::npos);
          assert(result.error.find("bytes") != std::string::npos);
          assert(result.error.find("sensitive-padding") == std::string::npos);
          assert(result.json.empty());
          assert(invocations == before);
        }
      }
    }
  }
}
}

int main() {
  solara::CliSidebarChannel channel;
  assert(!channel.Invoke("edit", true, false, 1, 1).error.empty());
  channel.Register(Handler);
  assert(!channel.Invoke("edit", false, false, 1, 1).error.empty());
  assert(!channel.Invoke("edit", true, true, 1, 1).error.empty());
  assert(!channel.Invoke("edit", true, false, 0, 0).error.empty());
  assert(!channel.Invoke("edit", true, false, 1, 0).error.empty());
  assert(!channel.Invoke("edit", true, false, 1, 2).error.empty());
  assert(edits == 0);
  auto result = channel.Invoke("edit", true, false, 2, 2);
  assert(result.error.empty());
  assert(result.json == "{\"changes\":[\"renamed\"]}");
  assert(edits == 1);
  auto next = channel.Invoke("read", true, false, 2, 2);
  assert(next.error.empty() && result.json == next.json);
  VerifyRequestBudget(channel);
  channel.Register(NoReply);
  assert(!channel.Invoke("edit", true, false, 2, 2).error.empty());
  channel.Register(nullptr);
  assert(!channel.Invoke("edit", true, false, 2, 2).error.empty());
  assert(edits == 1);
}
