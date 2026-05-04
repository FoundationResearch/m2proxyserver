#!/usr/bin/env bash
# m2proxyserver setup for WSL + Windows (one-shot dual-side installer).
#
# Flow for end users:
#   1. Inside WSL, clone this branch:
#        git clone -b WSL https://github.com/FoundationResearch/m2proxyserver.git
#   2. Run from inside WSL:
#        cd m2proxyserver && ./setup-wsl.sh
#
# What it does:
#   - WSL/Linux side: delegates to ./setup.sh (cloudflared via apt, ssh key,
#     ~/.ssh/config block, ~/.local/bin/m2-login, /etc/hosts IPv4 pin).
#   - Windows side (auto-detected via cmd.exe %USERPROFILE%, with a Y/n
#     confirm so people don't accidentally write into the wrong profile):
#     copies bundled bin/cloudflared.exe to %USERPROFILE%\bin\, mirrors the
#     SSH private key to %USERPROFILE%\.ssh\, and appends a marker-bracketed
#     m2 block to %USERPROFILE%\.ssh\config.
#   - Refreshes the Teleport cert and mirrors it to %USERPROFILE%\.tsh\
#     (via m2-login, which knows about the WSL→Windows mirror).
#
# Re-runnable: every write is in a marker block or an idempotent install.

set -euo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
log()  { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
ask()  {
  local prompt="$1"
  printf '\033[1;35m?\033[0m %s ' "$prompt"
  REPLY=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -r REPLY < /dev/tty || REPLY=""
  else
    printf '(no tty — using default)\n'
  fi
}

MARK_BEGIN="# ===== m2proxyserver: do not edit between markers ====="
MARK_END="# ===== /m2proxyserver ====="

main() {
  # ---------- 1. Pre-flight ----------
  bold "[1/6] Pre-flight"
  if ! grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    err "This script is for WSL only. On macOS/native Linux use ./setup.sh"
    exit 1
  fi
  ok "WSL detected ($(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}"))"

  local REPO_DIR
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ ! -f "$REPO_DIR/setup.sh" ] || [ ! -f "$REPO_DIR/bin/m2-login" ]; then
    err "Run from a clone of this repo (need setup.sh + bin/m2-login)."
    exit 1
  fi
  ok "Repo: $REPO_DIR"

  if ! command -v cmd.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
    err "WSL interop is required (cmd.exe + wslpath). Upgrade your WSL distro or install wslu."
    exit 1
  fi

  # ---------- 2. Detect + confirm Windows account ----------
  bold "[2/6] Confirm Windows account"
  local detected_userprofile detected_winhome detected_winuser
  # cd /mnt/c so cmd.exe doesn't whine about a UNC-style cwd.
  detected_userprofile=$(cd /mnt/c 2>/dev/null && cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')
  if [ -z "$detected_userprofile" ]; then
    err "Could not detect Windows %USERPROFILE% via cmd.exe."
    exit 1
  fi
  detected_winhome=$(wslpath -u "$detected_userprofile")
  detected_winuser=$(basename "$detected_winhome")

  printf '  Detected Windows user:   \033[1;36m%s\033[0m\n' "$detected_winuser"
  printf '  Windows home (DOS):      %s\n' "$detected_userprofile"
  printf '  Windows home (WSL path): %s\n' "$detected_winhome"
  echo
  ask "Proceed with Windows user '$detected_winuser'? [Y/n]"
  if [[ "${REPLY:-Y}" =~ ^[Nn]$ ]]; then
    err "Aborted. To override detection, set M2_WIN_USERPROFILE before re-running:"
    err "    M2_WIN_USERPROFILE='C:\\Users\\someone' ./setup-wsl.sh"
    exit 0
  fi

  local WIN_USERPROFILE WIN_HOME WIN_USER
  WIN_USERPROFILE="${M2_WIN_USERPROFILE:-$detected_userprofile}"
  WIN_HOME=$(wslpath -u "$WIN_USERPROFILE")
  WIN_USER=$(basename "$WIN_HOME")
  if [ ! -d "$WIN_HOME" ]; then
    err "Windows home not accessible at $WIN_HOME"
    exit 1
  fi
  ok "Using Windows user: $WIN_USER"

  # ---------- 3. WSL/Linux side ----------
  bold "[3/6] WSL/Linux side (delegating to ./setup.sh)"
  bash "$REPO_DIR/setup.sh"

  # ---------- 4. cloudflared.exe → Windows ----------
  bold "[4/6] cloudflared.exe → Windows"
  local CF_SRC="$REPO_DIR/bin/cloudflared.exe"
  local CF_TMP=""
  if [ ! -f "$CF_SRC" ]; then
    warn "Bundled bin/cloudflared.exe missing — downloading from GitHub"
    CF_TMP=$(mktemp --suffix=.exe)
    CF_SRC="$CF_TMP"
    curl -fsSL --retry 3 -o "$CF_SRC" \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe
  fi
  local WIN_BIN="$WIN_HOME/bin"
  mkdir -p "$WIN_BIN"
  install -m 755 "$CF_SRC" "$WIN_BIN/cloudflared.exe"
  [ -n "$CF_TMP" ] && rm -f "$CF_TMP"
  ok "Installed: $WIN_USERPROFILE\\bin\\cloudflared.exe ($("$WIN_BIN/cloudflared.exe" --version 2>&1 | head -1))"

  # ---------- 5. Windows .ssh/config m2 block + key mirror ----------
  bold "[5/6] Windows .ssh\\config m2 block"
  local WIN_SSH_DIR="$WIN_HOME/.ssh"
  mkdir -p "$WIN_SSH_DIR"

  # Mirror SSH private key so Windows-native ssh can auth to m2proxymachine
  # without ProxyJump'ing through WSL. Same key on both sides ⇒ admin only
  # has to authorize once.
  if [ -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$WIN_SSH_DIR/id_ed25519" ]; then
    install -m 600 "$HOME/.ssh/id_ed25519" "$WIN_SSH_DIR/id_ed25519"
    [ -f "$HOME/.ssh/id_ed25519.pub" ] && install -m 644 "$HOME/.ssh/id_ed25519.pub" "$WIN_SSH_DIR/id_ed25519.pub"
    ok "Mirrored ed25519 key to Windows .ssh/"
  fi

  local WIN_SSH_CFG="$WIN_SSH_DIR/config"
  touch "$WIN_SSH_CFG"

  # Strip any prior m2 block (idempotency).
  if grep -q "^${MARK_BEGIN}$" "$WIN_SSH_CFG" 2>/dev/null; then
    log "Removing previous m2proxyserver block from Windows .ssh/config"
    awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
      $0 == b {skip=1; next}
      $0 == e {skip=0; next}
      !skip
    ' "$WIN_SSH_CFG" > "$WIN_SSH_CFG.tmp" && mv "$WIN_SSH_CFG.tmp" "$WIN_SSH_CFG"
  fi

  # Append fresh block. cmd.exe gives DOS paths (with \), so $WIN_USERPROFILE
  # already has backslashes — paste verbatim.
  cat >> "$WIN_SSH_CFG" <<EOF

${MARK_BEGIN}
# Generated by m2proxyserver/setup-wsl.sh — re-run to regenerate.
# Mirrors the WSL ~/.ssh/config block but with Windows paths and cloudflared.exe.
# Cert files under .tsh\\ are kept in sync from WSL by m2-login.

Host m2proxymachine
  HostName ssh.alexzms.com
  User proxy
  ProxyCommand "${WIN_USERPROFILE}\\bin\\cloudflared.exe" access ssh --hostname %h
  IdentityFile "${WIN_USERPROFILE}\\.ssh\\id_ed25519"

Host m2-login-001 m2-login-003
  HostName %h.mbzuai-hpc.teleport.sh

Host m2-login-001 m2-login-003 *.mbzuai-hpc.teleport.sh
  User hao.zhang
  Port 3022
  IdentityFile "${WIN_USERPROFILE}\\.tsh\\keys\\mbzuai-hpc.teleport.sh\\hao.zhang@mbzuai.ac.ae"
  CertificateFile "${WIN_USERPROFILE}\\.tsh\\keys\\mbzuai-hpc.teleport.sh\\hao.zhang@mbzuai.ac.ae-ssh\\mbzuai-hpc.teleport.sh-cert.pub"
  UserKnownHostsFile "${WIN_USERPROFILE}\\.tsh\\known_hosts"
  ProxyCommand ssh -q m2proxymachine /opt/homebrew/bin/tsh proxy ssh --cluster mbzuai-hpc.teleport.sh --proxy mbzuai-hpc.teleport.sh:443 %r@%h:%p
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ForwardAgent yes
${MARK_END}
EOF
  ok "Wrote m2 block to $WIN_USERPROFILE\\.ssh\\config"

  # ---------- 6. Refresh cert (mirror happens inside m2-login) ----------
  bold "[6/6] Refresh Teleport cert + Windows mirror"
  log "Running m2-login (will mirror ~/.tsh to $WIN_USERPROFILE\\.tsh)"
  if "$REPO_DIR/bin/m2-login"; then
    ok "Cert refreshed and mirrored"
  else
    warn "m2-login returned non-zero — try ssh m2-login-001 to verify."
  fi

  # ---------- Summary ----------
  printf '\n'
  bold "Setup complete for $WIN_USER."
  printf '\n  From WSL:        \033[1;36mssh m2-login-001\033[0m\n'
  printf '  From Windows:    \033[1;36mssh m2-login-001\033[0m   (PowerShell / Terminal / VS Code Remote-SSH)\n'
  printf '  Refresh cert:    \033[1;36mm2-login\033[0m   (run from WSL; auto-mirrors to Windows)\n'
  printf '\n'
  printf '  \033[2mNote: the public key is at ~/.ssh/id_ed25519.pub. If admin hasn'"'"'t added it yet,\n'
  printf '  send it on Slack, then re-run m2-login to pick up the cert.\033[0m\n'
}

main "$@"
