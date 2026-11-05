#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$root/.roc-version")
destination=${1:?usage: scripts/install-roc.sh DESTINATION}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux_x86_64; digest=48ad051270b4a6585b3a246ed4f1374cc521ddd1f98b7e11820c6077bcad3071 ;;
    Darwin-arm64) platform=macos_apple_silicon; digest=dc510524486b2f04f042187622753af055225c0173bb540bfd63e85c70d2d611 ;;
    *) echo 'Use the pinned compiler from https://github.com/roc-lang/nightlies/releases' >&2; exit 1 ;;
esac
mkdir -p "$destination"
archive="$destination/compiler.tar.gz"
curl --fail --location --retry 3 "https://github.com/roc-lang/nightlies/releases/download/$version/roc_nightly-$platform-${version#nightly-}.tar.gz" --output "$archive"
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
test "$actual" = "$digest"
tar -xzf "$archive" -C "$destination" --strip-components=1
"$destination/roc" version
