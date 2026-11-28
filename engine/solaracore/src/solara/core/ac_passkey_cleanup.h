#ifndef SOLARA_CORE_AC_PASSKEY_CLEANUP_H_
#define SOLARA_CORE_AC_PASSKEY_CLEANUP_H_

namespace base {
class FilePath;
}

class ProfileManager;

namespace solaracore {

bool RemoveProfilePasskeys(ProfileManager& manager, const base::FilePath& path);

}

#endif
