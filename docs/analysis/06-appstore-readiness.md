# 06 · App Store Readiness

_Last updated: 2026-07-24. Audited against the App Store requirements in force in 2026._

This is the checklist that stands between the current build and a submittable one.
Items are graded **BLOCKER** (submission will fail / be rejected), **REQUIRED**
(needed for a credible 1.0), and **POLISH** (raises quality, not gating).

## Status at a glance

| # | Item | Status | Grade | Effort |
|---|------|--------|-------|--------|
| 1 | Build with iOS 26 SDK (Xcode 26) | ✅ met (sim build used iPhoneSimulator 26.2 SDK) | BLOCKER | — |
| 2 | Privacy manifest `PrivacyInfo.xcprivacy` | ❌ missing | BLOCKER | S |
| 3 | Export-compliance declaration | ❌ not set | REQUIRED | XS |
| 4 | App Store Connect app record + signing on first archive | ⏳ user step | BLOCKER | S |
| 5 | Final app name + bundle display name | ⏳ pending (rename likely) | REQUIRED | XS |
| 6 | Marketing version → 1.0.0 | ❌ still `0.1.0` | REQUIRED | XS |
| 7 | App icon (1024²) | ✅ present (1024×1024) | REQUIRED | — |
| 8 | Usage-description strings (camera, photos) | ✅ present | BLOCKER | — |
| 9 | Privacy "nutrition label" answers | ⏳ user step (easy — app collects nothing) | REQUIRED | XS |
| 10 | Screenshots (6.9" + 6.5" iPhone, iPad) | ❌ not produced | REQUIRED | M |
| 11 | Live Activity / Dynamic Island | ❌ none (user-reported) | POLISH* | M |
| 12 | Localization (String Catalog) | ❌ English-only | POLISH | M |
| 13 | Accessibility pass (VoiceOver / Dynamic Type) | ⚠️ see [03-ux-and-design](03-ux-and-design.md) | POLISH | M |

\* Not gating for submission, but the user explicitly wants it — tracked in [07-roadmap](07-roadmap.md).

---

## 1. iOS 26 SDK — met

Since **28 April 2026**, App Store submissions must be built with the **iOS 26
SDK**. Our simulator build linked `iPhoneSimulator26.2.sdk`, so Xcode 26 is
installed and this is satisfied. Note the distinction: the **deployment target**
stays `iOS 17.0` (`project.yml`) — that is allowed and keeps iOS 17–25 devices
supported. Only the *SDK you build against* must be 26.

## 2. Privacy manifest — BLOCKER, missing

There is no `PrivacyInfo.xcprivacy` anywhere in the project. The app uses two
**required-reason API** categories that must be declared:

- **File timestamps** — `FileStore.entries` and stores read
  `.contentModificationDateKey` / modification dates to sort the library
  (4 files). Category `NSPrivacyAccessedAPICategoryFileTimestamp`, reason
  **`C617.1`** (timestamps of files inside the app container).
- **User defaults** — `AppSettings`, `ScanFavorites`, `CloudSyncPreference`,
  GPU/adaptive flags (4 files). Category
  `NSPrivacyAccessedAPICategoryUserDefaults`, reason **`CA92.1`** (access to
  info from the app itself).

The app collects **no** user data and has no third-party SDKs, so
`NSPrivacyTracking` is `false` and `NSPrivacyCollectedDataTypes` is empty — a
clean privacy story. Add this file to the **app target** (and, because the
widget also reads UserDefaults-style prefs via the App Group and file
timestamps, add a copy to the **widget target** too):

```xml
<!-- MagicCamera/App/PrivacyInfo.xcprivacy -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key><array/>
    <key>NSPrivacyCollectedDataTypes</key><array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>C617.1</string></array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
    </array>
</dict>
</plist>
```

Wire it into `project.yml` (it lands in the bundle automatically as a resource
once it is inside the `MagicCamera` source path; verify it is in the target's
resources after `xcodegen generate`).

## 3. Export compliance — set it once

The app uses only HTTPS / Apple's standard crypto (no custom encryption). Add to
`Info.plist` to skip the per-upload export-compliance prompt:

```xml
<key>ITSAppUsesNonExemptEncryption</key><false/>
```

## 4. Signing & App Store Connect — user step

Automatic signing + team `8Y755TXDN8` + the iCloud and App Group entitlements are
wired. On the **first Archive**, Xcode registers the iCloud container
(`iCloud.com.keks.MagicCamera`) and the App Group (`group.com.keks.MagicCamera`)
on the portal. Before uploading you must create the **App Store Connect record**
for the bundle id (or the final one, see #5).

Steps: `Product ▸ Archive` → `Distribute App` → `App Store Connect`.

## 5. Final name — decide before the ASC record

The user noted the name may change. `CFBundleDisplayName` is currently
"Magic Camera". Changing the **display name** later is trivial; changing the
**bundle identifier** after an ASC record exists is not — so lock the final name
and bundle id *before* creating the App Store Connect record. If the bundle id
changes, the iCloud/App-Group/URL-scheme identifiers that embed
`com.keks.MagicCamera` must change with it (see the identifier list in
[04-features-and-integrations](04-features-and-integrations.md)).

## 6. Version → 1.0.0

`MARKETING_VERSION` is `0.1.0`. Ship 1.0.0. `CURRENT_PROJECT_VERSION` (build
number) must increase on every upload.

## 9. Privacy nutrition label

In App Store Connect, answer "Data Not Collected" — the app stores everything
locally / in the user's own iCloud, has no analytics, no accounts, no network
calls to first-/third-party servers. This is a genuine selling point; say so in
the description ("Your scans never leave your devices").

## 10. Screenshots & marketing

Needed: iPhone 6.9" and 6.5" and iPad 13" screenshots, an optional preview
video, description, keywords, support URL, privacy-policy URL (a simple hosted
page is enough given "no data collected"). The scanning flow and a finished
textured model make strong hero shots.

---

## Submission punch-list (ordered)

1. Add `PrivacyInfo.xcprivacy` (app + widget). **BLOCKER**
2. Add `ITSAppUsesNonExemptEncryption=false`.
3. Lock final name + bundle id; propagate to iCloud/App-Group/URL-scheme ids.
4. Bump version to 1.0.0.
5. Create the App Store Connect record; first Archive to register containers.
6. Fill privacy label ("Data Not Collected"), rating, description, screenshots.
7. TestFlight internal build → sanity-check iCloud/widget/share on a real device.
8. Submit.

## Sources
- [App Store submitting](https://developer.apple.com/app-store/submitting/)
- [Privacy requirement start date (Apple Developer News)](https://developer.apple.com/news/?id=pvszzano)
- [App Store submission checklist 2026 (Fload)](https://www.fload.com/blog/app-store-submission-checklist)
- [How to publish to the App Store in 2026 (Cynoteck)](https://www.cynoteck.com/blog-post/how-to-publish-app-to-the-app-store)
