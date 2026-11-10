#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Scripts/Progress.command
build_started=$SECONDS
mkdir -p .build dist
stage="$(mktemp -d "$PWD/.build/build.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Super Bar.app"
bundle="$app/Contents"
mkdir -p "$bundle"/{MacOS,Resources} .build/modules
sources=()
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find Sources -name '*.swift' -print0)
step "Compiling Super Bar (optimized Swift)" xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$(uname -m)-apple-macosx15.0" -module-cache-path .build/modules -import-objc-header Sources/Bluetti/Bluetooth/BluettiPOSIX.h "${sources[@]}" -o "$bundle/MacOS/SuperBar"
printf "▶ Preparing resources and metadata\n"
cp Info.plist "$bundle/"
cp Resources/* "$bundle/Resources/"
build="$(date -u +%s)"
previous="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' 'dist/Super Bar.app/Contents/Info.plist' 2>/dev/null || true)"
if [[ "$previous" =~ ^[0-9]+$ ]] && (( previous >= build )); then build=$((previous + 1)); fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$bundle/Info.plist"
plutil -lint "$bundle/Info.plist" >/dev/null
step "Signing the application" codesign --force --sign - "$app"
step "Verifying the signature" codesign --verify --deep --strict "$app"
# Publish a complete bundle and restore the previous bundle if publication fails.
if [[ -e 'dist/Super Bar.app' ]]; then mv 'dist/Super Bar.app' "$stage/previous.app"; fi
if ! mv "$app" 'dist/Super Bar.app'; then
  [[ ! -e "$stage/previous.app" ]] || mv "$stage/previous.app" 'dist/Super Bar.app'
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/Super Bar.app/Contents/Info.plist')"
printf 'Built Super Bar %s (%s).\n' "$version" "$build"

printf "✓ Complete build — %s s\n" "$((SECONDS - build_started))"
