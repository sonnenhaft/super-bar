#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tests/RepositoryPolicy.command
mkdir -p .build
xcrun swiftc -module-cache-path .build/modules Sources/Cloud/CloudSupport.swift Tests/CloudResponse.swift -o .build/cloud-response-check
.build/cloud-response-check
xcrun swiftc -module-cache-path .build/modules Sources/Bluetti/Polling/CLIJob.swift Tests/BluetoothStream.swift -o .build/bluetooth-stream-check
.build/bluetooth-stream-check
xcrun swiftc -swift-version 5 -module-cache-path .build/modules iOS/App/WidgetCommandQueue.swift Tests/WidgetCommandQueueCheck.swift -o .build/widget-command-queue-check
.build/widget-command-queue-check
xcrun swiftc -module-cache-path .build/modules Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Tests/CredentialStorage.swift -o .build/credential-storage-check
.build/credential-storage-check
xcrun swiftc -swift-version 5 -D SUPER_BAR_DEV_CREDENTIALS -module-cache-path .build/modules Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Sources/Cloud/DevelopmentCredentialVault.swift Tests/DevelopmentCredentials.swift -o .build/development-credentials-check
.build/development-credentials-check
xcrun swiftc -module-cache-path .build/modules Sources/Readings.swift Sources/Shared/PanelTheme.swift Sources/Shared/DeviceDisplayName.swift Sources/Shared/ReadingAge.swift Sources/Shared/ClimateSelection.swift Sources/BarSelection.swift Sources/SuperHeader.swift Sources/LG/MenuViews.swift Tests/HeaderCheck.swift -o .build/header-check
.build/header-check
xcrun swiftc -module-cache-path .build/modules Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Sources/TCL/TCLCloud.swift Tests/CredentialFixtures.swift Tests/SessionReuse.swift -o .build/session-check
.build/session-check
xcrun swiftc -swift-version 5 -module-cache-path .build/modules Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Sources/LG/ThinQ.swift Sources/LG/LGDeviceState.swift Tests/LGSharedState.swift -o .build/lg-shared-check
.build/lg-shared-check
xcrun swiftc -swift-version 5 -module-cache-path .build/modules Sources/Readings.swift Sources/Shared/ReadingAge.swift Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Sources/Deye/DeyeReading.swift Sources/Deye/DeyeCloud.swift Sources/Deye/DeyeStore.swift Sources/Tuya/TuyaCrypto.swift Sources/Tuya/TuyaCloud.swift Sources/Tuya/TuyaReading.swift Sources/Tuya/TuyaStore.swift Tests/CredentialFixtures.swift Tests/EnergyStoreLifecycle.swift -o .build/energy-store-check
.build/energy-store-check
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find Sources -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx15.0" -module-cache-path .build/modules -import-objc-header Sources/Bluetti/Bluetooth/BluettiPOSIX.h "${sources[@]}" iOS/App/PhoneLG.swift iOS/App/WidgetClimateMetrics.swift iOS/Shared/WidgetSnapshot.swift Tests/MemoryLifecycle.swift -o .build/memory-lifecycle-check
.build/memory-lifecycle-check
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx15.0" -module-cache-path .build/modules -import-objc-header Sources/Bluetti/Bluetooth/BluettiPOSIX.h "${sources[@]}" Tests/StatusStability.swift -o .build/status-stability
.build/status-stability

xcrun swiftc -swift-version 5 -module-cache-path .build/modules Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Sources/Deye/DeyeReading.swift Sources/Deye/DeyeCloud.swift Tests/CredentialFixtures.swift Tests/DeyeSession.swift -o .build/deye-session-check
.build/deye-session-check

/usr/bin/openssl genrsa -out .build/tuya-test-key.pem 2048 2>/dev/null
/usr/bin/openssl rsa -in .build/tuya-test-key.pem -outform DER -out .build/tuya-test-key.der 2>/dev/null
xcrun swiftc -swift-version 5 -module-cache-path .build/modules Sources/Readings.swift Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift Sources/Tuya/TuyaCrypto.swift Sources/Tuya/TuyaCloud.swift Sources/Tuya/TuyaReading.swift Sources/Deye/DeyeReading.swift Sources/Deye/EnergyBalance.swift Tests/CredentialFixtures.swift Tests/TuyaNative.swift -o .build/tuya-native-check
.build/tuya-native-check
