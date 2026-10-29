![HermesTray](/assets/logo96.png)

# HermesTray

Run the [Hermes Agent](https://github.com/NousResearch/hermes-agent) backend from the Windows system tray.

- Starts the server when you open the app, without a console or application window.
- Stops its own server and child processes when you choose **Exit**.
- Leaves existing servers alone and allows one instance per user/session.

Requires Windows 10/11 x64 and Hermes installed with authentication configured.

## Usage

Extract the release ZIP and run `HermesTray.exe`. Right-click the tray icon to exit.

To start at login, add a shortcut to the executable in `shell:startup` (**Win + R**).

For mobile access, use [Hermes Mobile](https://hy4ri.github.io/hermes-mobile/) over a private Tailscale or ZeroTier network. Keep authentication enabled.

### Microsoft Defender

Microsoft Defender may report a false positive and flag `HermesTray.exe` as a threat. If this happens, add the executable to Microsoft Defender's exclusion list to run HermesTray.

## Documentation

[Setup and troubleshooting](docs/STARTUP.md) | [Build and releases](docs/RELEASES.md) | [Tests](docs/TESTS.md)

Unofficial project, not affiliated with Nous Research. The [Hermes Agent icon](https://github.com/NousResearch/hermes-agent/blob/main/apps/desktop/assets/icon.png) was recolored; [third-party notices](THIRD-PARTY-NOTICES.txt) retain its MIT attribution.
