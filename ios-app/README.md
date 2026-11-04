# Keyring Agent iOS

Native SwiftUI approval app. It fetches pending spends, displays the decoded request, and signs `approve` / `reject` with the Keyring card over NFC.

## Requirements

- Xcode 26+
- iOS 17+
- A physical iPhone with NFC (the Simulator cannot read the card)
- A paid Apple Developer team for a device build with the NFC entitlement
- The private `KeyringCardClient` Swift package at `../../near-hackthon-applets/client-swift`

## Setup

```sh
cd ios-app
xcodegen generate
open KeyringAgent.xcodeproj
```

1. Set your development team in **Signing & Capabilities**.
2. Set the bundle identifier if needed (default `so.keyring.agent`).
3. In the app, open **Settings** → **API server**, enter your Mac's LAN address (e.g. `http://192.168.1.20:8787`), and tap **Save and connect**. The default (`http://127.0.0.1:8787`) is used in the Simulator; **Reset to default** restores it.
4. Run the API from the repo root: `node api/server.mjs`.
5. Run on the iPhone. Tap a pending request, enter the 6-digit card PIN, then hold the card near the top of the iPhone.

The Simulator builds and displays the list, but NFC is disabled and the Approve/Reject buttons are intentionally disabled.

## Card configuration

| Setting | Value |
|---|---|
| Applet AID | `F04B455952494E470101` |
| Key path | `m/44'/397'/0'/0/0` |
| CA public key | Test CA from the applet repo, pinned in `Config.swift` |
| PIN | 6 digits, set during card personalization |

`Config.swift` pins the applet's **test CA** public key. Replace it with the production CA public key before using a production-personalized card.

The card protocol flow is:

```
SELECT → GET DATA(7F21) + verify CA → INTERNAL AUTHENTICATE
→ VERIFY PIN → SIGN(sha256(tx))
```

`KeyringCardClient` returns `publicKey65 || signature64 (r‖s)`. The app compares the card's public key with the account's approver key and sends the 64-byte signature to the API. The API recovers the recovery id and broadcasts.

## Flow

1. App polls `GET /api/pending` every 2 seconds while active.
2. A pending row shows amount, receiver, reason, and the untrusted memo.
3. **Approve with card**: app asks the API to build the unsigned `approve(id)` transaction, receives the hash, starts an NFC session, verifies the PIN, signs the hash, and posts the signature to the API.
4. The API broadcasts and returns the tx hash; the app links to NEAR Blocks.
5. **Reject** follows the same path with `reject(id)`.

The API never sees the card key or PIN. The app displays the intent; the card signs the hash.

## Deep link

```
keyring-agent://approve?account=keyring-spike-1023.testnet&id=3
```

For local testing without the system "Open in" prompt, launch with the debug environment:

```sh
SIMCTL_CHILD_OPEN_URL='keyring-agent://approve?account=keyring-spike-1023.testnet&id=3' \
  xcrun simctl launch booted so.keyring.agent
```

## Files

| File | Purpose |
|---|---|
| `Config.swift` | API URL, account, CA key, card path |
| `Models.swift` | API models |
| `APIClient.swift` | Context, pending, prepare, submit |
| `AppModel.swift` | Polling, deep links, approval flow |
| `CardSigner.swift` | CoreNFC session + card protocol + PIN |
| `NFCCardTransport.swift` | CoreNFC APDU transport |
| `Views/` | Pending list, approval, settings |

## Known limitations

- No APNs push yet; polling while active. Add universal links + APNs for background notifications.
- The API builds the unsigned transaction. For production, use a card-derived function-call approval key or build on-device.
- The app uses the applet's test CA; production cards need the production CA.
- The `KeyringCardClient` dependency is private; replace it with the published client for a public build.
