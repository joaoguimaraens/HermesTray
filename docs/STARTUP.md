# Startup checks and troubleshooting

HermesTray uses your existing Hermes installation and environment. It does not install Hermes, change settings, or read/store credentials.

## Startup sequence

1. Resolve the CLI from `-HermesPath`, then `hermes.exe` on `PATH`, then the user's Windows application alias.
2. Require successful `--version` and `serve --help` checks identifying Hermes and advertising `serve`, `--host`, and `--port`.
3. Start the server in a kill-on-close Windows Job Object. See the [Store fallback](#microsoft-store-installations).
4. Verify IPv4 listener ownership, request `/api/status` on the bind address (loopback for wildcard), and recheck ownership.
5. Require HTTP 200 and JSON with a nonempty `version`, Boolean `auth_required=true`, and a nonempty `auth_providers` array of nonempty provider names before showing **server running**.

The app rejects redirects and malformed/unsupported status responses. It uses no proxy or Windows credentials and never attempts login. Password and OAuth providers are accepted. Ownership sampling is not cryptographic HTTP identity verification.

Checks run outside the UI thread. Exit remains available. Limits are 10 seconds per CLI command, 5 seconds for the complete HTTP response, and 60 seconds for server readiness, including retries. After readiness, transient connection failures, HTTP 5xx responses, or timeouts enter a checking state for up to 30 seconds before shutdown. Successful validation restores the running state. Authentication and listener ownership failures remain fatal. Failed HTTP checks log only a failure category or HTTP status code, never response bodies or credentials.

While running, ownership is checked each timer tick and HTTP status every five seconds. Unavailability clears readiness and shows **checking server**; recovery requires a valid authenticated response. Thirty seconds of persistent unavailability stops the owned tree. Invalid status/authentication or a foreign listener fails immediately.

## Startup failures

A fatal error stops only owned processes, writes instructions to `tray.log`, attempts one notification without a dialog, and exits after roughly five seconds with a nonzero code. Exit closes immediately. The app does not restart failed servers. Do Not Disturb may hide notifications; initialization failures may appear only in the log.

An occupied port before launch produces **port already in use** until Exit; the existing server is neither inspected nor adopted. A process claiming the port during startup causes validation to fail without stopping that external process.

## Install or repair Hermes

Run these in a terminal under the same Windows account that launches HermesTray:

```powershell
Get-Command hermes.exe
hermes --version
hermes serve --help
```

If the CLI is missing or fails, follow the [installation instructions](https://hermes-agent.nousresearch.com/docs/getting-started/installation). A Start menu shortcut or Windows alias does not prove it works.

For a custom installation, point HermesTray to the actual executable:

```powershell
.\dist\HermesTray.exe -HermesPath 'C:\path\to\hermes.exe'
```

## Configure dashboard authentication

In a real interactive terminal, run:

```powershell
hermes serve --host 0.0.0.0
```

Complete the terminal's **Username & password** setup, or configure [dashboard OAuth](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard#authentication-gated-mode). Enable the relevant dashboard-auth plugin if needed. An LLM API key is not dashboard authentication. Stop this terminal server with **Ctrl+C**, then open HermesTray.

Use the same account and environment as the tray app; different Hermes homes/profiles may use different settings. Hermes refuses public binds without authentication. HermesTray recognizes the missing-provider diagnostic using only the current launch's output; other early exits are server failures.

For a running backend, inspect only these public status fields:

```powershell
Invoke-RestMethod http://127.0.0.1:9119/api/status |
  Select-Object version, auth_required, auth_providers
```

Expect `auth_required` to be `True` and at least one provider, such as `basic`. This does not verify credentials, OAuth availability, or every protected endpoint.

## Mobile access

Connect the PC and phone to the same private [Tailscale](https://tailscale.com/) or [ZeroTier](https://www.zerotier.com/) network. Point [Hermes Mobile](https://hy4ri.github.io/hermes-mobile/) to the PC's VPN address on port **9119**. Test login on the actual device; automated tests do not establish mobile/VPN compatibility.

The default `0.0.0.0` bind listens on every network interface. Keep Hermes authentication enabled, restrict Windows Firewall access to the VPN network, and do not forward the port through your router. A private VPN does not replace authentication; `--insecure` is not an authentication bypass in current Hermes.

To restrict the bind, pass the PC's literal VPN IPv4 address with `-BindAddress`. IPv6 and hostnames are not supported. HermesTray still requires `auth_required=true`: a loopback bind that Hermes treats as ungated will be rejected even if a provider is configured.

## Microsoft Store installations

The tested Store package rejects atomic job-list creation. HermesTray creates the launcher suspended, assigns its job, then resumes it. Prior listener-ownership and forced-exit checks passed with Hermes 0.22.2 on Windows 11.

Terminating the tray between creation and assignment can leave a suspended process. Native standalone CLIs join the job atomically and avoid this gap. The app never adopts a listener outside its job as a workaround.

## Diagnostics and exit codes

Logs default to `%LOCALAPPDATA%\HermesTray\logs`; override with `-LogDirectory`. `server.log` rotates on launch and during use, with a 1 MiB limit per file and two backups (`.1`, `.2`). A capture thread keeps draining output; write/rotation failures stop the server with `LogWriteFailed`. `tray.log` rotates separately.

| Code | Meaning | Next step |
| --- | --- | --- |
| `0` | Normal Exit or duplicate launch | No action needed. |
| `1` | Unexpected launcher initialization failure | Check `tray.log` and the Windows PowerShell/.NET runtime; restore missing source files if running the script. |
| `2` | Hermes executable missing/invalid path | Install Hermes or correct `-HermesPath`. |
| `3` | Unusable/incompatible CLI or CLI timeout | Run the CLI checks above; repair or update Hermes. |
| `4` | Authentication unavailable or not required | Configure/enable dashboard authentication in the terminal. |
| `5` | Server launch/availability failure, unexpected exit, or log write failure | Check `server.log`, disk space, and log directory permissions. |
| `6` | Backend did not become ready in time | Check dependencies, startup output, and the status endpoint. |
| `7` | Invalid/unsupported status response or foreign listener | Update Hermes or resolve the port conflict; no external process is stopped. |

Validation messages exclude HTTP bodies, configuration values, passwords, hashes, and tokens. Temporary CLI probe output is deleted. **Hermes's own stdout/stderr in `server.log` may contain sensitive data; review it before sharing.**

## Testing

See [Tests](TESTS.md) for commands, coverage, and the limits of the fixture-based checks.
