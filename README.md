# Super Bar

A native macOS menu bar app for BLUETTI power stations and TCL Home and LG ThinQ air conditioners. Requires macOS 15 or later.

The Mac app, iPhone app and widget use Swift and Apple's system frameworks only.
Building and checking the apps requires Apple's developer tools (full Xcode for
iOS), with no Python, Node, package manager or third-party SDK. The checked-in
iOS Xcode project is edited directly, without a project generator. Standalone
Python diagnostics and historical export scripts are separate optional tools;
the applications and their build/check commands never invoke or bundle them.

![Super Bar menu with TCL air conditioner controls and energy history](docs/super-bar.png)

## Install

Download the Apple Silicon build from [Releases](https://github.com/sonnenhaft/super-bar/releases/latest), or build from source with Apple Command Line Tools (Apple Silicon or Intel):

```bash
git clone https://github.com/sonnenhaft/super-bar.git
cd super-bar
./start.command
```

`start.command` and `install.command` always build a fresh version, close the previous menu bar apps, and install Super Bar in `~/Applications`. The installer verifies the running app's path, process, version, build number, and executable checksum. If verification fails, it restores the previous installation.

## Use

- The 460-point panel uses a shared dark palette, thin borders and cyan selection accents. TCL, LG and BLUETTI use text labels; device buttons share a brand column and row height, with text aligned at the top. LG units use window-unit artwork and TCL uses wall-unit artwork. Clicking an AC device always opens its controls and chart and activates its menu-bar readout, including repeated clicks. Section headings still collapse their contents while keeping the readout. Powered-off AC readouts show a red power symbol beside the pinned room temperature.
- Only one section expands at a time; collapsing it also hides its charts. TCL and LG share the same brand typography, and Energy has no Deye label. The daily chart tooltip and Energy summary show estimated net cost: the whole-house consumption cost minus revenue from selling all generation. A negative balance is labelled Credit. All generation is valued as sold: previous days default to 70% of the purchase tariff, today to 50%. Days missing either generation or consumption are excluded and coverage is shown. The purchase tariff defaults to ₱13/kWh; the resulting sale prices are ₱9.10/kWh for previous days and ₱6.50/kWh today. These are estimates, not billing measurements.
- Green, red and gray dots mean on, off and offline/unknown. Online devices show room temperature even when off; offline summaries show only the name and dot. TCL summaries use two lines; LG cards pair a device icon with name, temperature pins and available power. Set/Room values are independent pin buttons in summaries and expanded controls. ECO leaves sit beside the set temperature. The expanded card keeps the temperature picker and adds bounded minus/plus controls.
- TCL and battery controls align with their device buttons. The selected chart appears in its own Climate, LG, Battery or Energy section. Settings expand inline from the bottom row; refresh, 9–24 pt text size, login and LG settings remain available. Refresh and text-size sliders share a blue filled track. The panel fits its content and scrolls only when taller than the available screen.
- Refresh settings follow the selected brand. Missing credentials show `Sign in to …`; Bluetooth starts only after **Allow Bluetooth**.
- Energy shows yellow production / blue Tuya consumption without a separate meter row or Deye label. Power tiles open the charts and toggle net power beside the clock; the Energy heading collapses the charts. The chart shows 30 days plus a rolling 24-hour generation/consumption curve, including yesterday's readings. Both headings show estimated net cost after generation credit; the detailed calculation remains below. Rolling totals integrate measured power and meter intervals without filling gaps; `*` marks incomplete coverage. Readings become bold while pinned: production minus consumption, yellow for surplus and blue for deficit. Missing/stale readings produce `—`; the selected consumption meter is never silently replaced.
- Energy compares the net bill with a struck-through bill for the same household consumption without solar. Today, calendar month and 30 days each show sale revenue and ROI for that same period: all generation valued at its applicable sale rate divided by panel cost (default ₱400,000, editable in Settings). Coverage is shown; missing days are not extrapolated, and this is not an annualized return. Existing tariff settings are preserved when adding panel cost.
- Power and energy use integers below 800 W/Wh and one decimal with a comma above it: `735 W`, `1,3 kW`, `28,2 kWh`. Completed Deye days and Tuya schemas are cached instead of refetched every poll.

## Connect devices

**TCL:** Super Bar reuses the local TCL Home session. If sign-in is required, enter your TCL Home email and password in the TCL panel.

**LG:** Open **LG settings…** and enter your ThinQ personal access token and account country/region. The app migrates an existing `LGBar/token.txt` into Keychain. Local development builds may import the standalone CLI `token.txt` without deleting that external source. Tokens are never included in the application bundle or repository.

**BLUETTI:** Press **Allow Bluetooth** on the BLUETTI row to start discovery and grant macOS Bluetooth access. Opening the app or panel never starts Bluetooth. Polling continues in the background after the first connection.

**Deye:** The native Swift client imports an existing protected Deye session once and stores its own session in macOS Keychain. Requests, token renewal and saved-login recovery use URLSession directly. If credentials are missing, use **Sign in to Deye Cloud** in its row. No Python, helper scripts, packages, or external runtime are required; credentials are never bundled.

## Credential storage

Deye, Smart Life, TCL and LG use the shared Keychain backend in standard Mac
builds and all iPhone builds. The explicit local Mac development exception is
described below.
On Mac, credentials live in the login Keychain with synchronization disabled and
normal macOS application access controls. iPhone uses device-only Keychain items
available after first unlock. Access tokens, refresh tokens, session IDs, personal
tokens and password hashes used for renewal are all treated as credentials; no
new session files are written by either production app. The credential API always
requires a vault; standard builds do not compile the development file backend.
Tests inject an isolated in-memory
vault. Plaintext passwords are not retained after sign-in; short-lived network
and Bluetooth session keys stay in memory only.

Existing app-owned credential files in Application Support migrate automatically.
The app verifies Keychain write/readback before removing a legacy file. Keychain
errors preserve the old file and never trigger a plaintext fallback. The native
app preserves independently owned import sources. The Deye and Tuya diagnostic
tools also use macOS Keychain: their own legacy session/login files migrate on
first use and are removed only after verified storage. Discovered external
imports remain untouched. The installer and simulator helper do not create
plaintext token copies.

Development builds use ad-hoc signing. A rebuilt Mac app can require macOS
Keychain access approval again because its signing identity changed; the app does
not weaken Keychain access controls to suppress that prompt. A production release
needs stable Apple signing. See [Apple's Keychain access control documentation](https://developer.apple.com/documentation/security/access-control-lists).

### Local Mac development without Keychain prompts

Use one explicit opt-in for local builds and installs:

```bash
SUPER_BAR_DEV_CREDENTIALS=1 ./start.command
```

This compiles the macOS-only development vault. The installed build keeps using
it after relaunch without needing environment variables in Finder. Account
tokens, refresh tokens and password hashes are saved as private local files in
this checkout's `.build/dev-credentials/` directory (directory
0700, files 0600). The files are `deye-session.json`, `tuya-session.json`,
`tcl-session.json` and `lg-token.txt`. They are plaintext development files,
excluded from Git by `.build/` and kept outside the application bundle.
The bundle contains only a text resource with the directory's absolute path,
so restarting the installed desktop app reuses the same local files. If that
resource is missing or invalid, dev mode refuses credential access. Moving the
checkout requires rebuilding to update the path; no alternate directory or
Keychain fallback is selected.

Writes are bounded, atomic and verified; symlinks and non-private files are
rejected. The same in-memory cache and failed-access suppression still apply.
Existing legacy token/session files can be imported read-only; development mode
never removes those import sources or exports anything from Keychain. If only a
Keychain account remains, connect it once in the development app. A Keychain
error never activates this mode automatically.

`SuperBarDevCredentials = true` in the built app's `Info.plist` identifies this
mode. `publish.command` rejects its marker or an enabled development flag.
Release builds reject the flag before compilation. To return to a production
Keychain build, run:

```bash
SUPER_BAR_DEV_CREDENTIALS=0 SUPER_BAR_RELEASE=1 ./build.command
```

No development file vault is compiled into iOS, regardless of this environment
variable. Diagnostic Python tools retain their separate Keychain policy.

## Build and check

```bash
./build.command
Tests/check.command
```

The optimized, ad-hoc signed app is written to `dist/Super Bar.app`. Build and installation scripts report progress while running.

## Native Tuya

Super Bar reads Smart Life directly with Foundation, CryptoKit and Security. On first launch it imports the existing protected `.env.tuya-session.json`, including the chosen main meter, and saves its own session in macOS Keychain. No script, Python interpreter, package or SDK is bundled or invoked. Session renewal uses the saved login; sign-in is Smart Life / country 63 / EU. Only authentication, device reads, and daily/hourly statistics actions are allowed. Device commands are rejected before a request can leave the client. The original scripts below remain standalone diagnostic tools.

The Deye charts compare yellow generation with blue Tuya consumption: paired
30-day energy bars and a connected step line for today's completed-hour average
power, labeled Generation and Consumption. Hourly statistics are already scaled kWh; a full hour's kWh × 1000 gives
average W. Missing hours and unfinished-hour aggregates are omitted. The current
hour is extended using live Tuya samples already collected for the readout.
Adjacent hourly intervals connect at their shared boundary. Consumption lines
break only for missing coverage longer than 30 minutes; other power lines break
after 10 minutes. Date labels are thinned out, and hovering shows the exact day.
History uses the selected
main meter, checks its timezone against the Manila station calendar, and is
cached between launches. It refreshes at most every five minutes while the Deye
charts are selected, reusing completed days. A `*` on a 30-day total indicates
missing days. The 15-minute API remains a diagnostic probe until verified for
this meter. Today's chart time labels use Manila time, including the Deye curve.

Live status polling and chart history have independent schedules. Deye and Tuya
update today's history at most every five minutes while their charts are selected;
their APIs return a whole day, so completed hours are not separately requested.
Completed days are cached and the previous day's partial total is finalized after
midnight. TCL's summary API is polled every 15 minutes (hourly data once an hour),
with one-minute sampling near its 09:00 accounting boundary. LG fetches missing
completed dates, then keeps that archive until another day is complete; failed or
missing archive data is retried at most hourly. Fast live samples for LG, TCL and
BLUETTI still extend local power curves without additional history API requests.

## Tuya CLI


Run `Scripts/tuya.command` without flags. Smart Life is fixed; there is no app-choice
prompt. First login asks for email, country (default 63), server region (default EU),
and a hidden password. Every answer is saved immediately to macOS Keychain,
even if login fails or the next prompt is interrupted. Existing private
`.env.tuya-login.json` files migrate after a verified Keychain write.
Press Enter to keep a saved value, including the password (stored as MD5, never
plaintext), or type a replacement. A successful login saves the account endpoint
returned by Tuya. Subsequent runs reuse the session and automatically log in
again when it expires. There is no User Code or QR requirement for this route.
Only macOS, Python 3.9+ and its standard library are required: no SDK, pip, or
packages. The shared CLI storage calls Apple's Security/CoreFoundation APIs
directly; credentials never travel through subprocess arguments.

The script calls the mobile API directly using the protocol implemented by
[TuyaAPI/cloud](https://github.com/TuyaAPI/cloud) and
[ioBroker.tuya](https://github.com/Apollon77/ioBroker.tuya/blob/master/lib/appcloud.js).
Login follows the mobile app sequence documented in the
[Frida first-login capture](https://github.com/thekoma/aventproxy/blob/main/WHITEPAPER.md#7-phase-4-login-flow-and-session-management)
and [Smart Life mobile client](https://github.com/reetamdan/smartlife-app-tuya/blob/main/plug_api/auth.py):
`thing.m.user.username.token.get` v2, then `thing.m.user.email.password.login` v3,
RSA PKCS#1 v1.5 over the password MD5, with `options` encoded as a JSON string.
The earlier token/login v1 pair could produce a misleading `USER_PASSWD_WRONG`.
DER/PEM keys and decimal RSA moduli are parsed separately from the padding choice.
The app registrations/signing format may be rejected by Tuya as the service changes;
live account compatibility has not been verified. If Tuya requires CAPTCHA or
additional account verification, the script reports it instead of bypassing it.

Devices, likely main meter, and latest cloud power are listed in kW. Power units
and scale come from the product schema. Ambiguous meters are not selected by
largest load; an explicit choice can be saved with `--meter ID`. `--json` emits
structured readings without credentials or device keys. Offline/unsupported
readings are unavailable rather than zero; measurement freshness is not verified.
If power was reported but connection status is unknown/offline, the CLI still
shows it explicitly as the last cloud reading, not a confirmed live measurement.
Each successful device fetch also writes `.env.tuya-devices.json` (mode 600,
ignored by Git), including device datapoints and product schemas for diagnosing
unsupported meters. Account tokens, password hashes, and device local keys are
not included in that snapshot.

The CLI's Keychain item contains the session ID, access/refresh tokens where
applicable, email, app/country settings, and the password MD5 needed for automatic
re-login (treat this hash as a credential). Plaintext passwords and new credential
files are not saved. The old `.env.tuya-session.json` path remains an account
identifier and a migration source. Existing sharing sessions remain readable,
and known local Tuya session files are discovered automatically. Network failures
do not trigger re-login. The Python `Client` context manager exposes `devices()`.
Exit codes: 0 = meter power available, 2 = no unambiguous meter/power, 1 = error.

Checks: `python3 -B -S -m unittest discover -s Tests -p 'test_tuya*.py'`.

Probe the selected meter's historical consumption with
`Scripts/tuya-history.command 2026-11-10 2026-11-11`. With no dates it checks
yesterday and seven days ago (Europe/Warsaw calendar). It prints requests,
complete JSON responses, underlying network errors, and an hourly data summary
to the terminal; credentials and request signatures are redacted. Only auth and
read requests are permitted. `--session PATH`, `--meter ID`, `--dp ID`, and
`--type minux|sum|avg|max` can override the defaults. The cumulative energy DP 1
defaults to Tuya's `minux` statistic. Missing points remain `#`, and raw values
are not assumed to be kWh. Check the device timezone and scale before comparing
with Deye. Exit codes: 0 = numeric hourly points returned (possibly incomplete),
2 = hourly history unconfirmed, 1 = failure. This probe does not add charts to the app.

Use `Scripts/tuya-history.command --deep` to probe 15-minute and hourly history
for 1, 7, 14, 30, and 90 days ago, daily totals for those dates, and the latest
100 energy-DP log entries. Explicit dates override that date selection.
`--interval 15min|hour|both` selects granularity; `--logs` adds the latest log
sample. Each interval summary reports numeric points, expected points, and the
sum of returned raw values. Complete groups of four quarters are compared with
the hourly value. No missing values are filled or interpolated. Exit 0 means at
least one requested statistics series has numeric points; it does not mean all
intervals/dates succeeded. Empty old dates do not by themselves establish a
retention limit. The 15-minute mobile action comes from Tuya's official
`tuya-panel-demo/examples/airThermostat/src/components/Chart/index.tsx`.

## Yearly Deye + Tuya JSON archive

Run `./Scripts/export-energy-year.command --year 2026` from this checkout. It
reuses the protected local Deye and Tuya sessions (including saved login recovery)
and automatically includes the selected Tuya meter and devices named `main switch`,
including the old meter. Override devices with repeated `--meter ID` arguments.

The result is `generated/energy-2026.json`: all Deye daily response fields and
intraday records, Tuya daily/hourly/15-minute energy statistics for each elapsed
day, device schemas, coverage counts, errors, and paginated reported-DP logs.
Missing values stay missing; today's data is partial. Logs include the history
retained by the API and can include other years. The default limit is 1,000 log
pages; `--max-log-pages N` changes it, and `--skip-logs` omits logs. The export
explicitly records whether log pagination finished.

Successful historical requests are cached under `generated/energy-2026-responses/`.
Rerun the same command after interruption to resume; today's data and moving log
pages are fetched again. `--through YYYY-MM-DD` limits the requested dates.
`--deye-session PATH` and `--tuya-session PATH` select alternative Keychain account
identities and, on first use, protected legacy files to migrate. No credentials
are included in the output. Export files are created
with mode 600 under the git-ignored `generated/` directory. Exit 2 means errors,
interrupted provider work, or incomplete/omitted logs; an empty successful API
response does not establish that consumption was zero or prove a retention limit.

## Credits

Super Bar combines the original TCL Bar, BLUETTI Bar, and LG Bar projects. The LG module is based on LG Bar 1.4.1, commit `cc3d4ac701c48a8dfae677f3f2ba72961e268715`. BLUETTI third-party notices are included in `Resources/THIRD_PARTY_NOTICES.txt`.

TCL Eco applies 26° and Silent together. Section headers toggle across their full width; compact TCL cards show set temperature beside the name and room temperature below.

### Keychain migration verification (2026-11-13)

Credential access is shared across the app process. Successful and missing reads
are cached in memory; concurrent callers do not each reopen Keychain. A failed
access attempt stops further uncached reads/writes until the user selects
**Retry Keychain access** in Settings, explicitly reconnects an account, or
restarts the app. Already loaded accounts remain usable. Saving a changed value
still writes to Keychain and verifies it by reading the underlying Keychain item
before updating the cache or removing an app-owned legacy file. No credential
cache is written to disk. External Keychain edits are read on the next app launch.

For Mac builds, set `SUPER_BAR_SIGNING_IDENTITY` to the same valid code-signing
certificate identity on every build (the installer inherits it). Without this
setting, local builds remain ad-hoc signed: their identity changes with the
binary, so macOS may request access again after an update. Existing Keychain
items have separate access controls; this change does not promise a single
initial authorization dialog for all accounts or loosen those controls.

The earlier migration build on Mac was installed and launched twice. Deye, Tuya, TCL and LG
continued reading their accounts after the app-owned legacy credential files were
removed; those files stayed absent after relaunch. Installation was verified
against the built executable checksum. Synthetic tests exercise both JSON session
and LG UTF-8 token migration, failed reads/writes/readback, corrupt data and
preservation of independent import sources. After removing the file backend,
the native test suite and iOS project checks passed again; the updated iPhone
app launched with existing connections. The new optimized Mac bundle built and
passed signature verification, but its runtime check is blocked by the local
launch environment. No hardware control commands were sent.

## Swagger / OpenAPI JSON

The native clients' HTTP requests are documented in one self-contained
[OpenAPI 3.0.3 JSON](docs/api/openapi.json), covering Deye, LG ThinQ, TCL and Tuya.
Import this file into a compatible Swagger/OpenAPI viewer. Operations are grouped
by provider and retain their own server origins and authentication schemes.

These are code-derived subsets, not complete vendor contracts or distribution
permissions. They contain no credentials or embedded signing keys. Tuya's seven
RPC actions share its real `POST /api.json` endpoint; action-specific payloads and
results are described in `x-rpc-actions` and component schemas. Dynamic TCL hosts
must come from discovery. Tuya signatures, TCL SaaS signatures and AWS SigV4
require an authorized signing-aware client; Swagger UI alone does not generate
these signatures. BLUETTI uses BLE and is not represented as a fictional HTTP API.
