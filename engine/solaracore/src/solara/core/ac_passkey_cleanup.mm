#include "solara/core/ac_passkey_cleanup.h"

#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

#include <optional>
#include <string>
#include <utility>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/json/json_reader.h"
#include "base/posix/eintr_wrapper.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/webauthn/webauthn_pref_names.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/common/chrome_version.h"
#include "components/os_crypt/common/os_crypt_switches.h"
#include "components/prefs/pref_service.h"
#include "device/fido/mac/authenticator_config.h"
#include "device/fido/mac/credential_store.h"

namespace solaracore {
namespace {

using webauthn::pref_names::kWebAuthnTouchIdMetadataSecretPrefName;

std::optional<std::string> ReadMetadataSecret(ProfileManager& manager,
                                              const base::FilePath& path) {
  if (Profile* profile = manager.GetProfileByPath(
          manager.user_data_dir().Append(path.BaseName()))) {
    if (!profile->IsRegularProfile() || profile->ShutdownStarted()) {
      return std::nullopt;
    }
    return profile->GetPrefs()->GetString(kWebAuthnTouchIdMetadataSecretPrefName);
  }

  base::ScopedFD directory(HANDLE_EINTR(
      open(path.value().c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)));
  if (!directory.is_valid()) {
    return errno == ENOENT ? std::optional(std::string()) : std::nullopt;
  }
  base::ScopedFD file(HANDLE_EINTR(
      openat(directory.get(), chrome::kPreferencesFilename,
             O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)));
  if (!file.is_valid()) {
    return errno == ENOENT ? std::optional(std::string()) : std::nullopt;
  }
  struct stat info;
  constexpr off_t kMaxPreferencesBytes = 16 * 1024 * 1024;
  if (fstat(file.get(), &info) != 0 || !S_ISREG(info.st_mode) ||
      info.st_nlink != 1 || info.st_size < 0 ||
      info.st_size > kMaxPreferencesBytes) {
    return std::nullopt;
  }
  std::string json(info.st_size, '\0');
  if (!base::ReadFromFD(file.get(), base::span(json))) {
    return std::nullopt;
  }
  auto preferences = base::JSONReader::ReadDict(
      json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!preferences) {
    return std::nullopt;
  }
  const base::Value* metadata =
      preferences->FindByDottedPath(kWebAuthnTouchIdMetadataSecretPrefName);
  if (!metadata) {
    return std::string();
  }
  if (!metadata->is_string()) {
    return std::nullopt;
  }
  return metadata->GetString();
}

}

bool RemoveProfilePasskeys(ProfileManager& manager, const base::FilePath& path) {
  NSString* root = base::SysUTF8ToNSString(manager.user_data_dir().value())
                       .stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString* name = base::SysUTF8ToNSString(path.BaseName().value());
  if (!path.IsAbsolute() || path.ReferencesParent() ||
      ![base::SysUTF8ToNSString(path.DirName().value()) isEqualToString:root] ||
      (![name isEqualToString:@"Default"] && ![name hasPrefix:@"Profile "])) {
    return false;
  }
  auto encoded = ReadMetadataSecret(manager, path);
  if (!encoded) {
    return false;
  }
  if (encoded->empty()) {
    return true;
  }
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          os_crypt::switches::kUseMockKeychain)) {
    return false;
  }
  std::string secret;
  if (!base::Base64Decode(*encoded, &secret) || secret.size() != 32) {
    return false;
  }
  NSArray<NSString*>* siblings =
      [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
  if (!siblings) {
    return false;
  }
  for (NSString* sibling in siblings) {
    if ([sibling isEqualToString:name] ||
        (![sibling isEqualToString:@"Default"] && ![sibling hasPrefix:@"Profile "])) {
      continue;
    }
    auto other = ReadMetadataSecret(
        manager, path.DirName().Append(base::SysNSStringToUTF8(sibling)));
    if (!other) {
      return false;
    }
    std::string other_secret;
    if (base::Base64Decode(*other, &other_secret) && secret == other_secret) {
      return false;
    }
  }
  device::fido::mac::TouchIdCredentialStore store({
      .keychain_access_group =
          MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn",
      .metadata_secret = std::move(secret),
  });
  return store.DeleteCredentialsSync(base::Time(), base::Time::Max());
}

}
