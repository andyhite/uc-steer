#!/bin/sh
# Builds and runs every check in a temp dir (nothing installed), then the installer test. Cleans up on exit.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
cd "$src"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

swiftc -swift-version 5 -parse-as-library Sources/Input.swift Sources/Peers.swift Tests/InputChecks.swift -o "$t/input"
swiftc -swift-version 5 -parse-as-library Sources/PairingKey.swift Tests/PairingKeyChecks.swift -o "$t/pairing"
# One file so `extension Peers` in the checks can reach Peers' private members.
cat Sources/Peers.swift Tests/PeersChecks.swift > "$t/PeersChecks.swift"
swiftc -swift-version 5 -parse-as-library Sources/Input.swift "$t/PeersChecks.swift" -o "$t/peers"
# Whole production source set (incl. main.swift) with the installer's flags.
swiftc -typecheck -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift

"$t/input"
"$t/pairing"
"$t/peers"
sh test-install.sh
