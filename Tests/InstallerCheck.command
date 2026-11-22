#!/bin/bash
set -euo pipefail
root="$(mktemp -d /tmp/sb-install-test.XXXXXX)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/project/dist" "$root/project/Scripts" "$root/bin" "$root/install"
export SUPER_BAR_TEST_HELPER="$root/real-lifecycle"
xcrun swiftc -module-cache-path "$PWD/.build/modules" Scripts/AppLifecycle.swift -o "$SUPER_BAR_TEST_HELPER"
printf 'abc' > "$root/sample"
[[ "$("$SUPER_BAR_TEST_HELPER" checksum "$root/sample")" == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]]
cp install.command "$root/project/"
cp Scripts/Progress.command "$root/project/Scripts/"
ditto 'dist/Super Bar.app' "$root/project/dist/Super Bar.app"
ditto 'dist/Super Bar.app' "$root/install/Super Bar.app"
touch "$root/install/Super Bar.app/old-marker"
cat > "$root/project/build.command" <<'END'
#!/bin/bash
exit 0
END
chmod +x "$root/project/build.command"
cat > "$root/bin/xcrun" <<'END'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    shift
    cat > "$1" <<'INNER'
#!/bin/bash
if [[ "$1" == checksum ]]; then exec "$SUPER_BAR_TEST_HELPER" "$@"; fi
echo "$1" >> "$SUPER_BAR_TEST_LOG"
if [[ "$1" == launch ]]; then
  case "$SUPER_BAR_TEST_FAIL" in
    launch) exit 1 ;;
    changed) printf 'damaged' >> "$2/Contents/MacOS/SuperBar" ;;
    missing) mv "$2/Contents/MacOS/SuperBar" "$2/Contents/MacOS/removed" ;;
  esac
fi
exit 0
INNER
    chmod +x "$1"
    exit 0
  fi
  shift
done
exit 1
END
chmod +x "$root/bin/xcrun"
cd "$root/project"
export PATH="$root/bin:$PATH" SUPER_BAR_INSTALL_DIR="$root/install" SUPER_BAR_TEST_LOG="$root/log" SUPER_BAR_TEST_FAIL=launch
if ./install.command > "$root/output" 2>&1; then echo 'Failure unexpectedly succeeded'; exit 1; fi
[[ -f "$root/install/Super Bar.app/old-marker" ]]
[[ "$(cat "$root/log")" == $'stop\nlaunch\nstop' ]]
export SUPER_BAR_TEST_FAIL=0
./install.command > "$root/output" 2>&1
[[ ! -e "$root/install/Super Bar.app/old-marker" ]]
cmp "$root/install/Super Bar.app/Contents/MacOS/SuperBar" 'dist/Super Bar.app/Contents/MacOS/SuperBar'
touch "$root/install/Super Bar.app/old-marker"
for SUPER_BAR_TEST_FAIL in changed missing; do
  if ./install.command > "$root/output" 2>&1; then echo 'Damaged installation unexpectedly succeeded'; exit 1; fi
  [[ -f "$root/install/Super Bar.app/old-marker" ]]
  [[ "$(tail -n 3 "$root/log")" == $'stop\nlaunch\nstop' ]]
done
echo 'Verified installation and rollback after a failed launch, changed executable or missing executable.'

