#include "chrome/browser/solara/ac_notifications.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <deque>
#include <initializer_list>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#include "base/base64.h"
#include "base/check.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/hash/sha1.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/ref_counted_memory.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/notifications/notification_display_service_impl.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/common/notifications/notification_operation.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/notification_database_data.h"
#include "content/public/browser/platform_notification_context.h"
#include "content/public/browser/storage_partition.h"
#include "ui/gfx/image/image.h"
#include "ui/message_center/public/cpp/notification.h"
#include "ui/message_center/public/cpp/notification_delegate.h"

namespace solara {
namespace {

constexpr size_t kMaxJSON = 1024 * 1024;
constexpr size_t kMaxCoverage = 64 * 1024;
constexpr size_t kMaxRoutes = 4096;
constexpr size_t kMaxScopes = 4096;
constexpr size_t kMaxJournal = 8192;
constexpr size_t kMaxActions = 8192;
constexpr size_t kMaxControls = 32768;
constexpr size_t kMaxImage = 128 * 1024;
constexpr size_t kMaxResources = 16 * 1024 * 1024;
constexpr size_t kMaxStateBytes = 6 * 1024 * 1024;
constexpr size_t kMaxQueuedBytes = 32 * 1024 * 1024;
constexpr size_t kMaxSnapshotBytes = 24 * 1024 * 1024;
constexpr size_t kMaxResource = 512 * 1024;
constexpr base::TimeDelta kDeadline = base::Seconds(5);

std::atomic<uint64_t> g_alert_attempts{0};
std::atomic<uint64_t> g_banner_attempts{0};
std::atomic<uint64_t> g_shim_attempts{0};
std::atomic<bool> g_started{false};
std::atomic<bool> g_hooks_installed{false};
std::atomic<uint64_t> g_provider_binds{0};
const int kReleasedProfileKey = 0;
class ReleasedProfileMarker final : public base::SupportsUserData::Data {};
std::mutex g_coverage_lock;
std::string g_coverage_nonce;
uint64_t g_coverage_ordinal = 0;
bool g_coverage_initialized = false;
size_t g_coverage_bytes = 0;
uint64_t g_coverage_dropped = 0;
std::deque<base::DictValue> g_coverage_events;
std::map<std::string, base::DictValue> g_coverage_checkpoints;
std::mutex g_native_runner_lock;
scoped_refptr<base::SequencedTaskRunner> g_native_runner;
ac_notifications_control_t g_control = nullptr;
ac_engine_event_t g_event = nullptr;
void* g_transport_context = nullptr;
ac_notifications_context_lifetime_t g_transport_release = nullptr;
ac_notifications_context_lifetime_t g_transport_retire = nullptr;

class NotificationReply {
 public:
  NotificationReply(ac_engine_reply_t callback, void* context,
                    ac_notifications_context_lifetime_t retain,
                    ac_notifications_context_lifetime_t release)
      : callback_(callback), context_(context), release_(release) {
    CHECK(callback && retain && release);
    retain(context);
  }
  NotificationReply(NotificationReply&& other)
      : callback_(std::exchange(other.callback_, nullptr)),
        context_(std::exchange(other.context_, nullptr)),
        release_(std::exchange(other.release_, nullptr)) {}
  ~NotificationReply() {
    if (callback_) Send(base::DictValue().Set("ok", false).Set("error", "closed"));
  }
  void Send(base::DictValue value) {
    if (!callback_) return;
    auto callback = std::exchange(callback_, nullptr);
    auto release = std::exchange(release_, nullptr);
    void* context = std::exchange(context_, nullptr);
    callback(context, base::WriteJson(value).value_or("{}").c_str());
    release(context);
  }
  void Ok() { Send(base::DictValue().Set("ok", true)); }
 private:
  ac_engine_reply_t callback_;
  void* context_;
  ac_notifications_context_lifetime_t release_;
};

std::string Token() { return base::UnguessableToken::Create().ToString(); }
std::string Number(uint64_t value) { return base::NumberToString(value); }
void Coverage(std::string_view kind, base::DictValue fields = {}) {
  std::lock_guard<std::mutex> guard(g_coverage_lock);
  fields.Set("kind", kind);
  fields.Set("phase", "engine");
  fields.Set("pid", static_cast<int>(getpid()));
  fields.Set("runNonce", g_coverage_nonce);
  fields.Set("ordinal", base::NumberToString(++g_coverage_ordinal));
  fields.Set("timestamp", base::Time::Now().InMillisecondsFSinceUnixEpoch());
  fields.Set("alertLaunch", base::NumberToString(g_alert_attempts.load()));
  fields.Set("bannerBind", base::NumberToString(g_banner_attempts.load()));
  fields.Set("providerBind", base::NumberToString(g_provider_binds.load()));
  fields.Set("appShimBind", base::NumberToString(g_shim_attempts.load()));
  if (kind != "provider-attempt") {
    g_coverage_checkpoints.insert_or_assign(std::string(kind), std::move(fields));
    return;
  }
  g_coverage_bytes += base::WriteJson(fields).value_or("{}").size();
  g_coverage_events.push_back(std::move(fields));
  while (g_coverage_events.size() > 64 || g_coverage_bytes > kMaxCoverage) {
    g_coverage_bytes -= base::WriteJson(g_coverage_events.front()).value_or("{}").size();
    g_coverage_events.pop_front();
    ++g_coverage_dropped;
  }
}
base::DictValue CoverageSnapshot() {
  std::lock_guard<std::mutex> guard(g_coverage_lock);
  base::ListValue events;
  for (const auto& event : g_coverage_events) events.Append(event.Clone());
  base::DictValue checkpoints;
  bool complete = g_coverage_dropped == 0;
  for (const auto& [kind, record] : g_coverage_checkpoints) {
    checkpoints.Set(kind, record.Clone());
    complete &= !record.FindBool("truncated").value_or(false);
  }
  return base::DictValue().Set("initialized", g_coverage_initialized)
      .Set("ordinal", base::NumberToString(g_coverage_ordinal))
      .Set("dropped", base::NumberToString(g_coverage_dropped))
      .Set("complete", complete)
      .Set("checkpoints", std::move(checkpoints)).Set("events", std::move(events));
}
std::string JSON(const base::DictValue& value) {
  return base::WriteJson(value).value_or("{}");
}
std::string Hash(std::string_view value) {
  return base::HexEncode(base::SHA1HashString(value));
}
std::string String(const base::DictValue& value, std::string_view key) {
  const auto* found = value.FindString(key);
  return found ? *found : std::string();
}
bool Allowed(std::string_view key,
             std::initializer_list<std::string_view> allowed) {
  return std::find(allowed.begin(), allowed.end(), key) != allowed.end();
}
bool Keys(const base::DictValue& value,
          std::initializer_list<std::string_view> allowed) {
  for (const auto item : value) if (!Allowed(item.first, allowed)) return false;
  return true;
}
bool RouteKeys(const base::DictValue& value,
               std::initializer_list<std::string_view> extra) {
  for (const auto item : value)
    if (!Allowed(item.first, {"op", "B", "W", "scope", "lifetime", "root", "profile",
        "incarnation", "session", "token", "creation", "generation", "nativeID"}) &&
        !Allowed(item.first, extra)) return false;
  return true;
}
bool Text(const base::DictValue& value, std::string_view key, size_t max = 256) {
  const auto* found = value.FindString(key);
  return found && !found->empty() && found->size() <= max;
}
std::optional<uint64_t> Integer(const base::DictValue& value,
                              std::string_view key) {
  uint64_t result;
  const auto* found = value.FindString(key);
  if (!found || !base::StringToUint64(*found, &result) ||
      Number(result) != *found) return std::nullopt;
  return result;
}
std::optional<base::DictValue> Parse(const char* json) {
  if (!json) return std::nullopt;
  const std::string_view input(json);
  if (input.size() > kMaxJSON) return std::nullopt;
  return base::JSONReader::ReadDict(input, base::JSON_PARSE_RFC);
}
base::DictValue Rejected(std::string_view reason) {
  return base::DictValue().Set("ok", false).Set("error", reason);
}
const char* Reason(NotificationReleaseReason reason) {
  switch (reason) {
    case NotificationReleaseReason::kProfileUnload: return "profileUnload";
    case NotificationReleaseReason::kPrivateEnd: return "privateEnd";
    case NotificationReleaseReason::kSystemShutdown: return "systemShutdown";
    case NotificationReleaseReason::kProfileDelete: return "profileDelete";
    case NotificationReleaseReason::kBrowserShutdown: return "browserShutdown";
  }
}
int Strength(NotificationReleaseReason reason) {
  switch (reason) {
    case NotificationReleaseReason::kProfileUnload: return 0;
    case NotificationReleaseReason::kBrowserShutdown: return 1;
    case NotificationReleaseReason::kSystemShutdown: return 2;
    case NotificationReleaseReason::kPrivateEnd: return 3;
    case NotificationReleaseReason::kProfileDelete: return 4;
  }
}
ProfileManager* Manager() {
  return g_browser_process ? g_browser_process->profile_manager() : nullptr;
}
bool Registered(const base::FilePath& path) {
  auto* manager = Manager();
  return manager && manager->GetProfileAttributesStorage()
                        .GetProfileAttributesWithPath(path);
}
struct DirectoryIdentity {
  base::FilePath path;
  uint64_t device = 0;
  uint64_t inode = 0;
  bool operator==(const DirectoryIdentity&) const = default;
};
std::optional<DirectoryIdentity> Identify(const base::FilePath& path) {
  const auto canonical = base::MakeAbsoluteFilePath(path);
  struct stat info;
  if (canonical.empty() || stat(canonical.value().c_str(), &info) ||
      !S_ISDIR(info.st_mode)) return std::nullopt;
  return DirectoryIdentity{canonical, static_cast<uint64_t>(info.st_dev),
                           static_cast<uint64_t>(info.st_ino)};
}
struct ProfileIdentity {
  DirectoryIdentity directory;
  std::string incarnation = Token();
};

struct Scope : public ProfileObserver {
  std::string id = Token();
  std::string lifetime = Token();
  std::string root;
  std::string incarnation;
  std::string session;
  base::FilePath path;
  raw_ptr<Profile> profile = nullptr;
  bool process = false;
  bool active = true;
  bool validated = false;
  bool settled = false;
  uint64_t mutation = 0;
  uint64_t release_serial = 0;
  size_t state_bytes = 0;
  std::optional<NotificationReleaseReason> reason;
  base::OnceClosure destruction;
  ~Scope() override {
    if (profile) profile->RemoveObserver(this);
  }
  void OnProfileWillBeDestroyed(Profile*) override {
    if (destruction) std::move(destruction).Run();
  }
  base::DictValue Envelope() const {
    return base::DictValue().Set("scope", id).Set("lifetime", lifetime)
        .Set("root", root).Set("profile", path.value())
        .Set("incarnation", incarnation).Set("session", session)
        .Set("process", process);
  }
};
struct Route {
  std::string token = Token();
  uint64_t generation = 1;
  uint64_t mutation = 0;
  uint64_t restore_serial = 0;
  std::string native;
  std::string key;
  std::string scope;
  std::string chromium_id;
  GURL origin;
  NotificationHandler::Type type = NotificationHandler::Type::TRANSIENT;
  scoped_refptr<message_center::NotificationDelegate> delegate;
  bool authorization_eligible = false;
  bool withdrawn = false;
  bool accepted = false;
  bool removed = false;
  bool dormant = false;
  bool database_validated = false;
  std::string acceptance;
  base::DictValue resources;
  size_t resource_bytes = 0;
  size_t state_bytes = 0;
};
struct Query {
  std::string id = Token();
  std::string scope;
  std::string watch;
  uint64_t mutation = 0;
  uint64_t native = 0;
  std::optional<GURL> origin;
  GetDisplayedNotificationsCallback callback;
};
struct NativeOperation {
  std::string scope;
  size_t bytes = 0;
  base::OnceCallback<void(base::DictValue)> callback;
};

enum class Consumer { kNoConsumer, kBootstrapping, kReplaying, kLive,
                      kDraining, kClosed };
const char* State(Consumer state) {
  switch (state) {
    case Consumer::kNoConsumer: return "NoConsumer";
    case Consumer::kBootstrapping: return "Bootstrapping";
    case Consumer::kReplaying: return "Replaying";
    case Consumer::kLive: return "Live";
    case Consumer::kDraining: return "Draining";
    case Consumer::kClosed: return "Closed";
  }
}

class Coordinator {
 public:
  static Coordinator& Get() {
    static base::NoDestructor<Coordinator> value;
    return *value;
  }
  Coordinator() = default;

  bool Closed() const {
    return consumer_ == Consumer::kDraining || consumer_ == Consumer::kClosed;
  }
  Scope* ForProfile(Profile* profile) {
    auto found = loaded_.find(profile);
    return found == loaded_.end() ? nullptr : FindScope(found->second);
  }
  Scope* FindScope(std::string_view id) {
    auto found = scopes_.find(std::string(id));
    return found == scopes_.end() ? nullptr : found->second.get();
  }
  Route* FindRoute(std::string_view token, uint64_t generation) {
    auto found = routes_.find(std::string(token) + "." + Number(generation));
    return found == routes_.end() ? nullptr : found->second.get();
  }
  std::string RouteID(const Route& route) const {
    return route.token + "." + Number(route.generation);
  }
  bool Current(const Route& route) {
    auto* scope = FindScope(route.scope);
    return !Closed() && !route.withdrawn && scope &&
        ((scope->active && scope->validated) ||
         (route.dormant && scope->settled &&
          scope->reason == NotificationReleaseReason::kProfileUnload));
  }
  void Attach() {
    CHECK(g_control && g_event);
    g_started.store(true);
    attached_++;
    if (!process_registered_) Register(nullptr);
  }
  void Detach() {
    CHECK_GT(attached_, 0);
    attached_--;
    CHECK(queries_.empty());
    CHECK(deferred_queries_.empty());
  }
  void Register(Profile* profile) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (Closed() || (!profile && process_registered_) || (profile && (profile->ShutdownStarted() ||
        profile->GetUserData(&kReleasedProfileKey) ||
        profile->GetOriginalProfile()->ShutdownStarted() ||
        profile->GetOriginalProfile()->GetUserData(&kReleasedProfileKey)))) return;
    if (profile) {
      auto* original = profile->GetOriginalProfile();
      const auto directory = Identify(original->GetPath());
      if (admitted_deletions_.contains(original->GetPath()) ||
          (directory && admitted_deletions_.contains(directory->path))) return;
      const auto pending = pending_loads_.find(original->GetPath());
      if (pending != pending_loads_.end()) {
        const auto identity = identities_.find(pending->first);
        if (!directory || deleted_paths_.contains(pending->first) ||
            identity == identities_.end() || identity->second.incarnation != pending->second ||
            identity->second.directory != *directory) {
          original->SetUserData(&kReleasedProfileKey,
                                std::make_unique<ReleasedProfileMarker>());
          for (auto* private_profile : original->GetAllOffTheRecordProfiles())
            private_profile->SetUserData(&kReleasedProfileKey,
                                        std::make_unique<ReleasedProfileMarker>());
          return;
        }
      }
    }
    if (ForProfile(profile)) return;
    const auto root = Manager() ? Identify(Manager()->user_data_dir()) : std::nullopt;
    if (!root || !ReserveScope()) return;
    root_namespace_ = Hash(root->path.value());
    auto scope = std::make_unique<Scope>();
    scope->process = !profile;
    if (profile) {
      const auto identity = Identify(profile->GetOriginalProfile()->GetPath());
      const auto root = Manager() ? Identify(Manager()->user_data_dir()) : std::nullopt;
      if (!identity || !root || identity->path.DirName() != root->path ||
          IsProfileDirectoryMarkedForDeletion(identity->path)) return;
      deleted_paths_.erase(identity->path);
      auto found = identities_.find(identity->path);
      if (found != identities_.end() && found->second.directory != *identity) {
        std::vector<std::string> obsolete;
        for (const auto& [id, old] : scopes_)
          if (old->path == identity->path) obsolete.push_back(id);
        for (const auto& id : obsolete) ReleaseID(id, NotificationReleaseReason::kProfileDelete);
        identities_.erase(found);
        deleted_paths_.erase(identity->path);
      }
      auto entry = identities_.try_emplace(identity->path, ProfileIdentity{*identity}).first;
      scope->path = identity->path;
      scope->root = Hash(root->path.value());
      scope->incarnation = entry->second.incarnation;
      scope->validated = true;
      if (profile->IsOffTheRecord()) scope->session = Token();
      scope->profile = profile;
      profile->AddObserver(scope.get());
      scope->destruction = base::BindOnce(&Coordinator::ReleaseID,
          weak_.GetWeakPtr(), scope->id,
          profile->IsOffTheRecord() ? NotificationReleaseReason::kPrivateEnd
                                   : NotificationReleaseReason::kProfileUnload);
    } else {
      scope->root = root_namespace_;
      scope->incarnation = bridge_;
      scope->validated = true;
    }
    scope->state_bytes = JSON(scope->Envelope()).size() + 512;
    if (state_bytes_ + scope->state_bytes > kMaxStateBytes) return;
    state_bytes_ += scope->state_bytes;
    const std::string id = scope->id;
    loaded_[profile] = id;
    scopes_[id] = std::move(scope);
    if (!profile) {
      process_registered_ = true;
      Activate(*FindScope(id));
      return;
    }
    Activate(*FindScope(id));
    if (!profile->IsOffTheRecord()) RebindDormant(id);
  }
  void Activate(Scope& scope) {
    auto value = scope.Envelope();
    value.Set("kind", "state");
    value.Set("state", "Active");
    scope.mutation = Mutate(std::move(value));
    Native("activate", scope.Envelope(), {});
  }
  base::DictValue Entry(const Route& route, bool resources = false) {
    auto* scope = FindScope(route.scope);
    CHECK(scope);
    auto value = scope->Envelope();
    value.Set("token", route.token);
    value.Set("creation", bridge_);
    value.Set("generation", Number(route.generation));
    value.Set("nativeID", route.native);
    value.Set("chromiumID", route.chromium_id);
    value.Set("origin", route.origin.spec());
    value.Set("handlerType", static_cast<int>(route.type));
    value.Set("authorizationEligible", route.authorization_eligible);
    value.Set("withdrawn", route.withdrawn);
    value.Set("accepted", route.accepted);
    value.Set("removed", route.removed);
    value.Set("dormant", route.dormant);
    value.Set("receipt", route.acceptance);
    if (resources && !route.withdrawn) value.Set("resources", route.resources.Clone());
    return value;
  }
  void AddImage(base::DictValue& value, const char* key, const gfx::Image& image) {
    if (image.IsEmpty() || image.Width() > 4096 || image.Height() > 4096) return;
    const auto png = image.As1xPNGBytes();
    if (!png || !png->size() || png->size() > kMaxImage) return;
    value.Set(key, base::Base64Encode(std::string_view(
        reinterpret_cast<const char*>(png->data()), png->size())));
  }
  base::DictValue Resources(const message_center::Notification& n,
                            NotificationHandler::Type type,
                            const NotificationCommon::Metadata* metadata) {
    auto value = base::DictValue().Set("title", base::UTF16ToUTF8(n.title()))
        .Set("body", base::UTF16ToUTF8(n.message())).Set("silent", n.silent())
        .Set("renotify", n.renotify()).Set("requireInteraction", n.never_timeout())
        .Set("timestamp", n.timestamp().InMillisecondsFSinceUnixEpoch());
    AddImage(value, "image", n.image());
    AddImage(value, "badge", n.small_image());
    if (n.icon().IsImage()) AddImage(value, "icon", n.icon().GetImage());
    if (type == NotificationHandler::Type::WEB_PERSISTENT)
      if (const auto* meta = PersistentNotificationMetadata::From(metadata))
        value.Set("workerScope", meta->service_worker_scope.spec());
    return value;
  }
  void Display(NotificationHandler::Type type, Profile* profile,
               const message_center::Notification& notification,
               std::unique_ptr<NotificationCommon::Metadata> metadata) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (Closed() || notification.id().size() > 4096 ||
        notification.title().size() > 16384 || notification.message().size() > 65536 ||
        notification.origin_url().spec().size() > 4096) return;
    auto* scope = ForProfile(profile);
    if (!scope || !scope->active) return;
    if (!scope->validated) return;
    const std::string key = scope->root + "|" + scope->incarnation + "|" +
        scope->session + "|" + (scope->process ? bridge_ : scope->path.value()) +
        "|" + notification.id();
    auto route = std::make_unique<Route>();
    Compact();
    if (routes_.size() >= kMaxRoutes ||
        (!watch_.empty() &&
         mutation_ - std::max(applied_, watch_base_) >= kMaxJournal - 4) ||
        native_ops_.size() >= kMaxControls - 6) {
      LoseConsumer(true, "routeOverflow");
      return;
    }
    auto resources = Resources(notification, type, metadata.get());
    const size_t bytes = JSON(resources).size();
    if (bytes > kMaxResource || resource_bytes_ + bytes > kMaxResources ||
        queued_bytes_ + 2 * bytes + 65536 > kMaxQueuedBytes ||
        native_bytes_ + 2 * bytes + 131072 > kMaxQueuedBytes) return;
    const size_t state_bytes = scope->path.value().size() * 2 +
        notification.id().size() + notification.origin_url().spec().size() + 2048;
    if (state_bytes_ + state_bytes > kMaxStateBytes) return;
    auto previous = current_.find(key);
    if (previous != current_.end()) {
      auto old = routes_.find(previous->second);
      if (old != routes_.end()) {
        route->token = old->second->token;
        route->generation = old->second->generation + 1;
        Withdraw(*old->second, "replacement");
      }
    }
    if (Closed() || !scope->active || !scope->validated) return;
    route->scope = scope->id;
    route->chromium_id = notification.id();
    route->origin = notification.origin_url();
    route->type = type;
    if (profile && !scope->process && notification.origin_url().SchemeIsHTTPOrHTTPS() &&
        (type == NotificationHandler::Type::WEB_PERSISTENT ||
         type == NotificationHandler::Type::WEB_NON_PERSISTENT)) {
      auto* settings = HostContentSettingsMapFactory::GetForProfile(profile);
      route->authorization_eligible = settings &&
          settings->GetContentSetting(notification.origin_url(), notification.origin_url(),
              ContentSettingsType::NOTIFICATIONS) == CONTENT_SETTING_ALLOW;
    }
    route->key = key;
    if (type != NotificationHandler::Type::WEB_PERSISTENT &&
        type != NotificationHandler::Type::WEB_NON_PERSISTENT &&
        type != NotificationHandler::Type::EXTENSION)
      route->delegate = notification.delegate();
    route->database_validated = true;
    route->resources = std::move(resources);
    route->resource_bytes = bytes;
    route->state_bytes = state_bytes;
    resource_bytes_ += bytes;
    state_bytes_ += state_bytes;
    route->native = "solara.n2." + scope->root + "." + bridge_ + "." +
        route->token + "." + Number(route->generation);
    const std::string id = RouteID(*route);
    current_[key] = id;
    routes_[id] = std::move(route);
    auto& stored = *routes_[id];
    auto value = Entry(stored);
    value.Set("kind", "state");
    value.Set("state", "Staged");
    stored.mutation = Mutate(std::move(value));
    Own(stored);
  }
  void Own(Route& route) {
    if (!Current(route)) return;
    auto value = Entry(route, true);
    Native("own", std::move(value), {});
    auto display = Entry(route, true);
    display.Set("kind", "display");
    route.mutation = Mutate(std::move(display));
  }
  void Close(Profile* profile, const std::string& id) {
    auto* scope = ForProfile(profile);
    if (!scope) return;
    std::vector<std::string> matches;
    for (const auto& [key, route] : routes_) {
      if (route->scope == scope->id && route->chromium_id == id &&
          !route->withdrawn) matches.push_back(key);
    }
    for (const auto& key : matches) {
      auto& route = *routes_[key];
      auto delegate = route.delegate;
      Withdraw(route, "programmaticClose");
      if (delegate) delegate->Close(false);
    }
  }
  void StateRoute(Route& route) {
    auto value = Entry(route);
    value.Set("kind", "state");
    route.mutation = Mutate(std::move(value));
  }
  void Withdraw(Route& route, std::string_view reason) {
    if (route.withdrawn) return;
    route.withdrawn = true;
    route.dormant = false;
    auto immediate = Entry(route);
    immediate.Set("reason", reason);
    Native("fenceGeneration", std::move(immediate), {});
    auto value = Entry(route);
    value.Set("kind", "close");
    value.Set("reason", reason);
    route.mutation = Mutate(std::move(value));
    route.delegate.reset();
    resource_bytes_ -= route.resource_bytes;
    route.resource_bytes = 0;
    route.resources.clear();
    Remove(route);
  }
  void Remove(Route& route) {
    Native("remove", Entry(route),
        base::BindOnce(&Coordinator::RemovalCompleted, weak_.GetWeakPtr(), RouteID(route)));
  }
  void RemovalCompleted(std::string id, base::DictValue answer) {
    auto found = routes_.find(id);
    if (found == routes_.end()) return;
    if (answer.FindBool("settled").value_or(false) && !found->second->removed) {
      found->second->removed = true;
      StateRoute(*found->second);
      Compact();
    }
    MaybeFinishDrain();
  }
  void Compact() {
    for (auto it = routes_.begin(); it != routes_.end();) {
      auto& route = *it->second;
      if (route.withdrawn && route.removed && applied_ >= route.mutation) {
        auto current = current_.find(route.key);
        if (current != current_.end() && current->second == it->first) current_.erase(current);
        state_bytes_ -= route.state_bytes;
        it = routes_.erase(it);
      } else ++it;
    }
    CompactScopes();
  }
  bool ScopeReferenced(const std::string& id) const {
    for (const auto& [profile, scope] : loaded_) if (scope == id) return true;
    for (const auto& [key, route] : routes_) if (route->scope == id) return true;
    for (const auto& [key, query] : queries_) if (query.scope == id) return true;
    for (const auto& query : deferred_queries_) if (query.scope == id) return true;
    for (const auto& [key, operation] : native_ops_)
      if (operation.scope == id) return true;
    for (const auto& [key, action] : actions_)
      if (String(action->args, "scope") == id) return true;
    return false;
  }
  void CompactScopes() {
    if (consumer_ != Consumer::kLive || watch_.empty()) return;
    for (auto it = scopes_.begin(); it != scopes_.end();) {
      const auto& scope = *it->second;
      if (!scope.active && scope.reason && scope.settled && !scope.profile &&
          applied_ >= scope.mutation &&
          !ScopeReferenced(it->first)) {
        state_bytes_ -= scope.state_bytes;
        it = scopes_.erase(it);
      } else ++it;
    }
    for (auto it = identities_.begin(); it != identities_.end();) {
      bool pinned = pending_loads_.contains(it->first);
      for (const auto& [id, scope] : scopes_) pinned |= scope->path == it->first;
      if (!pinned) it = identities_.erase(it); else ++it;
    }
    if (scopes_.size() < kMaxScopes) scope_pressure_ = false;
  }
  bool ReserveScope() {
    CompactScopes();
    if (scopes_.size() < kMaxScopes) return true;
    if (!scope_pressure_) {
      scope_pressure_ = true;
      LoseConsumer(true, "scopeOverflow");
    }
    return false;
  }
  void RetryLoadedRegistrations() {
    auto* manager = Manager();
    if (!manager || Closed()) return;
    for (auto* profile : manager->GetLoadedProfiles()) {
      Register(profile);
      for (auto* private_profile : profile->GetAllOffTheRecordProfiles())
        Register(private_profile);
    }
  }
  void RebindDormant(const std::string& id) {
    auto* scope = FindScope(id);
    if (!scope || !scope->active || !scope->validated) return;
    std::vector<std::string> candidates;
    for (auto& [route_id, route] : routes_) {
      auto* old = FindScope(route->scope);
      if (route->dormant && old && old->root == scope->root &&
          old->path == scope->path && old->incarnation == scope->incarnation &&
          old->settled && old->reason == NotificationReleaseReason::kProfileUnload)
        candidates.push_back(route_id);
    }
    for (const auto& route_id : candidates) {
      auto& route = *routes_[route_id];
      route.scope = id;
      ++route.restore_serial;
      route.dormant = false;
      route.database_validated = false;
      StateRoute(route);
      Native("rebind", Entry(route), {});
      ValidateDatabase(route_id);
    }
  }
  void ValidateDatabase(const std::string& id) {
    auto found = routes_.find(id);
    if (found == routes_.end()) return;
    auto& route = *found->second;
    auto* scope = FindScope(route.scope);
    if (!scope || !scope->active || !scope->profile ||
        !scope->session.empty() || !IdentityMatches(scope->path, scope->incarnation)) {
      Withdraw(route, "databaseOwnerMissing");
      return;
    }
    auto* partition = scope->profile->GetStoragePartitionForUrl(route.origin);
    auto* context = partition ? partition->GetPlatformNotificationContext() : nullptr;
    if (!context) {
      Withdraw(route, "databaseUnavailable");
      return;
    }
    const uint64_t mutation = route.mutation;
    const std::string scope_id = scope->id;
    bootstrap_++;
    context->ReadNotificationDataAndRecordInteraction(route.chromium_id,
        route.origin, content::PlatformNotificationContext::Interaction::NONE,
        base::BindOnce(&Coordinator::DatabaseValidated, weak_.GetWeakPtr(),
                       id, scope_id, mutation));
  }
  base::ScopedClosureRunner BootstrapCompletion() {
    CHECK_GT(bootstrap_, 0u);
    bootstrap_--;
    return base::ScopedClosureRunner(base::BindOnce(
        &Coordinator::MaybeFinishDrain, weak_.GetWeakPtr()));
  }
  void DatabaseValidated(std::string id, std::string scope_id,
                         uint64_t mutation, bool success,
                         const content::NotificationDatabaseData& data) {
    auto completion = BootstrapCompletion();
    auto found = routes_.find(id);
    if (found == routes_.end()) {
      MaybeReplay();
      return;
    }
    auto& route = *found->second;
    auto* scope = FindScope(scope_id);
    if (route.mutation != mutation || route.scope != scope_id ||
        !scope || !scope->active || Closed() || route.withdrawn) {
      MaybeReplay();
      return;
    }
    if (!success || !IdentityMatches(scope->path, scope->incarnation) || !scope->profile ||
        data.notification_id != route.chromium_id || data.origin != route.origin ||
        data.service_worker_registration_id < 0) {
      Withdraw(route, "databaseValidationFailed");
    } else {
      route.database_validated = true;
      StateRoute(route);
      auto entry = Entry(route);
      entry.Set("adoptOnly", true);
      bootstrap_++;
      Native("restore", std::move(entry),
          base::BindOnce(&Coordinator::RestorationCompleted, weak_.GetWeakPtr(),
                         id, route.scope, route.mutation, ++route.restore_serial));
    }
    MaybeReplay();
    ResumeActions(id);
  }
  void RestorationCompleted(std::string id, std::string scope, uint64_t mutation,
                             uint64_t serial, base::DictValue answer) {
    auto completion = BootstrapCompletion();
    auto found = routes_.find(id);
    if (found == routes_.end() || !Current(*found->second) ||
        found->second->scope != scope || found->second->mutation != mutation ||
        found->second->restore_serial != serial) { MaybeReplay(); return; }
    auto& route = *found->second;
    const bool owned = answer.FindBool("settled").value_or(false) &&
        String(answer, "nativeID") == route.native &&
        Integer(answer, "generation") == route.generation;
    if (owned && answer.FindBool("accepted").value_or(false) &&
        Text(answer, "receipt") && Integer(answer, "N")) {
      route.accepted = true;
      route.acceptance = String(answer, "receipt");
      native_revision_ = std::max(native_revision_, *Integer(answer, "N"));
      StateRoute(route);
    } else {
      Withdraw(route, "nativeRestoreAbsent");
      if (owned && answer.FindBool("removed").value_or(false)) {
        route.removed = true;
        StateRoute(route);
      }
    }
    MaybeReplay();
  }
  void LoadDormant(std::string id) {
    auto found = routes_.find(id);
    if (found == routes_.end()) return;
    auto* scope = FindScope(found->second->scope);
    if (!scope || !found->second->dormant || Closed() ||
        !scope->settled || scope->reason != NotificationReleaseReason::kProfileUnload) {
      FailActions(id, "profileUnavailable");
      return;
    }
    const auto identity = identities_.find(scope->path);
    const auto actual = Identify(scope->path);
    if (!Manager() || !Registered(scope->path) || deleted_paths_.contains(scope->path) ||
        identity == identities_.end() || !actual ||
        identity->second.directory != *actual ||
        identity->second.incarnation != scope->incarnation) {
      Withdraw(*found->second, "profileIdentityChanged");
      FailActions(id, "profileIdentityChanged");
      return;
    }
    const std::string key = scope->root + "|" + scope->incarnation;
    if (!loading_.insert(key).second) return;
    pending_loads_[scope->path] = scope->incarnation;
    bootstrap_++;
    Manager()->LoadProfileByPath(scope->path, false,
        base::BindOnce(&Coordinator::DormantProfileLoaded, weak_.GetWeakPtr(),
                       id, key, scope->path, scope->incarnation));
  }
  void DormantProfileLoaded(std::string id, std::string key,
                            base::FilePath path, std::string incarnation,
                            Profile* profile) {
    auto completion = BootstrapCompletion();
    loading_.erase(key);
    const auto pending = pending_loads_.find(path);
    if (pending != pending_loads_.end() && pending->second == incarnation)
      pending_loads_.erase(pending);
    auto found = routes_.find(id);
    auto* old = found == routes_.end() ? nullptr : FindScope(found->second->scope);
    if (old && !found->second->withdrawn && !IdentityMatches(path, incarnation)) {
      if (profile && !profile->IsOffTheRecord() && profile->GetPath() == path) {
        profile->SetUserData(&kReleasedProfileKey, std::make_unique<ReleasedProfileMarker>());
        for (auto* private_profile : profile->GetAllOffTheRecordProfiles())
          private_profile->SetUserData(&kReleasedProfileKey,
                                      std::make_unique<ReleasedProfileMarker>());
      }
      Withdraw(*found->second, "profileIdentityChanged");
      FailActions(id, "profileIdentityChanged");
      MaybeReplay();
      return;
    }
    if (!profile || profile->IsOffTheRecord() || profile->ShutdownStarted() ||
        !Registered(path) || !old || !Current(*found->second) ||
        old->incarnation != incarnation || profile->GetPath() != path || Closed() ||
        !IdentityMatches(path, incarnation)) {
      FailActions(id, "profileLoadFailed");
      MaybeReplay();
      return;
    }
    Register(profile);
    auto* current = ForProfile(profile);
    if (current && current->validated) RebindDormant(current->id);
    MaybeReplay();
  }
  void ReleaseID(std::string id, NotificationReleaseReason reason) {
    if (consumer_ == Consumer::kClosed || finishing_) return;
    auto* scope = FindScope(id);
    if (!scope) return;
    if (scope->reason && Strength(*scope->reason) >= Strength(reason)) return;
    scope->reason = reason;
    if (reason == NotificationReleaseReason::kProfileDelete)
      deleted_paths_.insert(scope->path);
    scope->active = false;
    scope->settled = false;
    const auto release_serial = ++scope->release_serial;
    if (scope->profile) {
      auto loaded = loaded_.find(scope->profile);
      if (loaded != loaded_.end() && loaded->second == id) loaded_.erase(loaded);
      scope->profile->SetUserData(&kReleasedProfileKey,
                                  std::make_unique<ReleasedProfileMarker>());
      scope->profile->RemoveObserver(scope);
      scope->profile = nullptr;
    } else if (scope->process) {
      auto loaded = loaded_.find(nullptr);
      if (loaded != loaded_.end() && loaded->second == id) loaded_.erase(loaded);
    }
    auto fence = scope->Envelope();
    fence.Set("reason", Reason(reason));
    base::ListValue dispositions;
    std::vector<std::string> revoke;
    for (auto& [route_id, route] : routes_) {
      if (route->scope != id || route->withdrawn) continue;
      const bool retain = scope->session.empty() && !scope->process &&
          reason == NotificationReleaseReason::kProfileUnload &&
          route->type == NotificationHandler::Type::WEB_PERSISTENT &&
          route->accepted && !route->acceptance.empty();
      route->dormant = retain;
      if (retain) {
        route->delegate.reset();
        route->database_validated = false;
      }
      auto disposition = base::DictValue().Set("nativeID", route->native);
      disposition.Set("disposition", retain ? "RetainedDormant" : "revoked");
      dispositions.Append(std::move(disposition));
      if (!retain) revoke.push_back(route_id);
    }
    fence.Set("dispositions", std::move(dispositions));
    Native("fenceScope", fence.Clone(), {});
    auto delta = fence.Clone();
    delta.Set("kind", "scopeFence");
    scope->mutation = Mutate(std::move(delta));
    auto callbacks = TakeQueries(id);
    for (const auto& route_id : revoke) Withdraw(*routes_[route_id], Reason(reason));
    for (auto& query : callbacks) std::move(query.callback).Run({}, false);
    Native("release", std::move(fence),
        base::BindOnce(&Coordinator::ScopeSettled, weak_.GetWeakPtr(), id, release_serial));
  }
  void ScopeSettled(std::string id, uint64_t serial, base::DictValue answer) {
    auto* scope = FindScope(id);
    if (!scope || scope->release_serial != serial) return;
    scope->settled = answer.FindBool("settled").value_or(false);
    if (scope->settled) {
      std::vector<std::string> active;
      for (const auto& [other_id, other] : scopes_)
        if (other->active && other->path == scope->path &&
            other->incarnation == scope->incarnation && other->session.empty())
          active.push_back(other_id);
      for (const auto& other : active) RebindDormant(other);
      auto value = scope->Envelope();
      value.Set("kind", "state");
      value.Set("state", "Released");
      value.Set("reason", Reason(*scope->reason));
      value.Set("settled", true);
      scope->mutation = Mutate(std::move(value));
    }
    MaybeFinishDrain();
  }
  void Release(Profile* profile, NotificationReleaseReason reason) {
    auto* scope = ForProfile(profile);
    if (scope) ReleaseID(scope->id, reason);
  }
  void ReleasePath(const base::FilePath& path, NotificationReleaseReason reason,
                   base::OnceCallback<void(bool)> callback) {
    if (Closed() || !Manager() || !path.IsAbsolute() ||
        path.DirName() != Manager()->user_data_dir() ||
        path == Manager()->user_data_dir().Append(ProfileManager::GetInitialProfileDir()) ||
        pending_loads_.contains(path) ||
        (admitted_deletions_.size() + deleted_paths_.size() +
         !admitted_deletions_.contains(path) + !deleted_paths_.contains(path) > kMaxScopes) ||
        reason != NotificationReleaseReason::kProfileDelete) {
      std::move(callback).Run(false);
      return;
    }
    const auto actual = Identify(path);
    const auto root = Identify(Manager()->user_data_dir());
    if (!actual || !root || actual->path != path ||
        actual->path.DirName() != root->path) {
      std::move(callback).Run(false);
      return;
    }
    admitted_deletions_.insert(path);
    deleted_paths_.insert(path);
    if (auto* loaded = Manager()->GetProfileByPath(path)) {
      loaded->SetUserData(&kReleasedProfileKey, std::make_unique<ReleasedProfileMarker>());
      for (auto* private_profile : loaded->GetAllOffTheRecordProfiles())
        private_profile->SetUserData(&kReleasedProfileKey,
                                    std::make_unique<ReleasedProfileMarker>());
    }
    std::vector<std::string> scopes;
    for (const auto& [id, scope] : scopes_)
      if (!scope->process && scope->path == path) scopes.push_back(id);
    for (const auto& id : scopes) ReleaseID(id, reason);
    identities_.erase(path);
    std::move(callback).Run(true);
  }
  bool IdentityMatches(const base::FilePath& path, const std::string& incarnation) {
    const auto known = identities_.find(path);
    const auto actual = Identify(path);
    return !deleted_paths_.contains(path) && Registered(path) && actual &&
        known != identities_.end() && known->second.directory == *actual &&
        known->second.incarnation == incarnation;
  }
  uint64_t Mutate(base::DictValue value) {
    const auto mutation = ++mutation_;
    value.Set("B", bridge_);
    value.Set("M", Number(mutation));
    if (!watch_.empty()) value.Set("W", watch_);
    if (!watch_.empty() && mutation - std::max(applied_, watch_base_) >= kMaxJournal) {
      LoseConsumer(true, "journalOverflow");
    }
    if (consumer_ == Consumer::kLive || consumer_ == Consumer::kReplaying)
      Emit(std::move(value));
    return mutation;
  }
  void Emit(base::DictValue value) {
    if (Closed() || watch_.empty()) return;
    auto payload = JSON(value);
    if (payload.size() > kMaxJSON || queued_bytes_ + payload.size() > kMaxQueuedBytes) {
      LoseConsumer(true, "eventByteOverflow");
      return;
    }
    const auto id = ++event_ticket_;
    queued_bytes_ += payload.size();
    events_.emplace(id, std::move(payload));
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE,
        base::BindOnce(&Coordinator::EmitCurrent, weak_.GetWeakPtr(), watch_, id, false));
  }
  void EmitCurrent(std::string epoch, uint64_t id, bool invalidation) {
    auto found = events_.find(id);
    if (found == events_.end()) return;
    auto payload = std::move(found->second);
    queued_bytes_ -= payload.size();
    events_.erase(found);
    if (g_event && !epoch.empty() && (invalidation || watch_ == epoch) && !Closed())
      g_event(g_transport_context, "notifications", payload.c_str());
  }
  void LoseConsumer(bool defer_callbacks = false,
                    std::string_view reason = "observerLost") {
    if (Closed()) return;
    if (consumer_ == Consumer::kNoConsumer && watch_.empty()) {
      if (!defer_callbacks) FlushDeferredQueries();
      return;
    }
    auto reset = Envelope().Set("kind", "watchInvalidated").Set("reason", reason);
    events_.clear();
    queued_bytes_ = 0;
    if (!watch_.empty() && g_event) {
      const auto id = ++event_ticket_;
      auto payload = JSON(reset);
      queued_bytes_ += payload.size();
      events_.emplace(id, std::move(payload));
      content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE,
          base::BindOnce(&Coordinator::EmitCurrent, weak_.GetWeakPtr(), watch_, id, true));
    }
    watch_.clear();
    consumer_ = Consumer::kNoConsumer;
    auto taken = TakeQueries();
    if (defer_callbacks) {
      for (auto& query : taken) deferred_queries_.push_back(std::move(query));
      content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE,
          base::BindOnce(&Coordinator::FlushDeferredQueries, weak_.GetWeakPtr()));
    } else {
      for (auto& query : taken) std::move(query.callback).Run({}, false);
    }
  }
  void FlushDeferredQueries() {
    auto callbacks = std::move(deferred_queries_);
    deferred_queries_.clear();
    for (auto& query : callbacks) std::move(query.callback).Run({}, false);
  }
  base::DictValue Watch(const base::DictValue& args) {
    if (Closed() || !g_event || !g_control ||
        !Keys(args, {"consumerNonce", "ready"}) ||
        !Text(args, "consumerNonce") || !args.FindBool("ready").value_or(false))
      return Rejected("consumerUnavailable");
    const auto transition = ++watch_transition_;
    LoseConsumer();
    if (Closed() || transition != watch_transition_ || !g_event || !g_control)
      return Rejected(Closed() ? "browserDraining" : "watchSuperseded");
    watch_ = Number(++epoch_);
    consumer_ = Consumer::kBootstrapping;
    applied_ = 0;
    watch_base_ = mutation_;
    if (!root_ready_ && !purging_) {
      purging_ = true;
      const auto root = Manager() ? Identify(Manager()->user_data_dir()) : std::nullopt;
      if (!root) { purging_ = false; return Rejected("rootUnavailable"); }
      root_namespace_ = Hash(root->path.value());
      Native("purgePriorProcesses", Envelope().Set("root", root_namespace_)
          .Set("nativePrefix", "solara.n2." + root_namespace_ + ".")
          .Set("currentB", bridge_),
          base::BindOnce(&Coordinator::OrphansPurged, weak_.GetWeakPtr()));
    }
    MaybeReplay();
    if (Closed() || transition != watch_transition_ || watch_.empty())
      return Rejected(Closed() ? "browserDraining" : "watchSuperseded");
    return Envelope().Set("ok", true).Set("state", State(consumer_));
  }
  void OrphansPurged(base::DictValue answer) {
    purging_ = false;
    root_ready_ = answer.FindBool("settled").value_or(false) &&
        answer.FindBool("complete").value_or(false) &&
        String(answer, "root") == root_namespace_ && String(answer, "currentB") == bridge_;
    if (!root_ready_) LoseConsumer(true, "orphanCleanupIncomplete");
    else MaybeReplay();
  }
  base::DictValue Envelope() const {
    return base::DictValue().Set("B", bridge_).Set("W", watch_)
        .Set("M", Number(mutation_));
  }
  void MaybeReplay() {
    if (consumer_ != Consumer::kBootstrapping || bootstrap_ || !root_ready_)
      return;
    high_water_ = mutation_;
    base::ListValue entries;
    size_t snapshot_bytes = 0;
    auto append = [&](base::DictValue value) {
      const auto bytes = JSON(value).size();
      if (bytes > kMaxJSON || snapshot_bytes + bytes > kMaxSnapshotBytes) return false;
      snapshot_bytes += bytes;
      entries.Append(std::move(value));
      return true;
    };
    for (const auto& [id, scope] : scopes_) {
      auto value = scope->Envelope();
      value.Set("entryType", "scope");
      value.Set("active", scope->active);
      value.Set("validated", scope->validated);
      value.Set("settled", scope->settled);
      value.Set("scopeM", Number(scope->mutation));
      if (scope->reason) value.Set("reason", Reason(*scope->reason));
      if (!append(std::move(value))) {
        LoseConsumer(true, "snapshotByteOverflow");
        return;
      }
    }
    for (const auto& [id, route] : routes_) {
      auto value = Entry(*route, true);
      value.Set("entryType", "route");
      value.Set("routeM", Number(route->mutation));
      if (!append(std::move(value))) {
        LoseConsumer(true, "snapshotByteOverflow");
        return;
      }
    }
    snapshot_count_ = entries.size();
    snapshot_id_ = Token();
    snapshot_hash_ = Hash(base::WriteJson(entries).value_or("[]"));
    consumer_ = Consumer::kReplaying;
    auto begin = ReplayEnvelope();
    begin.Set("kind", "replayBegin");
    Emit(std::move(begin));
    for (auto& entry : entries) {
      auto value = ReplayEnvelope();
      value.Set("kind", "replayEntry");
      value.Set("entry", std::move(entry));
      Emit(std::move(value));
    }
    auto end = ReplayEnvelope();
    end.Set("kind", "replayEnd");
    Emit(std::move(end));
  }
  base::DictValue ReplayEnvelope() const {
    return Envelope().Set("H", Number(high_water_)).Set("snapshot", snapshot_id_)
        .Set("count", static_cast<int>(snapshot_count_)).Set("hash", snapshot_hash_);
  }
  bool Epoch(const base::DictValue& args) const {
    return !watch_.empty() && String(args, "B") == bridge_ &&
           String(args, "W") == watch_ && !Closed();
  }
  bool ScopeMatches(const base::DictValue& args, const Scope& scope) const {
    return String(args, "scope") == scope.id &&
        String(args, "lifetime") == scope.lifetime &&
        String(args, "root") == scope.root &&
        String(args, "profile") == scope.path.value() &&
        String(args, "incarnation") == scope.incarnation &&
        String(args, "session") == scope.session;
  }
  bool RouteMatches(const base::DictValue& args, const Route& route) {
    auto* scope = FindScope(route.scope);
    return scope && ScopeMatches(args, *scope) &&
        String(args, "token") == route.token &&
        String(args, "creation") == bridge_ &&
        Integer(args, "generation") == route.generation &&
        String(args, "nativeID") == route.native;
  }
  bool AuthorizationEligible(const base::DictValue& args) {
    const auto generation = Integer(args, "generation");
    if (!Keys(args, {"B", "W", "scope", "lifetime", "root", "profile",
        "incarnation", "session", "token", "creation", "generation", "nativeID"}) ||
        !Epoch(args) || finishing_ || !generation) return false;
    auto* route = FindRoute(String(args, "token"), *generation);
    if (!route || !RouteMatches(args, *route) || !Current(*route) ||
        !route->authorization_eligible || route->withdrawn || route->removed ||
        route->dormant || !route->database_validated ||
        !route->origin.SchemeIsHTTPOrHTTPS() ||
        (route->type != NotificationHandler::Type::WEB_PERSISTENT &&
         route->type != NotificationHandler::Type::WEB_NON_PERSISTENT)) return false;
    const auto current = current_.find(route->key);
    if (current == current_.end() || current->second != RouteID(*route)) return false;
    auto* scope = FindScope(route->scope);
    if (!scope || !scope->active || !scope->validated || scope->reason ||
        scope->process || !scope->profile || ForProfile(scope->profile) != scope ||
        scope->profile->ShutdownStarted() ||
        scope->profile->GetUserData(&kReleasedProfileKey) ||
        scope->profile->GetOriginalProfile()->ShutdownStarted() ||
        scope->profile->GetOriginalProfile()->GetUserData(&kReleasedProfileKey) ||
        !IdentityMatches(scope->path, scope->incarnation)) return false;
    auto* settings = HostContentSettingsMapFactory::GetForProfile(scope->profile);
    return settings && settings->GetContentSetting(route->origin, route->origin,
        ContentSettingsType::NOTIFICATIONS) == CONTENT_SETTING_ALLOW;
  }
  base::DictValue Acknowledge(const base::DictValue& args, bool replay) {
    const auto applied = Integer(args, "applied");
    const auto native = Integer(args, "N");
    const bool schema = replay
        ? Keys(args, {"op", "B", "W", "H", "applied", "N", "barrier", "snapshot", "count", "hash"})
        : Keys(args, {"op", "B", "W", "from", "applied", "N", "barrier"});
    if (!schema || !Epoch(args) || bootstrap_ || !applied || !native ||
        *native < native_revision_ || !Text(args, "barrier") ||
        (replay ? consumer_ != Consumer::kReplaying ||
          Integer(args, "H") != high_water_ || *applied < high_water_ ||
          *applied != mutation_ || String(args, "snapshot") != snapshot_id_ ||
          String(args, "hash") != snapshot_hash_ ||
          args.FindInt("count") != static_cast<int>(snapshot_count_)
        : consumer_ != Consumer::kLive || Integer(args, "from") != applied_ ||
          *applied < applied_ || *applied > mutation_))
      return Rejected(replay ? "replayMismatch" : "liveAcknowledgmentMismatch");
    applied_ = *applied;
    native_revision_ = *native;
    if (replay) consumer_ = Consumer::kLive;
    Compact();
    if (!replay) return Envelope().Set("ok", true).Set("applied", Number(applied_));
    RetryLoadedRegistrations();
    std::vector<std::string> waiting;
    for (const auto& [token, action] : actions_) waiting.push_back(token);
    for (const auto& token : waiting) {
      auto found = actions_.find(token);
      if (found == actions_.end() || !found->second->native_validated) continue;
      auto route = routes_.find(found->second->route);
      if (route != routes_.end() && route->second->dormant) LoadDormant(route->first);
      else DispatchAction(token);
    }
    return Envelope().Set("ok", consumer_ == Consumer::kLive)
        .Set("state", State(consumer_));
  }
  void QueryDisplayed(Profile* profile, std::optional<GURL> origin,
                       GetDisplayedNotificationsCallback callback) {
    auto* scope = ForProfile(profile);
    if (queries_.size() >= 1024 || Closed() || consumer_ != Consumer::kLive || bootstrap_ || !scope ||
        !scope->active || !scope->validated || deleted_paths_.contains(scope->path)) {
      std::move(callback).Run({}, false);
      return;
    }
    Query query;
    query.scope = scope->id;
    query.watch = watch_;
    query.mutation = mutation_;
    query.native = native_revision_;
    query.origin = origin;
    query.callback = std::move(callback);
    const auto id = query.id;
    queries_.emplace(id, std::move(query));
    content::GetUIThreadTaskRunner({})->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Coordinator::QueryTimeout, weak_.GetWeakPtr(), id), kDeadline);
    auto value = scope->Envelope();
    value.Set("kind", "displayedQuery");
    value.Set("Q", id);
    value.Set("B", bridge_);
    value.Set("W", watch_);
    value.Set("M", Number(mutation_));
    value.Set("N", Number(native_revision_));
    if (origin) value.Set("origin", origin->spec());
    Emit(std::move(value));
  }
  std::optional<Query> TakeQuery(const std::string& id) {
    auto it = queries_.find(id);
    if (it == queries_.end()) return std::nullopt;
    Query query = std::move(it->second);
    queries_.erase(it);
    return query;
  }
  std::vector<Query> TakeQueries(std::optional<std::string_view> scope = std::nullopt) {
    std::vector<Query> result;
    for (auto it = queries_.begin(); it != queries_.end();) {
      if (!scope || it->second.scope == *scope) {
        result.push_back(std::move(it->second));
        it = queries_.erase(it);
      } else ++it;
    }
    if (scope) for (auto it = deferred_queries_.begin(); it != deferred_queries_.end();) {
      if (it->scope == *scope) {
        result.push_back(std::move(*it));
        it = deferred_queries_.erase(it);
      } else ++it;
    }
    return result;
  }
  void QueryTimeout(std::string id) {
    auto query = TakeQuery(id);
    if (query) std::move(query->callback).Run({}, false);
  }
  base::DictValue DisplayedAnswer(const base::DictValue& args) {
    if (!Text(args, "Q")) return Rejected("queryMissing");
    auto query = TakeQuery(String(args, "Q"));
    if (!query) return Rejected("queryExpired");
    auto* scope = FindScope(query->scope);
    const auto* ids = args.FindList("ids");
    bool valid = Keys(args, {"op", "Q", "B", "W", "M", "N", "scope",
        "lifetime", "root", "profile", "incarnation", "session", "beginN",
        "endN", "inFlight", "settled", "complete", "ids", "barrier"}) &&
        Epoch(args) && consumer_ == Consumer::kLive && !bootstrap_ && scope &&
        scope->active && scope->validated && ScopeMatches(args, *scope) &&
        query->watch == watch_ && Integer(args, "M") == query->mutation &&
        query->mutation == mutation_ && Integer(args, "N") == query->native &&
        Integer(args, "beginN").has_value() &&
        Integer(args, "beginN") == Integer(args, "endN") &&
        *Integer(args, "beginN") >= query->native &&
        *Integer(args, "endN") >= native_revision_ &&
        args.FindInt("inFlight") == 0 && Text(args, "barrier") &&
        args.FindBool("settled").value_or(false) &&
        args.FindBool("complete").value_or(false) && ids && ids->size() <= kMaxRoutes;
    std::set<std::string> chromium_ids;
    std::set<std::string> unique;
    if (valid) {
      for (const auto& item : *ids) {
        if (!item.is_dict() ||
            !Keys(item.GetDict(), {"token", "generation", "nativeID"}) ||
            !Integer(item.GetDict(), "generation")) { valid = false; break; }
        const auto& value = item.GetDict();
        auto* route = FindRoute(String(value, "token"), *Integer(value, "generation"));
        if (!route || !Current(*route) || route->scope != scope->id ||
            String(value, "nativeID") != route->native || !route->accepted ||
            (route->type == NotificationHandler::Type::WEB_PERSISTENT &&
             !route->database_validated) ||
            !unique.insert(route->native).second) { valid = false; break; }
        if (!query->origin || route->origin == *query->origin)
          chromium_ids.insert(route->chromium_id);
      }
    }
    if (valid) native_revision_ = std::max(native_revision_, *Integer(args, "endN"));
    std::move(query->callback).Run(valid ? std::move(chromium_ids) :
                                         std::set<std::string>(), valid);
    return Envelope().Set("ok", valid).Set("supportsSynchronization", valid);
  }
  base::DictValue PostAck(const base::DictValue& args) {
    const auto generation = Integer(args, "generation");
    if (!RouteKeys(args, {"receipt", "N", "accepted"}) || !Epoch(args) || !generation ||
        !Text(args, "receipt") || !Integer(args, "N") ||
        !args.FindBool("accepted").value_or(false)) return Rejected("invalidReceipt");
    auto* route = FindRoute(String(args, "token"), *generation);
    if (!route || !RouteMatches(args, *route) || !Current(*route) ||
        (route->type == NotificationHandler::Type::WEB_PERSISTENT &&
         FindScope(route->scope)->session.empty() &&
         !route->database_validated))
      return Rejected("staleReceipt");
    if (route->accepted && route->acceptance != String(args, "receipt"))
      return Rejected("receiptChanged");
    if (!route->accepted) {
      route->accepted = true;
      route->acceptance = String(args, "receipt");
      native_revision_ = std::max(native_revision_, *Integer(args, "N"));
      StateRoute(*route);
    }
    return Envelope().Set("ok", true).Set("engineAccepted", true)
        .Set("token", route->token).Set("generation", Number(route->generation))
        .Set("nativeID", route->native).Set("receipt", route->acceptance);
  }
  base::DictValue NativeRemoved(const base::DictValue& args) {
    const auto generation = Integer(args, "generation");
    if (!RouteKeys(args, {"receipt", "N", "removed"}) || !Epoch(args) || !generation ||
        !Text(args, "receipt") || !Integer(args, "N") ||
        !args.FindBool("removed").value_or(false)) return Rejected("invalidRemoval");
    auto* route = FindRoute(String(args, "token"), *generation);
    if (!route || !RouteMatches(args, *route)) return Rejected("staleRemoval");
    Withdraw(*route, "nativeRemoved");
    if (!route->removed) {
      route->removed = true;
      StateRoute(*route);
    }
    native_revision_ = std::max(native_revision_, *Integer(args, "N"));
    return Envelope().Set("ok", true).Set("removed", true);
  }
  struct Action {
    base::DictValue args;
    std::string route;
    NotificationReply reply;
    bool dispatched = false;
    bool native_validated = false;
    Action(base::DictValue value, std::string id, NotificationReply response)
        : args(std::move(value)), route(std::move(id)), reply(std::move(response)) {}
  };
  void ActionRequest(const base::DictValue& args, NotificationReply reply) {
    if (Text(args, "B") && String(args, "B") != bridge_) {
      const auto prior = String(args, "B");
      const auto generation = Integer(args, "generation");
      const auto action = String(args, "action");
      const auto native = "solara.n2." + root_namespace_ + "." + prior + "." +
          String(args, "token") + "." + Number(generation.value_or(0));
      if (!RouteKeys(args, {"action", "actionToken"}) || root_namespace_.empty() ||
          !Text(args, "token") || !Text(args, "actionToken") || !generation ||
          !*generation || String(args, "creation") != prior ||
          String(args, "nativeID") != native || (action != "click" && action != "close")) {
        reply.Send(Rejected("invalidPriorProcessAction"));
        return;
      }
      auto reject = base::DictValue().Set("priorB", prior).Set("nativeID", native)
          .Set("actionToken", String(args, "actionToken")).Set("action", action)
          .Set("namespace", root_namespace_).Set("currentB", bridge_);
      Native("rejectPriorProcessAction", std::move(reject),
          base::BindOnce([](NotificationReply response, base::DictValue) {
            response.Send(Rejected("priorProcessAction"));
          }, std::move(reply)));
      return;
    }
    const auto generation = Integer(args, "generation");
    const auto action = String(args, "action");
    if (!RouteKeys(args, {"action", "actionToken"}) || !Epoch(args) || !generation ||
        (action != "click" && action != "close") || !Text(args, "actionToken") ||
        actions_.size() >= 128) {
      reply.Send(Rejected("invalidAction"));
      return;
    }
    auto* route = FindRoute(String(args, "token"), *generation);
    if (!route || !Current(*route) || !RouteMatches(args, *route) || !route->accepted) {
      reply.Send(Rejected("staleAction"));
      return;
    }
    const std::string token = String(args, "actionToken");
    if (!seen_actions_.insert(token).second) {
      reply.Send(Rejected("duplicateAction"));
      return;
    }
    const std::string id = RouteID(*route);
    actions_.emplace(token, std::make_unique<Action>(args.Clone(), id, std::move(reply)));
    content::GetUIThreadTaskRunner({})->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Coordinator::ActionTimeout, weak_.GetWeakPtr(), token), kDeadline);
    Native("validateAction", args.Clone(),
        base::BindOnce(&Coordinator::ActionValidated, weak_.GetWeakPtr(), token));
  }
  void ActionValidated(std::string token, base::DictValue proof) {
    auto found = actions_.find(token);
    if (found == actions_.end()) return;
    if (!proof.FindBool("valid").value_or(false) ||
        String(proof, "actionToken") != token ||
        String(proof, "nativeID") != String(found->second->args, "nativeID") ||
        Integer(proof, "generation") != Integer(found->second->args, "generation")) {
      FinishAction(token, false, "nativeActionNotOwned");
      return;
    }
    found->second->native_validated = true;
    if (consumer_ != Consumer::kLive) return;
    auto route = routes_.find(found->second->route);
    if (route != routes_.end() && route->second->dormant) LoadDormant(route->first);
    else DispatchAction(token);
  }
  void ResumeActions(const std::string& id) {
    std::vector<std::string> tokens;
    for (const auto& [token, action] : actions_)
      if (action->route == id) tokens.push_back(token);
    for (const auto& token : tokens) DispatchAction(token);
  }
  void FailActions(const std::string& id, const char* reason) {
    std::vector<std::string> tokens;
    for (const auto& [token, action] : actions_)
      if (action->route == id) tokens.push_back(token);
    for (const auto& token : tokens) FinishAction(token, false, reason);
  }
  void DispatchAction(const std::string& token) {
    auto action = actions_.find(token);
    if (action == actions_.end() || action->second->dispatched ||
        !action->second->native_validated || consumer_ != Consumer::kLive) return;
    auto found = routes_.find(action->second->route);
    if (found == routes_.end() || !Current(*found->second)) {
      FinishAction(token, false, "routeRevoked");
      return;
    }
    auto& route = *found->second;
    auto* scope = FindScope(route.scope);
    if (!scope || !scope->active || !scope->validated ||
        (!scope->process && (!scope->profile || scope->profile->ShutdownStarted()))) {
      FinishAction(token, false, "producerReleased");
      return;
    }
    if (route.dormant || (route.type == NotificationHandler::Type::WEB_PERSISTENT &&
                         !route.database_validated)) return;
    action->second->dispatched = true;
    const bool close = String(action->second->args, "action") == "close";
    auto delegate = route.delegate;
    const auto type = route.type;
    const auto origin = route.origin;
    const auto chromium_id = route.chromium_id;
    const std::string owner_id = scope->id;
    if (close) Withdraw(route, "userClose");
    scope = FindScope(owner_id);
    if (!scope || !scope->active || (!scope->process &&
        (!scope->profile || scope->profile->ShutdownStarted()))) {
      FinishAction(token, false, "producerReleased");
      return;
    }
    Profile* profile = scope->profile;
    if (delegate) {
      if (close) delegate->Close(true);
      else delegate->Click(std::nullopt, std::nullopt);
      FinishAction(token, true, "");
      return;
    }
    if (!profile || type == NotificationHandler::Type::TRANSIENT) {
      FinishAction(token, false, "delegateUnavailable");
      return;
    }
    auto* service = NotificationDisplayServiceImpl::GetForProfile(profile);
    if (!service || !service->GetNotificationHandler(type)) {
      FinishAction(token, false, "handlerUnavailable");
      return;
    }
    service->ProcessNotificationOperation(close ? NotificationOperation::kClose
                                                : NotificationOperation::kClick,
        type, origin, chromium_id, std::nullopt, std::nullopt,
        close ? std::optional<bool>(true) : std::nullopt, std::nullopt,
        base::BindOnce(&Coordinator::FinishAction, weak_.GetWeakPtr(), token, true, ""));
  }
  void ActionTimeout(std::string token) {
    FinishAction(token, false, "engineOperationTimedOut");
  }
  void FinishAction(std::string token, bool success, std::string error) {
    auto found = actions_.find(token);
    if (found == actions_.end()) return;
    auto action = std::move(found->second);
    actions_.erase(found);
    completed_actions_.push_back(token);
    while (completed_actions_.size() > kMaxActions) {
      seen_actions_.erase(completed_actions_.front());
      completed_actions_.pop_front();
    }
    auto result = Envelope().Set("ok", success).Set("engineCompleted", success)
        .Set("actionToken", token);
    if (!error.empty()) result.Set("error", error);
    action->reply.Send(std::move(result));
  }
  void Control(base::DictValue args, NotificationReply reply) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (Closed()) { reply.Send(Rejected("browserDraining")); return; }
    const auto op = String(args, "op");
    if (op == "replayAck" || op == "liveAck" || op == "displayedAnswer" ||
        op == "postAck" || op == "nativeRemoved") {
      const std::string kind = (op == "replayAck" || op == "liveAck") ? "validateReplayBarrier" :
          op == "displayedAnswer" ? "validateEnumeration" :
          op == "nativeRemoved" ? "validateRemoval" : "validateReceipt";
      auto request = args.Clone();
      auto completion = base::BindOnce(&Coordinator::ProofValidated,
          weak_.GetWeakPtr(), std::move(args), std::move(reply));
      Native(kind, std::move(request), std::move(completion));
    }
    else if (op == "action") ActionRequest(args, std::move(reply));
    else if (op == "observerLost" && Keys(args, {"op", "B", "W"}) && Epoch(args)) {
      LoseConsumer();
      reply.Ok();
    } else reply.Send(Rejected("unsupportedControl"));
  }
  void ProofValidated(base::DictValue args, NotificationReply reply, base::DictValue proof) {
    const auto op = String(args, "op");
    const auto field = (op == "postAck" || op == "nativeRemoved") ? "receipt" : "barrier";
    const bool valid = proof.FindBool("valid").value_or(false) &&
        proof.FindBool("settled").value_or(false) && proof.FindInt("inFlight") == 0 &&
        String(proof, field) == String(args, field) && Text(args, field) &&
        String(proof, "B") == String(args, "B") &&
        String(proof, "W") == String(args, "W");
    if (!valid) {
      if (op == "displayedAnswer") QueryTimeout(String(args, "Q"));
      reply.Send(Rejected("nativeProofRejected"));
      return;
    }
    if ((op == "postAck" || op == "nativeRemoved") &&
        (String(proof, "nativeID") != String(args, "nativeID") ||
         Integer(proof, "generation") != Integer(args, "generation") ||
         Integer(proof, "N") != Integer(args, "N"))) {
      reply.Send(Rejected("receiptOwnershipMismatch"));
      return;
    }
    if (op == "displayedAnswer" &&
        (String(proof, "Q") != String(args, "Q") ||
         Integer(proof, "beginN") != Integer(args, "beginN") ||
         Integer(proof, "endN") != Integer(args, "endN") ||
         !args.FindList("ids") ||
         String(proof, "idsHash") != Hash(base::WriteJson(*args.FindList("ids")).value_or("[]")))) {
      QueryTimeout(String(args, "Q"));
      reply.Send(Rejected("enumerationOwnershipMismatch"));
      return;
    }
    if ((op == "replayAck" || op == "liveAck") &&
        (Integer(proof, "applied") != Integer(args, "applied") ||
         Integer(proof, "N") != Integer(args, "N") ||
         (op == "liveAck" && Integer(proof, "from") != Integer(args, "from")))) {
      reply.Send(Rejected("barrierOwnershipMismatch"));
      return;
    }
    if (op == "liveAck" || op == "replayAck") reply.Send(Acknowledge(args, op == "replayAck"));
    else if (op == "displayedAnswer") reply.Send(DisplayedAnswer(args));
    else if (op == "nativeRemoved") reply.Send(NativeRemoved(args));
    else reply.Send(PostAck(args));
  }
  static void NativeCompletion(void* raw, const char* json) {
    const auto ticket = reinterpret_cast<uintptr_t>(raw);
    if (!ticket) return;
    const auto parsed = Parse(json);
    base::DictValue value = parsed ? parsed->Clone() : Rejected("nativeReplyInvalid");
    scoped_refptr<base::SequencedTaskRunner> runner;
    {
      std::lock_guard<std::mutex> guard(g_native_runner_lock);
      runner = g_native_runner;
    }
    if (!runner) return;
    runner->PostTask(FROM_HERE, base::BindOnce(
        [](uintptr_t id, base::DictValue result) {
          Coordinator::Get().NativeCompleted(Number(id), std::move(result));
        }, ticket, std::move(value)));
  }
  void Native(std::string kind, base::DictValue value,
               base::OnceCallback<void(base::DictValue)> callback) {
    value.Set("control", kind);
    value.Set("B", bridge_);
    value.Set("W", watch_);
    value.Set("M", Number(mutation_));
    const size_t bytes = JSON(value).size();
    const bool cleanup = kind == "fenceGeneration" || kind == "fenceScope" ||
        kind == "remove" || kind == "release" || kind == "browserDrain" ||
        kind == "finalRemove" || kind == "purgePriorProcesses" ||
        kind == "rejectPriorProcessAction";
    if (!g_control || finishing_ || consumer_ == Consumer::kClosed || bytes > kMaxJSON ||
        native_ops_.size() >= kMaxControls || native_bytes_ + bytes * 2 > kMaxQueuedBytes) {
      if (cleanup || kind == "own") native_failed_ = true;
      value.Set("operation", Token());
      value.Set("untracked", true);
      if (cleanup && g_control && !finishing_ &&
          consumer_ != Consumer::kClosed && bytes <= kMaxJSON)
        g_control(g_transport_context, JSON(value).c_str(), &NativeCompletion, nullptr);
      if (callback) std::move(callback).Run(Rejected("nativeControlUnavailable"));
      return;
    }
    {
      std::lock_guard<std::mutex> guard(g_native_runner_lock);
      if (!g_native_runner) g_native_runner = content::GetUIThreadTaskRunner({});
    }
    CHECK_LT(native_ticket_, static_cast<uint64_t>(UINTPTR_MAX));
    const auto ticket = static_cast<uintptr_t>(++native_ticket_);
    const auto id = Number(ticket);
    NativeOperation operation;
    operation.scope = String(value, "scope");
    operation.bytes = bytes * 2;
    native_bytes_ += operation.bytes;
    operation.callback = std::move(callback);
    native_ops_.emplace(id, std::move(operation));
    value.Set("operation", id);
    content::GetUIThreadTaskRunner({})->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Coordinator::NativeTimeout, weak_.GetWeakPtr(), id), kDeadline);
    g_control(g_transport_context, JSON(value).c_str(), &NativeCompletion,
              reinterpret_cast<void*>(ticket));
  }
  void NativeCompleted(std::string id, base::DictValue answer) {
    auto found = native_ops_.find(id);
    if (found == native_ops_.end()) return;
    auto operation = std::move(found->second);
    native_ops_.erase(found);
    native_bytes_ -= operation.bytes;
    if (const auto revision = Integer(answer, "N"))
      native_revision_ = std::max(native_revision_, *revision);
    if (operation.callback) std::move(operation.callback).Run(std::move(answer));
    CompactScopes();
    MaybeFinishDrain();
  }
  void NativeTimeout(std::string id) {
    auto found = native_ops_.find(id);
    if (found == native_ops_.end()) return;
    auto operation = std::move(found->second);
    native_ops_.erase(found);
    native_bytes_ -= operation.bytes;
    native_failed_ = true;
    if (operation.callback) std::move(operation.callback).Run(
        Rejected("nativeControlTimedOut").Set("settled", false));
    MaybeFinishDrain();
  }
  void Drain(base::OnceClosure continuation) {
    if (consumer_ == Consumer::kClosed) {
      std::move(continuation).Run();
      return;
    }
    quit_.push_back(std::move(continuation));
    if (consumer_ == Consumer::kDraining) return;
    ++watch_transition_;
    consumer_ = Consumer::kDraining;
    events_.clear();
    queued_bytes_ = 0;
    drain_native_complete_ = false;
    std::vector<std::string> scopes;
    for (const auto& [id, scope] : scopes_) scopes.push_back(id);
    for (const auto& id : scopes) {
      auto* scope = FindScope(id);
      auto reason = scope->session.empty()
          ? NotificationReleaseReason::kBrowserShutdown
          : NotificationReleaseReason::kPrivateEnd;
      ReleaseID(id, reason);
    }
    auto taken = TakeQueries();
    for (auto& query : taken) std::move(query.callback).Run({}, false);
    FlushDeferredQueries();
    std::vector<std::string> actions;
    for (const auto& [token, action] : actions_) actions.push_back(token);
    for (const auto& token : actions) FinishAction(token, false, "browserDraining");
    watch_.clear();
    Native("browserDrain",
        Envelope().Set("root", root_namespace_).Set("removeAll", true),
        base::BindOnce(&Coordinator::NativeDrainCompleted, weak_.GetWeakPtr()));
    content::GetUIThreadTaskRunner({})->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Coordinator::DrainDeadline, weak_.GetWeakPtr()), kDeadline);
    MaybeFinishDrain();
  }
  void NativeDrainCompleted(base::DictValue answer) {
    drain_native_complete_ = answer.FindBool("settled").value_or(false);
    if (!drain_native_complete_) native_failed_ = true;
    MaybeFinishDrain();
  }
  void MaybeFinishDrain() {
    if (finishing_ || consumer_ != Consumer::kDraining || !drain_native_complete_ ||
        !native_ops_.empty() || bootstrap_) return;
    FinishDrain(!native_failed_);
  }
  void DrainDeadline() {
    if (finishing_ || consumer_ != Consumer::kDraining) return;
    base::ListValue ids;
    for (const auto& [id, route] : routes_)
      if (route->withdrawn && !route->removed)
        ids.Append(route->native);
    Native("finalRemove", Envelope().Set("ids", std::move(ids)), {});
    FinishDrain(false);
  }
  void FinishDrain(bool settled) {
    if (finishing_) return;
    finishing_ = true;
    FlushDeferredQueries();
    CHECK(queries_.empty());
    CHECK(deferred_queries_.empty());
    drain_settled_ = settled;
    weak_.InvalidateWeakPtrs();
    events_.clear();
    queued_bytes_ = 0;
    base::ListValue unresolved_ids;
    base::ListValue unresolved_operations;
    size_t evidence_bytes = 0;
    size_t unresolved_count = 0;
    bool truncated = false;
    auto append = [&](base::ListValue& list, const std::string& id) {
      if (evidence_bytes + id.size() + 8 > kMaxCoverage) { truncated = true; return; }
      evidence_bytes += id.size() + 8;
      list.Append(id);
    };
    for (const auto& [id, route] : routes_) {
      if (!route->withdrawn || route->removed) continue;
      ++unresolved_count;
      append(unresolved_ids, route->native);
    }
    for (const auto& [id, operation] : native_ops_) append(unresolved_operations, id);
    Coverage("drain-complete", base::DictValue().Set("settled", settled)
        .Set("state", "Closed").Set("truncated", truncated)
        .Set("complete", !truncated).Set("unresolvedIDCount", static_cast<int>(unresolved_count))
        .Set("unresolvedOperationCount", static_cast<int>(native_ops_.size()))
        .Set("unresolvedIDs", std::move(unresolved_ids))
        .Set("unresolvedOperations", std::move(unresolved_operations)));
    Coverage("coverage-end", base::DictValue().Set("settled", settled));
    auto controls = std::move(native_ops_);
    native_ops_.clear();
    native_bytes_ = 0;
    {
      std::lock_guard<std::mutex> guard(g_native_runner_lock);
      g_native_runner = nullptr;
    }
    g_control = nullptr;
    g_event = nullptr;
    controls.clear();
    auto retire = std::exchange(g_transport_retire, nullptr);
    auto release = std::exchange(g_transport_release, nullptr);
    void* context = std::exchange(g_transport_context, nullptr);
    if (retire) retire(context);
    if (release) release(context);
    consumer_ = Consumer::kClosed;
    auto continuations = std::move(quit_);
    for (auto& continuation : continuations) std::move(continuation).Run();
  }
  void AbortStartup() {
    if (consumer_ == Consumer::kClosed) return;
    consumer_ = Consumer::kClosed;
    finishing_ = true;
    weak_.InvalidateWeakPtrs();
    events_.clear();
    queued_bytes_ = 0;
    auto queries = TakeQueries();
    for (auto& query : queries) std::move(query.callback).Run({}, false);
    FlushDeferredQueries();
    while (!actions_.empty()) FinishAction(actions_.begin()->first, false, "startupAborted");
    native_ops_.clear();
    native_bytes_ = 0;
  }
  void DebugDisplayed(const base::DictValue& args, NotificationReply reply) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    const GURL origin(String(args, "origin"));
    if (!Keys(args, {"profile", "origin"}) || !Text(args, "profile", 4096) ||
        !origin.is_valid() || Closed()) {
      reply.Send(Rejected("invalidDisplayedDebugRequest"));
      return;
    }
    for (const auto& [profile, id] : loaded_) {
      auto* scope = FindScope(id);
      if (!profile || !scope || !scope->active || !scope->validated ||
          scope->path.value() != String(args, "profile") ||
          !scope->session.empty()) continue;
      NotificationDisplayServiceImpl::GetForProfile(profile)->GetDisplayedForOrigin(
          origin, base::BindOnce([](NotificationReply response,
                                   std::set<std::string> ids, bool synchronized) {
            base::ListValue values;
            for (const auto& id : ids) values.Append(id);
            response.Send(base::DictValue().Set("completed", true)
                .Set("supportsSynchronization", synchronized)
                .Set("ids", std::move(values)));
          }, std::move(reply)));
      return;
    }
    reply.Send(Rejected("profileNotLoaded"));
  }
  base::DictValue Debug() {
    auto value = Envelope().Set("state", State(consumer_))
        .Set("protocol", 2).Set("nativeApi", 37).Set("abi", 2)
        .Set("queryCount", static_cast<int>(queries_.size()))
        .Set("nativeOperationCount", static_cast<int>(native_ops_.size()))
        .Set("bootstrapCount", static_cast<int>(bootstrap_))
        .Set("nativeFailed", native_failed_)
        .Set("drainSettled", drain_settled_)
        .Set("scopeCount", static_cast<int>(scopes_.size()))
        .Set("scopePressure", scope_pressure_)
        .Set("processRegistered", process_registered_)
        .Set("providerAttempts", base::DictValue()
            .Set("alertLaunch", Number(g_alert_attempts.load()))
            .Set("bannerBind", Number(g_banner_attempts.load()))
            .Set("appShimBind", Number(g_shim_attempts.load()))
            .Set("providerBind", Number(g_provider_binds.load())))
        .Set("hooksInstalled", g_hooks_installed.load())
        .Set("coverage", CoverageSnapshot());
    base::ListValue routes;
    size_t bytes = 0;
    for (const auto& [id, route] : routes_) {
      auto item = Entry(*route);
      const auto size = JSON(item).size();
      if (bytes + size > kMaxJSON / 2) { value.Set("truncated", true); break; }
      bytes += size;
      routes.Append(std::move(item));
    }
    value.Set("routes", std::move(routes));
    base::ListValue scopes;
    for (const auto& [id, scope] : scopes_) {
      auto item = scope->Envelope();
      item.Set("active", scope->active);
      item.Set("settled", scope->settled);
      const auto size = JSON(item).size();
      if (bytes + size > kMaxJSON * 3 / 4) { value.Set("truncated", true); break; }
      bytes += size;
      scopes.Append(std::move(item));
    }
    value.Set("scopes", std::move(scopes));
    return value;
  }

 private:
  const std::string bridge_ = Token();
  Consumer consumer_ = Consumer::kNoConsumer;
  int attached_ = 0;
  uint64_t mutation_ = 0;
  uint64_t epoch_ = 0;
  uint64_t watch_transition_ = 0;
  uint64_t native_revision_ = 0;
  uint64_t high_water_ = 0;
  uint64_t applied_ = 0;
  uint64_t watch_base_ = 0;
  std::string watch_;
  std::string snapshot_id_;
  std::string snapshot_hash_;
  size_t snapshot_count_ = 0;
  size_t bootstrap_ = 0;
  bool process_registered_ = false;
  bool scope_pressure_ = false;
  bool native_failed_ = false;
  bool drain_native_complete_ = false;
  bool drain_settled_ = false;
  bool finishing_ = false;
  std::map<std::string, std::unique_ptr<Scope>> scopes_;
  std::map<Profile*, std::string> loaded_;
  std::map<std::string, std::unique_ptr<Route>> routes_;
  std::map<std::string, std::string> current_;
  std::map<std::string, Query> queries_;
  std::vector<Query> deferred_queries_;
  std::map<std::string, std::unique_ptr<Action>> actions_;
  std::map<std::string, NativeOperation> native_ops_;
  uint64_t native_ticket_ = 0;
  std::set<std::string> seen_actions_;
  std::deque<std::string> completed_actions_;
  std::set<std::string> loading_;
  std::map<base::FilePath, std::string> pending_loads_;
  std::set<base::FilePath> deleted_paths_;
  std::set<base::FilePath> admitted_deletions_;
  std::map<base::FilePath, ProfileIdentity> identities_;
  std::string root_namespace_;
  bool root_ready_ = false;
  bool purging_ = false;
  uint64_t event_ticket_ = 0;
  std::map<uint64_t, std::string> events_;
  size_t native_bytes_ = 0;
  size_t resource_bytes_ = 0;
  size_t state_bytes_ = 0;
  size_t queued_bytes_ = 0;
  std::vector<base::OnceClosure> quit_;
  base::WeakPtrFactory<Coordinator> weak_{this};
};

class SolaraNotificationPlatformBridge final : public NotificationPlatformBridge {
 public:
  SolaraNotificationPlatformBridge() { Coordinator::Get().Attach(); }
  ~SolaraNotificationPlatformBridge() override { Coordinator::Get().Detach(); }
  void Display(NotificationHandler::Type type, Profile* profile,
               const message_center::Notification& notification,
               std::unique_ptr<NotificationCommon::Metadata> metadata) override {
    Coordinator::Get().Display(type, profile, notification, std::move(metadata));
  }
  void Close(Profile* profile, const std::string& id) override {
    Coordinator::Get().Close(profile, id);
  }
  void GetDisplayed(Profile* profile,
                    GetDisplayedNotificationsCallback callback) const override {
    Coordinator::Get().QueryDisplayed(profile, std::nullopt, std::move(callback));
  }
  void GetDisplayedForOrigin(Profile* profile, const GURL& origin,
                    GetDisplayedNotificationsCallback callback) const override {
    Coordinator::Get().QueryDisplayed(profile, origin, std::move(callback));
  }
  void SetReadyCallback(NotificationBridgeReadyCallback callback) override {
    std::move(callback).Run(true);
  }
  void DisplayServiceShutDown(Profile* profile) override {
    ReleaseNotificationProfile(profile, !profile
        ? NotificationReleaseReason::kSystemShutdown
        : profile->IsOffTheRecord() ? NotificationReleaseReason::kPrivateEnd
                                   : NotificationReleaseReason::kProfileUnload);
  }
};

}

std::unique_ptr<NotificationPlatformBridge> CreateNotificationPlatformBridge() {
  CHECK(NotificationBridgeConfigured());
  return std::make_unique<SolaraNotificationPlatformBridge>();
}
bool NotificationBridgeConfigured() { return g_control && g_event; }
void InitializeNotificationBridgeCoverage() {
  CHECK(NotificationBridgeConfigured());
  {
    std::lock_guard<std::mutex> guard(g_coverage_lock);
    if (g_coverage_initialized) return;
    g_coverage_initialized = true;
    g_coverage_nonce = Token();
  }
  Coverage("coverage-start");
}
void NotificationHooksInstalled() {
  CHECK(!g_hooks_installed.exchange(true));
  Coverage("startup-complete", base::DictValue().Set("hooksInstalled", true));
}
void DisplayNotificationWithPrivateProvenance(Profile* exact_private,
    NotificationHandler::Type type, const message_center::Notification& notification,
    std::unique_ptr<NotificationCommon::Metadata> metadata) {
  if (!exact_private || !exact_private->IsOffTheRecord()) return;
  Coordinator::Get().Display(type, exact_private, notification, std::move(metadata));
}
void RegisterNotificationProfile(Profile* profile) {
  Coordinator::Get().Register(profile);
}
void ReleaseNotificationProfile(Profile* profile, NotificationReleaseReason reason) {
  Coordinator::Get().Release(profile, reason);
}
void ReleaseNotificationProfilePath(const base::FilePath& path,
    NotificationReleaseReason reason, base::OnceCallback<void(bool)> callback) {
  Coordinator::Get().ReleasePath(path, reason, std::move(callback));
}
void BeginNotificationDrain(base::OnceClosure continuation) {
  Coordinator::Get().Drain(std::move(continuation));
}
void RecordNotificationProviderAttempt(const char* kind) {
  const std::string_view value(kind ? kind : "");
  if (value == "alertLaunch") g_alert_attempts.fetch_add(1);
  else if (value == "bannerBind") g_banner_attempts.fetch_add(1);
  else if (value == "providerBind") g_provider_binds.fetch_add(1);
  else g_shim_attempts.fetch_add(1);
  Coverage("provider-attempt", base::DictValue().Set("provider", value));
}

}

extern "C" AC_ENGINE_EXPORT const char* ac_notifications_capabilities() {
  return R"({"abi":2,"notifications":2,"nativeApi":37,"customBridge":true,"allHandlerTypes":true,"featureFlagIndependent":true,"childRefusal":true,"directControls":true,"directDrain":true,"scopeFences":true,"profileFree":true,"requiresMatchingApp":true,"processLifetimeOnly":true,"contextLifetime":true,"startupAbort":true,"trustedAuthorizationEligibility":true,"synchronousAuthorizationEligibility":true})";
}
extern "C" AC_ENGINE_EXPORT int ac_notifications_register_transport(
    int protocol, ac_notifications_control_t control, ac_engine_event_t event,
    void* context, ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release,
    ac_notifications_context_lifetime_t retire) {
  if (protocol != 2 || !retain || !release || !retire || !control || !event ||
      solara::g_started.load() ||
      solara::g_control || solara::g_event) return false;
  solara::g_control = control;
  solara::g_event = event;
  retain(context);
  solara::g_transport_context = context;
  solara::g_transport_release = release;
  solara::g_transport_retire = retire;
  return true;
}
extern "C" AC_ENGINE_EXPORT void ac_notifications_abort_transport(void* expected_context) {
  if (!solara::g_transport_release || solara::g_transport_context != expected_context) return;
  solara::g_control = nullptr;
  solara::g_event = nullptr;
  {
    std::lock_guard<std::mutex> guard(solara::g_native_runner_lock);
    solara::g_native_runner = nullptr;
  }
  auto retire = std::exchange(solara::g_transport_retire, nullptr);
  auto release = std::exchange(solara::g_transport_release, nullptr);
  void* context = std::exchange(solara::g_transport_context, nullptr);
  solara::Coordinator::Get().AbortStartup();
  if (retire) retire(context);
  release(context);
}
extern "C" AC_ENGINE_EXPORT int ac_notifications_authorization_eligible(
    const char* route_json, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !solara::g_transport_release || solara::g_transport_context != context ||
      !solara::g_control || !solara::g_event) return false;
  auto args = solara::Parse(route_json);
  return args && solara::Coordinator::Get().AuthorizationEligible(*args);
}
extern "C" AC_ENGINE_EXPORT void ac_notifications_watch(
    const char*, const char* json, ac_engine_reply_t reply, void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release) {
  solara::NotificationReply response(reply, context, retain, release);
  auto args = solara::Parse(json);
  response.Send(args ? solara::Coordinator::Get().Watch(*args)
                     : solara::Rejected("invalidSchema"));
}
extern "C" AC_ENGINE_EXPORT void ac_notifications_control(
    const char*, const char* json, ac_engine_reply_t reply, void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release) {
  solara::NotificationReply response(reply, context, retain, release);
  auto args = solara::Parse(json);
  if (!args) { response.Send(solara::Rejected("invalidSchema")); return; }
  solara::Coordinator::Get().Control(std::move(*args), std::move(response));
}
extern "C" AC_ENGINE_EXPORT void ac_notifications_debug_snapshot(
    const char*, const char* json, ac_engine_reply_t reply, void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release) {
  solara::NotificationReply response(reply, context, retain, release);
  auto args = solara::Parse(json);
  response.Send(args && args->empty() ? solara::Coordinator::Get().Debug()
                                     : solara::Rejected("invalidSchema"));
}

extern "C" AC_ENGINE_EXPORT void ac_notifications_debug_displayed(
    const char*, const char* json, ac_engine_reply_t reply, void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release) {
  solara::NotificationReply response(reply, context, retain, release);
  auto args = solara::Parse(json);
  if (!args) { response.Send(solara::Rejected("invalidSchema")); return; }
  solara::Coordinator::Get().DebugDisplayed(*args, std::move(response));
}
