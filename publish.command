#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${SUPER_BAR_DEV_CREDENTIALS:-0}" != 0 ]]; then
  printf 'Publishing is disabled with development credential files.\n' >&2
  exit 1
fi
if [[ -f 'dist/Super Bar.app/Contents/Info.plist' ]]; then
  development="$(/usr/libexec/PlistBuddy -c 'Print :SuperBarDevCredentials' 'dist/Super Bar.app/Contents/Info.plist' 2>/dev/null || true)"
  if [[ "$development" == true ]]; then
    printf 'Publishing is disabled for a development-credentials build. Rebuild with SUPER_BAR_RELEASE=1 first.\n' >&2
    exit 1
  fi
fi
test "$(git remote get-url --push origin)" = 'git@github.com:sonnenhaft/super-bar.git'
git push -u origin main
