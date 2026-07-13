# MacDroid

Connect your Mac and your Samsung (Android) phone over your local Wi-Fi — your own
mini KDE Connect. Two apps, one protocol (see [PROTOCOL.md](PROTOCOL.md)).

**Features**
- Automatic discovery: the phone finds the Mac on the same Wi-Fi (Bonjour/mDNS)
- Pairing with a 6-digit confirmation code — **once**; reconnects are silent (remembered token)
- Clipboard sync: Mac → phone automatically (toggleable), phone → Mac with one tap
- File & photo transfer:
  - Phone → Mac: share sheet from any app ("Share → MacDroid") or the in-app picker; lands in the Mac's Downloads
  - Mac → phone: "Send file…" button or drag & drop onto the window; lands in the phone's Downloads
- Stays connected in the background: an Android foreground service keeps the link alive
  and auto-reconnects whenever it sees your Mac on the network
- Ping in both directions (Mac beeps; phone shows a notification with sound)
- Open links on the other device (share from the browser, or the "Open link" buttons)
- Mac remote on the phone: volume, mute, play/pause, lock, sleep, screenshot-to-phone
- Phone as microphone: streams the phone's mic to the Mac live (pick a virtual output
  device like BlackHole on the Mac to use it as an input in Zoom & co.)
- Mac audio on the phone: streams system audio to the phone, which plays it through
  its current route — including Bluetooth devices paired to the phone (handy when the
  Mac itself has no Bluetooth). Needs "Screen & System Audio Recording" permission for
  your terminal in System Settings → Privacy & Security the first time.

## Run the Mac app

```sh
cd macos
swift run
```

A window opens showing "Advertising as <your Mac's name>".

## Build & install the Android app

Option A — Android Studio: open the `android/` folder, press Run with your phone
connected.

Option B — command line:

```sh
cd android
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew assembleDebug
# with the phone connected via USB (USB debugging enabled):
~/Library/Android/sdk/platform-tools/adb install app/build/outputs/apk/debug/app-debug.apk
```

To enable USB debugging on the Samsung: Settings → About phone → Software
information → tap **Build number** 7 times, then Settings → Developer options →
**USB debugging**.

## Use it

1. Start the Mac app, open MacDroid on the phone (same Wi-Fi network).
2. The Mac appears in the list on the phone → tap **Connect**.
3. A 6-digit code shows on both screens → click **Accept** on the Mac.
4. Copy something on the Mac — it lands on the phone's clipboard automatically.
   On the phone, tap **Send clipboard** to push the other way.

## Project layout

```
PROTOCOL.md   — the wire protocol both apps implement
macos/        — SwiftUI app (Swift Package, Network framework, Bonjour listener)
android/      — Kotlin + Jetpack Compose app (NsdManager discovery, TCP client)
```

## Roadmap

- [ ] TLS with pinned certificates (traffic is currently plaintext on your LAN)
- [ ] Notification mirroring (Android → Mac)
- [ ] Battery status on the Mac + full-volume find-my-phone
- [ ] SMS from the Mac
