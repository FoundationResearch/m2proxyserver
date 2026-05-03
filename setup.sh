#!/usr/bin/env bash
# m2proxyserver setup — one-shot installer for lab members (macOS only).
# Works either from a git clone (./setup.sh) or piped from curl
# (curl ... | bash). Re-runnable; safe to invoke multiple times.

set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/FoundationResearch/m2proxyserver/main"
JUMP_HOST_FQDN="ssh.alexzms.com"
JUMP_USER="proxy"
ADMIN_CONTACT="Alex Zhang, Will Lin, or Yuxuan Zhang on Slack"

MARK_BEGIN="# ===== m2proxyserver: do not edit between markers ====="
MARK_END="# ===== /m2proxyserver ====="

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
log()   { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
# Read prompts from the controlling tty so `curl ... | bash` still works
# (otherwise stdin is the script itself).
ask()   { local prompt="$1"; printf '\033[1;35m?\033[0m %s ' "$prompt"; read -r REPLY < /dev/tty; }

# Everything below lives in main() so bash parses the whole script body BEFORE
# any child process runs. This is the standard `curl | bash` defense: brew's
# auto-update spawns subprocesses (git, ruby) which inherit stdin and can
# consume script bytes from the curl pipe. Pre-parsing into a function means
# bash no longer needs to read more from stdin once main() starts executing.
main() {
  # Resolve where bin/m2-login lives. If we're running from a clone, use the
  # local copy; if we're piped via curl | bash, fetch from GitHub.
  local REPO_DIR=""
  local SCRIPT_SRC="${BASH_SOURCE[0]:-}"
  if [ -n "$SCRIPT_SRC" ] && [ -f "$SCRIPT_SRC" ]; then
    REPO_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
  fi

  # ---------- 1. Pre-flight ----------
  bold "[1/8] Pre-flight checks"
  if [ "$(uname -s)" != "Darwin" ]; then
    err "This installer currently supports macOS only."
    exit 1
  fi
  ok "macOS detected ($(sw_vers -productName) $(sw_vers -productVersion))"

  # ---------- 2. Homebrew ----------
  bold "[2/8] Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found. Install it (will run the official installer):"
    ask "Install Homebrew now? [y/N]"
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      # The Homebrew installer reads "Press RETURN to continue" from stdin
      # AND prompts sudo for /opt/homebrew ownership. Both come from the
      # controlling tty. We can't pass /dev/null here (would EOF the prompt)
      # and we can't inherit our stdin (would consume the curl|bash pipe).
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
    else
      err "Homebrew is required. Install manually from https://brew.sh and re-run."
      exit 1
    fi
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi
  ok "Homebrew: $(brew --version | head -1)"

  # ---------- 3. cloudflared ----------
  bold "[3/8] cloudflared"
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "Installing cloudflared via Homebrew..."
    brew install cloudflared < /dev/null
  fi
  ok "cloudflared: $(cloudflared --version 2>&1 | head -1)"

  # ---------- 3b. Chromium-family browser (strict-mode requirement) ----------
  bold "[3b/8] Chromium-family browser (required for strict Okta flow)"
  local HAVE_CHROMIUM=""
  local app
  for app in \
    "/Applications/Google Chrome.app" \
    "/Applications/Brave Browser.app" \
    "/Applications/Chromium.app" \
    "/Applications/Microsoft Edge.app" \
    "/Applications/Arc.app"; do
    if [ -d "$app" ]; then
      HAVE_CHROMIUM="$app"
      break
    fi
  done

  if [ -z "$HAVE_CHROMIUM" ]; then
    warn "No Chromium-family browser found."
    warn "STRICT mode (mandatory) routes the Okta login through an SSH SOCKS5"
    warn "tunnel into the macmini, so Okta sees the macmini's IP — NOT yours."
    warn "Safari and Firefox cannot be configured for per-instance proxy via CLI,"
    warn "so we require a Chromium-family browser."
    echo
    ask "Install Google Chrome via Homebrew now? [Y/n]"
    if [[ "${REPLY:-Y}" =~ ^[Nn]$ ]]; then
      err "A Chromium-family browser is required. Install one and re-run."
      exit 1
    fi
    brew install --cask google-chrome < /dev/null
    HAVE_CHROMIUM="/Applications/Google Chrome.app"
  fi
  ok "Found: $HAVE_CHROMIUM"

  # ---------- 3c. /etc/hosts IPv4 pin ----------
  # cloudflared dials Cloudflare's edge by hostname. On networks with broken
  # IPv6 to Cloudflare (common at universities / behind some NATs), cloudflared
  # picks the AAAA record, gets "no route to host", and dies without falling
  # back to IPv4. Pinning ssh.alexzms.com to the v4 anycast IPs in /etc/hosts
  # forces v4-only resolution.
  #
  # We resolve the CURRENT v4 IPs via 1.1.1.1 every time so re-running setup.sh
  # automatically fixes any drift if Cloudflare ever rotates their anycast pool.
  bold "[3c/8] /etc/hosts IPv4 pin for ssh.alexzms.com"
  local HOSTS_MARK="# m2proxyserver: pin ssh.alexzms.com to IPv4 (fixes cloudflared 'no route to host' on networks with broken IPv6 to Cloudflare)"
  log "Resolving current Cloudflare IPv4 for ssh.alexzms.com (via 1.1.1.1)"
  local CF_IPS
  CF_IPS=$(dig @1.1.1.1 +short +time=3 +tries=2 A ssh.alexzms.com 2>/dev/null \
    | grep -E '^[0-9.]+$' | sort -u)
  if [ -z "$CF_IPS" ]; then
    warn "DNS resolution failed; falling back to known-good IPs"
    CF_IPS=$'104.21.59.64\n172.67.216.250'
  fi
  ok "Resolved: $(echo $CF_IPS | tr '\n' ' ')"

  log "Refreshing /etc/hosts pin (sudo required; nukes any prior ssh.alexzms.com line and re-adds with current IPs)"
  local TMP_HOSTS
  TMP_HOSTS=$(mktemp)
  awk -v mark="$HOSTS_MARK" '
    $0 ~ /ssh\.alexzms\.com/ { next }
    $0 == mark { next }
    { print }
  ' /etc/hosts > "$TMP_HOSTS"
  {
    printf '\n%s\n' "$HOSTS_MARK"
    while IFS= read -r ip; do
      printf '%s\tssh.alexzms.com\n' "$ip"
    done <<< "$CF_IPS"
  } >> "$TMP_HOSTS"

  if sudo install -m 644 -o root -g wheel "$TMP_HOSTS" /etc/hosts; then
    ok "Pinned ssh.alexzms.com → $(echo $CF_IPS | tr '\n' ' ')in /etc/hosts"
  else
    warn "Could not write /etc/hosts. If ssh fails with 'no route to host', run manually:"
    warn "    echo '$(echo $CF_IPS | head -1) ssh.alexzms.com' | sudo tee -a /etc/hosts"
  fi
  rm -f "$TMP_HOSTS"

  # ---------- 4. SSH key ----------
  bold "[4/8] SSH key"
  local SSH_DIR="$HOME/.ssh"
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

  local PUBKEY=""
  local candidate
  for candidate in id_ed25519.pub id_rsa.pub id_ecdsa.pub; do
    if [ -f "$SSH_DIR/$candidate" ]; then
      PUBKEY="$SSH_DIR/$candidate"
      break
    fi
  done

  if [ -z "$PUBKEY" ]; then
    log "No existing SSH public key found — generating a new ed25519 key"
    ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" < /dev/null
    PUBKEY="$SSH_DIR/id_ed25519.pub"
  fi
  ok "Using public key: $PUBKEY"

  # ---------- 5. SSH config ----------
  bold "[5/8] SSH config"
  local SSH_CONFIG="$SSH_DIR/config"
  touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"

  if grep -q "^${MARK_BEGIN}$" "$SSH_CONFIG" 2>/dev/null; then
    log "Removing previous m2proxyserver block from ~/.ssh/config"
    awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
      $0 == b {skip=1; next}
      $0 == e {skip=0; next}
      !skip
    ' "$SSH_CONFIG" > "$SSH_CONFIG.tmp" && mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
  fi

  log "Inserting m2proxyserver block at top of ~/.ssh/config"
  local TMP_CFG
  TMP_CFG=$(mktemp)
  cat > "$TMP_CFG" <<EOF
${MARK_BEGIN}
# Generated by m2proxyserver/setup.sh — re-run to regenerate.

Host macmini
  HostName ${JUMP_HOST_FQDN}
  User ${JUMP_USER}
  ProxyCommand cloudflared access ssh --hostname %h

Host m2-login-001 m2-login-003
  HostName %h.mbzuai-hpc.teleport.sh

Host m2-login-001 m2-login-003 *.mbzuai-hpc.teleport.sh
  User hao.zhang
  Port 3022
  IdentityFile ~/.tsh/keys/mbzuai-hpc.teleport.sh/hao.zhang@mbzuai.ac.ae
  CertificateFile ~/.tsh/keys/mbzuai-hpc.teleport.sh/hao.zhang@mbzuai.ac.ae-ssh/mbzuai-hpc.teleport.sh-cert.pub
  UserKnownHostsFile ~/.tsh/known_hosts
  ProxyCommand ssh -q macmini /opt/homebrew/bin/tsh proxy ssh --cluster mbzuai-hpc.teleport.sh --proxy mbzuai-hpc.teleport.sh:443 %r@%h:%p
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ForwardAgent yes
${MARK_END}

EOF
  cat "$SSH_CONFIG" >> "$TMP_CFG"
  mv "$TMP_CFG" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  ok "SSH config updated"

  # ---------- 6. m2-login script ----------
  bold "[6/8] m2-login script"
  local INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"

  local M2_LOGIN_TMP=""
  local M2_LOGIN_SRC
  if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/bin/m2-login" ]; then
    M2_LOGIN_SRC="$REPO_DIR/bin/m2-login"
  else
    log "Fetching bin/m2-login from GitHub"
    M2_LOGIN_TMP=$(mktemp -t m2-login)
    M2_LOGIN_SRC="$M2_LOGIN_TMP"
    curl -fsSL "${REPO_RAW_BASE}/bin/m2-login" -o "$M2_LOGIN_SRC"
  fi

  install -m 755 "$M2_LOGIN_SRC" "$INSTALL_DIR/m2-login"
  [ -n "$M2_LOGIN_TMP" ] && rm -f "$M2_LOGIN_TMP"
  ok "Installed: $INSTALL_DIR/m2-login"

  # ---------- 7. PATH / shell rc ----------
  bold "[7/8] Shell PATH"
  local RC_FILES=()
  [ -f "$HOME/.zshrc" ] && RC_FILES+=("$HOME/.zshrc")
  [ -f "$HOME/.bashrc" ] && RC_FILES+=("$HOME/.bashrc")
  [ -f "$HOME/.bash_profile" ] && RC_FILES+=("$HOME/.bash_profile")
  if [ ${#RC_FILES[@]} -eq 0 ]; then
    case "$SHELL" in
      *zsh)  RC_FILES+=("$HOME/.zshrc") ;;
      *bash) RC_FILES+=("$HOME/.bash_profile") ;;
      *)     RC_FILES+=("$HOME/.profile") ;;
    esac
  fi

  local rc
  for rc in "${RC_FILES[@]}"; do
    if grep -q "^${MARK_BEGIN}$" "$rc" 2>/dev/null; then
      log "Removing previous m2proxyserver PATH block from $rc"
      awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
        $0 == b {skip=1; next}
        $0 == e {skip=0; next}
        !skip
      ' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
    fi
    cat >> "$rc" <<EOF
${MARK_BEGIN}
# Add m2-login to PATH
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH";; esac
${MARK_END}
EOF
    ok "PATH block added to $rc"
  done

  # ---------- 8. Pubkey hand-off ----------
  bold "[8/8] Hand off your public key"

  # ANSI palette for the styled sections below.
  local CR=$'\033[0m'
  local B=$'\033[1m'
  local DIM=$'\033[2m'
  local CYAN=$'\033[1;36m'
  local YEL=$'\033[1;33m'
  local RED=$'\033[1;31m'
  local GRN=$'\033[1;32m'
  local MAG=$'\033[1;35m'
  local DIV='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

  # Pubkey block — boxed and bright so it's impossible to miss.
  printf '\n'
  printf '%s%s%s\n' "$YEL" "  ┌─ Send this exact line to ${ADMIN_CONTACT}" "$CR"
  printf '%s%s%s\n' "$YEL" "  │" "$CR"
  while IFS= read -r line; do
    printf '%s  │  %s%s%s\n' "$YEL" "$CYAN" "$line" "$CR"
  done < "$PUBKEY"
  printf '%s%s%s\n' "$YEL" "  │" "$CR"
  printf '%s%s%s%s%s\n' "$YEL" "  └─ copy with: " "$B" "pbcopy < $PUBKEY" "$CR"
  printf '\n'

  # Pick the most likely rc file the user's interactive shell will read.
  local SOURCE_HINT=""
  case "$SHELL" in
    *zsh)
      [ -f "$HOME/.zshrc" ] && SOURCE_HINT="source ~/.zshrc"
      ;;
    *bash)
      if [ -f "$HOME/.bash_profile" ]; then
        SOURCE_HINT="source ~/.bash_profile"
      elif [ -f "$HOME/.bashrc" ]; then
        SOURCE_HINT="source ~/.bashrc"
      fi
      ;;
  esac
  [ -z "$SOURCE_HINT" ] && SOURCE_HINT="source ~/.zshrc   # or ~/.bashrc, whichever your shell uses"

  printf '%s%s%s\n'  "$GRN" "  ✓ Setup complete." "$CR"

  # ---------- NEXT STEPS ----------
  printf '\n%s%s%s\n'   "$DIM"  "$DIV"           "$CR"
  printf '%s%s%s\n'     "${B}${CYAN}" "  NEXT STEPS"  "$CR"
  printf '%s%s%s\n\n'   "$DIM"  "$DIV"           "$CR"

  printf '  %s1.%s Send the public key above to %s%s%s on Slack.\n' \
    "$B" "$CR" "$MAG" "$ADMIN_CONTACT" "$CR"
  printf '  %s2.%s Wait for confirmation that your key has been added.\n' \
    "$B" "$CR"
  printf '  %s3.%s Activate the new PATH in %sTHIS%s shell:\n' \
    "$B" "$CR" "$B" "$CR"
  printf '         %s%s%s\n' "$CYAN" "$SOURCE_HINT" "$CR"
  printf '       %sor%s open a new terminal window.\n' "$DIM" "$CR"
  printf '  %s4.%s Run:\n' "$B" "$CR"
  printf '         %s%s%s   %s# obtain Teleport cert (~24h)%s\n' \
    "$CYAN" "m2-login" "$CR" "$DIM" "$CR"
  printf '         %s%s%s   %s# connect to cluster login node%s\n' \
    "$CYAN" "ssh m2-login-003" "$CR" "$DIM" "$CR"

  # ---------- VS Code ----------
  printf '\n%s%s%s\n'   "$DIM"  "$DIV"           "$CR"
  printf '%s%s%s\n'     "${B}${CYAN}" "  VS CODE / CURSOR / ANTIGRAVITY"  "$CR"
  printf '%s%s%s\n\n'   "$DIM"  "$DIV"           "$CR"
  printf '  Remote-SSH  →  Connect to Host  →  %s%s%s\n' "$CYAN" "m2-login-003" "$CR"

  # ---------- Hard rule ----------
  printf '\n%s%s%s\n'   "$DIM"  "$DIV"           "$CR"
  printf '%s%s%s\n'     "${B}${RED}" "  ⚠  HARD RULE — DO NOT VIOLATE"  "$CR"
  printf '%s%s%s\n\n'   "$DIM"  "$DIV"           "$CR"
  printf '  %sNEVER%s ssh / tsh directly to %smbzuai-hpc.teleport.sh%s from your\n' \
    "${B}${RED}" "$CR" "$B" "$CR"
  printf '  laptop or %sany non-macmini machine%s. The cluster bans the shared\n' \
    "$B" "$CR"
  printf '  account if it sees multiple source IPs. %sAll traffic must flow\n' "$B"
  printf '  through macmini.%s\n\n' "$CR"
}

main "$@"
