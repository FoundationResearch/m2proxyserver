# m2proxyserver — WSL + Windows

> Branch `wsl`. For native macOS, switch to `main`.

This branch installs m2proxyserver on **WSL** and **Windows side-by-side** in a single run. After setup, `ssh m2-login-001` works from both:

- **WSL** (bash/zsh, terminal in WSL)
- **Windows** (PowerShell, Windows Terminal, VS Code Remote-SSH, Cursor, Antigravity, …)

…against the same identity, with the Teleport cert auto-mirrored from WSL to Windows by `m2-login`.

## Setup

Run **inside WSL** (not in Windows). Do **not** prefix with `sudo` — if you're not already `root`, the script will `sudo` only the parts that need it.

```bash
git clone -b wsl https://github.com/FoundationResearch/m2proxyserver.git
cd m2proxyserver
./setup-wsl.sh
```

What it does:

1. **Confirms your Windows account.** Auto-detects via `cmd.exe %USERPROFILE%`, then asks `Proceed with Windows user 'XXX'? [Y/n]`. Override with `M2_WIN_USERPROFILE='C:\Users\someone' ./setup-wsl.sh` if it picks the wrong profile.
2. **WSL/Linux side** (delegates to `./setup.sh`): installs `cloudflared` from Cloudflare's signed `.deb`, generates an ed25519 SSH key if you don't have one, writes a marker-bracketed m2 block to `~/.ssh/config`, pins `ssh.alexzms.com` to IPv4 in `/etc/hosts`, installs `~/.local/bin/m2-login`, and adds `~/.local/bin` to PATH in `.bashrc`/`.zshrc`.
3. **Windows side**: copies bundled `bin/cloudflared.exe` to `%USERPROFILE%\bin\`, mirrors the ed25519 SSH key to `%USERPROFILE%\.ssh\` (so admin only authorizes one key), and appends the m2 block to `%USERPROFILE%\.ssh\config` — also marker-bracketed, so re-running only touches that block.
4. **Refreshes the Teleport cert** (runs `m2-login`). On WSL, `m2-login` automatically mirrors `~/.tsh/` to `%USERPROFILE%\.tsh\`, which is where Windows-native ssh reads the cert from.

The first run will print your public key. Send it to Alex Zhang, Will Lin, or Yuxuan Zhang on Slack:

```bash
clip.exe < ~/.ssh/id_ed25519.pub      # copies to Windows clipboard
```

Wait for confirmation, then re-run `m2-login` to pull the cert.

Re-running `setup-wsl.sh` is safe and idempotent.

## Usage

From WSL:

```bash
m2-login            # refresh cert (run when it expires; cert is good for ~24h)
ssh m2-login-001
ssh m2-login-003
scp file m2-login-003:/path/
ssh -L 8888:localhost:8888 m2-login-003
```

From Windows (PowerShell / Terminal):

```powershell
wsl m2-login        # cert refresh still happens in WSL — it auto-mirrors here
ssh m2-login-001
ssh m2-login-003
```

VS Code / Cursor / Antigravity (works from both WSL and Windows hosts): Remote-SSH → **Connect to Host…** → `m2-login-003` (or `m2-login-001`).

## Commands

```
m2-login            log in and sync cert (default; on WSL also mirrors to Windows)
m2-login status     show current cert status on the m2proxymachine
```

## Rules

Violating any of these risks the shared cluster account being suspended. They are not optional.

1. **Do not bypass `m2-login` to authenticate to Okta.** The script routes the Okta browser session through an SSH SOCKS5 tunnel into the m2proxymachine, in an isolated Chromium profile. Logging in through your normal browser exposes your laptop's IP to the Okta audit log.
2. **Do not connect to `mbzuai-hpc.teleport.sh` from any machine other than via the configured `m2-login-*` aliases.** All cluster traffic must originate from the m2proxymachine's IP. A second source IP triggers an account ban.
3. **Do not share or copy your `~/.tsh/` directory.** The cert it contains is short-lived but still a credential. The Windows mirror at `%USERPROFILE%\.tsh\` counts — keep it on your machine only.

## Requirements

- WSL2 with Ubuntu / Debian (apt). Tested on Ubuntu 24.04.
- Windows 10/11 with the built-in OpenSSH client (default since Win10 1809).
- WSL/Windows interop enabled (`cmd.exe` + `wslpath` reachable from WSL — the default on modern WSL2).
- A Chromium-family browser somewhere. **Only needed for the rare first-of-day Okta login** — `m2-login` skips Okta entirely when the shared cert on the jump host is still fresh (≥1 h left), which is the common case. For the cold-start case `m2-login` searches PATH for `chromium`/`google-chrome`/`brave-browser`/`microsoft-edge`, then falls back to Windows-side `chrome.exe`/`msedge.exe`/`brave.exe` under `/mnt/c/...`.

## Notes on the Windows hosts file

`setup.sh` pins `ssh.alexzms.com` to Cloudflare's current IPv4 anycast in **WSL's** `/etc/hosts` to work around `cloudflared` failing on networks where IPv6 to Cloudflare is broken. The same pin is **not** written to `C:\Windows\System32\drivers\etc\hosts` (it requires Windows admin elevation, and the issue is uncommon on Windows). If Windows-side `ssh m2-login-001` ever fails with `dial tcp ...: no route to host`, add the same line manually as Administrator:

```
104.21.59.64    ssh.alexzms.com
172.67.216.250  ssh.alexzms.com
```

(Or run `setup-wsl.sh` again from WSL to get the current IPs printed; Cloudflare rotates these occasionally.)
