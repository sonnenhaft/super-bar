# Super Bar for iPhone

Native SwiftUI app and WidgetKit extension, targeting iOS 17+. Open
`SuperBar.xcodeproj` and select the **SuperBar** scheme. The project references
the existing cloud clients and BLUETTI protocol sources directly; it does not
copy any Mac account files, local paths, tokens or passwords into the bundle.

## Build

Complete Xcode's first launch (license, components and an iOS Simulator runtime),
then run `bash iOS/build.command` from the repository root. This builds an unsigned
simulator app into `.build/ios`. Build and validation use only Xcode's tools;
no Python, package manager, project generator or third-party packages are required.
The checked-in Xcode project is the source of truth. Add new Swift files to the
appropriate target in Xcode; `iOS/check.command` checks target membership and
rejects external packages and script build phases.

For an iPhone installation, select your development team in **both targets**.
Set unique bundle identifiers and the same `SUPER_BAR_APP_GROUP` build setting
for the app and extension. Register that App Group with the signing team and
enable it on both identifiers. Choose your connected iPhone and Run. Signing
and App Group availability depend on the Apple developer account; the unsigned
simulator build is not an installable IPA or a TestFlight release.

## Menu layout

The iPhone app keeps the Mac menu's single scrolling panel: Climate (TCL/LG),
Battery, Energy, then inline Settings. Selecting a device expands its controls
in place; only one section opens at a time. There are no tabs or separate home
dashboard. Colors, 9-point card corners, thin outlines, brand labels and device
artwork follow the Mac version. App and widgets share the same SwiftUI cards;
outer padding is 14 points in the app and 10 in widgets.

The reusable UI lives in `Sources/Shared/`: `PanelTheme.swift` holds the sRGB
palette and layout constants, `PanelComponents.swift` the common surfaces,
headings, brand/name labels and energy tiles, and `DeviceIdentity.swift` the
name normalization. The Mac menu compiles those exact files too; its AppKit
colors are adapters over the same palette. `Sources/ClimateArtwork.swift`
provides the shared vector artwork. No duplicate UI copy lives under `iOS/`.

Cloud protocols, readings, units and energy pricing already come directly from
`Sources/`. Both apps now also use `DeyeStore` and `TuyaStore` directly: loading,
saved readings, authentication, meter selection and history throttling have one
implementation. There is no separate phone energy controller. The stores expose
an awaitable refresh so iOS can cancel foreground/background work cleanly.

`Sources/Shared/EnergyDetails.swift` and `Sources/EnergyCharts.swift`
provide the identical charts, coverage handling, bill/ROI periods and tariff
settings in both apps. Chart selection supports touch as well as pointer hover.
`Sources/Shared/ClimateControls.swift` supplies the same temperature, fan and
airflow controls to the Mac and phone climate cards, with larger touch targets
on iOS.

`Sources/LG/LGDeviceState.swift` also supplies the same capability
validation and state decoding to Mac and iPhone. Platform owners retain their
own polling, lifecycle, menu pinning, Bluetooth transport and secure storage.
LG's Mac controller still mixes menu management with polling/command queues;
the phone LG controller remains separate. The AppKit battery detail view and
the two Bluetooth transports have not yet been unified.

## Connections and behavior

- Deye and Smart Life: log in from Settings. Smart Life uses the existing Mac
  client's country 63 / EU configuration. Choose the main meter explicitly.
  Daily energy charts and estimated billing reuse the Mac accounting model.
- TCL Home: sign in from Settings. Power, supported temperature range, modes,
  fan, swing, Eco and presets use the existing confirmed-command queue. History
  retains the existing Manila / 09:00 accounting rules.
- LG ThinQ: enter a personal token, country and region. The token is stored in
  Keychain. Power, temperature, fan and other controls are exposed only when
  the device profile advertises them; writes are checked against reported state.
- BLUETTI: allow Bluetooth once. Opening or returning to the app automatically
  scans for nearby AC50P stations and reads each station in turn. Failed reads
  retry automatically; the refresh control starts a new pass immediately. Each
  station has a full-width card and a pencil button for its persistent local name.
  Names also appear in widgets. The shared Mac station directory handles aliases.
  Bluetooth stops in the background and resumes on return; saved readings retain their age.
  Close another BLUETTI client if it already holds the station connection.

Deye, Smart Life and TCL sessions (including password hashes and tokens) and
LG's token live in the app's device-only, non-synchronizing Keychain. Credentials
are available after the first unlock following a restart for background refresh.
Legacy private files migrate automatically and are removed only after Keychain
write/readback verification. A Keychain failure never falls back to file storage.
The App Group contains display readings, supported controls and widget selection only. Accounts
are entered separately on iPhone; Mac credentials are never silently imported.

Connect simulator accounts through the app's Settings, which saves credentials
directly in Keychain. Plaintext simulator staging has been removed, including
temporary copies. No separate credential-import command is needed.
Previously staged credentials still migrate to Keychain and are removed only
after verified storage. The legacy LG importer is excluded from device and
Release builds. Session values never enter the app bundle or command arguments.

## Widget

There is exactly one widget: **Super Bar**, available only in the large Home
Screen size. Climate, Battery and Energy share the same panel. Select a TCL/LG
unit, toggle power, use −/+ or open the inline temperature grid. Battery and
Energy remain visible while choosing a temperature. Section links open the app.
Display-only intents persist the selected unit/grid in the App Group. Commands
run in the containing app process, using its private Keychain and existing cloud
clients; the extension does not receive credentials. Commands validate supported
settings and refresh cloud state, then update readings only after confirmation.
Controls become unavailable after five minutes without a successful check.
The app writes a shared snapshot and asks WidgetKit to reload. Widgets display
timestamps and switch to a saved-reading label after five minutes. Missing values
stay unavailable. Climate shows up to three devices per brand; Battery shows the first station.

Background app refresh is requested no sooner than 15 minutes and may be deferred
or skipped by iOS. The extension does not poll cloud APIs or use Bluetooth.
Widgets cannot promise the Mac menu's live polling cadence. See Apple's
[Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

## Validation

On 2026-11-13 both targets built through Xcode 27.2. The application launched on
iPad Pro 13-inch (iOS 26.5) and was exercised on iPhone 17e (iOS 27.2).
Authorized local sessions were imported into the simulator sandbox. Deye and
Smart Life readings, 30-day history, billing, three TCL units and LG Bottom
loaded. LG Bedroom returned HTTP 416; its controls remained disabled.
The temporary LG import file was removed after Keychain import.

The single large widget was installed on the Home Screen and displayed the
shared readings. Climate, Battery and Energy links opened their sections.

Interactive climate controls were subsequently built and exercised on iPhone
17e (iOS 27.2): switching TCL units and opening the widget's inline temperature
grid worked without opening the app. The app's full 16–30 °C popover was checked
and its placement corrected to avoid clipping. Actual simulator PNGs are in
`screenshots/iphone-app-temperature.png` and `screenshots/iphone-widget-temperature.png`.
No hardware commands were submitted during this UI check. Power/temperature
command confirmation on physical devices and execution routing on older iOS
versions remain device-QA work; build metadata contains the app-process routing.
Expanded climate controls, history, settings and scrolling were checked without
sending commands to real devices. The simulator correctly reports Bluetooth as
unavailable. The native test suite and `iOS/check.command` passed after the fixes.

In this environment terminal builds hit Swift macro sandbox restrictions and
`simctl` cannot connect to CoreSimulator even after escalation; building/running
through the Xcode UI works. Xcode's normal DerivedData contains the verified app
and embedded widget extension.

Still verify on a physical iPhone: fresh account sign-in, supported LG/TCL
commands, denied Bluetooth permission, AC50P discovery, reconnection and
background cancellation. Dynamic Type extremes and actual iOS background
refresh scheduling have not yet been validated.

This is the initial mobile port. LG history shows completed calendar days in the
phone's timezone; the Mac's 09:00 boundary estimation is not reproduced for LG.
Battery names can be edited on the phone. Widget battery selection is not implemented yet. It has not been published
to TestFlight or the App Store.

## App Store preparation

See [APP_STORE.md](APP_STORE.md) for implemented privacy safeguards and the
remaining release blockers, including vendor API authorization, public privacy
policy, review access and physical-device validation. This is not yet a
submission-ready release.

## Device update validation

`iOS/check.command` also checks battery alias transfer between host-specific UUIDs,
rename persistence, reset and ambiguous advertisement names. For local development
installs, an optional `SUPER_BAR_STATION_ALIASES` JSON environment dictionary maps
full AC50P advertisement names to display aliases once per import. It contains no
credentials and is excluded from Release. Keep personal values in an ignored
local Xcode scheme, never in the shared project. Normal Settings no longer shows
a Keychain permission button; retry is offered only after a real access failure.

Physical iPhone validation (2026-11-13): automatic discovery/read of the Office
AC50P returned 100% and fresh input/output power without tapping Find or Connect.
Both desktop display aliases appeared on the phone. The second station had no
reading during this check. Simulator UI validation exercised rename/save/restore
and confirmed that normal Connections settings contain no Keychain access button.
