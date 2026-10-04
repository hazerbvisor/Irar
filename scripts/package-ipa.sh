#!/bin/bash
# Package an unsigned device build for re-signing by a sideloader.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$REPO/build/DerivedData/Build/Products/Release-iphoneos/Irar.app}
OUT=${2:-$REPO/build/Irar-unsigned.ipa}
[[ -d "$APP" ]] || { echo "Missing built app: $APP" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload" "$(dirname "$OUT")"
ditto "$APP" "$WORK/Payload/Irar.app"
ditto -c -k --sequesterRsrc --keepParent "$WORK/Payload" "$OUT"
echo "Unsigned IPA: $OUT (re-sign with your sideloader before installation)"
