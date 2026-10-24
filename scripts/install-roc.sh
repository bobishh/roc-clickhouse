#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$root/.roc-version")
destination=${1:?usage: scripts/install-roc.sh DESTINATION}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux_x86_64; digest=c283ae01e758b9d64002d72b8e4ad776466e7e6e5f495fd466e274afbd25ce7f ;;
    Darwin-arm64) platform=macos_apple_silicon; digest=668b2731c62ac9054ecf5cd4d483638c237626517df6c076204870065a103b38 ;;
    *) echo 'Use the pinned compiler from https://github.com/roc-lang/nightlies/releases' >&2; exit 1 ;;
esac
mkdir -p "$destination"
archive="$destination/compiler.tar.gz"
curl --fail --location --retry 3 "https://github.com/roc-lang/nightlies/releases/download/$version/roc_nightly-$platform-${version#nightly-}.tar.gz" --output "$archive"
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
test "$actual" = "$digest"
tar -xzf "$archive" -C "$destination" --strip-components=1
"$destination/roc" version
