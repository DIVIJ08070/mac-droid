# MacDroid Protocol v1

Both apps speak newline-delimited JSON packets over a plain TCP socket on the local network.

## Discovery
- The **Mac advertises** a Bonjour/mDNS service of type `_macdroid._tcp` on a system-assigned port.
- The **Android app browses** for that service type using `NsdManager`, resolves it to an IP + port, and connects.

## Framing
One JSON object per line, terminated by `\n`:

```json
{"id": 1720900000000, "type": "<packet-type>", "body": { ... }}
```

- `id` — milliseconds since epoch (for logging/dedup, not currently enforced)
- `type` — one of the types below
- `body` — type-specific payload, always an object

## Packet types

| type | direction | body | meaning |
|---|---|---|---|
| `identity` | both, on connect | `{"name": "...", "device": "android"\|"mac"}` | introduce yourself |
| `pair.request` | Android → Mac | `{"code": "123456"}` or `{"token": "..."}` | first pairing sends a code; reconnects send the remembered token |
| `pair.accept` | Mac → Android | `{"token": "..."}` | accepted; token is stored by the phone for silent reconnects |
| `pair.reject` | Mac → Android | `{}` | user rejected, or token was invalid |
| `clipboard` | both | `{"content": "..."}` | set the receiver's clipboard to `content` |
| `clipboard.image` | Android → Mac | `{"name": "...", "size": 123, "port": 54321}` | a copied image; Mac pulls the bytes on the side channel and puts it on NSPasteboard so ⌘V pastes it into any app |
| `ping` | both | `{"message": "..."}` | make the receiver ring/notify (find-my-phone) |
| `file.offer` | both | `{"name": "...", "size": 123, "port": 54321}` | a file is ready; receiver pulls it from the side channel |
| `notification` | Android → Mac | `{"app":"…","title":"…","text":"…","id":"…","canReply":true,"key":"…","actions":["Archive","Like"]}` | mirror a phone notification; `canReply` if it has an inline reply action. `key` is the Android sbn key; `actions` lists its non-reply action titles (max 3) — the Mac banner shows them as buttons |
| `notification.reply` | Mac → Android | `{"id":"…","text":"…"}` | send a typed reply for notification `id` (fires its inline reply action) |
| `notification.action` | Mac → Android | `{"key":"…","index":0}` | the user clicked action button `index` on the mirrored banner; the phone fires that action's PendingIntent |
| `notification.dismiss` | both | Android → Mac: `{"id":"…"}` · Mac → Android: `{"key":"…"}` | Android → Mac: the phone dismissed/cleared notification `id`; the Mac removes the mirrored banner so it can't be replied to after it's gone. Mac → Android: the user clicked Dismiss on the banner; the phone cancels notification `key` |
| `notification.reply.result` | Android → Mac | `{"id":"…","ok":false}` | a Mac reply could not be delivered (notification no longer present); the Mac tells the user instead of assuming success |
| `heartbeat` | Android → Mac | `{"batt": 87, "charging": false}` | keep-alive, sent every 15 s. Newer phones piggyback the battery level (0–100) and charger state; older ones send `{}`. A failed write tells the phone the link is dead |
| `battery` | Android → Mac | `{"batt": 87, "charging": true}` | immediate battery snapshot: sent on charger plug/unplug, on Android's battery-low/okay broadcasts, and once right after pairing |
| `call.state` | Android → Mac | `{"state": "ringing"\|"offhook"\|"idle", "name": "…", "number": "…", "muted": false, "speaker": false}` | phone call state changed. `name`/`number` may be empty (unknown caller, or missing phone-side permission). On `ringing` the Mac shows a high-priority banner with Silence/Decline and pauses local media playback (no auto-resume); `offhook`/`idle` clears the banner. `muted`/`speaker` are OPTIONAL and present during `offhook`: they report the phone's ACTUAL current mic-mute and speakerphone state so the Mac's on-call toggles never lie. After any `mute`/`speaker` action the phone re-emits `call.state` with the resulting real values. On `idle` the Mac clears them |
| `call.action` | Mac → Android | `{"action": "silence"\|"decline"\|"hangup"\|"mute"\|"unmute"\|"speaker_on"\|"speaker_off"}` | act on the call. While ringing: `silence` mutes the ringer for THIS ring only (the phone restores the previous ringer mode when the call ends); `decline` rejects the call. During `offhook`: `hangup` ends the active call (`TelecomManager.endCall`, same call `decline` targets but valid while connected); `mute`/`unmute` toggle the call microphone; `speaker_on`/`speaker_off` toggle speakerphone / earpiece. `mute` and `speaker` are best-effort — if the OS won't honor them the phone re-emits `call.state` with the UNCHANGED real state, so the Mac toggle simply doesn't flip rather than lying |
| `url` | both | `{"url": "https://…"}` | open this link on the receiver's default browser |
| `command` | Android → Mac | `{"action": "lock"\|"sleep"\|"mute"\|"volume_up"\|"volume_down"\|"playpause"\|"screenshot"}` | remote-control the Mac; `screenshot` captures and sends the image back as a file |
| `audio.start` | both | `{"direction": "mic"\|"speaker", "sampleRate": 48000, "channels": 2, "port": 54321}` | an audio stream is available on a side channel (same pull model as files, but endless) |
| `audio.stop` | both | `{"direction": "mic"\|"speaker"}` | stop the stream and close the side channel |
| `input` | Android → Mac | `{"a": "m"\|"sc"\|"c"\|"dd"\|"du"\|"g", "dx": 1.5, "dy": -2, "b": "l"\|"r"\|"m", "g": "3left"\|"3right"\|"3up"\|"3down"\|"pinchin"\|"pinchout"\|"4up"\|"4down"}` | touchpad: move, scroll, click (left/right/middle), drag down/up, or a named trackpad gesture. Sent up to ~60×/s; Mac injects CGEvents (needs Accessibility permission) |
| `browse` | both | `{"url": "https://…", "title": "…", "source": "phone"\|"mac"}` | Handoff-style tab sync: the page currently open in the sender's browser. Phone→Mac shows in the Mac menu bar; Mac→phone shows as an "Open on phone" card |
| `control.start` | Mac → Android | `{}` | Universal Control: the phone shows a cursor overlay (via its accessibility service) that the Mac now drives — no mirror window needed |
| `control.move` | Mac → Android | `{"dx": 4.0, "dy": -2.0}` | move the phone cursor by a relative delta (Mac points; the phone scales by its density) |
| `control.press` | Mac → Android | `{}` | left mouse down — anchor a possible drag at the current cursor |
| `control.release` | Mac → Android | `{"drag": true}` | left mouse up — `drag:true` swipes from the press anchor to the cursor; else a tap |
| `control.click` | Mac → Android | `{"button": "right"}` | right-click → long-press at the cursor |
| `control.scroll` | Mac → Android | `{"dy": 40.0}` | scroll at the cursor (positive = up) |
| `control.stop` | Mac → Android | `{}` | exit control; hide the cursor overlay. Keyboard while controlling reuses `screen.key` |
| `control.unavailable` | Android → Mac | `{}` | the phone's accessibility service is off — Mac aborts control and restores its cursor |
| `control.exit` | Android → Mac | `{}` | the user pushed the cursor off the phone's LEFT edge — Mac exits control and takes the cursor back (mirrors the slide-off-the-right-edge entry) |
| `screen.request` | Mac → Android | `{}` | ask the phone to share its screen; the phone shows a notification (Android requires user consent on-device) |
| `screen.start` | Android → Mac | `{"width": 540, "height": 1170, "port": 54321}` | screen stream ready: raw H.264 Annex-B on the side channel; Mac opens a viewer window |
| `screen.stop` | both | `{}` | end the screen stream |
| `screen.input` | Mac → Android | `{"a": "tap"\|"swipe", "x": 0.5, "y": 0.5, "x2": 0.5, "y2": 0.2, "ms": 200}` | control the phone from the screen-mirror window. Coordinates are normalized 0–1 of the screen; Android injects the gesture via an Accessibility service |
| `screen.key` | Mac → Android | `{"text": "a"}` or `{"special": "backspace"\|"enter"\|"space"\|"back"\|"home"}` | keyboard passthrough while mirroring: type into the phone's focused field, or press a navigation key |
| `macscreen.request` | Android → Mac | `{}` | ask the Mac to mirror its screen to the phone |
| `macscreen.start` | Mac → Android | `{"width": 1280, "height": 800, "port": 54321}` | Mac screen stream ready: raw H.264 Annex-B on the side channel; phone opens a viewer |
| `macscreen.stop` | both | `{}` | end the Mac→phone screen stream |
| `pull.request` | Mac → Android | `{"kind": "latest_image"\|"pick"}` | `latest_image`: phone replies with a `file.offer` carrying `"pull": true` (drag-out). `pick`: phone opens its photo picker and sends the chosen photos |
| `gallery.request` | Mac → Android | `{}` | Mac wants to browse the phone's gallery |
| `gallery.thumbs` | Android → Mac | `{"port": 54321, "items": [{"id": 123, "name": "…"}]}` | thumbnail side channel: for each item, `[4-byte length][JPEG]` in order |
| `gallery.pull` | Mac → Android | `{"id": 123}` | pull the full-resolution image for a gallery item; phone sends it via `file.offer` → Mac Downloads |
| `sync.manifest` | both | `{"files": [{"p": "sub/doc.txt", "s": 123, "m": 1720900000000}]}` | Sync-folder listing (relative path, size, mtime ms). Sent on toggle-on, pairing, changes, and periodically. Receiver pulls files that are missing or newer on the sender |
| `sync.pull` | both | `{"p": "sub/doc.txt"}` | ask the peer to send that sync-folder file; it replies with a `file.offer` carrying `"sync": true` and `"mtime"` so the receiver writes it into its own sync folder (subfolders preserved) and stamps the original mtime (prevents echo loops) |

## Side-channel encryption (v2 peers)

Both sides advertise `"enc": true` in their `identity` packet. When **both** peers
support it, every side-channel byte transfer (files, clipboard images, gallery
thumbnails, audio, screen video) is encrypted with the SAME per-connection
AES-256-GCM key as the control channel. Each offer packet carries `"enc": true`
so the receiver knows how to read that specific transfer — a mixed pairing
(old app on either end) transparently falls back to plaintext.

Encrypted side-channel wire format — repeated records:

```
[4-byte big-endian length N][N bytes: 12-byte nonce ‖ ciphertext ‖ 16-byte GCM tag]
```

The concatenation of all decrypted records equals the original plaintext stream;
`size` fields in offers always refer to PLAINTEXT bytes.

## Audio streaming
Same side-channel pattern as files, but continuous:

- **Mic (phone → Mac):** the phone records its microphone (16 kHz mono PCM16),
  opens a listener, and sends `audio.start {direction: "mic"}`. The Mac connects and
  plays the stream on a user-selectable output device (pick a virtual device like
  BlackHole to use it as a microphone in other apps).
- **Speaker (Mac → phone):** the Mac captures system audio via ScreenCaptureKit
  (48 kHz stereo PCM16), opens a listener, and sends `audio.start {direction: "speaker"}`.
  The phone connects and plays it through its current audio route — including a
  Bluetooth device paired to the phone.

Raw little-endian PCM16 frames, interleaved. The stream ends on `audio.stop` or when
either side closes the socket.

## Pairing flow
1. Android connects, both sides exchange `identity`.
2. **First time:** Android generates a random 6-digit code, displays it, and sends
   `pair.request {code}`. The Mac displays the same code with Accept/Reject.
   On Accept the Mac generates a per-device secret token, stores it, and replies
   `pair.accept {token}`. The phone stores the token.
3. **Reconnects:** Android sends `pair.request {token}`. If the token matches what
   the Mac stored for that device, the Mac silently replies `pair.accept {token}` —
   no UI on either side. If it doesn't match, the Mac sends `pair.reject`; the phone
   clears its token and falls back to the code flow.
4. Feature packets (`clipboard`, `ping`, `file.offer`) are only honored after pairing.

## File transfer
Files never travel over the main JSON channel — a per-transfer TCP side channel keeps
the control channel responsive:

1. The **sender** opens a TCP listener on an ephemeral port and sends
   `file.offer {name, size, port}` on the main channel.
2. The **receiver** connects to `<sender-ip>:port` (sender IP is already known from the
   main connection), reads exactly `size` raw bytes, and closes.
3. The sender streams the bytes, closes the socket, and tears down the listener.

Received files land in the Downloads folder on both platforms. Duplicate names are
deduplicated by the receiver.

## Roadmap (not yet implemented)
- TLS with pinned self-signed certificates exchanged at pairing (KDE Connect style)
- SMS from the Mac
