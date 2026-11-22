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
- The iPhone release uses the provider sign-in forms in Settings. The widget gallery
  preview is display-only. The iPhone app currently has no interactive review demo.

## Required before submission

1. **Provider authorization.** Confirm the release integration and artwork rights
   for each provider using the findings below. Apple asks developers to have
   permission to use third-party services and to produce authorization on request.
   [App Review Guidelines, sections 5.2.1 and 5.2.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property)
2. **Privacy and user control.** Supply the publisher/contact, public privacy and
   support URLs. Document purposes, providers, retention, deletion and consent
   withdrawal. Complete App Store Connect labels based on actual provider flows;
   direct-to-provider traffic is not automatically “no data collected.” Finish
   disconnect/local-data removal for every provider with in-flight task
   cancellation so cleared credentials cannot be written back. Deleting the app
   alone is insufficient to promise deletion of Keychain items or provider data.
   This app does not create a separate Super Bar account.
3. **Review access.** Provision provider-authorized review accounts and test
   equipment, then verify the reviewer steps below from a clean install. Apple
   accepts an active demo account or a fully featured demo mode with the resources
   necessary for review. Section 2.1 calls for prior Apple approval when legal or
   security obligations prevent supplying a demo account. A recording can explain
   the hardware interaction alongside the review access.
   [App Review Guidelines, section 2.1](https://developer.apple.com/app-store/review/guidelines/#app-completeness)
4. **Device QA.** Test fresh sign-ins, expired/revoked sessions, logout, failures,
   Bluetooth permission denial/recovery and real AC50P pairing. Test permitted
   control commands on real hardware, background refresh, widget staleness,
   VoiceOver and accessibility text sizes. LG Bedroom's observed HTTP 416 needs
   diagnosis; the simulator cannot establish BLE correctness.
5. **Distribution.** The project specifies team `D4V8YBWYX3`, app ID
   `com.sonnenhaft.superbar.ios`, widget ID `com.sonnenhaft.superbar.ios.widgets`
   and group `group.com.sonnenhaft.superbar`. Verify that both distribution
   profiles grant that App Group and that the publisher has access to the app
   record in App Store Connect. Choose the release version/build, supply support
   metadata and screenshots, then validate a signed iOS archive with both privacy
   manifests and the embedded widget.
6. **Encryption.** Answer Apple's export-compliance questionnaire for the actual
   protocol crypto and TLS usage. Do not set an encryption-exemption plist flag
   merely to suppress the question.

## Provider terms checked on 2026-11-17

| Provider | Current integration and outstanding release evidence |
| --- | --- |
| Deye | Super Bar reads the account service's `/maintain-s/` routes. Deye's published EU consumer terms grant personal use and reserve brand rights. Deye offers separate developer applications and agreements for OpenAPI. Confirm the applicable regional agreement and endpoints for this app registration. [Deye Cloud terms](https://eu1.deyecloud.com/EU-TermsOfService-en.html) · [Deye developer portal](https://developer.deyecloud.com/) |
| Tuya / Smart Life | Super Bar signs mobile API requests with an existing client registration. Tuya documents authorization for a developer's own cloud project. Its published annual store-distribution agreement applies specifically to its SmartLife App SDK. Permission for the current mobile registration remains unverified. [Tuya account authorization](https://developer.tuya.com/en/docs/iot/authorization-code-page-usage?id=Kdkyz44dz6a7r) · [SmartLife SDK distribution terms](https://developer.tuya.com/en/docs/app-development/app-sdk-price?id=Kbu0tcr2cbx3o) |
| TCL Home | Super Bar uses TCL Home's mobile registration, regional discovery and device APIs. The published GB app terms limit use to private, non-commercial purposes and restrict service for third parties. Confirm the applicable Philippine and release-territory terms and permission for this client. The publisher's Philippine listing links its global terms. [TCL Home app terms, section 3](https://sgp-default-prod.aws.tcljd.com/v2/resource/prod/common/app-privacy/terms-and-conditions-mobile.html?country=GB&language=en) · [Philippine App Store listing](https://apps.apple.com/ph/app/tcl-home/id1475407335) |
| LG ThinQ | Super Bar uses mobile account login and ThinQ2 device calls. LG documents a personal API and a Business API for partners. Confirm which registration covers this distributed consumer app and its AC controls. [LG's API announcement](https://www.lg.com/global/newsroom/news/home-appliance-solution/lg-opens-thinq-api-to-foster-smart-home-innovation/) |
| BLUETTI | Super Bar reads the AC50P locally over Bluetooth using a native adaptation of MIT-licensed rustytti. BLUETTI documents a serial-number authorization file for its own Bluetooth library. Public distribution rights for this independent client and bundled BLUETTI artwork remain unverified. Also confirm rights for the TCL Home artwork identified in the bundled notices. [BLUETTI Bluetooth documentation](https://github.com/bluetti-official/bluetti-bluetooth-lib/blob/main/README.md) · [Bundled notices](../Resources/THIRD_PARTY_NOTICES.txt) |

## Reviewer access and notes

Before submitting, supply dedicated provider-authorized test accounts linked to
a Deye site, a Smart Life meter, and test TCL and LG units. Record their regions
and working sign-in details in App Store Connect's private review information.
Keep credentials out of source control, screenshots and the app bundle. For
Bluetooth, arrange access to an AC50P within range of the review iPhone, or
agree an alternative with App Review. The following notes describe the current
release UI and can accompany those arrangements. [Apple's review access guidance](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)

> Open **Settings → Connections** and select each provider in turn. Sign in with the supplied test accounts and regions. The Smart Life form uses country code 63 and the EU server.
>
> Tap **Energy** and select the test meter under **Main consumption meter**. Tap the refresh arrow to read solar generation and household consumption. Expand **AC** and select a test unit to see its room reading, setpoint and power history. Viewing these screens leaves the unit's settings unchanged.
>
> With the AC50P nearby, tap **Allow Bluetooth** in **Battery** and grant the iOS permission. Super Bar discovers stations automatically while open. Tap a station to see charge, output and any available runtime estimate. Its output chart builds from readings collected on this phone.
>
> Add the large **Super Bar** widget to the Home Screen. After the app receives readings, use **Settings → Update widget** and return to the Home Screen. Compare the room and battery readings and energy costs. A clock marks a saved value. Tapping a section opens the corresponding screen in Super Bar.

## TestFlight handoff

1. Once the signed archive is available, the publisher uploads it to the app
   record and answers the encryption questions for that build. Wait for build
   processing before assigning it to a tester.
   [Apple's TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) · [Export compliance for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/)
2. If the miloradovich tester is an eligible App Store Connect team member, assign
   the build to an internal group. For external testing, supply the beta description,
   feedback email, review contact and access details, then submit the first external
   build for TestFlight App Review.
   [Internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/) · [External testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers) · [Beta review information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
3. On miloradovich, install the specific build through TestFlight. Record its
   version and build number, compare readings for both AC50Ps with the large
   widget, and capture both screens. The generic simulator build verifies the
   app and widget compile together. A TestFlight install remains pending.

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
