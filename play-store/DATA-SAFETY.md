# Data Safety form answers — Bifrost

Play Console → App content → Data safety. Bifrost's answers are simple because
it collects nothing — this section is a genuine strength, not a chore.

## Data collection & sharing
- **Does your app collect or share any of the required user data types?** → **No**

Rationale (Google's definitions): "Collected" means data is transmitted off the
device to you (the developer). "Shared" means transferred to a third party.
Bifrost has no servers and no third-party SDKs. All data (clipboard, files,
notifications, screen, audio) is processed on-device and sent only to the user's
OWN paired Mac over their local network — never to the developer or any third
party. Peer-to-peer transfer to the user's own other device is not "collection"
or "sharing." (This mirrors how similar local-only apps like KDE Connect and
LocalSend declare.)

## Security practices (declare these)
- **Is all of the user data encrypted in transit?** → **Yes** — the device-to-device
  link uses ECDH P-256 key exchange + AES-256-GCM.
- **Do you provide a way for users to request that their data be deleted?** →
  Not applicable / No data is collected, so there is nothing stored to delete.
  (There's no account and no server-side data.)

## If Google asks about specific sensitive access
The app ACCESSES sensitive things on-device (notifications, microphone, screen,
files) but does not COLLECT them (nothing is sent to the developer). Be ready to
explain in the permissions declarations (see SUBMISSION-CHECKLIST.md) that each
access exists solely to relay data to the user's own paired computer.
