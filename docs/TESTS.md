# Tests

Run on Windows from the project root. Install PS2EXE 1.0.18 as described in [Build and releases](RELEASES.md#build-locally). Suites use Windows PowerShell 5.1 and fixtures, without Pester or a real Hermes installation.

```powershell
powershell.exe -NoProfile -STA -File .\Test.ps1 -Build
```

The runner builds, discovers `tests/*.Tests.ps1`, and stops at the first failure. Omit `-Build` to test an existing `dist\HermesTray.exe`; add `-Tag v1.0.0` to build that version. Checks print `PASS:`; failures return nonzero. Expected tray icons/notifications may appear.

The runner creates `TMPDIR` if unset and leaves scratch files for inspection. To run one suite directly:

```powershell
if (-not $env:TMPDIR) {
  $env:TMPDIR = Join-Path $env:LOCALAPPDATA 'HermesTray\TestScratch'
}
New-Item -ItemType Directory -Force -Path $env:TMPDIR | Out-Null
powershell.exe -NoProfile -STA -File .\tests\Authentication.Tests.ps1
```

`Launcher.Tests.ps1` accepts `-ExecutablePath 'C:\path\to\HermesTray.exe'`. Build and release tests use the default `dist\HermesTray.exe`.

## Coverage

| Suite | What it checks |
| --- | --- |
| `Runtime.Tests.ps1` | Tray lifecycle, Exit cleanup, icon size, and existing-server protection. |
| `Validation.Tests.ps1` | Missing, broken, incompatible, or hanging CLIs; cancellation and automatic exit. |
| `Authentication.Tests.ps1` | Password/OAuth readiness, malformed responses, redirects, timeouts, ownership races, stale diagnostics, and secret suppression. |
| `Launcher.Tests.ps1` | Script/EXE startup, singleton behavior, forced-exit cleanup, restart, spaced paths, and exit codes. |
| `Build.Tests.ps1` | Compiler failure safety, single-file output, and complete project/dependency notices. |
| `Release.Tests.ps1` | ZIP contents and integrity, AMD64 checks, valid tags, and matching executable versions. |
| `Monitoring.Tests.ps1` | Listener loss after readiness and explicit IPv4 bind handling. |
| `Health.Tests.ps1` | Monitoring defaults, recovery from transient HTTP failures, shutdown after persistent unavailability, and connection-failure diagnostics. |
| `Process.Tests.ps1` | Host termination after atomic creation but before ResumeThread, using an isolated instrumented host. |
| `Logging.Tests.ps1` | Bounded output, rotating backups, and failure reporting without blocked children. |
| `Http.Tests.ps1` | A total HTTP deadline even when the response body trickles in. |
| `Version.Tests.ps1` | Semantic tags, Windows version limits, and actual executable metadata. |
| `Automation.Tests.ps1` | Shared CI entry points and separation of read-only validation from publication. |

Fixtures test the controller's behavior, not compatibility with a real Hermes installation. They do not change real credentials or Windows startup settings.

## Real Hermes smoke test

With Hermes installed and the executable built, set `TMPDIR` as above and run:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Smoke.Real.ps1
```

This opt-in test uses a temporary `HERMES_HOME`, random credentials, and a free port. It checks EXE startup, required basic authentication, wrong/correct passwords, the authenticated session, and backend cleanup without editing the active profile. It does not print credentials or run in fixture CI.

A prior local run passed with Hermes 0.22.2 on Windows 11 Pro. OAuth login and mobile/VPN compatibility require separate checks.

## Before publishing

- Run the workflow on GitHub; local lint is not a remote run.
- Extract the release ZIP on a clean Windows x64 machine and test as a normal user.
- Test the tray's Exit action and login via a shortcut in `shell:startup`.
- Check mobile login on the intended VPN and record the client version.
- Verify the published ZIP against the SHA-256 in the release notes.

See [startup troubleshooting](STARTUP.md) for installation and authentication diagnostics, including the Microsoft Store startup limitation.

