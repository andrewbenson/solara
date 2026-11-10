#import "../ios/SolaraCoreBookmarkURL.h"

#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"

#include <cstdio>
#include <vector>

static std::vector<uint16_t> received;
static int abi = AC_ENGINE_ABI_VERSION;
static int calls = 0;

extern "C" AC_ENGINE_EXPORT int ac_engine_abi_version(void) { return abi; }

extern "C" AC_ENGINE_EXPORT int ac_bookmarks_canonicalize_url_v1(
    const uint16_t *units, size_t length, ac_bookmark_url_reply_t reply, void *context) {
  ++calls;
  received.assign(units, units + length);
  constexpr char result[] = "https://example.test/%EF%BF%BD";
  reply(context, result, sizeof(result) - 1);
  return AC_BOOKMARK_URL_VALID;
}

int main() {
  @autoreleasepool {
    const std::vector<uint16_t> expected = {'h', 't', 't', 'p', 's', ':', '/', '/',
      'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 't', 'e', 's', 't', '/', 0xd800, 'x', 0xdfff, 'y',
      0xd83d, 0xde00, 0xdb80, 0xdc00};
    NSData *bytes = [NSData dataWithBytes:expected.data() length:expected.size() * sizeof(uint16_t)];
    NSError *error = nil;
    NSString *value = SolaraCanonicalBookmarkURLUTF16(bytes, &error);
    if (error || ![value isEqualToString:@"https://example.test/%EF%BF%BD"] || received != expected || calls != 1) {
      std::printf("FAIL canonicalBookmarkURLPreservesUTF16Units\n");
      return 1;
    }
    const uint8_t odd = 0;
    value = SolaraCanonicalBookmarkURLUTF16([NSData dataWithBytes:&odd length:1], &error);
    if (value || ![error.domain isEqualToString:SolaraCoreBookmarkURLErrorDomain] || calls != 1) {
      std::printf("FAIL malformedBookmarkURLUnitsNeverReachEngine\n");
      return 1;
    }
    abi = AC_ENGINE_ABI_VERSION + 1;
    value = SolaraCanonicalBookmarkURLUTF16(bytes, &error);
    if (value || error.code != SolaraCoreBookmarkURLUnavailable || calls != 1) {
      std::printf("FAIL bookmarkURLUnitsRespectFrameworkSkew\n");
      return 1;
    }
  }
  std::printf("bookmark-url-units: ok\n");
  return 0;
}
