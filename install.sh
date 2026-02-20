#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/Kup1ng/gost_autobalance/main"

CONF="/etc/gost_autobalance.conf"
BIN="/usr/local/bin/gost-autobalance"
STATE_DIR="/var/lib/gost-autobalance"

SERVICE="/etc/systemd/system/gost-autobalance.service"
TIMER="/etc/systemd/system/gost-autobalance.timer"

GOST_PORTS_FILE="/etc/gost_ports.txt"
GOST_ARGS_FILE="/etc/gost_args.conf"
GOST_SERVICE_DEFAULT="gost-multi.service"

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root"; exit 1; }; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

fetch() {
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  else
    echo "Need wget or curl"; exit 1
  fi
}

backup_files() {
  mkdir -p "$STATE_DIR/backup"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local dir="$STATE_DIR/backup/$ts"
  mkdir -p "$dir"
  [[ -f "$GOST_PORTS_FILE" ]] && cp -a "$GOST_PORTS_FILE" "$dir/gost_ports.txt"
  [[ -f "$GOST_ARGS_FILE"  ]] && cp -a "$GOST_ARGS_FILE"  "$dir/gost_args.conf"
  [[ -f "$CONF"            ]] && cp -a "$CONF"            "$dir/gost_autobalance.conf"
  echo "$dir" > "$STATE_DIR/backup/LATEST"
}

restore_latest_backup() {
  [[ -f "$STATE_DIR/backup/LATEST" ]] || return 0
  local dir; dir="$(cat "$STATE_DIR/backup/LATEST" 2>/dev/null || true)"
  [[ -d "$dir" ]] || return 0
  [[ -f "$dir/gost_ports.txt" ]] && cp -a "$dir/gost_ports.txt" "$GOST_PORTS_FILE"
  [[ -f "$dir/gost_args.conf" ]]  && cp -a "$dir/gost_args.conf"  "$GOST_ARGS_FILE"
}

install_flow() {
  need_root
  need_cmd ip
  need_cmd ping
  need_cmd systemctl
  need_cmd awk
  need_cmd sed
  need_cmd tr
  need_cmd grep

  echo "=== gost-autobalance :: INSTALL ==="

  read -rp "Ports CSV (example: 8001,8007,8002,...): " PORTS
  PORTS="$(printf '%s' "$PORTS" | tr -d '[:space:]')"
  [[ -n "$PORTS" ]] || { echo "Ports cannot be empty"; exit 1; }

  IFS=',' read -r -a _ports_arr <<< "$PORTS"
  for p in "${_ports_arr[@]}"; do
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port: $p"; exit 1; }
    (( p >= 1 && p <= 65535 )) || { echo "Invalid port range: $p"; exit 1; }
  done
  unset IFS

  read -rp "How many GRE backends to use concurrently? (default 4): " WANT_N
  WANT_N="${WANT_N:-4}"
  [[ "$WANT_N" =~ ^[0-9]+$ ]] || { echo "Invalid number"; exit 1; }
  (( WANT_N >= 1 && WANT_N <= 64 )) || { echo "Unreasonable number"; exit 1; }

  read -rp "Loss threshold percent (default 20): " LOSS_THRESH
  LOSS_THRESH="${LOSS_THRESH:-20}"
  [[ "$LOSS_THRESH" =~ ^[0-9]+$ ]] || { echo "Invalid loss threshold"; exit 1; }
  (( LOSS_THRESH >= 0 && LOSS_THRESH <= 100 )) || { echo "Invalid loss threshold"; exit 1; }

  read -rp "Bad for seconds to failover (default 120): " BAD_FOR
  BAD_FOR="${BAD_FOR:-120}"
  [[ "$BAD_FOR" =~ ^[0-9]+$ ]] || { echo "Invalid BAD_FOR"; exit 1; }

  read -rp "Good for seconds to failback (default 30): " GOOD_FOR
  GOOD_FOR="${GOOD_FOR:-30}"
  [[ "$GOOD_FOR" =~ ^[0-9]+$ ]] || { echo "Invalid GOOD_FOR"; exit 1; }

  read -rp "Check interval seconds (default 60): " INTERVAL
  INTERVAL="${INTERVAL:-60}"
  [[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "Invalid INTERVAL"; exit 1; }
  (( INTERVAL >= 5 && INTERVAL <= 3600 )) || { echo "Invalid interval"; exit 1; }

  read -rp "Gost systemd service name (default: ${GOST_SERVICE_DEFAULT}): " GOST_SERVICE
  GOST_SERVICE="${GOST_SERVICE:-$GOST_SERVICE_DEFAULT}"

  mkdir -p "$STATE_DIR"
  backup_files

  tmp="$(mktemp)"
  fetch "${REPO_RAW_BASE}/gost-autobalance" "$tmp"
  install -m 0755 "$tmp" "$BIN"
  rm -f "$tmp"

  cat > "$CONF" <<EOF
# gost-autobalance config
PORTS_CSV="$PORTS"
WANT_N=$WANT_N
LOSS_THRESH=$LOSS_THRESH
BAD_FOR=$BAD_FOR
GOOD_FOR=$GOOD_FOR
INTERVAL=$INTERVAL

# Output files used by your gost service
GOST_PORTS_FILE="$GOST_PORTS_FILE"
GOST_ARGS_FILE="$GOST_ARGS_FILE"
GOST_SERVICE="$GOST_SERVICE"
EOF

  cat > "$SERVICE" <<EOF
[Unit]
Description=gost auto-balance based on GRE loss
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
EOF

  cat > "$TIMER" <<EOF
[Unit]
Description=Run gost-autobalance periodically

[Timer]
OnBootSec=10
OnUnitActiveSec=$INTERVAL
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now gost-autobalance.timer

  echo
  echo "[OK] Installed."
  echo "Config: $CONF"
  echo "Run once: $BIN"
  echo "Timer: systemctl status gost-autobalance.timer --no-pager"
  echo "Logs : journalctl -u gost-autobalance.service -n 200 --no-pager"
}

remove_flow() {
  need_root
  echo "=== gost-autobalance :: REMOVE ==="

  systemctl stop gost-autobalance.timer 2>/dev/null || true
  systemctl disable gost-autobalance.timer 2>/dev/null || true
  systemctl stop gost-autobalance.service 2>/dev/null || true

  rm -f "$TIMER" "$SERVICE"
  systemctl daemon-reload || true

  restore_latest_backup

  rm -f "$CONF" "$BIN"
  rm -rf "$STATE_DIR"

  echo "[OK] Removed. (Restored backups if available.)"
}

main() {
  need_root
  echo "Select an option:"
  echo "  1) Install"
  echo "  2) Remove"
  read -rp "Choice [1-2]: " CH

  case "${CH:-}" in
    1) install_flow ;;
    2) remove_flow ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
}

main
