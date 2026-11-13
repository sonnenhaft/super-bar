# App Store release readiness

Status: development build, not ready for submission. Simulator success does not
establish service authorization, physical-device behavior or App Review approval.

## Implemented

- App and extension each bundle their own privacy manifest. App required-reason
  declarations cover its own preferences (CA92.1), metadata of its own cache files
  (C617.1), and elapsed-time timers (35F9.1). The extension reads display JSON and
  persists its selected conditioner and temperature-grid visibility.
- No tracking or advertising SDKs. No credentials in widget data or app resources.
  The app manifest deliberately does not assert an empty collected-data list:
  provider data flows must be reviewed before privacy labels are completed.
- Deye, Tuya, TCL and LG use one app-private, device-only Keychain backend on
  iOS (not synchronized). Deye/Tuya/TCL migrate existing session files only after
  a verified Keychain write. Failed migration preserves the old file; Keychain
  errors never trigger a file-storage fallback. Mac uses the login Keychain with the same verified
  migration; external CLI import files are preserved. Password hashes remain sensitive credentials.
- Settings explains provider data flows, local storage, Bluetooth and widget
  visibility, and exposes bundled open-source notices.
- A real HTTPS privacy policy can be supplied using the app target build setting
  SUPER_BAR_PRIVACY_POLICY_URL. The settings link appears only for a valid HTTPS
  URL. The empty default is a release blocker, not a policy placeholder.
- Simulator credential import is compiled only in DEBUG + targetEnvironment(simulator).
  Never supply personal cached credentials to App Review or ship them as fixtures.

## Required before submission

1. **Provider authorization.** The current Tuya path signs Smart Life mobile API
   requests using an embedded mobile-app registration. TCL uses the TCL Home
   mobile client ID and its login/discovery APIs. Do not assume their availability
   or the adapter's MIT license permits a public third-party app. Obtain permitted
   integration routes/registrations and any required distribution authorization;
   replace these adapters where necessary. Confirm Deye, LG ThinQ and BLUETTI
   terms and permitted branding too. Preserve feature transparency for reviewers.
2. **Privacy and user control.** Supply the publisher/contact, public privacy and
   support URLs. Document purposes, providers, retention, deletion and consent
   withdrawal. Complete App Store Connect labels based on actual provider flows;
   direct-to-provider traffic is not automatically “no data collected.” Finish
   disconnect/local-data removal for every provider with in-flight task
   cancellation so cleared credentials cannot be written back. Deleting the app
   alone is insufficient to promise deletion of Keychain items or provider data.
   This app does not create a separate Super Bar account.
3. **Review access.** Supply an authorized review account or a clearly labelled,
   fully featured demo mode with synthetic data, plus honest review notes about
   compatible devices and unavailable functions. Prepare a physical-iPhone video
   demonstrating pairing and hardware interaction as requested by Apple. Do not
   disguise unavailable integrations or review-specific behavior.
4. **Device QA.** Test fresh sign-ins, expired/revoked sessions, logout, failures,
   Bluetooth permission denial/recovery and real AC50P pairing. Test permitted
   control commands on real hardware, background refresh, widget staleness,
   VoiceOver and accessibility text sizes. LG Bedroom's observed HTTP 416 needs
   diagnosis; the simulator cannot establish BLE correctness.
5. **Distribution.** Configure the real signing team, registered bundle IDs and
   App Group, production version/build, support metadata and screenshots. Ensure
   the icon is opaque and suitable for App Store upload. Archive a Release build,
   inspect both privacy manifests and resources, generate Xcode's privacy report,
   validate the archive and test through TestFlight on a physical phone.
6. **Encryption.** Answer Apple's export-compliance questionnaire for the actual
   protocol crypto and TLS usage. Do not set an encryption-exemption plist flag
   merely to suppress the question.

References:
- https://developer.apple.com/app-store/review/guidelines/ (2.1, 2.5.1, 5.1.1, 5.2.2)
- https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype

## Preparation validation (2026-11-13)

The changed app and embedded widget built and launched through Xcode on the
iPhone 17e simulator. Both bundled manifests were inspected, and Settings opened
the privacy disclosure and bundled licenses. Existing Deye, Tuya and TCL session
files retained mode 0600 and acquired the iOS `com.apple.MobileBackup` exclusion
marker in the earlier preparation build, before the Keychain migration below. Physical-device data protection and a distribution archive remain to be
validated. `Tests/check.command`, `iOS/check.command` and `git diff --check` passed.

## Keychain migration validation (2026-11-13)

The app and extension rebuilt successfully in Xcode. On the iPhone 17e simulator,
Deye, Tuya and TCL migrated their existing sessions and removed all three legacy
credential files. A second launch loaded the accounts from Keychain; readings
and energy history remained available, and the credential files stayed absent.
LG uses the same device-only Keychain backend and ephemeral networking on iOS.
Tests cover secure-store read/write/readback errors, invalid data, interrupted
migration cleanup, secure-data precedence, preserving external import files and
the explicitly injected file storage used by tests. The full native test suite and iOS checks passed.
No real hardware commands were sent during this check.
