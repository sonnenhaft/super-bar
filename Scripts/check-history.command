#!/bin/bash
# Read-only provider and Bluetooth diagnostics. Credentials stay in memory.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/history-probes .build/modules
providers=()
options=()
periods=()
for argument in "$@"; do
  case "$argument" in
    tcl|lg|tuya|bluetti) providers+=("$argument") ;;
    --allow-keychain|--explore) options+=("$argument") ;;
    --48h|--30d) periods+=("$argument") ;;
    --help|-h)
      echo "48-hour cloud history (requests Keychain access): $0 --48h [tcl|lg|tuya ...]"
      echo "Daily history for 30 calendar days: $0 --30d [tcl|lg|tuya ...]"
      echo "Both checks and alternative read-only APIs: $0 --48h --30d --explore"
      echo "Other diagnostics: $0 [tcl|lg|tuya|bluetti ...] [--allow-keychain]"
      exit 0 ;;
    *) echo "Unknown argument: $argument. Use --help." >&2; exit 2 ;;
  esac
done
shared=(Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Scripts/HistoryProbeSession.swift Scripts/HistoryProbeWindow.swift)
lg=(Sources/LG/ThinQ.swift Sources/LG/LGMobileAuth.swift Sources/LG/LGMobileClient.swift Sources/LG/LGDeviceState.swift Scripts/LGHistoryProbe.swift)
tcl=(Sources/TCL/TCLCloud.swift Scripts/TCLHistoryProbe.swift)
tuya=(Sources/Tuya/TuyaCloud.swift Sources/Tuya/TuyaCrypto.swift Sources/Tuya/TuyaReading.swift Scripts/TuyaHistoryProbe.swift)
if [[ ${#periods[@]} -gt 0 ]]; then
  if [[ ${#providers[@]} == 0 ]]; then
    providers=(tcl lg tuya)
  fi
  for provider in "${providers[@]}"; do
    if [[ "$provider" == bluetti ]]; then
      echo "--48h and --30d support tcl, lg and tuya." >&2; exit 2
    fi
  done
  sources=("${shared[@]}" "${lg[@]}" "${tcl[@]}" "${tuya[@]}" Scripts/HistoryProbeSuite.swift)
  binary=.build/history-probes/SuperBarHistory
  rebuild=0
  for input in "${sources[@]}" Scripts/check-history.command; do
    if [[ ! -x "$binary" || "$input" -nt "$binary" ]]; then rebuild=1; break; fi
  done
  if [[ "$rebuild" == 1 ]]; then
    build_dir="$(mktemp -d .build/history-probes/build.XXXXXXXX)"
    trap 'rm -rf "$build_dir"' EXIT
    echo "Собираю скрипт проверки…" >&2
    snapshot=()
    for source in "${sources[@]}"; do
      mkdir -p "$build_dir/${source%/*}"
      cp "$source" "$build_dir/$source"
      snapshot+=("$build_dir/$source")
    done
    if ! xcrun swiftc -swift-version 5 -D HISTORY_PROBE_SUITE -module-cache-path .build/modules "${snapshot[@]}" -o "$build_dir/SuperBarHistory" >"$build_dir/build.log" 2>&1; then
      cat "$build_dir/build.log" >&2
      exit 1
    fi
    mv -f "$build_dir/SuperBarHistory" "$binary"
  fi
  "$binary" "${periods[@]}" --allow-keychain ${options[@]+"${options[@]}"} "${providers[@]}"
  exit
fi
if [[ ${#providers[@]} == 0 ]]; then providers=(bluetti tcl lg tuya); fi
run_probe() {
  local provider="$1" binary=".build/history-probes/$1" log=".build/history-probes/$1-compile.log"
  local sources=()
  case "$provider" in
    tcl) sources=("${tcl[@]}") ;;
    lg) sources=("${lg[@]}") ;;
    tuya) sources=("${tuya[@]}") ;;
    bluetti) xcrun swift -module-cache-path .build/modules Scripts/check-bluetti.swift ${options[@]+"${options[@]}"}; return ;;
  esac
  if ! xcrun swiftc -swift-version 5 -module-cache-path .build/modules "${shared[@]}" "${sources[@]}" -o "$binary" >"$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  "$binary" ${options[@]+"${options[@]}"}
}
result=0
for provider in "${providers[@]}"; do
  printf '\n%s\n' "$provider"
  run_probe "$provider" || result=1
done
exit "$result"
