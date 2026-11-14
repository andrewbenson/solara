// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/ac_user_hooks.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/stat.h>

#include <algorithm>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/solara/ac_engine.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/back_forward_cache.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "services/network/public/cpp/resource_request.h"
#include "third_party/blink/public/common/loader/url_loader_throttle.h"
#include "third_party/re2/src/re2/re2.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "url/url_constants.h"

extern bool (*g_solara_download_folder)(download::DownloadItem* item,
                                        base::FilePath* folder,
                                        base::FilePath* containment);

namespace solara {
namespace {

constexpr size_t kMaxRules = 200;
constexpr size_t kMaxListEntries = 100;
constexpr size_t kMaxPatternLength = 1024;
constexpr size_t kMaxMatchLength = 65536;
constexpr size_t kMaxResultLength = 8192;
constexpr int kMaxCaptures = 9;
constexpr int64_t kRegexMemory = 1 << 20;

enum class Action { kNone, kBlock, kRewrite, kStripParams, kHttps, kFileInto };

struct HostPattern {
  std::string host;
  bool subdomains = false;
  bool any = false;

  bool Matches(std::string_view candidate) const {
    if (any) {
      return true;
    }
    if (candidate == host) {
      return true;
    }
    return subdomains && candidate.size() > host.size() &&
           candidate.ends_with(host) &&
           candidate[candidate.size() - host.size() - 1] == '.';
  }
};

struct UrlPattern {
  std::string scheme;
  HostPattern host;
  std::optional<int> port;
  std::string path;
};

enum class PieceKind { kLiteral, kField, kCapture };

struct Piece {
  PieceKind kind = PieceKind::kLiteral;
  std::string text;
  int capture = 0;
};

enum class Authority { kLiteral, kPage };

struct Template {
  Authority authority = Authority::kLiteral;
  std::string literal_authority;
  GURL literal_origin;
  std::string page_scheme;
  bool keep_port = false;
  std::vector<Piece> tail;
};

struct Folder {
  std::string root;
  uint64_t root_dev = 0;
  uint64_t root_ino = 0;
  std::vector<std::string> below;
};

struct Rule {
  std::string id;
  std::string config;
  std::string name;
  Action action = Action::kNone;
  std::vector<HostPattern> hosts;
  std::vector<UrlPattern> urls;
  std::unique_ptr<re2::RE2> regex;
  std::optional<std::set<std::string>> profiles;
  Template rewrite;
  std::vector<std::string> params;
  Folder folder;
};

struct Matched {
  bool matched = false;
  bool failed = false;
  std::vector<std::string> captures;
};

struct Decision {
  enum class Kind { kProceed, kBlock, kRewrite };
  Kind kind = Kind::kProceed;
  std::string rule;
  GURL target;
};

std::vector<std::unique_ptr<Rule>>& Rules() {
  static base::NoDestructor<std::vector<std::unique_ptr<Rule>>> rules;
  return *rules;
}

std::map<int64_t, GURL>& PendingRewrites() {
  static base::NoDestructor<std::map<int64_t, GURL>> pending;
  return *pending;
}

bool g_configured = false;
bool g_pending = false;
base::TimeTicks g_pending_since;
bool g_hold_timed_out = false;
size_t g_late_count = 0;

int LateCount() {
  return static_cast<int>(
      std::min<size_t>(g_late_count, std::numeric_limits<int>::max()));
}
constexpr base::TimeDelta kPendingDeadline = base::Seconds(3);

class UserHooksThrottle;
bool RulesPending();
void HoldTimedOut();
void WaitForRules(base::WeakPtr<UserHooksThrottle> throttle);
void ReleaseWaiting();


bool IsNavigationAction(Action action) {
  return action == Action::kBlock || action == Action::kRewrite ||
         action == Action::kStripParams || action == Action::kHttps;
}

std::string NavigationFingerprint() {
  std::string fingerprint;
  for (const auto& rule : Rules()) {
    if (IsNavigationAction(rule->action)) {
      fingerprint += rule->config;
      fingerprint += '\n';
    }
  }
  return fingerprint;
}

void DropKeptPages() {
  extensions::ExtensionTabUtil::ForEachTab(
      base::BindRepeating([](content::WebContents* contents) {
        contents->GetController().GetBackForwardCache().Flush();
        contents->CancelAllPrerendering();
      }));
}

bool HasDownloadRules() {
  for (const auto& rule : Rules()) {
    if (rule->action == Action::kFileInto) {
      return true;
    }
  }
  return false;
}

bool PlainHost(std::string_view host) {
  if (host.empty() || host.size() > 253 || host.front() == '.' ||
      host.back() == '.' || host.find("..") != std::string_view::npos) {
    return false;
  }
  for (char c : host) {
    if (!base::IsAsciiLower(c) && !base::IsAsciiDigit(c) && c != '-' &&
        c != '.' && c != '_') {
      return false;
    }
  }
  return true;
}

std::optional<HostPattern> ParseHost(std::string_view text, bool allow_any) {
  HostPattern pattern;
  std::string lowered = base::ToLowerASCII(text);
  if (allow_any && lowered == "*") {
    pattern.any = true;
    return pattern;
  }
  if (lowered.starts_with("*.")) {
    pattern.subdomains = true;
    lowered = lowered.substr(2);
  }
  if (!lowered.empty() && lowered.back() == '.') {
    lowered.pop_back();
  }
  if (!PlainHost(lowered)) {
    GURL probe("http://" + lowered + "/");
    if (!probe.is_valid() || !probe.HostIsIPAddress() || probe.host() != lowered) {
      return std::nullopt;
    }
  }
  pattern.host = std::move(lowered);
  return pattern;
}

std::optional<UrlPattern> ParseUrlPattern(std::string_view text) {
  if (text.empty() || text.size() > kMaxPatternLength) {
    return std::nullopt;
  }
  for (char c : text) {
    if (c <= 0x20 || c >= 0x7f || c == '\\') {
      return std::nullopt;
    }
  }
  const size_t separator = text.find("://");
  if (separator == std::string_view::npos) {
    return std::nullopt;
  }
  UrlPattern pattern;
  pattern.scheme = base::ToLowerASCII(text.substr(0, separator));
  if (pattern.scheme != "http" && pattern.scheme != "https" &&
      pattern.scheme != "*") {
    return std::nullopt;
  }
  std::string_view rest = text.substr(separator + 3);
  const size_t slash = rest.find('/');
  if (slash == std::string_view::npos) {
    return std::nullopt;
  }
  std::string_view authority = rest.substr(0, slash);
  pattern.path = std::string(rest.substr(slash));
  if (authority.find_first_of("@?#") != std::string_view::npos) {
    return std::nullopt;
  }
  const size_t colon = authority.rfind(':');
  if (colon != std::string_view::npos && authority.find(']') == std::string_view::npos) {
    std::string_view port_text = authority.substr(colon + 1);
    authority = authority.substr(0, colon);
    if (port_text != "*") {
      int port = 0;
      if (!base::StringToInt(port_text, &port) || port < 1 || port > 65535) {
        return std::nullopt;
      }
      pattern.port = port;
    }
  }
  std::optional<HostPattern> host = ParseHost(authority, true);
  if (!host) {
    return std::nullopt;
  }
  pattern.host = std::move(*host);
  return pattern;
}

bool GlobMatches(std::string_view pattern, std::string_view text) {
  size_t p = 0;
  size_t t = 0;
  size_t star = std::string_view::npos;
  size_t resume = 0;
  while (t < text.size()) {
    if (p < pattern.size() && pattern[p] == '*') {
      star = p++;
      resume = t;
    } else if (p < pattern.size() && pattern[p] == text[t]) {
      ++p;
      ++t;
    } else if (star != std::string_view::npos) {
      p = star + 1;
      t = ++resume;
    } else {
      return false;
    }
  }
  while (p < pattern.size() && pattern[p] == '*') {
    ++p;
  }
  return p == pattern.size();
}

GURL MatchingURL(const GURL& url) {
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return GURL();
  }
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  std::string host(url.host());
  if (host.size() > 1 && host.back() == '.') {
    host.pop_back();
    replacements.SetHostStr(host);
  }
  return url.ReplaceComponents(replacements);
}

bool UrlPatternMatches(const UrlPattern& pattern, const GURL& url) {
  if (pattern.scheme != "*" && pattern.scheme != url.scheme()) {
    return false;
  }
  if (!pattern.host.Matches(url.host())) {
    return false;
  }
  if (pattern.port && *pattern.port != url.EffectiveIntPort()) {
    return false;
  }
  std::string path(url.path());
  if (url.has_query()) {
    path += "?";
    path += url.query();
  }
  return GlobMatches(pattern.path, path);
}

Matched MatchRule(const Rule& rule, const GURL& url) {
  Matched result;
  if (rule.hosts.empty() && rule.urls.empty() && !rule.regex) {
    result.matched = true;
    return result;
  }
  const bool long_url = url.spec().size() > kMaxMatchLength;
  for (const HostPattern& host : rule.hosts) {
    if (host.Matches(url.host())) {
      result.matched = true;
      return result;
    }
  }
  if (long_url) {
    for (const UrlPattern& pattern : rule.urls) {
      if ((pattern.scheme == "*" || pattern.scheme == url.scheme()) &&
          pattern.host.Matches(url.host()) &&
          (!pattern.port || *pattern.port == url.EffectiveIntPort())) {
        result.failed = true;
        return result;
      }
    }
    result.failed = rule.regex != nullptr;
    return result;
  }
  for (const UrlPattern& pattern : rule.urls) {
    if (UrlPatternMatches(pattern, url)) {
      result.matched = true;
      return result;
    }
  }
  if (!rule.regex) {
    return result;
  }
  const std::string& spec = url.spec();
  const int groups =
      std::min<int>(rule.regex->NumberOfCapturingGroups(), kMaxCaptures);
  std::vector<absl::string_view> found(groups + 1);
  if (!rule.regex->Match(spec, 0, spec.size(), re2::RE2::ANCHOR_BOTH,
                         found.data(), groups + 1)) {
    return result;
  }
  result.matched = true;
  for (const absl::string_view& group : found) {
    result.captures.emplace_back(group.data() ? std::string(group) : std::string());
  }
  return result;
}

bool ProfileMatches(const Rule& rule, Profile* profile) {
  if (!rule.profiles) {
    return true;
  }
  if (!profile || profile->IsOffTheRecord()) {
    return false;
  }
  return rule.profiles->contains(profile->GetBaseName().value());
}

std::optional<std::string> ParseTemplate(std::string_view text,
                                         int captures,
                                         Template* out) {
  if (text.empty() || text.size() > kMaxResultLength) {
    return "must be a URL template of at most 8 KB";
  }
  static constexpr std::string_view kFields[] = {
      "url", "scheme", "host", "port", "path", "query", "fragment", "origin"};
  std::vector<Piece> pieces;
  std::string literal;
  for (size_t i = 0; i < text.size();) {
    const char c = text[i];
    if (c == '}') {
      return "has a } without a matching {";
    }
    if (c != '{') {
      literal.push_back(c);
      ++i;
      continue;
    }
    const size_t close = text.find('}', i);
    if (close == std::string_view::npos) {
      return "has a { without a matching }";
    }
    std::string_view name = text.substr(i + 1, close - i - 1);
    if (!literal.empty()) {
      pieces.push_back({PieceKind::kLiteral, std::move(literal), 0});
      literal.clear();
    }
    bool known = false;
    for (std::string_view field : kFields) {
      known |= field == name;
    }
    if (known) {
      pieces.push_back({PieceKind::kField, std::string(name), 0});
    } else if (name.size() == 1 && name[0] >= '1' && name[0] <= '9' &&
               name[0] - '0' <= captures) {
      pieces.push_back({PieceKind::kCapture, std::string(), name[0] - '0'});
    } else {
      return "uses {" + std::string(name) + "}, which isn't a placeholder";
    }
    i = close + 1;
  }
  if (!literal.empty()) {
    pieces.push_back({PieceKind::kLiteral, std::move(literal), 0});
  }
  auto is_field = [&](size_t index, std::string_view name) {
    return index < pieces.size() && pieces[index].kind == PieceKind::kField &&
           pieces[index].text == name;
  };
  size_t next = 0;
  Template result;
  if (is_field(0, "origin")) {
    result.authority = Authority::kPage;
    result.keep_port = true;
    next = 1;
  } else if (is_field(0, "scheme") && pieces.size() > 2 &&
             pieces[1].kind == PieceKind::kLiteral && pieces[1].text == "://" &&
             is_field(2, "host")) {
    result.authority = Authority::kPage;
    next = 3;
    if (is_field(3, "port")) {
      result.keep_port = true;
      next = 4;
    }
  } else if (!pieces.empty() && pieces[0].kind == PieceKind::kLiteral) {
    std::string lowered = base::ToLowerASCII(pieces[0].text);
    std::string scheme;
    if (lowered.starts_with("https://")) {
      scheme = "https";
    } else if (lowered.starts_with("http://")) {
      scheme = "http";
    } else {
      return "must start with http://, https://, {origin} or {scheme}://{host}";
    }
    const std::string& first = pieces[0].text;
    const size_t start = scheme.size() + 3;
    const size_t end = first.find_first_of("/?#", start);
    if (end == std::string::npos && first.size() == start && is_field(1, "host")) {
      result.authority = Authority::kPage;
      result.page_scheme = scheme;
      next = 2;
      if (is_field(2, "port")) {
        result.keep_port = true;
        next = 3;
      }
    } else if (end == std::string::npos && pieces.size() > 1 &&
               !is_field(1, "path") && !is_field(1, "query") &&
               !is_field(1, "fragment")) {
      return "must spell out the host or use the page's own ({host}, "
             "{origin}); a placeholder can't be part of the host";
    } else {
      result.authority = Authority::kLiteral;
      result.literal_authority =
          end == std::string::npos ? first : first.substr(0, end);
      GURL origin(result.literal_authority + "/");
      if (!origin.is_valid() || !origin.SchemeIsHTTPOrHTTPS() ||
          !origin.has_host() || origin.has_username() || origin.has_password()) {
        return "must start with a valid http(s) address";
      }
      result.literal_origin = origin;
      if (end != std::string::npos) {
        pieces[0].text = first.substr(end);
        next = 0;
      } else {
        next = 1;
      }
    }
  } else {
    return "must start with http://, https://, {origin} or {scheme}://{host}";
  }
  if (next < pieces.size()) {
    const Piece& piece = pieces[next];
    const bool tail_field =
        piece.kind == PieceKind::kField &&
        (piece.text == "path" || piece.text == "query" || piece.text == "fragment");
    const bool tail_literal =
        piece.kind == PieceKind::kLiteral && !piece.text.empty() &&
        (piece.text[0] == '/' || piece.text[0] == '?' || piece.text[0] == '#');
    if (!tail_field && !tail_literal) {
      return "must end the host with /, ?, # or {path}, {query}, {fragment}";
    }
  }
  result.tail.assign(std::make_move_iterator(pieces.begin() + next),
                     std::make_move_iterator(pieces.end()));
  *out = std::move(result);
  return std::nullopt;
}

GURL ExpandTemplate(const Template& tmpl,
                    const GURL& url,
                    const std::vector<std::string>& captures) {
  std::string expected_scheme;
  std::string text;
  if (tmpl.authority == Authority::kLiteral) {
    expected_scheme = std::string(tmpl.literal_origin.scheme());
    text = tmpl.literal_authority;
  } else {
    expected_scheme =
        tmpl.page_scheme.empty() ? std::string(url.scheme()) : tmpl.page_scheme;
    text = expected_scheme + "://" + std::string(url.host());
    if (tmpl.keep_port && url.has_port()) {
      text += ":" + std::string(url.port());
    }
  }
  for (const Piece& piece : tmpl.tail) {
    switch (piece.kind) {
      case PieceKind::kLiteral:
        text += piece.text;
        break;
      case PieceKind::kCapture:
        if (static_cast<size_t>(piece.capture) < captures.size()) {
          text += base::EscapeAllExceptUnreserved(captures[piece.capture]);
        }
        break;
      case PieceKind::kField:
        if (piece.text == "path") {
          text += url.path();
        } else if (piece.text == "query") {
          if (url.has_query()) {
            text += "?" + std::string(url.query());
          }
        } else if (piece.text == "fragment") {
          if (url.has_ref()) {
            text += "#" + std::string(url.ref());
          }
        } else if (piece.text == "url") {
          text += base::EscapeAllExceptUnreserved(url.spec());
        } else if (piece.text == "scheme") {
          text += base::EscapeAllExceptUnreserved(url.scheme());
        } else if (piece.text == "host") {
          text += base::EscapeAllExceptUnreserved(url.host());
        } else if (piece.text == "port") {
          text += base::EscapeAllExceptUnreserved(url.port());
        } else if (piece.text == "origin") {
          text += base::EscapeAllExceptUnreserved(
              url::Origin::Create(url).Serialize());
        }
        break;
    }
    if (text.size() > kMaxResultLength) {
      return GURL();
    }
  }
  GURL result(text);
  if (!result.is_valid() || !result.SchemeIsHTTPOrHTTPS() ||
      result.has_username() || result.has_password() ||
      result.spec().size() > kMaxResultLength) {
    return GURL();
  }
  if (result.scheme() != expected_scheme) {
    return GURL();
  }
  if (tmpl.authority == Authority::kLiteral) {
    if (result.host() != tmpl.literal_origin.host() ||
        result.EffectiveIntPort() != tmpl.literal_origin.EffectiveIntPort()) {
      return GURL();
    }
  } else {
    if (result.host() != url.host()) {
      return GURL();
    }
    const int expected_port =
        tmpl.keep_port ? url.EffectiveIntPort()
                       : (expected_scheme == "https" ? 443 : 80);
    if (result.EffectiveIntPort() != expected_port) {
      return GURL();
    }
    if (url.SchemeIs(url::kHttpsScheme) && !result.SchemeIs(url::kHttpsScheme)) {
      return GURL();
    }
  }
  return result;
}

bool ParamMatches(const std::vector<std::string>& names, std::string_view key) {
  for (const std::string& name : names) {
    if (name.ends_with('*')) {
      if (key.starts_with(std::string_view(name).substr(0, name.size() - 1))) {
        return true;
      }
    } else if (key == name) {
      return true;
    }
  }
  return false;
}

GURL StripParams(const std::vector<std::string>& names, const GURL& url) {
  if (!url.has_query()) {
    return GURL();
  }
  std::vector<std::string_view> kept;
  bool removed = false;
  for (std::string_view part : base::SplitStringPiece(
           url.query(), "&", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL)) {
    const std::string_view key = part.substr(0, part.find('='));
    if (!part.empty() && ParamMatches(names, key)) {
      removed = true;
    } else {
      kept.push_back(part);
    }
  }
  if (!removed) {
    return GURL();
  }
  const std::string query = base::JoinString(kept, "&");
  GURL::Replacements replacements;
  if (query.empty()) {
    replacements.ClearQuery();
  } else {
    replacements.SetQueryStr(query);
  }
  GURL result = url.ReplaceComponents(replacements);
  return result.is_valid() ? result : GURL();
}

GURL UpgradeToHttps(const GURL& url) {
  if (!url.SchemeIs(url::kHttpScheme)) {
    return GURL();
  }
  GURL::Replacements replacements;
  replacements.SetSchemeStr(url::kHttpsScheme);
  if (url.has_port() && url.IntPort() == 80) {
    replacements.ClearPort();
  }
  GURL result = url.ReplaceComponents(replacements);
  return result.is_valid() ? result : GURL();
}

GURL Rewritten(const Rule& rule, const GURL& matching, const GURL& original,
               const Matched& matched) {
  GURL result;
  switch (rule.action) {
    case Action::kRewrite:
      result = ExpandTemplate(rule.rewrite, matching, matched.captures);
      break;
    case Action::kStripParams:
      result = StripParams(rule.params, original);
      break;
    case Action::kHttps:
      result = UpgradeToHttps(original);
      break;
    default:
      return GURL();
  }
  if (!result.is_valid() || result == original) {
    return GURL();
  }
  return result;
}

GURL InnerURL(const GURL& url) {
  if (url.SchemeIsBlob() || url.SchemeIsFileSystem()) {
    const url::Origin origin = url::Origin::Create(url);
    return origin.opaque() ? GURL() : origin.GetURL();
  }
  return url;
}

Decision Decide(Profile* profile, const GURL& url, bool allow_rewrite) {
  Decision decision;
  const bool inner = url.SchemeIsBlob() || url.SchemeIsFileSystem();
  allow_rewrite = allow_rewrite && !inner;
  const GURL matching = MatchingURL(InnerURL(url));
  if (!matching.is_valid()) {
    return decision;
  }
  for (const auto& rule : Rules()) {
    if (!IsNavigationAction(rule->action) || !ProfileMatches(*rule, profile)) {
      continue;
    }
    const bool block = rule->action == Action::kBlock;
    if (!block && !allow_rewrite) {
      continue;
    }
    Matched matched = MatchRule(*rule, matching);
    if (matched.failed) {
      decision.kind = Decision::Kind::kBlock;
      decision.rule = rule->name;
      return decision;
    }
    if (!matched.matched) {
      continue;
    }
    if (block) {
      decision.kind = Decision::Kind::kBlock;
      decision.rule = rule->name;
      return decision;
    }
    GURL target = Rewritten(*rule, matching, url, matched);
    if (target.is_valid()) {
      decision.kind = Decision::Kind::kRewrite;
      decision.rule = rule->name;
      decision.target = std::move(target);
      return decision;
    }
  }
  return decision;
}

Profile* ProfileOf(content::NavigationHandle* handle) {
  content::WebContents* contents = handle->GetWebContents();
  return contents ? Profile::FromBrowserContext(contents->GetBrowserContext())
                  : nullptr;
}

void Report(Profile* profile,
            const Decision& decision,
            const GURL& url,
            bool redirect) {
  base::DictValue payload;
  payload.Set("rule", decision.rule);
  payload.Set("action",
              decision.kind == Decision::Kind::kBlock ? "block" : "rewrite");
  payload.Set("redirect", redirect);
  if (profile && !profile->IsOffTheRecord()) {
    payload.Set("url", url.spec());
    if (decision.target.is_valid()) {
      payload.Set("target", decision.target.spec());
    }
  }
  Emit("hooks.navigation", profile, std::move(payload));
}

class RewriteLoaderThrottle : public blink::URLLoaderThrottle {
 public:
  explicit RewriteLoaderThrottle(GURL target) : target_(std::move(target)) {}

  void DetachFromCurrentSequence() override {}

  void WillStartRequest(network::ResourceRequest* request,
                        bool* defer) override {
    if (applied_ || !request || request->method != "GET") {
      return;
    }
    applied_ = true;
    request->url = target_;
  }

 private:
  const GURL target_;
  bool applied_ = false;
};

class UserHooksThrottle : public content::NavigationThrottle {
 public:
  explicit UserHooksThrottle(content::NavigationThrottleRegistry& registry)
      : content::NavigationThrottle(registry) {}

  ~UserHooksThrottle() override {
    if (stashed_) {
      PendingRewrites().erase(navigation_id_);
    }
  }

  ThrottleCheckResult WillStartRequest() override {
    content::NavigationHandle* handle = navigation_handle();
    navigation_id_ = handle->GetNavigationId();
    const GURL& url = handle->GetURL();
    if (!url.SchemeIsHTTPOrHTTPS() && !url.SchemeIsBlob() &&
        !url.SchemeIsFileSystem()) {
      return PROCEED;
    }
    if (RulesPending()) {
      WaitForRules(weak_factory_.GetWeakPtr());
      return DEFER;
    }
    return Check();
  }

  void RulesArrived() {
    ThrottleCheckResult result = Check();
    if (result.action() == PROCEED) {
      Resume();
    } else {
      CancelDeferredNavigation(result);
    }
  }

  ThrottleCheckResult Check() {
    content::NavigationHandle* handle = navigation_handle();
    const GURL& url = handle->GetURL();
    if (g_hold_timed_out) {
      ++g_late_count;
    }
    const bool prerender = handle->IsInPrerenderedMainFrame();
    const bool rewritable =
        prerender ||
        (handle->IsInOutermostMainFrame() && url.SchemeIsHTTPOrHTTPS() &&
         handle->GetRequestMethod() == "GET" && !handle->IsPost() &&
         !handle->IsFormSubmission() && !handle->IsHistory() &&
         handle->GetReloadType() == content::ReloadType::NONE &&
         !handle->IsServedFromBackForwardCache() &&
         !handle->IsPageActivation());
    Profile* profile = ProfileOf(handle);
    Decision decision = Decide(profile, url, rewritable);
    if (decision.kind == Decision::Kind::kProceed) {
      return PROCEED;
    }
    if (prerender) {
      return CANCEL;
    }
    Report(profile, decision, url, false);
    if (decision.kind == Decision::Kind::kBlock) {
      return ThrottleCheckResult(BLOCK_REQUEST, net::ERR_BLOCKED_BY_CLIENT);
    }
    original_ = url;
    target_ = decision.target;
    PendingRewrites()[navigation_id_] = target_;
    stashed_ = true;
    return PROCEED;
  }

  ThrottleCheckResult WillRedirectRequest() override {
    content::NavigationHandle* handle = navigation_handle();
    const GURL& url = handle->GetURL();
    if (target_.is_valid() && url == target_) {
      rewritten_ = true;
    } else if (rewritten_ && url == original_) {
      return ThrottleCheckResult(BLOCK_REQUEST, net::ERR_BLOCKED_BY_CLIENT);
    }
    if (!url.SchemeIsHTTPOrHTTPS()) {
      return PROCEED;
    }
    Profile* profile = ProfileOf(handle);
    Decision decision = Decide(profile, url, false);
    if (decision.kind != Decision::Kind::kBlock) {
      return PROCEED;
    }
    if (handle->IsInPrerenderedMainFrame()) {
      return CANCEL;
    }
    Report(profile, decision, url, true);
    return ThrottleCheckResult(BLOCK_REQUEST, net::ERR_BLOCKED_BY_CLIENT);
  }

  ThrottleCheckResult WillProcessResponse() override {
    if (target_.is_valid() && !rewritten_) {
      return ThrottleCheckResult(BLOCK_RESPONSE, net::ERR_BLOCKED_BY_CLIENT);
    }
    return PROCEED;
  }

  const char* GetNameForLogging() override { return "ACUserHooksThrottle"; }

 private:
  int64_t navigation_id_ = 0;
  bool stashed_ = false;
  bool rewritten_ = false;
  GURL original_;
  GURL target_;
  base::WeakPtrFactory<UserHooksThrottle> weak_factory_{this};
};

std::vector<base::WeakPtr<UserHooksThrottle>>& Waiting() {
  static base::NoDestructor<std::vector<base::WeakPtr<UserHooksThrottle>>>
      waiting;
  return *waiting;
}

void ReleaseWaiting() {
  g_pending = false;
  g_pending_since = base::TimeTicks();
  std::vector<base::WeakPtr<UserHooksThrottle>> waiting =
      std::move(Waiting());
  Waiting().clear();
  for (base::WeakPtr<UserHooksThrottle>& throttle : waiting) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&UserHooksThrottle::RulesArrived,
                                  std::move(throttle)));
  }
}

void HoldTimedOut() {
  g_hold_timed_out = true;
  ReleaseWaiting();
}

bool RulesPending() {
  if (!g_pending) {
    return false;
  }
  if (!g_pending_since.is_null() &&
      base::TimeTicks::Now() - g_pending_since >= kPendingDeadline) {
    HoldTimedOut();
    return false;
  }
  return true;
}

void WaitForRules(base::WeakPtr<UserHooksThrottle> throttle) {
  if (g_pending_since.is_null()) {
    g_pending_since = base::TimeTicks::Now();
  }
  Waiting().push_back(std::move(throttle));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce([] {
        if (g_pending && !g_pending_since.is_null() &&
            base::TimeTicks::Now() - g_pending_since >= kPendingDeadline) {
          HoldTimedOut();
        }
      }),
      kPendingDeadline - (base::TimeTicks::Now() - g_pending_since));
}

std::optional<uint64_t> Number(const base::DictValue& dict,
                               std::string_view key) {
  const std::string* text = dict.FindString(key);
  uint64_t value = 0;
  if (!text || !base::StringToUint64(*text, &value)) {
    return std::nullopt;
  }
  return value;
}

bool FolderStillSafe(const Folder& folder,
                     base::FilePath* out,
                     base::FilePath* containment) {
  char resolved[PATH_MAX];
  if (!realpath(folder.root.c_str(), resolved) || folder.root != resolved) {
    return false;
  }
  struct stat info;
  if (lstat(folder.root.c_str(), &info) != 0 || !S_ISDIR(info.st_mode) ||
      static_cast<uint64_t>(static_cast<uint32_t>(info.st_dev)) !=
          folder.root_dev ||
      static_cast<uint64_t>(info.st_ino) != folder.root_ino) {
    return false;
  }
  base::FilePath path(folder.root);
  bool missing = false;
  for (const std::string& part : folder.below) {
    path = path.Append(part);
    if (missing) {
      continue;
    }
    if (lstat(path.value().c_str(), &info) != 0) {
      if (errno != ENOENT) {
        return false;
      }
      missing = true;
      continue;
    }
    if (!S_ISDIR(info.st_mode)) {
      return false;
    }
  }
  *out = path;
  *containment = base::FilePath(folder.root);
  return true;
}

bool SameSiteAsDownload(download::DownloadItem* item, const GURL& url) {
  using net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES;
  using net::registry_controlled_domains::SameDomainOrHost;
  const std::optional<url::Origin>& initiator = item->GetRequestInitiator();
  if (!initiator) {
    return true;
  }
  if (!initiator->opaque() &&
      SameDomainOrHost(url, *initiator, INCLUDE_PRIVATE_REGISTRIES)) {
    return true;
  }
  const GURL& tab = item->GetTabUrl();
  return tab.is_valid() && tab.SchemeIsHTTPOrHTTPS() &&
         SameDomainOrHost(url, url::Origin::Create(tab),
                          INCLUDE_PRIVATE_REGISTRIES);
}

bool DownloadFolder(download::DownloadItem* item,
                    base::FilePath* folder,
                    base::FilePath* containment) {
  if (!item || !folder || !containment || !pthread_main_np()) {
    return false;
  }
  content::BrowserContext* context =
      content::DownloadItemUtils::GetBrowserContext(item);
  if (!context || context->IsOffTheRecord()) {
    return false;
  }
  Profile* profile = Profile::FromBrowserContext(context);
  const GURL& url = item->GetURL();
  const GURL matching = MatchingURL(url);
  if (!matching.is_valid() || !SameSiteAsDownload(item, url)) {
    return false;
  }
  for (const auto& rule : Rules()) {
    if (rule->action != Action::kFileInto || !ProfileMatches(*rule, profile)) {
      continue;
    }
    Matched matched = MatchRule(*rule, matching);
    if (matched.failed) {
      return false;
    }
    if (!matched.matched) {
      continue;
    }
    base::FilePath target;
    base::FilePath root;
    if (!FolderStillSafe(rule->folder, &target, &root)) {
      Emit("hooks.download_refused", profile,
           base::DictValue().Set("rule", rule->name));
      return false;
    }
    *folder = target;
    *containment = root;
    return true;
  }
  return false;
}

std::optional<std::vector<std::string>> Strings(const base::DictValue& dict,
                                                std::string_view key) {
  const base::ListValue* list = dict.FindList(key);
  if (!list) {
    return std::nullopt;
  }
  std::vector<std::string> result;
  if (list->size() > kMaxListEntries) {
    return std::nullopt;
  }
  for (const base::Value& value : *list) {
    if (!value.is_string() || value.GetString().empty()) {
      return std::nullopt;
    }
    result.push_back(value.GetString());
  }
  return result;
}

std::optional<std::string> ParseRule(const base::DictValue& dict, Rule* rule) {
  const std::string* id = dict.FindString("id");
  const std::string* name = dict.FindString("name");
  const std::string* action = dict.FindString("action");
  if (!id || !name || !action) {
    return "needs id, name and action";
  }
  rule->id = *id;
  rule->name = *name;
  if (dict.Find("hosts")) {
    std::optional<std::vector<std::string>> hosts = Strings(dict, "hosts");
    if (!hosts) {
      return "hosts must be a list of strings";
    }
    for (const std::string& text : *hosts) {
      std::optional<HostPattern> host = ParseHost(text, false);
      if (!host) {
        return "\"" + text + "\" isn't a host";
      }
      rule->hosts.push_back(std::move(*host));
    }
  }
  if (dict.Find("urls")) {
    std::optional<std::vector<std::string>> urls = Strings(dict, "urls");
    if (!urls) {
      return "urls must be a list of strings";
    }
    for (const std::string& text : *urls) {
      std::optional<UrlPattern> pattern = ParseUrlPattern(text);
      if (!pattern) {
        return "\"" + text + "\" isn't a URL pattern";
      }
      rule->urls.push_back(std::move(*pattern));
    }
  }
  if (const std::string* regex = dict.FindString("regex")) {
    if (regex->empty() || regex->size() > kMaxPatternLength) {
      return "regex must be 1 to 1,024 characters";
    }
    re2::RE2::Options options;
    options.set_max_mem(kRegexMemory);
    options.set_log_errors(false);
    rule->regex = std::make_unique<re2::RE2>(*regex, options);
    if (!rule->regex->ok()) {
      return "regex: " + rule->regex->error();
    }
  }
  if (dict.Find("profiles")) {
    std::optional<std::vector<std::string>> profiles = Strings(dict, "profiles");
    if (!profiles) {
      return "profiles must be a list of strings";
    }
    rule->profiles.emplace(profiles->begin(), profiles->end());
  }
  const bool has_url_condition =
      !rule->hosts.empty() || !rule->urls.empty() || rule->regex;
  if (*action == "none") {
    rule->action = Action::kNone;
  } else if (*action == "block") {
    rule->action = Action::kBlock;
  } else if (*action == "rewrite") {
    rule->action = Action::kRewrite;
    const std::string* text = dict.FindString("template");
    if (!text) {
      return "rewrite needs a template";
    }
    const bool regex_only =
        rule->regex && rule->hosts.empty() && rule->urls.empty();
    const int captures =
        regex_only ? std::min<int>(rule->regex->NumberOfCapturingGroups(),
                                   kMaxCaptures)
                   : 0;
    if (std::optional<std::string> problem =
            ParseTemplate(*text, captures, &rule->rewrite)) {
      return "rewrite " + *problem;
    }
  } else if (*action == "stripParams") {
    rule->action = Action::kStripParams;
    std::optional<std::vector<std::string>> params = Strings(dict, "params");
    if (!params || params->empty()) {
      return "stripParams must list parameter names";
    }
    rule->params = std::move(*params);
  } else if (*action == "https") {
    rule->action = Action::kHttps;
  } else if (*action == "fileInto") {
    rule->action = Action::kFileInto;
    const std::string* root = dict.FindString("root");
    std::optional<uint64_t> dev = Number(dict, "rootDev");
    std::optional<uint64_t> ino = Number(dict, "rootIno");
    if (!root || root->empty() || root->front() != '/' || !dev || !ino) {
      return "fileInto needs root, rootDev and rootIno";
    }
    rule->folder.root = *root;
    rule->folder.root_dev = *dev;
    rule->folder.root_ino = *ino;
    if (dict.Find("below")) {
      std::optional<std::vector<std::string>> below = Strings(dict, "below");
      if (!below) {
        return "below must be a list of folder names";
      }
      for (const std::string& part : *below) {
        if (part == "." || part == ".." ||
            part.find('/') != std::string::npos ||
            part.find('\0') != std::string::npos) {
          return "below must be plain folder names";
        }
      }
      rule->folder.below = std::move(*below);
    }
  } else {
    return "unknown action " + *action;
  }
  if (rule->action != Action::kNone && rule->action != Action::kFileInto &&
      !has_url_condition) {
    return "needs hosts, urls or regex";
  }
  return std::nullopt;
}

void ReplyWith(ac_engine_reply_t reply,
               void* context,
               const base::DictValue& result) {
  if (reply) {
    reply(context, base::WriteJson(result).value_or("{}").c_str());
  }
}

}

void AddUserHooksThrottle(content::NavigationThrottleRegistry& registry) {
  content::NavigationHandle& handle = registry.GetNavigationHandle();
  content::WebContents* contents = handle.GetWebContents();
  if (!g_configured || !contents || handle.IsSameDocument() ||
      contents->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  registry.AddThrottle(std::make_unique<UserHooksThrottle>(registry));
}

std::unique_ptr<blink::URLLoaderThrottle> TakeUserHooksRewrite(
    std::optional<int64_t> navigation_id) {
  if (!navigation_id) {
    return nullptr;
  }
  auto found = PendingRewrites().find(*navigation_id);
  if (found == PendingRewrites().end()) {
    return nullptr;
  }
  GURL target = std::move(found->second);
  PendingRewrites().erase(found);
  return std::make_unique<RewriteLoaderThrottle>(std::move(target));
}

std::optional<GURL> PendingUserHooksRewrite(content::NavigationHandle& handle) {
  auto found = PendingRewrites().find(handle.GetNavigationId());
  if (found == PendingRewrites().end()) {
    return std::nullopt;
  }
  return found->second;
}

}

extern "C" AC_ENGINE_EXPORT int ac_hooks_configure_v1(const char* json,
                                                      ac_engine_reply_t reply,
                                                      void* context) {
  if (!pthread_main_np()) {
    solara::ReplyWith(reply, context,
                      base::DictValue().Set("error", "call on the main thread"));
    return 0;
  }
  std::optional<base::Value> parsed =
      base::JSONReader::Read(json ? json : "", base::JSON_PARSE_RFC);
  const base::DictValue* root = parsed ? parsed->GetIfDict() : nullptr;
  const base::ListValue* list = root ? root->FindList("rules") : nullptr;
  if (!list || list->size() > solara::kMaxRules) {
    if (solara::g_pending || !solara::Waiting().empty()) {
      solara::HoldTimedOut();
    }
    solara::ReplyWith(reply, context,
                      base::DictValue()
                          .Set("error", "bad hooks configuration")
                          .Set("late", solara::LateCount()));
    return 0;
  }
  std::vector<std::unique_ptr<solara::Rule>> rules;
  base::ListValue problems;
  for (const base::Value& value : *list) {
    const base::DictValue* dict = value.GetIfDict();
    auto rule = std::make_unique<solara::Rule>();
    std::optional<std::string> problem =
        dict ? solara::ParseRule(*dict, rule.get())
             : std::optional<std::string>("each rule must be an object");
    if (problem) {
      problems.Append(base::DictValue()
                          .Set("id", rule->id)
                          .Set("rule", rule->name)
                          .Set("problem", *problem));
      continue;
    }
    rule->config = base::WriteJson(*dict).value_or(rule->id);
    rules.push_back(std::move(rule));
  }
  if (root->FindBool("pending").value_or(false)) {
    if (!solara::g_configured) {
      solara::g_pending = true;
      solara::g_configured = true;
    }
    solara::ReplyWith(reply, context,
                      base::DictValue().Set("ok", true).Set("pending", true));
    return 1;
  }
  const std::string before = solara::NavigationFingerprint();
  solara::Rules() = std::move(rules);
  g_solara_download_folder =
      solara::HasDownloadRules() ? &solara::DownloadFolder : nullptr;
  if (solara::g_configured && g_browser_process &&
      before != solara::NavigationFingerprint()) {
    solara::DropKeptPages();
  }
  solara::g_configured = true;
  solara::g_hold_timed_out = false;
  if (solara::g_pending || !solara::Waiting().empty()) {
    solara::ReleaseWaiting();
  }
  solara::ReplyWith(
      reply, context,
      base::DictValue()
          .Set("ok", true)
          .Set("rules", static_cast<int>(solara::Rules().size()))
          .Set("late", solara::LateCount())
          .Set("problems", std::move(problems)));
  return 1;
}

extern "C" AC_ENGINE_EXPORT int ac_hooks_match_v1(const char* url,
                                                  ac_engine_reply_t reply,
                                                  void* context) {
  if (!pthread_main_np()) {
    solara::ReplyWith(reply, context,
                      base::DictValue().Set("error", "call on the main thread"));
    return 0;
  }
  const GURL matching = solara::MatchingURL(GURL(url ? url : ""));
  if (!matching.is_valid()) {
    solara::ReplyWith(reply, context,
                      base::DictValue().Set("error", "not an http(s) URL"));
    return 0;
  }
  base::ListValue matched;
  base::ListValue failed;
  for (const auto& rule : solara::Rules()) {
    solara::Matched result = solara::MatchRule(*rule, matching);
    if (result.failed) {
      failed.Append(rule->id);
    } else if (result.matched) {
      matched.Append(rule->id);
    }
  }
  solara::ReplyWith(reply, context,
                    base::DictValue()
                        .Set("matched", std::move(matched))
                        .Set("failed", std::move(failed))
                        .Set("host", std::string(matching.host())));
  return 1;
}
