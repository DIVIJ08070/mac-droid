# Signing — read before you build a release

Both apps rely on a **single, stable signing key per platform**. If a release is
signed with a different key, two things break for everyone who already installed:

- **In-app auto-update fails** — the updater (Mac) and the OS (Android) both
  refuse an update whose signature doesn't match the installed app.
- **Permissions reset** — macOS TCC (Screen Recording, Accessibility,
  Notifications) is keyed to the cert; a new cert means the user re-grants
  everything. Android likewise treats a differently-signed APK as a different app.

This actually happened: 1.5.x got signed with a second Mac cert and the phone got
a third Android key, which is why updates were refused. **Don't build releases on
a machine that doesn't have these exact keys.**

## Canonical keys (the ONLY ones that may ship)

| Platform | Key location | Identity / fingerprint |
|---|---|---|
| **Android** | `android/keystore/macdroid-release.jks` (alias `macdroid`, creds in `android/keystore.properties`) | APK cert SHA-256 `9af8408f832cd5eb571c55168a3325165b92ddd81cc3bf59dccbcd5d14a6c38a` |
| **macOS** | `~/Library/Keychains/macdroid-signing.keychain-db` (identity `MacDroid Self-Signed`, password `macdroid`) | designated-requirement leaf `f00d88463c9e5045e1b77f5ae14e136c2566827e` |

These files are **gitignored** (they hold private keys). To build on another
machine, copy them there securely first — never commit them, never regenerate them.

## Build + verify

- **Mac:** `./scripts/package-mac-app.sh` — already pins the expected leaf and
  **fails the build** if it can't sign with the stable identity (no silent ad-hoc
  fallback).
- **Android:** `./gradlew assembleRelease` (uses `keystore.properties`). It will
  silently use whatever key the local `keystore.properties` points at, so always
  verify before publishing.
- **Before publishing either download**, run `./scripts/verify-signing.sh` — it
  checks `website/downloads/bifrost.apk` and `website/downloads/Bifrost.app.zip`
  against the fingerprints above and refuses if either drifted.
