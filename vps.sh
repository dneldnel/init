#!/usr/bin/env bash
set -euo pipefail

# ============ Config (you can override via env) ============
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"          # default 2GB swap
NODE_MAX_OLD_SPACE_MB="${NODE_MAX_OLD_SPACE_MB:-256}"  # default node heap limit 256MB
SYSCTL_CONF="/etc/sysctl.d/99-vps-tuning.conf"
SWAPFILE="/swapfile"

log() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[✗] $*\033[0m" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ============ Preflight ============
if ! need_cmd sudo; then
  err "sudo not found. Please install sudo or run as root."
  exit 1
fi

log "Updating apt & installing required packages (curl, build-essential, htop, glances, earlyoom)..."
sudo apt update -y
sudo apt install -y curl build-essential htop glances earlyoom

# ============ STEP 1: Swap ============
log "STEP 1: Ensuring swap exists and is enabled..."
# If swap is already enabled, skip creation; still ensure persistence.
if swapon --show | awk '{print $1}' | grep -qx "$SWAPFILE"; then
  log "Swapfile already enabled: $SWAPFILE"
else
  if [[ -f "$SWAPFILE" ]]; then
    warn "$SWAPFILE exists but not enabled. Will try to enable it."
  else
    log "Creating ${SWAP_SIZE_GB}G swapfile at $SWAPFILE ..."
    # Prefer fallocate; fallback to dd if needed
    if need_cmd fallocate; then
      sudo fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE" || true
    fi
    if [[ ! -s "$SWAPFILE" ]]; then
      warn "fallocate failed or produced empty file; using dd (slower)..."
      sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    fi
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
  fi

  sudo swapon "$SWAPFILE"
  log "Swap enabled."
fi

# Persist swap in /etc/fstab (avoid duplicates)
if ! grep -qE "^\s*$SWAPFILE\s+none\s+swap\s" /etc/fstab; then
  log "Persisting swap in /etc/fstab ..."
  echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
else
  log "Swap persistence already present in /etc/fstab"
fi

# ============ STEP 2: Sysctl tuning ============
log "STEP 2: Applying sysctl tuning for small-memory VPS..."
sudo tee "$SYSCTL_CONF" >/dev/null <<'EOF'
# Tunings for small VPS stability
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.overcommit_memory=1
EOF

sudo sysctl --system >/dev/null
log "Sysctl applied via $SYSCTL_CONF"

# ============ STEP 3: Protect SSH from OOM killer ============
log "STEP 3: Protecting SSH service from OOM killer..."

# Ubuntu typically uses ssh.service; some systems use sshd.service
SSH_UNIT=""
if systemctl list-unit-files | awk '{print $1}' | grep -qx "ssh.service"; then
  SSH_UNIT="ssh.service"
elif systemctl list-unit-files | awk '{print $1}' | grep -qx "sshd.service"; then
  SSH_UNIT="sshd.service"
else
  warn "Neither ssh.service nor sshd.service found. Skipping SSH OOM protection."
fi

if [[ -n "$SSH_UNIT" ]]; then
  OVERRIDE_DIR="/etc/systemd/system/${SSH_UNIT}.d"
  sudo mkdir -p "$OVERRIDE_DIR"
  sudo tee "${OVERRIDE_DIR}/override.conf" >/dev/null <<'EOF'
[Service]
OOMScoreAdjust=-1000
EOF

  sudo systemctl daemon-reload
  # daemon-reexec is stronger but can be disruptive; reload + restart is usually enough
  sudo systemctl restart "$SSH_UNIT"
  log "Applied OOMScoreAdjust=-1000 to $SSH_UNIT"
fi

# ============ STEP 4: Limit Node memory (user shell) ============
log "STEP 4: Setting NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE_MB} for your shell..."

append_once() {
  local file="$1"
  local line="$2"
  [[ -f "$file" ]] || return 0
  if ! grep -qF "$line" "$file"; then
    echo "" >> "$file"
    echo "# Added by vps_tune.sh" >> "$file"
    echo "$line" >> "$file"
    log "Updated $file"
  else
    log "Already set in $file"
  fi
}

NODE_LINE="export NODE_OPTIONS=\"--max-old-space-size=${NODE_MAX_OLD_SPACE_MB}\""

# Current user (who runs the script)
USER_HOME="${HOME:-/root}"
append_once "${USER_HOME}/.bashrc" "$NODE_LINE"
append_once "${USER_HOME}/.zshrc"  "$NODE_LINE"

# Also set globally (optional but useful for non-interactive services)
GLOBAL_NODE_CONF="/etc/profile.d/node_options.sh"
if ! sudo grep -qF "$NODE_LINE" "$GLOBAL_NODE_CONF" 2>/dev/null; then
  sudo tee "$GLOBAL_NODE_CONF" >/dev/null <<EOF
# Added by vps_tune.sh
$NODE_LINE
EOF
  log "Updated $GLOBAL_NODE_CONF"
else
  log "Already set in $GLOBAL_NODE_CONF"
fi

# ============ STEP 5: Tools (htop/glances already installed) ============
log "STEP 5: htop & glances installed."

# ============ STEP 6: earlyoom ============
log "STEP 6: Enabling earlyoom..."
sudo systemctl enable --now earlyoom >/dev/null
log "earlyoom enabled."

# ============ Summary ============
log "DONE. Quick status:"
echo "---- free -h ----"
free -h || true
echo
echo "---- swapon --show ----"
swapon --show || true
echo
echo "---- sysctl (selected) ----"
sysctl vm.swappiness vm.vfs_cache_pressure vm.overcommit_memory || true
echo
if [[ -n "$SSH_UNIT" ]]; then
  echo "---- SSH unit ----"
  systemctl is-active "$SSH_UNIT" || true
fi
echo
echo "Next login will pick up NODE_OPTIONS automatically. To apply now, run:"
echo "  source ~/.bashrc  # or source ~/.zshrc"
