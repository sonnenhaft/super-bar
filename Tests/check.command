#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -module-cache-path .build/modules Sources/Readings.swift Sources/BarSelection.swift Sources/SuperHeader.swift Sources/LG/MenuViews.swift Tests/HeaderCheck.swift -o .build/header-check
.build/header-check
xcrun swiftc -module-cache-path .build/modules Sources/Cloud/CloudSupport.swift Sources/TCL/TCLCloud.swift Tests/SessionReuse.swift -o .build/session-check
.build/session-check
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find Sources -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx15.0" -module-cache-path .build/modules -import-objc-header Sources/Bluetti/Bluetooth/BluettiPOSIX.h "${sources[@]}" Tests/StatusStability.swift -o .build/status-stability
.build/status-stability

xcrun swiftc -swift-version 5 -module-cache-path .build/modules Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Deye/DeyeReading.swift Sources/Deye/DeyeCloud.swift Tests/DeyeSession.swift -o .build/deye-session-check
.build/deye-session-check

/usr/bin/openssl genrsa -out .build/tuya-test-key.pem 2048 2>/dev/null
/usr/bin/openssl rsa -in .build/tuya-test-key.pem -outform DER -out .build/tuya-test-key.der 2>/dev/null
xcrun swiftc -swift-version 5 -module-cache-path .build/modules Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Tuya/TuyaCrypto.swift Sources/Tuya/TuyaCloud.swift Sources/Tuya/TuyaReading.swift Sources/Deye/DeyeReading.swift Sources/Deye/EnergyBalance.swift Tests/TuyaNative.swift -o .build/tuya-native-check
.build/tuya-native-check
