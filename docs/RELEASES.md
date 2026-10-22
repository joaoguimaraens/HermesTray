# Build and releases

Run commands from the project root on Windows. Close HermesTray before replacing its executable.

## Build locally


```powershell
Install-Module ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser
pwsh -NoProfile -STA -File .\Build.ps1
```

The default tag comes from [VERSION](../VERSION). Override it with `-Tag v1.0.0`. Install PS2EXE in the host used to build: `pwsh` and `powershell.exe` have separate module paths.

The output is only `dist\HermesTray.exe` for Windows x64. It embeds the icon, runtime, [project license](../LICENSE), and [third-party notices](../THIRD-PARTY-NOTICES.txt). Users need Hermes installed and configured, but not PS2EXE.

Fresh output and version metadata are validated before replacing an existing build. Use `-OutputDirectory` if the normal executable is running.

Tags use `vMAJOR.MINOR.PATCH` with an optional prerelease such as `-rc.1`. Numeric components must fit Windows file metadata. For `v1.0.0-rc.1`, FileVersion is `1.0.0.0`; FileDescription stays `HermesTray`; Comments and the embedded script retain the full tag. Packaging rejects a tag that does not match the executable.

## CI and publication

[CI](../.github/workflows/ci.yml) and [releases](../.github/workflows/release.yml) share the [build action](../.github/actions/build/action.yml) and [test runner](../Test.ps1). Branch/PR validation and release builds have read-only permissions. A separate publication job receives the validated artifact and uses `contents: write`.

After committing and pushing the project, send a version tag:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

The workflow publishes `HermesTray-v1.0.0-windows-x64.zip` containing only `HermesTray.exe` at its root. Release notes include the ZIP's SHA-256. Publication checks the downloaded build artifact, reads back release metadata, then downloads and verifies the published ZIP. Prerelease tags create prereleases; existing releases are not overwritten. The built-in `GITHUB_TOKEN` needs no custom secret for unsigned releases.

## Package without publishing

Build and package using the same tag:

```powershell
powershell.exe -NoProfile -STA -File .\Build.ps1 -Tag v1.0.0
powershell.exe -NoProfile -STA -File .\Release.ps1 -Tag v1.0.0
```

The archive goes into `release\`, leaving `dist\` executable-only. `-ExecutablePath 'C:\path\to\HermesTray.exe'` selects another build; `-OutputDirectory 'C:\path\to\archives'` selects the ZIP destination.

## Optional code signing

Builds are unsigned unless you supply `-SigningCertificateThumbprint` for a trusted code-signing certificate with an accessible private key in `Cert:\CurrentUser\My`. The build uses SHA-256, timestamps the signature, and verifies it before replacing the executable. `-TimestampServer` overrides the timestamp service.

No signing certificate is bundled or generated. CI currently produces unsigned releases. Signing and publisher reputation do not guarantee that SmartScreen or antivirus will show no warnings.

## Source and notices

- [HermesTray.ps1](../HermesTray.ps1) handles arguments, CLI discovery, and the per-user/session mutex.
- [src/Runtime.cs](../src/Runtime.cs) owns the tray, icons, server tree, readiness checks, and logs.
- [Build.ps1](../Build.ps1) embeds resources; [Release.ps1](../Release.ps1) validates AMD64 architecture and creates the ZIP.

HermesTray's source uses MIT. The recolored Hermes icon retains Nous Research's MIT notice; the PS2EXE host retains its own notice. Both full notices and the project license are embedded. Read them without starting the server:

```powershell
.\dist\HermesTray.exe -extract:source.ps1
```

The first remote workflow run, clean-machine checks, and mobile/VPN login remain [prepublication checks](TESTS.md#before-publishing), not results implied by local test success.

