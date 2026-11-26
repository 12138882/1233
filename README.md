# Tailscale remote workflows

Windows RDP, Linux SSH, and macOS SSH with an optional local RDP server.

The structure is based on [sky-beta/tailscale-remote-desktop](https://github.com/sky-beta/tailscale-remote-desktop), inspected at commit `ecf0f3e`.

Each workflow is manually dispatched with a `minutes` input between 10 and 300 (default 60). Jobs end when that time expires. Files stored on hosted runners are temporary. Use these workflows only for project development/testing permitted by [GitHub Actions terms](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions). For a permanent remote machine, use your own server.

## Secrets

| Secret | Purpose |
| --- | --- |
| `TAILSCALE_AUTHKEY` | Reusable, ephemeral Tailscale auth key |
| `SSH_PUBLIC_KEY` | Client public key for Linux and macOS |
| `LINUX_SSH_HOST_KEY` | Private Ed25519 host key for Linux |
| `MACOS_SSH_HOST_KEY` | Private Ed25519 host key for macOS |
| `WINDOWS_DESKTOP_PASSWORD` | Password for the Windows `runneradmin` account |

Never put the client SSH private key or account tokens in this repository. The tailnet policy must allow your client to reach port 22 (SSH) and/or 3389 (Windows RDP).

## Connection information

Each workflow publishes a short-lived artifact named `windows-connection`, `linux-connection`, or `macos-connection`. It contains the Tailscale address, username, and public SSH host key, but no passwords or private keys.

Linux SSH only listens on its Tailscale address. Windows RDP uses NLA and an inbound firewall rule scoped to the Tailscale interface. IPv4 and IPv6 forwarding are enabled at setup. All three systems advertise themselves as Tailscale exit nodes. Approve "Use as exit node" for each device in the Tailscale admin console before selecting one as your client's internet exit. The auth key used to join the tailnet cannot approve these routes through the administrative API.

macOS uses [mac-rdp-server](https://github.com/DawidAdamski/mac-rdp-server). It stays bound to `127.0.0.1:3389`; connect with an authenticated SSH tunnel. Its screen recording and accessibility permissions must be authorized in macOS settings. Installing the binary and opening a TCP port does not prove that screen capture and input work.

The local connection helper retrieves the artifact through GitHub, pins SSH host keys, and uses Tailscale for the actual remote connection.

Fixed device names are `remote-windows-1233`, `remote-linux-1233`, and `remote-macos-1233`. Addresses may change; the helper retrieves the current address instead of guessing it from the hostname. It verifies that the local client is in the same tailnet, retains the previous local account, and uses unattended mode to keep the selected connection running when the UI is closed. The local service's boot startup setting is managed separately.

Passwords and the optional local Tailscale auth key are protected using Windows DPAPI for the current user. The client SSH key and configuration files are installed with user-only access. The GitHub token is read from a local file and its encrypted backup is stored in `GH_REMOTE_TOKEN`; no workflow requires or exposes its plaintext in source code.
