# HermesTray agent instructions

HermesTray is an unofficial Windows 10/11 x64 tray-only launcher for an installed Hermes Agent backend. Windows PowerShell loads a C# WinForms runtime; PS2EXE packages the launcher, runtime, icon, and licenses into one executable. The app owns its server process tree, never adopts an existing server, and exposes only an Exit menu.

## Project map

- `HermesTray.ps1`: arguments, CLI discovery, per-user/session mutex, runtime loading, and message loop.
- `src/Runtime.cs`: `HermesTray.Runtime` namespace; process ownership, output capture, startup/status checks, icons, and `TrayApplication : ApplicationContext`.
- `Build.ps1`: resource embedding and fresh executable validation; `Release.ps1`: AMD64/version validation and ZIP packaging.
- `scripts/Version.ps1`: shared tag validation; `VERSION`: default version without the `v` prefix.
- `tests/*.Tests.ps1`: standalone fixture suites; `tests/Helpers.ps1`: free ports, UI polling, shared log reads; `tests/fixtures/FakeHermes.cs`: compiled test backend.
- `docs/STARTUP.md`: runtime diagnostics; `docs/TESTS.md`: coverage and limitations; `docs/RELEASES.md`: building, packaging, signing, and publication.

## Dev environment

Use Windows with Windows PowerShell 5.1, .NET Framework, WinForms, and System.Drawing. C# compiles through PowerShell `Add-Type`, not a .NET SDK project. Fixture suites need neither Pester nor a real Hermes installation.

Run commands below in PowerShell from the repository root. Install PS2EXE in the host used to build: `pwsh` and `powershell.exe` have separate module paths. CI uses Windows PowerShell on `windows-2022`.

```powershell
Install-Module ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser
```

## Build and verification

Build and run all fixture suites through the runner also used by CI:

```powershell
powershell.exe -NoProfile -STA -File .\Test.ps1 -Build
```

`Test.ps1` discovers and sorts `tests/*.Tests.ps1`, starts each in a fresh STA Windows PowerShell process, and stops at the first failure. Omit `-Build` to reuse `dist\HermesTray.exe`; several suites require that executable. Checks print `PASS:` and throw on failure. No separate lint/formatter command is configured.

Build and package with matching tags:

```powershell
powershell.exe -NoProfile -STA -File .\Build.ps1 -Tag v1.0.0
powershell.exe -NoProfile -STA -File .\Release.ps1 -Tag v1.0.0
```

Build defaults to `VERSION` when `-Tag` is absent. Output is `dist\HermesTray.exe`; the ZIP goes to `release\` with only `HermesTray.exe` at its root. Tags accept `vMAJOR.MINOR.PATCH` and optional prerelease identifiers; numeric version components must fit 0..65535.

For an individual suite, initialize scratch first:

```powershell
if (-not $env:TMPDIR) {
  $env:TMPDIR = Join-Path $env:LOCALAPPDATA 'HermesTray\TestScratch'
}
New-Item -ItemType Directory -Force -Path $env:TMPDIR | Out-Null
powershell.exe -NoProfile -STA -File .\tests\Authentication.Tests.ps1
```

Opt-in real-backend check, after the same scratch setup and a build:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Smoke.Real.ps1
```

This needs an installed Hermes CLI and uses temporary `HERMES_HOME`, random credentials, and a free port. It is excluded from fixture CI. Neither fixture success nor this smoke test proves OAuth or mobile/VPN compatibility.

## Conventions and invariants

- `.editorconfig` requires UTF-8, CRLF, two-space indentation, and a final newline. PowerShell scripts use `$ErrorActionPreference = 'Stop'`; tests use explicit assertions/`throw` and `try/finally` cleanup.
- Keep runtime code compatible with Windows PowerShell 5.1's `Add-Type` compiler and .NET Framework. C# uses PascalCase types/methods/properties, camelCase fields/locals, and explicit `IDisposable` cleanup of native handles and UI resources.
- Preserve `# EMBED_RUNTIME_CS` and `# EMBED_ICON_ICO` in `HermesTray.ps1`; the build replaces these markers in a temporary script. Edit source/assets, not generated EXEs, ZIPs, or embedded payloads. Keep complete `LICENSE` and `THIRD-PARTY-NOTICES.txt` embedding.
- Keep the UI tray-only: `ApplicationContext`, no forms/dialogs, English messages, one Exit action. `-NoRun` returns the real context without starting the server or taking the lifetime mutex; dispose it in tests.
- Tests use free ports, GUID-based scratch directories/mutex names, and test-owned processes. Use `Read-SharedLog` for actively written logs rather than `ReadAllText`.
- Preserve kill-on-close Job Object ownership, owned-listener checks, and refusal to adopt/stop external servers. Native CLIs use atomic job assignment; the Store fallback's create/assign gap remains documented.
- Readiness requires owned IPv4 listening plus HTTP 200 status JSON with a nonempty version, `auth_required=true`, and nonempty providers. Do not weaken authentication, follow redirects, log response bodies/secrets, or present fixture results as real Hermes verification.

## Pitfalls

- A running `dist\HermesTray.exe` locks build output. Choose Exit or use `Build.ps1 -OutputDirectory`; `Launcher.Tests.ps1` supports `-ExecutablePath`, but build/release suites use the default executable.
- The runner creates `TMPDIR` when unset, redirects `TEMP`/`TMP` during execution, and leaves scratch for inspection. Direct suites need scratch setup; tray icons/notifications may appear during tests.
- Default binding is `0.0.0.0:9119`; only literal IPv4 bind addresses are supported. Real Hermes needs dashboard authentication, not just an LLM API key. Occupied ports remain external; loopback binds with `auth_required=false` fail readiness.
- Logs default to `%LOCALAPPDATA%\HermesTray\logs`. Controller diagnostics suppress secrets, but Hermes stdout/stderr in `server.log` may contain sensitive data.
- CI and release workflows share `.github/actions/build/action.yml`; validation is read-only and publication runs in a separate write-enabled job. Local checks do not establish remote workflow or clean-machine release success.
