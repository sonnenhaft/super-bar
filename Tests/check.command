#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tests/RepositoryPolicy.command
source Scripts/SwiftChecks.sh
mkdir -p .build/modules

cloud=(Sources/Cloud/CloudSupport.swift Sources/Cloud/CredentialStore.swift)
lg=(Sources/LG/ThinQ.swift Sources/LG/LGMobileAuth.swift Sources/LG/LGMobileClient.swift Sources/LG/LGDeviceState.swift)
deye=(Sources/Deye/DeyeReading.swift Sources/Deye/DeyeCloud.swift)
tuya=(Sources/Tuya/TuyaCrypto.swift Sources/Tuya/TuyaCloud.swift Sources/Tuya/TuyaReading.swift)

run_swift_check editing-commands-check Sources/EditingCommands.swift Tests/EditingCommandsCheck.swift
run_swift_check cloud-response-check Sources/Cloud/CloudSupport.swift Tests/CloudResponse.swift
run_swift_check bluetooth-stream-check Sources/Bluetti/Polling/CLIJob.swift Tests/BluetoothStream.swift
run_swift_check widget-command-queue-check iOS/App/WidgetCommandQueue.swift Tests/WidgetCommandQueueCheck.swift
run_swift_check credential-storage-check "${cloud[@]}" Tests/CredentialStorage.swift
run_swift_check development-credentials-check -D SUPER_BAR_DEV_CREDENTIALS "${cloud[@]}" \
  Sources/Cloud/DevelopmentCredentialVault.swift Tests/DevelopmentCredentials.swift
run_swift_check header-check Sources/Readings.swift Sources/Shared/PanelTheme.swift Sources/Shared/DeviceIdentity.swift \
  Sources/Shared/ReadingAge.swift Sources/BarSelection.swift Sources/SuperHeader.swift Tests/HeaderCheck.swift
run_swift_check session-check "${cloud[@]}" Sources/TCL/TCLCloud.swift Tests/CredentialFixtures.swift Tests/SessionReuse.swift

run_swift_check lg-shared-check Sources/Readings.swift "${cloud[@]}" "${lg[@]}" Tests/LGSharedState.swift
run_swift_check lg-mobile-check Sources/Readings.swift "${cloud[@]}" "${lg[@]}" Tests/CredentialFixtures.swift Tests/LGMobile.swift
run_swift_check webos-remote-check "${cloud[@]}" Sources/LG/WebOSTVRemote.swift Sources/LG/WebOSTVTransport.swift Sources/LG/WebOSTVPairingStore.swift Sources/LG/WebOSTVCommand.swift Sources/LG/WebOSTVDiscovery.swift \
  Tests/CredentialFixtures.swift Tests/WebOSTVRemoteCheck.swift
run_swift_check energy-store-check Sources/Readings.swift Sources/Shared/ReadingAge.swift "${cloud[@]}" \
  "${deye[@]}" Sources/Deye/DeyeStore.swift "${tuya[@]}" Sources/Tuya/TuyaStore.swift \
  Tests/CredentialFixtures.swift Tests/EnergyStoreLifecycle.swift
run_swift_check deye-session-check Sources/Readings.swift "${cloud[@]}" "${deye[@]}" Tests/CredentialFixtures.swift Tests/DeyeSession.swift
run_swift_check tuya-native-check Sources/Readings.swift Sources/Shared/ReadingAge.swift "${cloud[@]}" "${tuya[@]}" Sources/Tuya/TuyaStore.swift \
  Sources/Deye/DeyeReading.swift Sources/Deye/EnergyBalance.swift Tests/CredentialFixtures.swift Tests/TuyaNative.swift

desktop=(-target "$(uname -m)-apple-macosx15.0" -import-objc-header Sources/Bluetti/Bluetooth/BluettiPOSIX.h)
while IFS= read -r -d '' file; do
  desktop+=("$file")
done < <(find Sources -type f -name '*.swift' ! -name main.swift -print0)
run_swift_check memory-lifecycle-check "${desktop[@]}" iOS/App/PhoneLG.swift iOS/App/WidgetClimateMetrics.swift \
  iOS/Shared/WidgetSnapshot.swift Tests/MemoryLifecycle.swift
run_swift_check status-stability "${desktop[@]}" Tests/StatusStability.swift
