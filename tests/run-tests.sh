#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
export IRAR_ARCHIVE_HOST_TEST=1 IRAR_ARCHIVE_BUILD_DIR="$TEMP/archive"
if ! "$REPO/scripts/build-libarchive.sh" > "$TEMP/build.log" 2>&1; then tail -100 "$TEMP/build.log"; exit 1; fi
python3 "$REPO/tests/check-archives.py" "$TEMP/archive/libirar-archive.so" "$TEMP/archive/source"
cc -Wall -Wextra -Werror -I "$TEMP/archive/source/libarchive" -c "$REPO/Irar/Core/ArchiveBridge.c" -o "$TEMP/bridge.o"
swiftc -swift-version 5 -warnings-as-errors -import-objc-header "$REPO/Irar/Core/ArchiveBridge.h" \
  "$REPO/Irar/Core/FileStore.swift" "$REPO/Irar/Core/ArchiveService.swift" \
  "$REPO/tests/FileStoreTests.swift" "$TEMP/bridge.o" "$TEMP/archive/libarchive.a" -lz -o "$TEMP/swift-tests"
python3 - "$TEMP/service.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('setup.exe', b'MZ')
    archive.writestr('data', b'hello')
PY
"$TEMP/swift-tests" "$TEMP/service.zip"
swiftc -frontend -parse "$REPO/Irar/IrarApp.swift" "$REPO/Irar/UI/"*.swift
python3 "$REPO/tests/check-project.py"
echo 'PASS: backend, storage, Swift/C integration, UI syntax and project inputs'
