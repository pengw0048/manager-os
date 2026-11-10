#!/bin/sh
# Run the core tests. With only Command Line Tools installed, swift-testing macros need the plugin path.
cd "$(dirname "$0")/.."
PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$PLUGIN" ]; then
  exec swift test --no-parallel -Xswiftc -plugin-path -Xswiftc "$PLUGIN" "$@"
fi
exec swift test --no-parallel "$@"
