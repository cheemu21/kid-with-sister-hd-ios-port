#!/bin/bash
# Build the iOS app (an unsigned .ipa) from your own copy of the game.
#
# The game code is recompiled here on the Mac from your cking.rpx and linked into the app, so the
# IPA holds game code: it is for your own devices only, never share it.
#
# usage:
#   tools/ios/build-ipa.sh --game DIR            an extracted game (DIR/code/cking.rpx, content/, meta/)
#   tools/ios/build-ipa.sh --image game.wux      a disc image: extracted first (game.key next to it and
#                                                your common key, see tools/wudextract.py)
# options:
#   --no-content      leave the game files out of the app (copy the game folder to the app's
#                     Documents as "game" with the Files app or Finder instead; smaller IPA)
#   --cpu NAME        -mcpu for the game code (default apple-a12: iPhone XS and newer)
#   --env FILE        KEY=VALUE lines baked in as the app's env.txt (WWHD_* switches)
#   --bundle-id ID    bundle identifier (default org.wwhdrecomp.ios)
#   --version V       app version (default 1.0)
#   -o FILE           output (default build/ios/WindWakerHD.ipa)
#   --sim             build for the iOS Simulator instead (a .app, no IPA; GPU features differ)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${PYTHON:-python3}"
GAME="" IMAGE="" CONTENT=1 CPU="apple-a12" ENVFILE="" BUNDLE_ID="org.wwhdrecomp.ios" VERSION="1.0"
OUT="$ROOT/build/ios/WindWakerHD.ipa" SIM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --game) GAME="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --no-content) CONTENT=0; shift ;;
    --cpu) CPU="$2"; shift 2 ;;
    --env) ENVFILE="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    --sim) SIM=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$ROOT/build/ios"

# 1. the game files
if [ -n "$IMAGE" ]; then
  GAME="$ROOT/build/ios/game"
  if [ ! -f "$GAME/code/cking.rpx" ]; then
    echo "== extracting $IMAGE"
    "$PY" "$ROOT/tools/wudextract.py" "$IMAGE" extract "$GAME"
  fi
fi
[ -n "$GAME" ] || { echo "give --game DIR or --image FILE (see --help)" >&2; exit 2; }
GAME="$(cd "$GAME" && pwd)"
RPX="$GAME/code/cking.rpx"
[ -f "$RPX" ] || { echo "no $RPX" >&2; exit 1; }

# 2. recompile the game code to C (build/gen), again only when the RPX or the recompiler changed
GEN="$ROOT/build/gen"
STAMP="$(shasum "$RPX" "$ROOT"/tools/recomp/*.py "$ROOT"/tools/recomp/*.txt "$ROOT"/tools/*.py | shasum | cut -c1-16)"
if [ ! -f "$GEN/.stamp" ] || [ "$(cat "$GEN/.stamp")" != "$STAMP" ]; then
  echo "== recompiling $RPX"
  rm -rf "$GEN"
  "$PY" "$ROOT/tools/recomp/recomp.py" "$RPX" "$GEN"
  echo "$STAMP" > "$GEN/.stamp"
fi

# 3. the app
if [ "$SIM" = 1 ]; then BDIR="$ROOT/build/ios/cmake-sim"; SYSROOT=iphonesimulator; else BDIR="$ROOT/build/ios/cmake"; SYSROOT=iphoneos; fi
echo "== building ($SYSROOT, $CPU)"
cmake -S "$ROOT" -B "$BDIR" -G "Unix Makefiles" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$SYSROOT \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_BUILD_TYPE=Release \
  -DWWHD_IOS_NO_GAME=OFF -DWWHD_IOS_CPU="$CPU" -DWWHD_BUNDLE_ID="$BUNDLE_ID" -DWWHD_IOS_VERSION="$VERSION" \
  -DGEN_DIR="$GEN" >/dev/null
make -C "$BDIR" -j"$(sysctl -n hw.ncpu)" wwhd

# 4. stage Payload/WWHD.app: game files, env.txt, signature
STAGE="$ROOT/build/ios/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
APP="$STAGE/Payload/WWHD.app"
ditto "$BDIR/WWHD.app" "$APP"
if [ "$CONTENT" = 1 ]; then
  echo "== copying the game files into the app"
  mkdir -p "$APP/game"
  for d in code content meta shadercache; do
    [ -d "$GAME/$d" ] && ditto "$GAME/$d" "$APP/game/$d"
  done
fi
[ -n "$ENVFILE" ] && cp "$ENVFILE" "$APP/env.txt"
# ad-hoc signature carrying the entitlements; sideloading tools re-sign with your certificate
codesign --force --sign - --entitlements "$ROOT/runtime/src/ios/wwhd.entitlements" --timestamp=none "$APP"

if [ "$SIM" = 1 ]; then
  echo "== done: $APP (xcrun simctl install booted \"$APP\")"
  exit 0
fi
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$STAGE" && zip -qry -1 "$OUT" Payload)
echo "== done: $OUT ($(du -h "$OUT" | cut -f1)) - it contains game code: keep it to yourself"
