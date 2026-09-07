#!/bin/bash
set -euo pipefail

# Builds both outputs with one command:
# 1) unsigned IPA for local/user signing workflows
# 2) signed App Store IPA for Transporter/App Store Connect upload
# Optional local overrides can be placed in build-tvos.private.env.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-"$REPO_ROOT"}"
APP_NAME="Moonfin"
ARCHIVE_DIR="$REPO_ROOT/build/tvos/archive"
IPA_DIR="$REPO_ROOT/build/tvos/ipa"
ROOT_IPA_OUTPUT=""
ROOT_UNSIGNED_IPA_OUTPUT=""
TVOS_CODESIGN="${TVOS_CODESIGN:-"0"}"

# Optional local overrides for private values.
PRIVATE_ENV_FILE="$REPO_ROOT/build-tvos.private.env"
if [ -f "$PRIVATE_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$PRIVATE_ENV_FILE"
fi

resolve_fluttertvos() {
  if [ -n "${FLUTTERTVOS_BIN:-}" ] && [ -x "$FLUTTERTVOS_BIN" ]; then
    printf '%s\n' "$FLUTTERTVOS_BIN"
    return 0
  fi

  if command -v flutter-tvos >/dev/null 2>&1; then
    command -v flutter-tvos
    return 0
  fi

  local candidates=(
    "$HOME/flutter-tvos/bin/flutter-tvos"
    "$HOME/Documents/flutter-tvos/bin/flutter=tvos"
    "$HOME/snap/flutter-tvos/common/flutter-tvos/bin/flutter-tvos"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Error: flutter-tvos not found. Add flutter-tvos to PATH or set FLUTTERTVOS_BIN to the full flutter executable path." >&2
  exit 1
}

FLUTTERTVOS="$(resolve_fluttertvos)"
FLUTTERTVOS_ROOT=$(/usr/bin/dirname "$(/usr/bin/dirname "$FLUTTERTVOS")")
export PATH="$FLUTTERTVOS_ROOT/bin:$FLUTTERTVOS_ROOT/flutter/bin:$PATH"
TVOS_EXPORT_METHOD="${TVOS_EXPORT_METHOD:-app-store}"
TVOS_EXPORT_OPTIONS_PLIST="${TVOS_EXPORT_OPTIONS_PLIST:-}"

if [ "$#" -gt 0 ]; then
  echo "Error: this script no longer accepts positional arguments." >&2
  echo "Run: ./build-tvos.sh" >&2
  exit 1
fi

if [ -n "$TVOS_EXPORT_OPTIONS_PLIST" ] && [[ "$TVOS_EXPORT_OPTIONS_PLIST" != /* ]]; then
  TVOS_EXPORT_OPTIONS_PLIST="$REPO_ROOT/$TVOS_EXPORT_OPTIONS_PLIST"
fi

for cmd in xcodebuild zip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

APP_VERSION=$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version:[[:space:]]*//' | cut -d'+' -f1 | tr -d '[:space:]')
if [ -z "$APP_VERSION" ]; then
  echo "Error: could not read version from pubspec.yaml" >&2
  exit 1
fi

ROOT_IPA_OUTPUT="$REPO_ROOT/${APP_NAME}_tvOS_v${APP_VERSION}.ipa"
ROOT_UNSIGNED_IPA_OUTPUT="$REPO_ROOT/${APP_NAME}_tvOS_v${APP_VERSION}_unsigned.ipa"

echo "${APP_NAME} version: ${APP_VERSION}"

cd "$REPO_ROOT"

echo "Cleaning previous Flutter outputs..."
"$FLUTTERTVOS" clean

echo "Resolving packages..."
"$FLUTTERTVOS" pub get

# The tool's own build stops before the app is signed, but by then it
# has written the project settings and the assets.
flutter-tvos build tvos --release --no-tree-shake-icons --dart-define=MOONFIN_TVOS=true || true
test -f tvos/Flutter/Generated.xcconfig
grep -q '^FLUTTER_ROOT=' tvos/Flutter/Generated.xcconfig ||
  echo "FLUTTER_ROOT=$FLUTTERTVOS_ROOT" >>tvos/Flutter/Generated.xcconfig

# The flutter tool writes the plugin registry without a tvos section, so
# the pods it names have to be put back before CocoaPods reads it, or the
# Runner links against nothing.
LC_ALL=en_US.UTF-8 python3 tvos/scripts/restore_tvos_plugins.py
(cd tvos && pod install)

# Stage flutter_assets for the Xcode copy phase
DEST="tvos/Flutter/flutter_assets"
rm -rf "$DEST"
mkdir -p "$DEST"
SRC_APP=$(find build/tvos -maxdepth 3 -type d -path "*Release-appletvos/Runner.app/flutter_assets" | head -1)
if [ -n "$SRC_APP" ]; then
  rsync -a "$SRC_APP/" "$DEST/"
else
  rsync -a \
    --exclude='*-appletvos' --exclude='*-appletvsimulator' \
    --exclude='aot' --exclude='.last_build_id' \
    --exclude='kernel_blob.bin' --exclude='vm_snapshot_data' \
    --exclude='isolate_snapshot_data' \
    build/tvos/ "$DEST/"
fi
test -f "$DEST/fonts/MaterialIcons-Regular.otf" ||
  {
    echo "::error::MaterialIcons font missing from staged flutter_assets"
    exit 1
  }
test -f "$DEST/AssetManifest.bin" ||
  {
    echo "::error::AssetManifest.bin missing from staged flutter_assets"
    exit 1
  }

rm -f "$ROOT_IPA_OUTPUT"
rm -f "$ROOT_UNSIGNED_IPA_OUTPUT"
rm -f "$IPA_DIR"/*.ipa 2>/dev/null || true

if ! [ -v RUNNER_TEMP ]; then
  RUNNER_TEMP=$(mktemp -d)
fi
# Build unsigned app
xcodebuild \
  -workspace tvos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk appletvos \
  -derivedDataPath "$RUNNER_TEMP/dd" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build

# Build a signed IPA
# aka, Archive for App Store
if [ "$TVOS_CODESIGN" == "1" ]; then
  xcodebuild \
    -workspace tvos/Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=tvOS' \
    -archivePath "$RUNNER_TEMP/Runner.xcarchive" \
    -derivedDataPath "$RUNNER_TEMP/dd" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$MOONFIN_DEVELOPMENT_TEAM" \
    archive
  echo "Archive built in $RUNNER_TEMP/Runner.xcarchive"
  xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/Runner.xcarchive" -exportPath "$RUNNER_TEMP/ipa" -exportOptionsPlist "$REPO_ROOT/tvos/ExportOptions.plist"
  mv "$RUNNER_TEMP/ipa/moonfin.ipa" "$ROOT_IPA_OUTPUT"
  echo "Signed IPA saved to: $ROOT_IPA_OUTPUT"
fi

# App Store Connect rejects an App.framework whose Info.plist floor
# disagrees with the binary (ITMS-90208), and a build that lost the Top
# Shelf extension or its fonts is not worth shipping either way.
# Verify the app bundle
if [ "$TVOS_EXPORT_METHOD" == 'testflight' ] || [ "$TVOS_EXPORT_METHOD" == "development" ]; then
  APP="$RUNNER_TEMP/Runner.xcarchive/Products/Applications/Runner.app"
else
  APP="$RUNNER_TEMP/dd/Build/Products/Release-appletvos/Runner.app"
fi
test -d "$APP" || {
  echo "::error::no app bundle at $APP"
  exit 1
}
test -f "$APP/flutter_assets/fonts/MaterialIcons-Regular.otf" ||
  {
    echo "::error::Built app is missing flutter_assets fonts"
    exit 1
  }
test -e "$APP/PlugIns/MoonfinTopShelf.appex/MoonfinTopShelf" ||
  {
    echo "::error::Top Shelf extension missing from PlugIns"
    exit 1
  }
PLIST_MIN=$(plutil -extract MinimumOSVersion raw "$APP/Frameworks/App.framework/Info.plist")
BIN_MIN=$(vtool -show-build "$APP/Frameworks/App.framework/App" | awk '/minos/{print $2; exit}')
[ "$PLIST_MIN" = "$BIN_MIN" ] ||
  {
    echo "::error::App.framework MinimumOSVersion ($PLIST_MIN) != binary minos ($BIN_MIN) (ITMS-90208)"
    exit 1
  }

if [ "$TVOS_EXPORT_METHOD" != "testflight" ]; then
  rm -rf "$RUNNER_TEMP/Payload"
  mkdir -p "$RUNNER_TEMP/Payload"
  cp -R "$APP" "$RUNNER_TEMP/Payload/"
  (cd "$RUNNER_TEMP" && zip -qry "$ROOT_UNSIGNED_IPA_OUTPUT" Payload)
  echo "Unsigned IPA copied to root: $ROOT_UNSIGNED_IPA_OUTPUT"
  # if [ -v GITHUB_WORKSPACE ]; then
  #   (cd "$RUNNER_TEMP" && zip -qry "$GITHUB_WORKSPACE/Moonfin_tvOS_v${APP_VERSION}_unsigned.ipa" Payload)
  # else
  #   (cd "$RUNNER_TEMP" && zip -qry "$ROOT_UNSIGNED_IPA_OUTPUT" Payload)
  #   # echo "Unsigned tvOS archive created in: $ARCHIVE_DIR"
  #   # echo "Unsigned IPA created: $UNSIGNED_IPA_SOURCE"
  #   echo "Unsigned IPA copied to root: $ROOT_UNSIGNED_IPA_OUTPUT"
  # fi
fi

# # Provision the bundled libretro cores before the build, since pod install (run
# # by flutter build ipa) resolves moonfin_game_host's vendored_frameworks glob
# # then and would otherwise embed nothing. TVOS_CORES_MODE=fetch downloads
# # prebuilt cores for a dev build. The default builds them from pinned sources
# # with no JIT for the App Store. Set TVOS_CORES_FORCE=1 to reprovision.
# GAME_HOST_DIR="$REPO_ROOT/tvos/game_host"
# if [ ! -f "$GAME_HOST_DIR/cores/fceumm_libretro.framework/fceumm_libretro" ] || [ "${TVOS_CORES_FORCE:-0}" = "1" ]; then
#   echo "Provisioning bundled libretro cores (mode: ${TVOS_CORES_MODE:-build})..."
#   if [ "${TVOS_CORES_MODE:-build}" = "fetch" ]; then
#     "$GAME_HOST_DIR/fetch_cores.sh"
#   else
#     "$GAME_HOST_DIR/build_cores.sh"
#   fi
#   "$GAME_HOST_DIR/wrap_frameworks.sh"
# else
#   echo "Bundled libretro cores already present, skipping provisioning."
# fi
#
#
# echo "Building unsigned tvOS archive..."
# "$FLUTTERTVOS" build ipa --release --no-codesign \
#   --dart-define=DISTRIBUTION_CHANNEL=tvos_unsigned
#
# if [ ! -d "$ARCHIVE_DIR" ]; then
#   echo "Error: expected archive directory not found: $ARCHIVE_DIR" >&2
#   exit 1
# fi
#
# APP_IN_ARCHIVE="$(find "$ARCHIVE_DIR" -type d -path '*/Products/Applications/*.app' | head -n 1)"
# if [ -z "$APP_IN_ARCHIVE" ]; then
#   echo "Error: .app not found in archive at $ARCHIVE_DIR" >&2
#   exit 1
# fi
#
# mkdir -p "$IPA_DIR"
# UNSIGNED_IPA_SOURCE="$IPA_DIR/${APP_NAME}-unsigned.ipa"
# rm -f "$UNSIGNED_IPA_SOURCE"
#
# TMP_DIR="$(mktemp -d)"
# trap 'rm -rf "$TMP_DIR"' EXIT
# mkdir -p "$TMP_DIR/Payload"
# cp -R "$APP_IN_ARCHIVE" "$TMP_DIR/Payload/"
# (
#   cd "$TMP_DIR"
#   zip -qry "$UNSIGNED_IPA_SOURCE" Payload
# )
# cp "$UNSIGNED_IPA_SOURCE" "$ROOT_UNSIGNED_IPA_OUTPUT"
#
#
# if [ "$TVOS_CODESIGN" != "1" ]; then
#   exit
# else
#   if [ -n "$TVOS_EXPORT_OPTIONS_PLIST" ]; then
#     if [ ! -f "$TVOS_EXPORT_OPTIONS_PLIST" ]; then
#       echo "Error: export options plist not found: $TVOS_EXPORT_OPTIONS_PLIST" >&2
#       exit 1
#     fi
#     echo "Building signed App Store IPA with export options plist..."
#     "$FLUTTERTVOS" build ipa --release --export-options-plist="$TVOS_EXPORT_OPTIONS_PLIST" \
#       --dart-define=DISTRIBUTION_CHANNEL=tvos_signed
#   else
#     echo "Building signed App Store IPA with export method: $TVOS_EXPORT_METHOD"
#     "$FLUTTERTVOS" build ipa --release --export-method="$TVOS_EXPORT_METHOD" \
#       --dart-define=DISTRIBUTION_CHANNEL=tvos_signed
#   fi
#
#   IPA_SOURCE="$(find "$IPA_DIR" -maxdepth 1 -type f -name '*.ipa' ! -name '*-unsigned.ipa' | head -n 1)"
#   if [ -z "$IPA_SOURCE" ]; then
#     echo "Error: IPA not found in $IPA_DIR" >&2
#     exit 1
#   fi
#
#   cp "$IPA_SOURCE" "$ROOT_IPA_OUTPUT"
#
#   echo "IPA created: $IPA_SOURCE"
#   echo "IPA copied to root: $ROOT_IPA_OUTPUT"
#   echo "Export method: $TVOS_EXPORT_METHOD"
# fi
