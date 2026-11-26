# Tailscale remote workflows

Windows RDP, Linux SSH, and macOS SSH with an optional local RDP server.

The structure is based on [sky-beta/tailscale-remote-desktop](https://github.com/sky-beta/tailscale-remote-desktop), inspected at commit `ecf0f3e`.

Windows and macOS are manually dispatched with a `minutes` input between 10 and 300 (default 60). Linux runs for 340 minutes and requests its next session when `LINUX_AUTORUN=true`. A scheduled maintenance workflow checks every 15 minutes and also reacts when Linux completes, starting a session only if none is active. Recent failures wait at least 15 minutes before another attempt. Files stored on hosted runners are temporary. Use these workflows only for project development/testing permitted by [GitHub Actions terms](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions). For a permanent remote machine, use your own server.

## Secrets

| Secret | Purpose |
| --- | --- |
| `TAILSCALE_AUTHKEY` | Reusable, ephemeral Tailscale auth key |
| `SSH_PUBLIC_KEY` | Client public key for Linux and macOS |
| `LINUX_SSH_HOST_KEY` | Private Ed25519 host key for Linux |
| `MACOS_SSH_HOST_KEY` | Private Ed25519 host key for macOS |
| `WINDOWS_DESKTOP_PASSWORD` | Password for the Windows `runneradmin` account |
| `ALIST_ADMIN_PASSWORD` | AList admin password for Windows and Linux |
| `BROWSER_BACKUP_KEY` | Random 32-byte AES-256-GCM key, base64 encoded |
| `GH_REMOTE_TOKEN` | Access to the separate private browser backup repository |

Never put the client SSH private key or account tokens in this repository. The tailnet policy must allow your client to reach port 22 (SSH) and/or 3389 (Windows RDP).

## Connection information

Each workflow publishes a short-lived artifact named `windows-connection`, `linux-connection`, or `macos-connection`. It contains the Tailscale address, username, and public SSH host key, but no passwords or private keys.

Linux SSH only listens on its Tailscale address. Windows RDP uses NLA and an inbound firewall rule scoped to the Tailscale interface. IPv4 and IPv6 forwarding are enabled at setup. All three systems advertise themselves as Tailscale exit nodes. Approve "Use as exit node" for each device in the Tailscale admin console before selecting one as your client's internet exit. The auth key used to join the tailnet cannot approve these routes through the administrative API.

macOS uses [mac-rdp-server](https://github.com/DawidAdamski/mac-rdp-server). It stays bound to `127.0.0.1:3389`; connect with an authenticated SSH tunnel. Its screen recording and accessibility permissions must be authorized in macOS settings. Installing the binary and opening a TCP port does not prove that screen capture and input work.

The local connection helper retrieves the artifact through GitHub, pins SSH host keys, and uses Tailscale for the actual remote connection.

Fixed device names are `remote-windows-1233`, `remote-linux-1233`, and `remote-macos-1233`. Addresses may change; the helper retrieves the current address instead of guessing it from the hostname. It verifies that the local client is in the same tailnet, retains the previous local account, and uses unattended mode to keep the selected connection running when the UI is closed. The local service's boot startup setting is managed separately.

AList is installed by default on Linux and Windows, listening on the Tailscale address at port 5244. Its `admin` account uses `ALIST_ADMIN_PASSWORD`. The local storage driver is mounted at `/`: the actual Linux folder is `/c`, and Windows uses `C:\`. Windows also creates desktop links for ChatGPT, X, YouTube, Google, Baidu, Gemini, and the local AList panel. Linux `/c` is temporary runner storage and is cleared when that runner is replaced.

Set repository variable `LINUX_AUTORUN=false` before cancelling Linux to stop automatic renewal. The local stop launcher performs both actions. Turning off the maintenance workflow or changing the variable stops scheduled recovery; a workflow cancellation alone is treated as a recoverable interruption while automatic maintenance is enabled.

Passwords and the optional local Tailscale auth key are protected using Windows DPAPI for the current user. The client SSH key and configuration files are installed with user-only access. The GitHub token is read from a local file and its encrypted backup is stored in `GH_REMOTE_TOKEN`; no workflow requires or exposes its plaintext in source code.

## Remote Chrome data

Windows and macOS restore their complete dedicated Chrome user-data directory from the private repository `12138882/1233-browser-data`. This includes all profiles, bookmarks, history, extensions, cookies, website storage and caches under that directory. Data is encrypted locally using AES-256-GCM before upload. Windows and macOS archives are independent. The previous complete snapshot is retained until the replacement is verified; two snapshots per system are kept. Backups occur approximately every 150 seconds and at normal workflow cleanup. Forced termination, host failure, or a failed upload can lose changes made since the last successful snapshot.

The default profile's bookmarks are also shared as a separate encrypted file: each startup reads the latest shared bookmarks, and changed bookmarks are uploaded with the next checkpoint. Concurrent edits use the last uploaded version; full platform snapshots retain their own copies. Sharing does not grant repository access to other accounts automatically.

Chrome uses a dedicated user-data directory and a loopback-only debugging endpoint to checkpoint and restore cookies without copying operating-system encryption keys. The full raw profile is also preserved. Cookies are not a guarantee of continued login: Google, ChatGPT and other services can require authentication again; OS-bound saved passwords, passkeys, client certificates and device-bound credentials are not made portable by copying a profile. This does not back up Downloads or any browser on the connecting computer.

Website shortcuts explicitly open Chrome with this profile. Windows initializes services and backups in the background, suppresses Server Manager and Tailscale foreground startup, and keeps Tailscale running unattended. The helper console remains visible while retrieving a remote session or reporting an error.
