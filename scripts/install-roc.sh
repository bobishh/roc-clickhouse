#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$root/.roc-version")
destination=${1:?usage: scripts/install-roc.sh DESTINATION}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux_x86_64; digest=e1be77f68bc71b1422e66810f3a57230b26b6c46ee95af8e7ee6027fccab94c0 ;;
    Darwin-arm64) platform=macos_apple_silicon; digest=a1035f23a8c2ac80b804a3f6b806a05fb87f6844202a50bbb71adb05b098b131 ;;
    *) echo 'Use the pinned compiler from https://github.com/roc-lang/nightlies/releases' >&2; exit 1 ;;
esac
mkdir -p "$destination"
archive="$destination/compiler.tar.gz"
curl --fail --location --retry 3 "https://github.com/roc-lang/nightlies/releases/download/$version/roc_nightly-$platform-${version#nightly-}.tar.gz" --output "$archive"
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
test "$actual" = "$digest"
tar -xzf "$archive" -C "$destination" --strip-components=1
"$destination/roc" version
