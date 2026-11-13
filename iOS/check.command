#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tests/RepositoryPolicy.command
plutil -lint iOS/SuperBar.xcodeproj/project.pbxproj iOS/App/Info.plist iOS/Widgets/Info.plist iOS/SuperBar.entitlements iOS/App/PrivacyInfo.xcprivacy iOS/Widgets/PrivacyInfo.xcprivacy
xcrun swiftc -frontend -parse Sources/Shared/*.swift iOS/App/*.swift iOS/Shared/*.swift iOS/Widgets/*.swift
mkdir -p .build
xcrun swiftc -module-cache-path .build/modules iOS/Tests/ProjectCheck.swift -o .build/ios-project-check
.build/ios-project-check
xcrun swiftc -module-cache-path .build/modules iOS/Shared/WidgetSnapshot.swift iOS/Shared/WidgetClimateSelection.swift iOS/Tests/WidgetSnapshotCheck.swift -o .build/widget-snapshot-check
.build/widget-snapshot-check
xcrun swiftc -module-cache-path .build/modules Sources/Bluetti/Readings/StationDirectory.swift iOS/Tests/StationNamesCheck.swift -o .build/station-names-check
.build/station-names-check
