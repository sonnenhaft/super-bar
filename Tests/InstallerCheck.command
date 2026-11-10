#!/bin/bash
set -euo pipefail
root="$(mktemp -d /tmp/sb-install-test.XXXXXX)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/project/dist" "$root/project/Scripts" "$root/bin" "$root/install"
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
echo "$1" >> "$SUPER_BAR_TEST_LOG"
if [[ "$1" == launch && "$SUPER_BAR_TEST_FAIL" == 1 ]]; then exit 1; fi
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
export PATH="$root/bin:$PATH" SUPER_BAR_INSTALL_DIR="$root/install" SUPER_BAR_SKIP_TOKEN_MIGRATION=1 SUPER_BAR_TEST_LOG="$root/log" SUPER_BAR_TEST_FAIL=1
if ./install.command > "$root/output" 2>&1; then echo 'Failure unexpectedly succeeded'; exit 1; fi
[[ -f "$root/install/Super Bar.app/old-marker" ]]
[[ "$(cat "$root/log")" == $'stop\nlaunch\nstop' ]]
export SUPER_BAR_TEST_FAIL=0
./install.command > "$root/output" 2>&1
[[ ! -e "$root/install/Super Bar.app/old-marker" ]]
cmp "$root/install/Super Bar.app/Contents/MacOS/SuperBar" 'dist/Super Bar.app/Contents/MacOS/SuperBar'
# The third hash is the installed bundle after launch. Force it to mismatch.
touch "$root/install/Super Bar.app/old-marker"
cat > "$root/bin/shasum" <<'END'
#!/bin/bash
count=0
[[ ! -f "$SUPER_BAR_HASH_COUNTER" ]] || count=$(cat "$SUPER_BAR_HASH_COUNTER")
count=$((count + 1))
echo "$count" > "$SUPER_BAR_HASH_COUNTER"
if [[ "$count" == 3 ]]; then echo 'bad-hash  executable'; else /usr/bin/shasum "$@"; fi
END
chmod +x "$root/bin/shasum"
export SUPER_BAR_HASH_COUNTER="$root/hash-count"
if ./install.command > "$root/output" 2>&1; then echo 'Hash mismatch unexpectedly succeeded'; exit 1; fi
[[ -f "$root/install/Super Bar.app/old-marker" ]]
[[ "$(tail -n 3 "$root/log")" == $'stop\nlaunch\nstop' ]]
echo 'Installer simulation: successful replacement and rollback after launch failure or final hash mismatch.'

