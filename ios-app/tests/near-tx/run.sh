#!/bin/sh
# Cross-checks the app's NearTx.swift against @near-js/transactions, byte for byte.
#   sh ios-app/tests/near-tx/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
tmp=$(mktemp -d)
node "$here/vector.mjs" > "$tmp/vector.json"
swiftc -o "$tmp/near-tx-check" \
  "$root/ios-app/KeyringAgent/NearTx.swift" \
  "$root/ios-app/KeyringAgent/Data+Hex.swift" \
  "$here/main.swift"
"$tmp/near-tx-check" "$tmp/vector.json"
