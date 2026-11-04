#!/bin/sh
# Cross-checks the app's Bip39.swift against @scure/bip39, for words and seeds.
#   sh ios-app/tests/bip39/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
tmp=$(mktemp -d)
node "$here/vector.mjs" > "$tmp/vector.json"
swiftc -o "$tmp/bip39-check" \
  "$root/ios-app/KeyringAgent/Setup/Bip39.swift" \
  "$root/ios-app/KeyringAgent/Setup/Bip39Words.swift" \
  "$root/ios-app/KeyringAgent/Data+Hex.swift" \
  "$here/main.swift"
"$tmp/bip39-check" "$tmp/vector.json"
