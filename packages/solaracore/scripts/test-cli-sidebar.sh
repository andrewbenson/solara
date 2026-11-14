#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sidebar_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/solaracore-cli-sidebar.XXXXXX")
trap 'rm -rf "$sidebar_test_dir"' 0
clang++ -std=c++20 -Wall -Wextra -Werror ../../engine/chromium/tests/cli-sidebar-channel.test.cc -o "$sidebar_test_dir/channel"
"$sidebar_test_dir/channel"
clang++ -std=c++20 -Wall -Wextra -Werror -fobjc-arc -fblocks -framework Foundation -Wl,-export_dynamic tests/cli-sidebar-handler.test.mm ios/SolaraCoreCliSidebar.mm -o "$sidebar_test_dir/handler"
"$sidebar_test_dir/handler"
clang++ -std=c++20 -Wall -Wextra -Werror -fobjc-arc -fblocks -framework Foundation -DSOLARA_TEST_NO_SIDEBAR_EXPORT tests/cli-sidebar-handler.test.mm ios/SolaraCoreCliSidebar.mm -o "$sidebar_test_dir/absent-export"
"$sidebar_test_dir/absent-export"
