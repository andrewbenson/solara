export CB="${AC_CHROMIUM_BUILD:-$HOME/chromium-build}"
_ac_repo="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
[[ -f "$_ac_repo/engine/patches/series" ]] || _ac_repo="$HOME/Documents/solara"
export AC_REPO="${AC_REPO:-$_ac_repo}"
unset _ac_repo
export DEPOT_TOOLS_UPDATE=0
export PATH="$CB/depot_tools:$PATH"
export CHROMIUM_VERSION=157.0.8103.50
export CHROMIUM_COMMIT=049750111b1e5c11565c792b2aeed5541f332bad
export SISO_VERSION=git_revision:dfc32e4edca158cff2b64a1658ee3940f0116b3a
export HELIUM_TAG=0.21.2
export HELIUM_MACOS_TAG=0.21.2.1
export HELIUM_DIR="$CB/helium"
export HELIUM_MACOS_DIR="$CB/helium-macos"
export GN_OUT_CONFIGS=Release_GN_arm64
lowprio() { taskpolicy -b nice -n 19 "$@"; }
lowprio_net() { taskpolicy -c utility -d throttle nice -n 19 "$@"; }
export DEPOT_TOOLS_METRICS=0
