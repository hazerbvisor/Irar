#!/bin/bash
# Build only libarchive, without CLI programs or optional binary dependencies.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${IRAR_ARCHIVE_BUILD_DIR:-${TARGET_TEMP_DIR:?Run from Xcode or set IRAR_ARCHIVE_BUILD_DIR}/libarchive}
HOST_TEST=${IRAR_ARCHIVE_HOST_TEST:-0}
ARCH=${CURRENT_ARCH:-}
if [[ "$HOST_TEST" != 1 && ( -z "$ARCH" || "$ARCH" == undefined_arch ) ]]; then
  libraries=()
  for selected_arch in ${ARCHS:-arm64}; do
    IRAR_ARCHIVE_BUILD_DIR="$OUT-$selected_arch" CURRENT_ARCH="$selected_arch" "$0"
    libraries+=("$OUT-$selected_arch/libarchive.a")
  done
  mkdir -p "$OUT"
  "$(xcrun --find libtool)" -static -o "$OUT/libarchive.a" "${libraries[@]}"
  cp "$OUT-$selected_arch/archive.h" "$OUT-$selected_arch/archive_entry.h" "$OUT/"
  exit 0
fi
PACKAGE="$REPO/vendor/libarchive-3.8.7.tar.xz"
echo 'd3a8ba457ae25c27c84fd2830a2efdcc5b1d40bf585d4eb0d35f47e99e5d4774  '"$PACKAGE" | shasum -a 256 -c -
if [[ "$HOST_TEST" == 1 ]]; then
  SDK=host; ARCH=${ARCH:-$(uname -m)}
  export CC=${IRAR_HOST_CC:-cc} CFLAGS="-O2 -fPIC" CPPFLAGS="" LDFLAGS=""
  CONFIG_HOST=()
else
  SDK=${SDKROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}
  MINFLAG=-miphoneos-version-min=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}
  [[ ${PLATFORM_NAME:-iphoneos} != iphonesimulator ]] || MINFLAG=-mios-simulator-version-min=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}
  export CC="$(xcrun --find clang)"
  export CFLAGS="-arch $ARCH -isysroot $SDK $MINFLAG -O2"
  export CPPFLAGS="-isysroot $SDK" LDFLAGS="-arch $ARCH -isysroot $SDK $MINFLAG"
  CONFIG_HOST=(--host="$ARCH-apple-darwin")
fi
STAMP="$SDK/$ARCH/${IPHONEOS_DEPLOYMENT_TARGET:-17.0}/$(shasum -a 256 "$0" "$REPO/Irar/Core/ArchiveBridge.c" "$REPO/Irar/Core/ArchiveBridge.h" | shasum -a 256 | cut -d ' ' -f1)"
if [[ -f "$OUT/stamp" && "$(cat "$OUT/stamp")" == "$STAMP" && -f "$OUT/libarchive.a" ]]; then exit 0; fi
mkdir -p "$OUT"
rm -rf "$OUT/source" "$OUT/obj"
mkdir -p "$OUT/source" "$OUT/obj"
tar -xf "$PACKAGE" -C "$OUT/source" --strip-components=1
cd "$OUT/obj"
export PKG_CONFIG=/usr/bin/false
../source/configure "${CONFIG_HOST[@]}" --enable-static --disable-shared \
  --disable-bsdtar --disable-bsdcat --disable-bsdcpio --disable-bsdunzip \
  --disable-acl --disable-xattr --without-openssl --without-cng --without-xml2 \
  --without-expat --without-libb2 --without-lz4 --without-zstd --without-iconv \
  --without-lzma --without-bz2lib
make -j "${IRAR_BUILD_JOBS:-4}" libarchive.la
cp .libs/libarchive.a "$OUT/libarchive.a"
cp ../source/libarchive/archive.h ../source/libarchive/archive_entry.h "$OUT/"
if [[ "$HOST_TEST" == 1 ]]; then
  "$CC" -shared -fPIC -Wall -Wextra -Werror -I "$OUT/source/libarchive" \
    "$REPO/Irar/Core/ArchiveBridge.c" "$OUT/libarchive.a" -lz -o "$OUT/libirar-archive.so"
fi
printf '%s' "$STAMP" > "$OUT/stamp"
