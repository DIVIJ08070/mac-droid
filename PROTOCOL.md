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
| `ping` | both | `{"message": "..."}` | make the receiver ring/notify (find-my-phone) |
| `file.offer` | both | `{"name": "...", "size": 123, "port": 54321}` | a file is ready; receiver pulls it from the side channel |
| `heartbeat` | Android → Mac | `{}` | keep-alive, sent every 15 s; receiver ignores it. A failed write tells the phone the link is dead |
| `url` | both | `{"url": "https://…"}` | open this link on the receiver's default browser |
| `command` | Android → Mac | `{"action": "lock"\|"sleep"\|"mute"\|"volume_up"\|"volume_down"\|"playpause"\|"screenshot"}` | remote-control the Mac; `screenshot` captures and sends the image back as a file |
| `audio.start` | both | `{"direction": "mic"\|"speaker", "sampleRate": 48000, "channels": 2, "port": 54321}` | an audio stream is available on a side channel (same pull model as files, but endless) |
| `audio.stop` | both | `{"direction": "mic"\|"speaker"}` | stop the stream and close the side channel |
| `input` | Android → Mac | `{"a": "m"\|"sc"\|"c"\|"dd"\|"du"\|"g", "dx": 1.5, "dy": -2, "b": "l"\|"r"\|"m", "g": "3left"\|"3right"\|"3up"\|"3down"\|"pinchin"\|"pinchout"\|"4up"\|"4down"}` | touchpad: move, scroll, click (left/right/middle), drag down/up, or a named trackpad gesture. Sent up to ~60×/s; Mac injects CGEvents (needs Accessibility permission) |
| `browse` | both | `{"url": "https://…", "title": "…", "source": "phone"\|"mac"}` | Handoff-style tab sync: the page currently open in the sender's browser. Phone→Mac shows in the Mac menu bar; Mac→phone shows as an "Open on phone" card |

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
- Notification mirroring, battery status, media control
- SMS from the Mac
