# Card setup (dev card)

How to turn a blank Keyring card into one the iOS app can use. The applet code is not changed for this; everything below uses the applet as built in `near-hackthon-applets`.

## What the card needs

| Step | Who | What it does | Reversible? |
|---|---|---|---|
| 1. Install the applet | You, on the Mac (`gp.jar`) | Loads `keyring.cap` onto the card | Yes: delete the applet |
| 2. Store the certificate | You, on the Mac (`./gradlew personalizeCard`) | Stores a certificate signing the card's key with the **dev CA** | **No**, except by deleting and reinstalling the applet |
| 3. PIN and wallet seed | The phone (iOS app) | Sets the 6-digit PIN and loads the wallet seed over NFC | PIN: no PUK, 3 wrong tries block the card. Seed: replaceable by factory reset |

Step 2 is factory personalization. In production it belongs to the factory, before the card reaches a user. The user only does step 3.

## Card defaults (read this first)

- **GlobalPlatform keys are the defaults** (`404142…4F`). This is intentional, so the applet can be replaced later. The trade-off: anyone holding the card can reinstall the applet, which wipes the seed. The backup words are the recovery.
- **The dev CA is public.** The test CA private key lives in the open applet repo (`TestCA.java`). Anyone can forge a certificate that passes our check. Fine for the hackathon; production needs the CA key kept offline.
- **The certificate is write-once.** Factory reset does not clear it. Storing it on a card whose key is wrong is permanent (until the applet is deleted).
- **PIN:** 3 attempts, no PUK. Three wrong PINs block the card. Use a PIN you will remember.

## Step 1: install the applet

Run from `near-hackthon-applets`, with the card in the reader:

```sh
cd /Users/kaichaosun/github/web3/near-hackthon-applets
java -jar gp.jar --install build/cap/keyring.cap
java -jar gp.jar --list
```

The list should include:

```
APP: F04B455952494E470101 (SELECTABLE)
```

If the install fails, rerun with `-d` (APDU trace) and keep the output.

## Step 2: store the certificate

Still in `near-hackthon-applets`, with the card in the reader and no other PC/SC tool open:

```sh
./gradlew personalizeCard
```

What it does:

1. Reads the applet's identity key (`GET DATA 7F49`).
2. Issues a certificate with the dev CA and stores it (`STORE CERTIFICATE`).
3. Factory-resets the card if it has a PIN or seed (the certificate survives).
4. Checks that the card is fresh: certificate present, no PIN, no seed.

Expected output on a new card:

```
[personalize] certificate stored (serial=…)
[personalize] DONE — card is personalized and fresh, ready for the app
```

If the certificate is already present, it prints `certificate already present` and still verifies the card.

**Re-run after any `gp --install`:** reloading the applet wipes the certificate.

## Removing the certificate

There is no command that removes only the certificate. Your options:

- **Factory reset** clears the PIN and seed. It does **not** clear the certificate.
- **Delete the applet** clears everything, including the certificate and the seed. Back up your words first.

  ```sh
  java -jar gp.jar --delete F04B455952494E4701 --deletedeps
  ```

  Then do Step 1 and Step 2 again.

## Step 3: PIN and wallet (phone, first launch)

The iOS app opens setup on first launch. Nothing else appears until the card is set up on that phone.

1. **Tap 1, check:** the app verifies the card's certificate against the pinned CA and confirms it has no wallet yet. Nothing is written.
2. **On the phone:** choose a 6-digit PIN and confirm it.
3. **On the phone:** the app generates 12 recovery words. Write them down, then tick the box. The words never leave the phone until tap 2.
4. **Tap 2, load:** the app sets the PIN (if none is set), verifies it, loads the seed, and reads the wallet's public key at `m/44'/397'/0'/0/0`.

The PIN goes to the card only over NFC. The Mac never sees it.

If tap 2 fails, nothing is lost: the seed isn't loaded yet, so you can retry with the same words. If the card already has a wallet, the app refuses; factory reset it first.

After setup, the app shows the card's ID and public key. Approvals appear only once the card's key is the approver of a NEAR account. Linking the account is the next build step. To start over on a phone, use **Settings → Forget card on this phone**. That doesn't touch the card.

## Checks

- `java -jar gp.jar --list` shows the applet.
- `./gradlew personalizeCard` ends with `DONE`.
- The app (once Step 3 exists) refuses a card whose certificate is not signed by the pinned CA.
