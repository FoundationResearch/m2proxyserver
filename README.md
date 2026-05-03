# m2proxyserver

## Setup (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/FoundationResearch/m2proxyserver/main/setup.sh | bash
```

The installer may prompt for your local sudo password (used by the Homebrew installer if Homebrew is missing, and to pin Cloudflare's IPv4 in `/etc/hosts` to work around a `cloudflared` IPv6 routing issue on some networks). Do **not** run the whole command with `sudo` — files would land in root's home instead of yours.

Send the public key printed at the end of setup to Alex Zhang, Will Lin or Yuxuan Zhang in Slack. Wait for confirmation that the key has been added.

Open a new terminal, then:

```bash
m2-login
```

This obtains a Teleport cert valid for 24 hours. Re-run when it expires.

## Usage

```bash
ssh m2-login-001
ssh m2-login-003
scp file m2-login-003:/path/
rsync -av dir/ m2-login-003:/path/
ssh -L 8888:localhost:8888 m2-login-003   # jupyter / tensorboard
```

VS Code, Cursor, Antigravity: Remote-SSH → **Connect to Host…** → `m2-login-003` (or `m2-login-001`).

## Commands

```
m2-login            log in and sync cert (default)
m2-login status     show current cert status on the macmini
```

## Rules

Violating any of these risks the shared cluster account being suspended. They are not optional.

1. **Do not bypass `m2-login` to authenticate to Okta.** The script routes the Okta browser session through an SSH SOCKS5 tunnel into the macmini, in an isolated Chromium profile. Logging in through your normal browser exposes your laptop's IP to the Okta audit log.
2. **Do not connect to `mbzuai-hpc.teleport.sh` from any machine other than via the configured `m2-login-*` aliases.** All cluster traffic must originate from the macmini's IP. A second source IP triggers an account ban.
3. **Do not share or copy your `~/.tsh/` directory.** The cert it contains is short-lived but still a credential.

## Requirements

- macOS.
- A Chromium-family browser (Chrome, Brave, Chromium, Edge, Arc). The installer offers to install Google Chrome via Homebrew if none is found.

