#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tests/RepositoryPolicy.command
source Scripts/SwiftChecks.sh
plutil -lint iOS/SuperBar.xcodeproj/project.pbxproj iOS/App/Info.plist iOS/Widgets/Info.plist iOS/SuperBar.entitlements iOS/App/PrivacyInfo.xcprivacy iOS/Widgets/PrivacyInfo.xcprivacy
xcrun swiftc -frontend -parse Sources/Shared/*.swift iOS/App/*.swift iOS/Shared/*.swift iOS/Widgets/*.swift
mkdir -p .build/modules
run_swift_check ios-project-check iOS/Tests/ProjectCheck.swift
run_swift_check widget-snapshot-check Sources/Shared/DeviceIdentity.swift \
  Sources/Bluetti/Readings/BatteryEstimates.swift \
  iOS/Shared/WidgetSnapshot.swift iOS/Shared/WidgetClimateSelection.swift iOS/Tests/WidgetSnapshotCheck.swift
run_swift_check station-names-check Sources/Bluetti/Readings/StationDirectory.swift iOS/Tests/StationNamesCheck.swift
run_swift_check widget-route-check Sources/Shared/DeviceIdentity.swift iOS/Shared/WidgetSnapshot.swift iOS/Tests/WidgetRouteCheck.swift
