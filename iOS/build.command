#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 generate_project.py
xcodebuild -project SuperBar.xcodeproj -scheme SuperBar -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ../.build/ios \
  CODE_SIGNING_ALLOWED=NO build
