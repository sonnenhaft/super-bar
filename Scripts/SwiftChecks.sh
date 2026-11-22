# Sourced by the macOS and iOS test runners from the repository root.
run_swift_check() {
  local executable=".build/$1"
  shift
  xcrun swiftc -swift-version 5 -module-cache-path .build/modules "$@" -o "$executable"
  "$executable"
}
