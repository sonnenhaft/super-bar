# Super Bar

A native macOS menu bar app for BLUETTI power stations and TCL Home and LG ThinQ air conditioners. Requires macOS 15 or later.

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

- The 460-point panel uses a shared dark palette, thin borders and cyan selection accents. TCL, LG and BLUETTI use text labels; device buttons share a brand column and row height, with text aligned at the top. LG units use window-unit artwork and TCL uses wall-unit artwork. Clicking a device opens its controls and activates its menu-bar readout; clicking again collapses it while keeping that readout. Powered-off AC readouts show a red power symbol beside the pinned room temperature.
- Only one section expands at a time; collapsing it also hides its charts. TCL and LG share the same brand typography, and Energy has no Deye label. The daily chart tooltip and Energy summary show estimated net cost: grid purchases minus export revenue, with self-used generation already deducted. A negative balance is labelled Credit. Matching intervals estimate today's self-use; gaps and historical days use the configurable assumption, capped by actual household consumption. Days missing either generation or consumption are excluded and coverage is shown. Defaults are ₱13/kWh purchase, 50% export price and 30% self-use; hourly averages and scenarios are estimates, not billing measurements.
- Green, red and gray dots mean on, off and offline/unknown. Online devices show room temperature even when off; offline summaries show only the name and dot. TCL summaries use two lines; LG cards pair a device icon with name, temperature pins and available power. Set/Room values are independent pin buttons in summaries and expanded controls. ECO leaves sit beside the set temperature. The expanded card keeps the temperature picker and adds bounded minus/plus controls.
- TCL and battery controls align with their device buttons. The selected chart appears in its own Climate, LG, Battery or Energy section. Settings expand inline from the bottom row; refresh, text size, login and LG settings remain available. The panel fits its content and scrolls only when taller than the available screen.
- Refresh settings follow the selected brand. Missing credentials show `Sign in to …`; Bluetooth starts only after **Allow Bluetooth**.
- Energy shows yellow production / blue Tuya consumption without a separate meter row or Deye label. Power tiles open the charts and toggle net power beside the clock; the Energy heading collapses the charts. The chart shows 30 days plus today's power curve when supplied by Deye. Readings become bold while pinned: production minus consumption, yellow for surplus and blue for deficit. Missing/stale readings produce `—`; the selected consumption meter is never silently replaced.
- Power and energy use integers below 800 W/Wh and one decimal with a comma above it: `735 W`, `1,3 kW`, `28,2 kWh`. Completed Deye days and Tuya schemas are cached instead of refetched every poll.

## Connect devices

**TCL:** Super Bar reuses the local TCL Home session. If sign-in is required, enter your TCL Home email and password in the TCL panel.

**LG:** Open **LG settings…** and enter your ThinQ personal access token and account country/region. The installer can migrate a local `token.txt` beside `Sources` into the protected LG configuration directory if no token is already saved. Tokens are never included in the application bundle or repository.

**BLUETTI:** Press **Allow Bluetooth** on the BLUETTI row to start discovery and grant macOS Bluetooth access. Opening the app or panel never starts Bluetooth. Polling continues in the background after the first connection.

**Deye:** The native Swift client imports an existing protected Deye session once and stores its own session in `~/Library/Application Support/Super Bar/Deye/`. Requests, token renewal and saved-login recovery use URLSession directly. If credentials are missing, use **Sign in to Deye Cloud** in its row. No Python, helper scripts, packages, or external runtime are required; credentials are never bundled.

## Build and check

```bash
./build.command
Tests/check.command
```

The optimized, ad-hoc signed app is written to `dist/Super Bar.app`. Build and installation scripts report progress while running.

## Native Tuya

Super Bar reads Smart Life directly with Foundation, CryptoKit and Security. On first launch it imports the existing protected `.env.tuya-session.json`, including the chosen main meter, and saves its own session under `~/Library/Application Support/Super Bar/Tuya/`. No script, Python interpreter, package or SDK is bundled or invoked. Session renewal uses the saved login; sign-in is Smart Life / country 63 / EU. Only authentication, device reads, and daily/hourly statistics actions are allowed. Device commands are rejected before a request can leave the client. The original scripts below remain standalone diagnostic tools.

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
and a hidden password. Every answer is saved immediately to the private, ignored
`.env.tuya-login.json`, even if login fails or the next prompt is interrupted.
Press Enter to keep a saved value, including the password (stored as MD5, never
plaintext), or type a replacement. A successful login saves the account endpoint
returned by Tuya. Subsequent runs reuse the session and automatically log in
again when it expires. There is no User Code or QR requirement for this route.
Only Python 3.9+ and its standard library are required: no SDK, pip, or packages.

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

The ignored `.env.tuya-session.json` file is saved atomically with mode 600. For
mobile login it contains the session ID, email, app/country settings, and the
password MD5 needed for automatic re-login (treat this hash as a credential).
The plaintext password is not saved. Existing sharing sessions remain readable,
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
`--deye-session PATH` and `--tuya-session PATH` accept alternative protected
session files. No credentials are included in the output. Files are created
with mode 600 under the git-ignored `generated/` directory. Exit 2 means errors,
interrupted provider work, or incomplete/omitted logs; an empty successful API
response does not establish that consumption was zero or prove a retention limit.

## Credits

Super Bar combines the original TCL Bar, BLUETTI Bar, and LG Bar projects. The LG module is based on LG Bar 1.4.1, commit `cc3d4ac701c48a8dfae677f3f2ba72961e268715`. BLUETTI third-party notices are included in `Resources/THIRD_PARTY_NOTICES.txt`.
