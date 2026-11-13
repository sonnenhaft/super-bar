#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
dev_credentials="${SUPER_BAR_DEV_CREDENTIALS:-0}"
case "$dev_credentials" in
  0|1) ;;
  *) printf 'SUPER_BAR_DEV_CREDENTIALS must be 0 or 1.\n' >&2; exit 1 ;;
esac
if [[ "$dev_credentials" == 1 && "${SUPER_BAR_RELEASE:-0}" == 1 ]]; then
  printf 'Release builds cannot enable development credential files.\n' >&2
  exit 1
fi
source Scripts/Progress.command
build_started=$SECONDS
mkdir -p .build dist
if [[ "$dev_credentials" == 1 ]]; then
  dev_credentials_directory="$PWD/.build/dev-credentials"
  if [[ -L "$dev_credentials_directory" ]]; then
    printf 'Development credential directory must not be a symlink.\n' >&2
    exit 1
  fi
  mkdir -p "$dev_credentials_directory"
  chmod 700 "$dev_credentials_directory"
fi
stage="$(mktemp -d "$PWD/.build/build.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Super Bar.app"
bundle="$app/Contents"
mkdir -p "$bundle"/{MacOS,Resources} .build/modules
# Compile a stable snapshot while other chats may be editing the workspace.
cp -R Sources "$stage/Sources"
sources=()
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find "$stage/Sources" -name '*.swift' -print0)
swift_flags=(-Osize -whole-module-optimization -Xlinker -dead_strip -swift-version 5 -target "$(uname -m)-apple-macosx15.0")
if [[ "$dev_credentials" == 1 ]]; then swift_flags+=(-D SUPER_BAR_DEV_CREDENTIALS); fi
step "Compiling Super Bar (optimized Swift)" xcrun swiftc "${swift_flags[@]}" -module-cache-path .build/modules -import-objc-header "$stage/Sources/Bluetti/Bluetooth/BluettiPOSIX.h" "${sources[@]}" -o "$bundle/MacOS/SuperBar"
printf "▶ Preparing resources and metadata\n"
cp Info.plist "$bundle/"
/usr/libexec/PlistBuddy -c "Add :SuperBarDevCredentials bool $dev_credentials" "$bundle/Info.plist"
cp Resources/* "$bundle/Resources/"
if [[ "$dev_credentials" == 1 ]]; then
  printf '%s' "$dev_credentials_directory" > "$bundle/Resources/development-credentials-path.txt"
fi
if [[ "${SUPER_BAR_RELEASE:-0}" != 1 ]]; then
  printf '%s' "$PWD/.env.deye-session.json" > "$bundle/Resources/deye-session-path.txt"
  printf '%s' "$PWD/.env.tuya-session.json" > "$bundle/Resources/tuya-session-path.txt"
  printf '%s' "$PWD/token.txt" > "$bundle/Resources/lg-session-path.txt"
fi
cp Scripts/TUYA-NOTICE.txt "$bundle/Resources/"
strip -x "$bundle/MacOS/SuperBar"
build="$(date -u +%s)"
previous="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' 'dist/Super Bar.app/Contents/Info.plist' 2>/dev/null || true)"
if [[ "$previous" =~ ^[0-9]+$ ]] && (( previous >= build )); then build=$((previous + 1)); fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$bundle/Info.plist"
plutil -lint "$bundle/Info.plist" >/dev/null
# Reuse the same certificate across updates so Keychain can recognize this app.
# Keep ad-hoc signing available for machines without a signing identity.
signing_identity="${SUPER_BAR_SIGNING_IDENTITY:--}"
step "Signing the application" codesign --force --sign "$signing_identity" "$app"
step "Verifying the signature" codesign --verify --deep --strict "$app"
# Publish a complete bundle and restore the previous bundle if publication fails.
if [[ -e 'dist/Super Bar.app' ]]; then mv 'dist/Super Bar.app' "$stage/previous.app"; fi
if ! mv "$app" 'dist/Super Bar.app'; then
  [[ ! -e "$stage/previous.app" ]] || mv "$stage/previous.app" 'dist/Super Bar.app'
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/Super Bar.app/Contents/Info.plist')"
printf 'Built Super Bar %s (%s).\n' "$version" "$build"
if [[ "$dev_credentials" == 1 ]]; then printf 'Development credential files enabled; this build cannot be published.\n'; fi

printf "✓ Complete build — %s s\n" "$((SECONDS - build_started))"
