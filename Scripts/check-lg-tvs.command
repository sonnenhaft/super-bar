#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
work=.build/lg-tv-probe
case "$#:${1:-}" in
    0:) args=(--allow-keychain); report=last-run.txt ;;
    1:--nearby) args=(--nearby); report=nearby-last-run.txt ;;
    2:--host) args=(--host "$2"); report=host-last-run.txt ;;
    *) echo "Usage: $0 [--nearby | --host LOCAL_IPV4]" >&2; exit 2 ;;
esac
mkdir -p "$work" .build/modules
files=(Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift
       Sources/LG/ThinQ.swift Sources/LG/LGDeviceState.swift Sources/LG/LGMobileAuth.swift
       Sources/LG/LGMobileClient.swift Sources/LG/WebOSTVRemote.swift Sources/LG/WebOSTVTransport.swift Sources/LG/WebOSTVPairingStore.swift Sources/LG/WebOSTVCommand.swift Sources/LG/WebOSTVDiscovery.swift
       Scripts/HistoryProbeSession.swift Scripts/LGTelevisionProbe.swift)
bin="$work/SuperBarLGTVs"
for input in "${files[@]}" Scripts/check-lg-tvs.command; do
    if [[ ! -x "$bin" || "$input" -nt "$bin" ]]; then
        stage="$(mktemp -d "$work/compile.XXXXXXXX")"
        trap 'rm -rf "$stage"' EXIT
        if ! xcrun swiftc -swift-version 5 -module-cache-path .build/modules "${files[@]}" -o "$stage/probe" >"$stage/build.log" 2>&1; then
            cat "$stage/build.log" >&2
            exit 1
        fi
        mv "$stage/probe" "$bin"
        break
    fi
done
"$bin" "${args[@]}" 2>&1 | /usr/bin/tee "$work/$report"
