#!/usr/bin/env bash
# One-time build environment setup for FreeGrid on Fedora (armv7 / iOS 9.3 SDK).
# Needs these packages first (run yourself): sudo dnf install dpkg fakeroot perl-core git curl xz
set -euo pipefail
export THEOS="${THEOS:-$HOME/theos}"

# 1. Theos
[ -d "$THEOS" ] || git clone --recursive --depth 1 https://github.com/theos/theos.git "$THEOS"

# 2. Linux iOS toolchain (clang 11 + ld64, supports armv7)
if [ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]; then
  curl -sL "https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-$(uname -m).tar.xz" \
    | tar -xJf - -C "$THEOS/toolchain/"
fi

# 3. iOS 9.3 SDK
[ -d "$THEOS/sdks/iPhoneOS9.3.sdk" ] || "$THEOS/bin/install-sdk" iPhoneOS9.3

# 4. The 9.3 SDK lacks this stub, which libSystem re-exports: without it linking fails
#    with "file not found: /usr/lib/system/liblaunch.dylib for architecture armv7".
cp "$(dirname "$0")/liblaunch.tbd" "$THEOS/sdks/iPhoneOS9.3.sdk/usr/lib/system/liblaunch.tbd"
echo "OK. Build with:  THEOS=$THEOS make package FINALPACKAGE=1"
