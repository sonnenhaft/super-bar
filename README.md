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

- Switch between TCL, LG, and BLUETTI using the logos at the top. TCL is selected at startup.
- Click an air conditioner's header to select it. Only the selected card expands and shows refresh controls.
- Click readings to choose what appears beside the clock. Visible readings are bold.
- Set the temperature from the value on the right of a card. A powered-off unit shows room temperature.
- Hold a device name to reorder cards by dragging.
- View matching seven-day energy and 24-hour power charts when readings are available. Hover over energy bars for exact values.
- Set each brand's refresh interval, adjust the shared menu bar text size, or enable launch at login at the bottom of the menu.

Power is shown in watts below 1,000 W and in kilowatts with two decimal places above that threshold. Energy uses the same convention for Wh and kWh. Read ages update every three seconds while the menu is open.

## Connect devices

**TCL:** Super Bar reuses the local TCL Home session. If sign-in is required, enter your TCL Home email and password in the TCL panel.

**LG:** Open **LG settings…** and enter your ThinQ personal access token and account country/region. The installer can migrate a local `token.txt` beside `Sources` into the protected LG configuration directory if no token is already saved. Tokens are never included in the application bundle or repository.

**BLUETTI:** Open the BLUETTI panel to start Bluetooth discovery and grant macOS Bluetooth access. Polling continues in the background after the first connection.

## Build and check

```bash
./build.command
Tests/check.command
```

The optimized, ad-hoc signed app is written to `dist/Super Bar.app`. Build and installation scripts report progress while running.

## Credits

Super Bar combines the original TCL Bar, BLUETTI Bar, and LG Bar projects. The LG module is based on LG Bar 1.4.1, commit `cc3d4ac701c48a8dfae677f3f2ba72961e268715`. BLUETTI third-party notices are included in `Resources/THIRD_PARTY_NOTICES.txt`.
