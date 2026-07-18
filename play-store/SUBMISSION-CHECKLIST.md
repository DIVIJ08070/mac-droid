# Bifrost — Play Store submission checklist

Work top to bottom. Steps marked **[you]** need your account/hands; the rest is
prepped in this repo.

## 0. Before you start
- [x] Privacy policy live → `https://mac-droid.vercel.app/privacy.html`
- [x] Contact email set → `divijpatel0807@gmail.com` (in privacy policy + listing)
- [x] Creator credit + Instagram (@divij_0_0_7) added to the website
- [x] App made Play-compliant in code: Calls feature removed, self-updater removed,
      Accessibility prominent-disclosure added, `.aab` build enabled *(done in the app)*

## 1. Developer account — **[you]**
- [ ] Create a **Google Play Developer account** — $25 one-time — play.google.com/console
- [ ] Complete identity verification (Google now requires ID for personal accounts)

## 2. Create the app — **[you]**
- [ ] "Create app" → name **Bifrost**, language English, type **App**, **Free**
- [ ] Package name is **com.macdroid.app** — ⚠️ this is PERMANENT once published; it's
      not user-visible, so keeping it is fine
- [ ] Enroll in **Play App Signing** (recommended): Google holds the app signing key;
      you upload builds signed with your existing keystore as the "upload key"

## 3. Store listing — **[you]** (content is ready in LISTING.md)
- [ ] Paste app name, short + full description from `LISTING.md`
- [ ] Upload **app icon** 512×512, **feature graphic** 1024×500, and **2–8 phone screenshots**
- [ ] Category **Tools**; add contact email + website + privacy-policy URL

## 4. App content declarations — **[you]**
- [ ] **Privacy policy**: `https://mac-droid.vercel.app/privacy.html`
- [ ] **Data safety**: answer per `DATA-SAFETY.md` → "No data collected / shared", encrypted in transit = Yes
- [ ] **Content rating** questionnaire → it's a utility, no objectionable content
- [ ] **Target audience**: 18+ or 13+ (not for children)
- [ ] **Permissions declarations** (the important ones for this app):
  - **Accessibility (AccessibilityService)** — declare the use: "Remote control of
    the phone from the user's paired Mac (trackpad/remote input) and browser-tab
    sync. A prominent in-app disclosure is shown before the user enables it." Attach
    a short screen-recording of the disclosure + feature if asked.
  - **Foreground service types** (Android 14+) — declare each: `microphone` (stream
    phone mic to Mac), `mediaProjection` (screen mirroring), `connectedDevice`
    (keep the link to the paired Mac alive).
  - If the app still requests **All files access** (MANAGE_EXTERNAL_STORAGE) for the
    file browser / Sync Folder, fill the **All files access declaration** and justify
    it as a file-management feature. (If review pushes back, the fallback is to scope
    it to the Media/Documents pickers.)

## 5. Upload the build — **[you]**
- [ ] Build the bundle: `cd android && ./gradlew bundleRelease`
      → `android/app/build/outputs/bundle/release/app-release.aab`
- [ ] **Closed testing** track first: upload the `.aab`, add **12+ testers** (email list)
- [ ] ⚠️ Google requires new personal accounts to run closed testing with 12+ testers
      for **14 days** before you can apply for production. Plan for that two-week gate.

## 6. Go to production — **[you]**
- [ ] After 14 days of testing, apply for production access
- [ ] Create a production release, upload the same/newer `.aab`, submit for review
- [ ] Review typically takes a few days; sensitive permissions (Accessibility) can add time

## Known risks to watch
- **Accessibility** is the main review risk. The prominent disclosure + a clear
  permissions-declaration + (if asked) a demo video are your mitigations. If rejected,
  the reviewer will say which policy — reply with the companion-device justification.
- **All files access** may draw a follow-up; have the file-manager justification ready.

## After launch
- Point the website's **Android** download at the Play Store listing (replace the
  APK link). The Mac stays on the Terminal-install flow as-is.
- Updates now ship through Play — just bump versionCode, upload a new `.aab`.
