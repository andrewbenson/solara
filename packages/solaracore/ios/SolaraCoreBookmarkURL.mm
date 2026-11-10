#import "SolaraCoreBookmarkURL.h"

#import <dlfcn.h>

#include <vector>

#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"

NSErrorDomain const SolaraCoreBookmarkURLErrorDomain = @"SolaraCoreBookmarkURL";

namespace {

struct CanonicalReply {
  NSUInteger calls = 0;
  NSString *value = nil;
};

void Canonicalized(void *context, const char *utf8, size_t length) {
  auto *reply = static_cast<CanonicalReply *>(context);
  ++reply->calls;
  reply->value = utf8 && length
      ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
      : nil;
}

NSString *Failed(NSError **error, SolaraCoreBookmarkURLError code, NSString *message) {
  if (error) *error = [NSError errorWithDomain:SolaraCoreBookmarkURLErrorDomain code:code
                                   userInfo:@{NSLocalizedDescriptionKey: message}];
  return nil;
}

}

NSString *SolaraCanonicalBookmarkURL(NSString *url, NSError **error) {
  if (error) *error = nil;
  auto version = reinterpret_cast<ac_engine_abi_version_t>(dlsym(RTLD_DEFAULT, "ac_engine_abi_version"));
  auto canonicalize = reinterpret_cast<ac_bookmarks_canonicalize_url_v1_t>(
      dlsym(RTLD_DEFAULT, "ac_bookmarks_canonicalize_url_v1"));
  if (!version || version() != AC_ENGINE_ABI_VERSION || !canonicalize)
    return Failed(error, SolaraCoreBookmarkURLUnavailable, @"The engine does not support bookmark URL canonicalization.");
  std::vector<uint16_t> units(url.length);
  if (!units.empty()) [url getCharacters:units.data() range:NSMakeRange(0, url.length)];
  CanonicalReply reply;
  int status = canonicalize(units.data(), units.size(), Canonicalized, &reply);
  if (status == AC_BOOKMARK_URL_INVALID && reply.calls == 0)
    return Failed(error, SolaraCoreBookmarkURLInvalid, @"This URL cannot be saved as a bookmark.");
  if (status != AC_BOOKMARK_URL_VALID || reply.calls != 1 || !reply.value.length)
    return Failed(error, SolaraCoreBookmarkURLBadReply, @"The engine returned an invalid bookmark URL result.");
  return reply.value;
}

NSString *SolaraCanonicalBookmarkURLUTF16(NSData *bytes, NSError **error) {
  if (bytes.length % sizeof(uint16_t))
    return Failed(error, SolaraCoreBookmarkURLInvalid, @"The bookmark URL has incomplete UTF-16 code units.");
  std::vector<uint16_t> units(bytes.length / sizeof(uint16_t));
  if (!units.empty()) [bytes getBytes:units.data() length:bytes.length];
  NSString *url = [[NSString alloc] initWithCharacters:units.data() length:units.size()];
  return SolaraCanonicalBookmarkURL(url, error);
}
