#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/gost_autobalance.conf"
[[ -f "$CONF" ]] || { echo "Missing $CONF"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

STATE_DIR="/var/lib/gost-autobalance"
mkdir -p "$STATE_DIR"

now_epoch() { date +%s; }

# Calculate peer .1<->.2 in /30 (simple heuristic)
calc_peer_ip() {
  local local_ip="$1"
  if [[ "$local_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.1$ ]]; then
    echo "${BASH_REMATCH[1]}.2"
  elif [[ "$local_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.2$ ]]; then
    echo "${BASH_REMATCH[1]}.1"
  else
    echo ""
  fi
}

# Fast loss check (integer 0-100). Unknown => 100
ping_loss_pct_fast() {
  local src_ip="$1"
  local dst_ip="$2"
  local out loss
  out=$(/bin/ping -c 20 -i 0.2 -W 1 -w 6 -I "$src_ip" "$dst_ip" 2>&1 || true)
  loss=$(echo "$out" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | head -n1 | cut -d% -f1 || true)
  if [[ -z "${loss:-}" ]]; then
    echo "100"; return 0
  fi
  loss="${loss%%.*}"
  [[ "$loss" =~ ^[0-9]+$ ]] || { echo "100"; return 0; }
  (( loss < 0 )) && loss=0
  (( loss > 100 )) && loss=100
  echo "$loss"
}

# Discover GRE ifaces like gre-ir-1, gre-kh-2, ...
discover_gre_ifaces() {
  /sbin/ip -o link show 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | grep -E '^gre-(ir|kh)-[0-9]+' \
    | sed 's/@.*$//' \
    | sort -u
}

iface_id() {
  local ifc="$1"
  echo "$ifc" | sed -E 's/^gre-(ir|kh)-([0-9]+)$/\2/'
}

iface_local_tun_ip() {
  local ifc="$1"
  /sbin/ip -o -4 addr show dev "$ifc" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}

state_file() { echo "$STATE_DIR/tunnel_${1}.state"; }

load_state() {
  local tid="$1"
  local f; f="$(state_file "$tid")"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
  else
    usable=0; bad_streak=0; good_streak=0; last_ts=0
  fi
}

save_state() {
  local tid="$1"
  local f; f="$(state_file "$tid")"
  cat > "$f" <<EOF
usable=$usable
bad_streak=$bad_streak
good_streak=$good_streak
last_ts=$last_ts
EOF
}

update_state_for_result() {
  local tid="$1" is_good="$2" step="$3"
  load_state "$tid"

  if (( is_good == 1 )); then
    good_streak=$((good_streak + step))
    bad_streak=0
    if (( good_streak >= GOOD_FOR )); then
      usable=1
    fi
  else
    bad_streak=$((bad_streak + step))
    good_streak=0
    if (( bad_streak >= BAD_FOR )); then
      usable=0
    fi
  fi

  last_ts="$(now_epoch)"
  save_state "$tid"
}

select_backends() {
  local -a all_ids=("$@")
  local -a usable_ids=()
  local tid
  for tid in "${all_ids[@]}"; do
    load_state "$tid"
    if (( usable == 1 )); then
      usable_ids+=("$tid")
    fi
  done

  IFS=$'\n' usable_ids=($(printf "%s\n" "${usable_ids[@]}" | sort -n))
  unset IFS

  local -a picked=()
  local i=0
  for tid in "${usable_ids[@]}"; do
    picked+=("$tid")
    i=$((i+1))
    (( i >= WANT_N )) && break
  done

  printf "%s\n" "${picked[@]}"
}

declare -A TID2PEER=()
declare -A TID2LOCAL=()

refresh_tunnel_map() {
  TID2PEER=()
  TID2LOCAL=()

  local ifc tid local_ip peer_ip
  while read -r ifc; do
    [[ -n "$ifc" ]] || continue
    tid="$(iface_id "$ifc")"
    [[ "$tid" =~ ^[0-9]+$ ]] || continue

    local_ip="$(iface_local_tun_ip "$ifc")"
    [[ -n "$local_ip" ]] || continue

    peer_ip="$(calc_peer_ip "$local_ip")"
    [[ -n "$peer_ip" ]] || continue

    TID2PEER["$tid"]="$peer_ip"
    TID2LOCAL["$tid"]="$local_ip"
  done < <(discover_gre_ifaces || true)
}

rebuild_gost_args_and_restart() {
  : > "$GOST_ARGS_FILE"
  while IFS= read -r rawline; do
    line="$(printf '%s' "$rawline" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    case "$line" in \#*) continue ;; esac

    ip="${line%%:*}"
    ports_csv="${line#*:}"

    IFS=',' read -r -a ports <<< "$ports_csv"
    for p in "${ports[@]}"; do
      p="$(printf '%s' "$p" | tr -d '[:space:]')"
      [[ "$p" =~ ^[0-9]{1,5}$ ]] || continue
      printf ' -L=tcp://:%s/[%s]:%s' "$p" "$ip" "$p" >> "$GOST_ARGS_FILE"
    done
    unset IFS
  done < "$GOST_PORTS_FILE"

  systemctl restart "$GOST_SERVICE"
}

main() {
  refresh_tunnel_map

  local -a tids=()
  local tid
  for tid in "${!TID2PEER[@]}"; do tids+=("$tid"); done

  if (( ${#tids[@]} == 0 )); then
    echo "[gost-autobalance] No GRE tunnel IPs found."
    exit 0
  fi

  IFS=$'\n' tids=($(printf "%s\n" "${tids[@]}" | sort -n))
  unset IFS

  # Evaluate each tunnel loss and update state
  local loss local_ip peer_ip is_good
  for tid in "${tids[@]}"; do
    local_ip="${TID2LOCAL[$tid]:-}"
    peer_ip="${TID2PEER[$tid]:-}"
    if [[ -z "$local_ip" || -z "$peer_ip" ]]; then
      update_state_for_result "$tid" 0 "$INTERVAL"
      continue
    fi

    loss="$(ping_loss_pct_fast "$local_ip" "$peer_ip")"
    if (( loss <= LOSS_THRESH )); then is_good=1; else is_good=0; fi
    update_state_for_result "$tid" "$is_good" "$INTERVAL"
  done

  mapfile -t chosen < <(select_backends "${tids[@]}" || true)
  if (( ${#chosen[@]} == 0 )); then
    echo "[gost-autobalance] No usable tunnels yet (waiting for GOOD_FOR). Keeping existing config."
    exit 0
  fi

  local tmp_ports; tmp_ports="$(mktemp)"
  trap 'rm -f "$tmp_ports"' EXIT

  # Build /etc/gost_ports.txt content (round-robin across chosen)
  {
    IFS=',' read -r -a ports <<< "$PORTS_CSV"
    unset IFS

    declare -A ip2ports=()
    local idx=0 p tid ip
    for p in "${ports[@]}"; do
      p="$(printf '%s' "$p" | tr -d '[:space:]')"
      [[ "$p" =~ ^[0-9]{1,5}$ ]] || continue

      tid="${chosen[$(( idx % ${#chosen[@]} ))]}"
      ip="${TID2PEER[$tid]:-}"
      [[ -n "$ip" ]] || { idx=$((idx+1)); continue; }

      if [[ -z "${ip2ports[$ip]:-}" ]]; then
        ip2ports["$ip"]="$p"
      else
        ip2ports["$ip"]+=",${p}"
      fi
      idx=$((idx+1))
    done

    for tid in "${chosen[@]}"; do
      ip="${TID2PEER[$tid]:-}"
      [[ -n "$ip" ]] || continue
      [[ -n "${ip2ports[$ip]:-}" ]] || continue
      echo "${ip}:${ip2ports[$ip]}"
    done
  } > "$tmp_ports"

  [[ -s "$tmp_ports" ]] || exit 0

  # If unchanged, do nothing
  if [[ -f "$GOST_PORTS_FILE" ]] && cmp -s "$tmp_ports" "$GOST_PORTS_FILE"; then
    exit 0
  fi

  install -m 0644 "$tmp_ports" "$GOST_PORTS_FILE"
  rebuild_gost_args_and_restart

  echo "[gost-autobalance] Updated mapping using GRE: ${chosen[*]}"
}

main
