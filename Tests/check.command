#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -module-cache-path .build/modules Sources/BarSelection.swift Sources/SuperHeader.swift Sources/LG/MenuViews.swift Tests/HeaderCheck.swift -o .build/header-check
.build/header-check
xcrun swiftc -module-cache-path .build/modules Sources/TCL/TCLCloud.swift Tests/SessionReuse.swift -o .build/session-check
.build/session-check
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find Sources -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx15.0" -module-cache-path .build/modules -import-objc-header Sources/Bluetti/Bluetooth/BluettiPOSIX.h "${sources[@]}" Tests/StatusStability.swift -o .build/status-stability
.build/status-stability
