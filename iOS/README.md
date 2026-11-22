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
artwork follow the Mac version. The widget uses the same `PanelSections` screen
composition, summary grids and full card styles, with all sections collapsed and
no charts. The shared layout uses 14-point padding and scales proportionally to
fit WidgetKit's fixed canvas; it has no separate table or compact card design.

The screen hierarchy lives in `Sources/Shared/PanelScreen.swift`: both Mac's
`UnifiedPanel` and iPhone's `PhoneRoot` supply their existing models, navigation
actions and platform controls to it. Section headings, separators, footer and
settings placement have one implementation. `ClimatePresentation.swift` and
`BatteryPanel.swift` provide the desktop-based device cards; `PanelEnergySection.swift`
provides Energy and common settings. Narrow layouts wrap controls and use two
AC columns instead of the desktop's three. The same source files are compiled
into both apps, with larger touch targets on iOS.

`PanelTheme.swift` holds the sRGB palette and layout constants,
`PanelComponents.swift` the common surfaces and labels, and `DeviceIdentity.swift`
the name normalization. Mac AppKit colors adapt the same palette, and
`Sources/ClimateArtwork.swift` provides the shared vector artwork.

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
the phone LG controller remains separate, as do the Bluetooth transports.
The main Mac panel now renders the shared SwiftUI battery card directly. Its
legacy menu adapter allocates an AppKit hosting view only while an actual menu
displays it. Platform shells keep ownership of services; rendering the shared
screen does not create another network client, timer or Bluetooth connection.

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
- BLUETTI: tap **Allow Bluetooth** in the battery section and grant the system permission. Opening or returning to the app automatically
  scans for nearby AC50P stations and reads each station in turn. Failed reads
  retry automatically; the refresh control starts a new pass immediately. Compact
  station cards share a row. Open a station and tap the pencil to rename it.
  Names also appear in widgets. The shared Mac station directory handles aliases.
  Bluetooth stops in the background and resumes on return. In the foreground,
  each successfully read station stays visible between polls until a scan or
  failed read indicates it is unreachable. Widgets retain the age of saved readings.
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

Super Bar also offers three compact families: medium and small Home Screen,
and rectangular Lock Screen. All three preserve every visible snapshot device
and all navigation links. AC cards show names, room/target temperatures,
on/off dots, eco and saved-reading indicators. Battery cards show both stations,
charge, output and available runtime. Energy retains generation, consumption,
net power and hourly/daily costs, followed by Settings and the app refresh link.
These families reduce spacing and font scale to fit rather than limiting the
room count or dropping sections. Medium and Lock Screen layouts put AC and
battery/Energy sections side by side; small uses stacked sections. Card names
wrap naturally without reserving empty title rows. Room readings have higher
contrast, Energy values are larger, and scale fitting uses 2.5% steps to use
the available height. Very small accessory text and tap areas are a
consequence of keeping the full contents in the fixed Lock Screen canvas.
iOS renders the Lock Screen in monochrome: dots remain, but their green color
is desaturated by the system. See Apple's
[rendering modes](https://developer.apple.com/documentation/widgetkit/widgetrenderingmode).
The same saved snapshot and offline filtering apply in every family.

The large **Super Bar** Home Screen widget repeats the app with all sections
collapsed: the same shared AC summary cards, battery charge cards and Energy
tiles, followed by Settings. It uses `ClimateSummaryCard`, `BatterySummaryCard`,
`PanelEnergyTile` and `PanelSectionHeading`; it has no separate table layout.
Energy shows generation, consumption, net power and the same hourly and rolling
24-hour peso balance as the app (an asterisk marks partial coverage).
Tap a room row or a battery to open that exact device, selected and expanded in
the app. Solar, Load and each peso balance select their corresponding Energy
component. Section headings open the full section. Provider and device IDs are
encoded separately, so similarly named TCL/LG units cannot select each other.
Repeated links scroll again; cold launches retain the selection while devices load.
Settings opens and expands the app's settings. The refresh icon opens the app;
the widget itself does not start a provider request. Links only navigate and
never send device commands. This uses WidgetKit's
[per-component Link support](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity).

A clock marks a last-known reading when the device disconnects or the reading
is more than five minutes old. Disconnecting Bluetooth keeps the station’s last
measured charge and runtime in the snapshot; disconnected stations are visible
only with **Show offline devices** enabled. Devices that have never supplied a
reading stay hidden while offline unless **Show offline devices** is enabled.
Connected air conditioners remain visible when powered off. The widget fits up
to six rooms and two stations; section links open the full lists.

Background app refresh is requested no sooner than 15 minutes and may be deferred
or skipped by iOS. The extension does not poll cloud APIs or use Bluetooth.
Widgets cannot promise the Mac menu's live polling cadence. See Apple's
[Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

## Validation

On 2026-11-18 compact widget previews were rendered from their actual SwiftUI
views with test readings at 320×148, 148×148 and 160×72, including empty snapshots.
The current layout previews are in `.build/widget-fit/`; `.build/widget-dense/`
and the earlier limited-room versions in `.build/widget-sizes/` are superseded.
These are previews, not screenshots from
miloradovich or a running simulator; on-device taps still require verification.
The app and embedded widget built for iOS Simulator; project, snapshot and route
checks passed. Long room names wrap to up to three lines in compact cards.

On 2026-11-18 the widget presentation was corrected to the collapsed-app design.
The current shared cards were rendered at 344×360 and 320×330 with six AC units
and two batteries, plus an empty-account state. Previews with test readings are
in `.build/widget-collapsed/`. Route and snapshot checks passed; the app and
embedded extension built for iOS Simulator. This does not constitute a launch
or a Home Screen tap test on miloradovich.

On 2026-11-17 the shared native checks, widget snapshot checks, route round trips
(including Unicode IDs, provider collisions and invalid/control URLs), and app
embedding checks passed. Both simulator and unsigned iPhone builds include the
widget extension. The actual SwiftUI widget view was rendered and inspected at
344×360 and 320×330 with six rooms, two stations, old readings, zero load and
empty accounts. Previews are in `.build/widget-review/`; their readings are test
fixtures. This pass did not run on miloradovich or in Simulator: CoreSimulator
was unavailable. End-to-end Home Screen taps on the new build remain unverified.

On 2026-11-13 both targets built through Xcode 27.2. The application launched on
iPad Pro 13-inch (iOS 26.5) and was exercised on iPhone 17e (iOS 27.2).
Authorized local sessions were imported into the simulator sandbox. Deye and
Smart Life readings, 30-day history, billing, three TCL units and LG Bottom
loaded. LG Bedroom returned HTTP 416; its controls remained disabled.
The temporary LG import file was removed after Keychain import.

The single large widget was installed on the Home Screen and displayed the
shared readings. Climate, Battery and Energy links opened their sections.

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
Battery names can be edited on the phone; tapping a widget station selects it in the app. It has not been published
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

## LG webOS remote expansion (2026-11-19, source-only)

The shared Mac/iPhone TV remote now includes Home, Back, Menu, mute, playback,
reported installed apps, broadcast channels and text entry. The keyboard sends
only explicitly submitted text to the focused TV field and clears its local
buffer after submission, disconnect or TV selection changes. App and channel
IDs must come from that TV's reported lists. Media/text/app controls are shown
only for advertised services; explicit 401/403/404 refusals disable that command
until controls are refreshed through a new connection. A service advertisement
is not proof that a particular foreground app accepts playback or text input.
Old pairing grants may need an explicit Pair again for the additional permissions.
No playback, input, power, text or launch command is sent merely by opening TV.

Implementation boundaries:
- `WebOSTVTransport.swift`: ephemeral WebSocket sessions, local certificate pinning.
- `WebOSTVPairingStore.swift`: backward-compatible Keychain records and revocation.
- `WebOSTVRemote.swift`: registration/PIN, serialized requests and socket lifecycle.
- `WebOSTVCommand.swift`: typed SSAP commands and bounded payload validation.
- `LGTelevisionStore.swift`: discovery, saved TV identity, selection and UI state.
- `LGTelevisionPanel.swift` / `TelevisionSection.swift`: shared platform presentation.

Requests use cancellation handlers to close their captured socket, and replies
from replaced connections cannot update the current selection. Queued commands
are bounded, discarded on disconnect/selection change and never persisted.
PIN strings retain leading zeros; explicit pairing ignores old rejected keys.
AirPlay discovery IDs remain separate from router-confirmed wake MAC addresses.

Protocol references: LG Connect SDK's
[WebOSTVService implementation](https://github.com/ConnectSDK/Connect-SDK-iOS-Core/blob/master/Services/WebOSTVService.m)
and [service documentation](https://connectsdk.com/en/latest/apis-ios/ios-webostvservice.html).
Device support and UI behavior remain unverified: no app launch, installation,
TV connection, pairing or device command was performed for this source change.
Offline fixture assertions were added for a later test run; tests were not run.

## Power-on source investigation (2026-11-19)

LG documents iPhone power-on through Wi-Fi, while Android can also use Bluetooth.
For webOS 6 the setting is All Settings → Devices → External Devices → TV On With
Mobile → Turn on via Wi-Fi. Models before webOS 3.5 may support power-off only.
Source: [LG ThinQ setup / Power On-Off](https://www.lg.com/us/support/help-library/lg-tv-how-to-set-up-the-lg-thinq-app-on-your-lg-smart-tv--20152745625356).
ThinQ's private implementation has not been inspected; its documentation does not
establish the exact packet format or prove equivalent behavior on this TV.
The user reports that ThinQ also does not wake this television. That is not proof
of an app signing failure; TV settings, model support and network delivery remain
unverified.

Primary code comparisons:
- [lgtv2](https://github.com/hobbyquaker/lgtv2/blob/master/index.js) reads wired/wifi
  interface MACs using connectionmanager/getinfo and uses broadcast WOL.
- [aiowebostv](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/webos_client.py)
  implements system/turnOn for reachable TVs and reads getPowerState independently.
- [Swift WOL sender](https://github.com/nakomis/tv-remote/blob/main/TVRemote/Shared/Services/WakeOnLAN.swift)
  targets subnet/global broadcast on ports 7 and 9. Its source alone is not evidence
  of successful physical-iPhone operation or an exemption from Apple signing rules.
- [Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)
  requires approval and a multicast entitlement for physical-iOS broadcast traffic.
  The locally inspected Super Bar provisioning profile does not include it.

Corrections made after comparison: WOL now attempts ports 7 and 9 and retains
unicast/broadcast acceptance separately, including POSIX permission failures.
An open SSAP socket is no longer reported as proof that the screen is on.
getPowerState distinguishes Active, Active Standby, Suspend, Power Off, Screen Off
and Screen Saver. A reachable screen-off/standby set gets an explicit supported
wake attempt; a sleeping set still needs a WOL-capable network interface.
The UI confirms power-on only from a reported active state, never from UDP sendto
or a command acknowledgement. Unknown/unsupported power-state replies stay unknown.

The research changes have not been installed or exercised against the TV. Offline
fixture assertions were added for later execution; no tests were run.

### TV wake signing check (2026-11-19)

A signed Xcode build requesting `com.apple.developer.networking.multicast` was rejected: the current personal development team does not support Multicast Networking, and its provisioning profile lacks the capability. The normal app continues using `SuperBar.entitlements`. `SuperBarAppMulticast.entitlements` is an optional app-only entitlement template for an Apple-approved team/profile; do not apply it to the widget. A successful UDP send only means the OS accepted the packet, not that the TV woke.

Wake packets now go before connection restoration, so an offline TV's socket timeout cannot delay sending them. The last wake result is retained in `lg.tv.wakeDiagnostics.v1` and displayed in the TV connection editor. Background read failures do not replace an in-progress power command's status. No device wake success has been confirmed.

Further source review: LG Connect SDK's `powerOnWithSuccess` reports unsupported; this is not the source of the closed-source ThinQ app. Home Assistant documents Wake-on-LAN and an additional newer-model setting at Support → IP control settings → Wake on LAN. UDP direct-send and broadcast failures are now tracked separately, and the retained unconfirmed result includes both transport outcomes. Power-on restoration uses a three-second per-attempt registration deadline rather than the normal ten-second deadline. This does not bypass the multicast entitlement requirement or prove physical wake.

### Widget handoff to background

Temporary inactive phases (Control Center, app switching animation, permission overlays) no longer cancel provider polling or disconnect Bluetooth. Actual background entry saves the shared snapshot immediately, schedules BGAppRefresh, and starts one read-only refresh under a finite iOS background execution lease. It waits for cancelled foreground polling to finish before starting provider reads, then publishes a final snapshot and reloads the widget timeline before ending the lease. Expiration cancels that refresh and flushes the latest available readings. Scheduled background refresh now awaits TCL/LG as well as energy providers and explicitly publishes the final snapshot; it does not wait for historical chart downloads. Returning to the app cancels the transition refresh. iOS still controls future BGAppRefresh and WidgetKit timing; continuous background polling is not promised. Bluetooth continues to use saved readings when the app is suspended.

### Power-button follow-up

A phone container export after the timeout report retained the configured network MAC but contained no `lg.tv.wakeDiagnostics.v1` entry, so it did not establish which command had run. The single power button now chooses Turn off only for an explicitly confirmed powered-on state, rather than a connected socket with unknown power state. A bounded 40-event local cache trace records taps, rejected command starts, UDP transport results and power failures (no credentials); this avoids relying only on deferred preferences persistence. Temporary inactive phases no longer cancel the TV panel's connection task. Physical power-on remains unconfirmed.
