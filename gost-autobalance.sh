#!/usr/bin/env bash
set -euo pipefail

# Colors (for status output)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Status ping defaults (can be overridden in /etc/gost_autobalance.conf)
STATUS_PING_COUNT=${STATUS_PING_COUNT:-20}
STATUS_PING_INTERVAL=${STATUS_PING_INTERVAL:-0.1}
STATUS_PING_TIMEOUT=${STATUS_PING_TIMEOUT:-1}
STATUS_PING_DEADLINE=${STATUS_PING_DEADLINE:-6}

CONF="/etc/gost_autobalance.conf"
[[ -f "$CONF" ]] || { echo "Missing $CONF"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

STATE_DIR="/var/lib/gost-autobalance"
mkdir -p "$STATE_DIR"

now_epoch() { date +%s; }

# Calculate peer .1<->.2 in /30
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
ping_loss_pct() {
  # Usage: ping_loss_pct <src_ip_or_dash> <dst_ip>
  # If src is "-", ping without binding; otherwise bind using -I <src>.
  local src="$1"
  local dst="$2"
  local out loss
  if [[ "$src" == "-" ]]; then
    out=$(/bin/ping -c "${STATUS_PING_COUNT}" -i "${STATUS_PING_INTERVAL}" -W "${STATUS_PING_TIMEOUT}" -w "${STATUS_PING_DEADLINE}" "$dst" 2>&1 || true)
  else
    out=$(/bin/ping -c "${STATUS_PING_COUNT}" -i "${STATUS_PING_INTERVAL}" -W "${STATUS_PING_TIMEOUT}" -w "${STATUS_PING_DEADLINE}" -I "$src" "$dst" 2>&1 || true)
  fi
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

ping_loss_pct_fast() {
  local src_ip="$1"
  local dst_ip="$2"
  local out loss

  # Configurable ping parameters from /etc/gost_autobalance.conf
  # Defaults match the original behavior unless overridden.
  out=$(/bin/ping -c "${PING_COUNT:-20}" -i "${PING_INTERVAL:-0.2}" -W "${PING_TIMEOUT:-1}" -w "${PING_DEADLINE:-6}" -I "$src_ip" "$dst_ip" 2>&1 || true)
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

# Get tunnel id number from iface name
iface_id() {
  local ifc="$1"
  echo "$ifc" | sed -E 's/^gre-(ir|kh)-([0-9]+)$/\2/'
}

# Get local tunnel IP (without /mask)
iface_local_tun_ip() {
  local ifc="$1"
  /sbin/ip -o -4 addr show dev "$ifc" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}

# State tracking per tunnel id: usable=0/1 + streak seconds
state_file() { echo "$STATE_DIR/tunnel_${1}.state"; }

load_state() {
  local tid="$1"
  local f; f="$(state_file "$tid")"
  if [[ -f "$f" ]]; then
    # usable=1 bad=0 good=0 last=epoch
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

  if (( last_ts <= 0 )); then
    last_ts="$(now_epoch)"
  fi

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

# Build desired backend set: choose lowest WANT_N usable tunnel IDs
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

  # sort numeric
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

# Map tid -> peer_tun_ip
declare -A TID2PEER=()
declare -A TID2IFACE=()
declare -A TID2LOCAL=()

refresh_tunnel_map() {
  TID2PEER=()
  TID2IFACE=()
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
    TID2IFACE["$tid"]="$ifc"
    TID2LOCAL["$tid"]="$local_ip"
  done < <(discover_gre_ifaces || true)
}

# Generate /etc/gost_ports.txt based on selected tids + ports distribution
parse_ports_csv() {
  # PORTS_CSV items may be:
  #   8081
  #   8081:2
  # Meaning: port 8081 with weight 2 (counts like 2 ports for balancing).
  # Outputs: two arrays (ports + weights).
  local csv="$1"
  local -n PORTS_OUT="$2"
  local -n WEIGHTS_OUT="$3"

  PORTS_OUT=()
  WEIGHTS_OUT=()

  local item port w
  IFS=',' read -r -a items <<< "$csv"
  unset IFS
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [[ -n "$item" ]] || continue

    port="${item%%:*}"
    w="${item#*:}"
    if [[ "$item" == "$port" ]]; then
      w="1"
    fi

    [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
    (( port >= 1 && port <= 65535 )) || continue
    [[ "$w" =~ ^[0-9]+$ ]] || w="1"
    (( w < 1 )) && w=1
    (( w > 100 )) && w=100

    PORTS_OUT+=("$port")
    WEIGHTS_OUT+=("$w")
  done
}

write_gost_ports() {
  local -a backends=("$@")
  (( ${#backends[@]} > 0 )) || return 1

  local -a ports weights
  parse_ports_csv "$PORTS_CSV" ports weights
  (( ${#ports[@]} > 0 )) || return 1

  # Weighted greedy assignment: assign each port to the backend with the lowest current load.
  # Load = sum(weights). Default weight=1; e.g. 8801:3 counts like 3 ports.
  declare -A ip2ports=()
  declare -A ip2load=()

  local tid ip i best_ip best_load cur_load w p
  for tid in "${backends[@]}"; do
    ip="${TID2PEER[$tid]:-}"
    [[ -n "$ip" ]] || continue
    ip2load["$ip"]=0
    ip2ports["$ip"]=""
  done

  for i in "${!ports[@]}"; do
    p="${ports[$i]}"
    w="${weights[$i]}"

    best_ip=""
    best_load=0

    for tid in "${backends[@]}"; do
      ip="${TID2PEER[$tid]:-}"
      [[ -n "$ip" ]] || continue
      cur_load="${ip2load[$ip]:-0}"
      if [[ -z "$best_ip" || "$cur_load" -lt "$best_load" ]]; then
        best_ip="$ip"
        best_load="$cur_load"
      fi
    done

    [[ -n "$best_ip" ]] || continue
    if [[ -z "${ip2ports[$best_ip]:-}" ]]; then
      ip2ports["$best_ip"]="$p"
    else
      ip2ports["$best_ip"]+=",${p}"
    fi
    ip2load["$best_ip"]=$(( ${ip2load[$best_ip]:-0} + w ))
  done

  local tmp; tmp="$(mktemp)"
  for tid in "${backends[@]}"; do
    ip="${TID2PEER[$tid]:-}"
    [[ -n "$ip" ]] || continue
    [[ -n "${ip2ports[$ip]:-}" ]] || continue
    echo "${ip}:${ip2ports[$ip]}" >> "$tmp"
  done

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi

  install -m 0644 "$tmp" "$GOST_PORTS_FILE"
  rm -f "$tmp"
  return 0
}


# Build gost args file exactly like your snippet
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

files_equal() {
  local a="$1" b="$2"
  [[ -f "$a" && -f "$b" ]] || return 1
  cmp -s "$a" "$b"
}

status_ping_all() {
  shopt -s nullglob

  local ifaces=()
  local sline
  while read -r sline; do
    [[ -n "$sline" ]] || continue
    sline="${sline%%@*}"
    ifaces+=("$sline")
  done < <(
    /sbin/ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^gre-(ir|kh)-[0-9]+' | sort -u
  )

  if (( ${#ifaces[@]} == 0 )); then
    echo "No GRE interfaces found."
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir:-}"' RETURN

  for ifc in "${ifaces[@]}"; do
    (
      local tid local_tun_ip dst_ip link_line local_pub peer_pub
      local peer_loss dst_loss detail max_loss
      local peer_file dst_file row_file

      tid=$(echo "$ifc" | sed -E 's/^gre-(ir|kh)-([0-9]+)$/\2/')
      [[ -n "$tid" ]] || tid="$ifc"

      local_tun_ip=$(/sbin/ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
      if [[ -z "$local_tun_ip" ]]; then
        echo -e "${tid}\t-\t(100%)\t-\t(100%)\t${RED}DC${NC}" > "$tmpdir/row_${tid}"
        exit 0
      fi

      dst_ip=$(calc_peer_ip "$local_tun_ip")
      if [[ -z "$dst_ip" ]]; then
        echo -e "${tid}\t-\t(100%)\t-\t(100%)\t${RED}DC${NC}" > "$tmpdir/row_${tid}"
        exit 0
      fi

      link_line=$(/sbin/ip -d link show "$ifc" 2>/dev/null | grep -m1 "link/gre" || true)
      local_pub=$(echo "$link_line" | awk '{print $2}')
      peer_pub=$(echo "$link_line" | awk '{for (i=1;i<=NF;i++) if ($i=="peer") {print $(i+1); exit}}')

      peer_file="$tmpdir/.peer_${tid}"
      dst_file="$tmpdir/.dst_${tid}"
      row_file="$tmpdir/row_${tid}"

      if [[ -n "${local_pub:-}" && -n "${peer_pub:-}" ]]; then
        ping_loss_pct "-" "$peer_pub" > "$peer_file" &
      else
        peer_pub="-"
        echo "100" > "$peer_file" &
      fi

      ping_loss_pct "$local_tun_ip" "$dst_ip" > "$dst_file" &
      wait

      peer_loss=$(cat "$peer_file" 2>/dev/null || echo "100")
      dst_loss=$(cat "$dst_file" 2>/dev/null || echo "100")

      if (( peer_loss >= 100 || dst_loss >= 100 )); then
        detail="${RED}DC${NC}"
      else
        if (( peer_loss > LOSS_THRESH || dst_loss > LOSS_THRESH )); then
          max_loss=$peer_loss
          (( dst_loss > max_loss )) && max_loss=$dst_loss
          detail="${YELLOW}Warning (${max_loss}%)${NC}"
        else
          detail="${GREEN}Connected${NC}"
        fi
      fi

      echo -e "${tid}\t${peer_pub}\t(${peer_loss}%)\t${dst_ip}\t(${dst_loss}%)\t${detail}" > "$row_file"
    ) &
  done

  wait

  {
    for f in "$tmpdir"/row_*; do
      [[ -f "$f" ]] || continue
      cat "$f"
    done
  } | sort -t$'\t' -k1,1n | awk -F'\t' 'BEGIN{
      printf "%-6s %-16s %-7s %-16s %-7s %s\n","IFACE","PEER_IP","STAT","DST_IP","STAT","DETAIL"
      printf "%-6s %-16s %-7s %-16s %-7s %s\n","-----","---------------","-----","---------------","-----","-------------------------"
    }{
      printf "%-6s %-16s %-7s %-16s %-7s %s\n",$1,$2,$3,$4,$5,$6
    }'
}

gost_port_map() {
  if [[ ! -f "$GOST_PORTS_FILE" ]]; then
    echo "No $GOST_PORTS_FILE found."
    return 0
  fi

  echo
  echo "PORT   -> BACKEND_IP"
  echo "-----     ----------------"
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
      printf "%-7s %-16s\n" "$p" "$ip"
    done
    unset IFS
  done < "$GOST_PORTS_FILE" | sort -n
}

show_status() {
  status_ping_all
  gost_port_map
}

main() {
  refresh_tunnel_map

  local -a tids=()
  local tid
  for tid in "${!TID2PEER[@]}"; do
    tids+=("$tid")
  done

  if (( ${#tids[@]} == 0 )); then
    echo "[gost-autobalance] No GRE tunnel IPs found."
    exit 0
  fi

  # sort tids numeric
  IFS=$'\n' tids=($(printf "%s\n" "${tids[@]}" | sort -n))
  unset IFS

  # Evaluate each tunnel quickly (loss test), update state with step=INTERVAL
  # (we approximate streak seconds by interval; good enough)
  # Evaluate each tunnel quickly (loss test) in parallel, then update state.
  # This prevents long runtimes when you have many GRE interfaces.
  local tmp_results
  tmp_results="$(mktemp)"
  local MAXP
  MAXP="${MAX_PARALLEL:-8}"

  # Run parallel ping checks with a concurrency limit
  local active=0
  local loss local_ip peer_ip
  for tid in "${tids[@]}"; do
    (
      local_ip="${TID2LOCAL[$tid]:-}"
      peer_ip="${TID2PEER[$tid]:-}"
      if [[ -z "$local_ip" || -z "$peer_ip" ]]; then
        echo "$tid 100" >> "$tmp_results"
        exit 0
      fi
      loss="$(ping_loss_pct_fast "$local_ip" "$peer_ip")"
      echo "$tid $loss" >> "$tmp_results"
    ) &

    active=$((active + 1))
    if (( active >= MAXP )); then
      wait -n || true
      active=$((active - 1))
    fi
  done
  wait || true

  # Apply results (state updates are done sequentially to avoid state file races)
  local is_good
  while read -r tid loss; do
    [[ "$tid" =~ ^[0-9]+$ ]] || continue
    [[ "$loss" =~ ^[0-9]+$ ]] || loss=100
    if (( loss <= LOSS_THRESH )); then
      is_good=1
    else
      is_good=0
    fi
    update_state_for_result "$tid" "$is_good" "$INTERVAL"
  done < "$tmp_results"
  rm -f "$tmp_results"

  # Pick best backends
  mapfile -t chosen < <(select_backends "${tids[@]}" || true)

  if (( ${#chosen[@]} == 0 )); then
    echo "[gost-autobalance] No usable tunnels yet (waiting for GOOD_FOR). Keeping existing config."
    exit 0
  fi

  # Build new gost_ports in temp and compare
  local tmp_ports; tmp_ports="$(mktemp)"
  local tmp_args;  tmp_args="$(mktemp)"
  trap 'rm -f "$tmp_ports" "$tmp_args"' EXIT

  # Write temp gost_ports (weighted greedy assignment)
  {
    local -a ports weights
    parse_ports_csv "$PORTS_CSV" ports weights

    declare -A ip2ports=()
    declare -A ip2load=()

    local tid ip i best_ip best_load cur_load w p
    for tid in "${chosen[@]}"; do
      ip="${TID2PEER[$tid]:-}"
      [[ -n "$ip" ]] || continue
      ip2load["$ip"]=0
      ip2ports["$ip"]=""
    done

    for i in "${!ports[@]}"; do
      p="${ports[$i]}"
      w="${weights[$i]}"

      best_ip=""
      best_load=0

      for tid in "${chosen[@]}"; do
        ip="${TID2PEER[$tid]:-}"
        [[ -n "$ip" ]] || continue
        cur_load="${ip2load[$ip]:-0}"
        if [[ -z "$best_ip" || "$cur_load" -lt "$best_load" ]]; then
          best_ip="$ip"
          best_load="$cur_load"
        fi
      done

      [[ -n "$best_ip" ]] || continue
      if [[ -z "${ip2ports[$best_ip]:-}" ]]; then
        ip2ports["$best_ip"]="$p"
      else
        ip2ports["$best_ip"]+=",${p}"
      fi
      ip2load["$best_ip"]=$(( ${ip2load[$best_ip]:-0} + w ))
    done

    for tid in "${chosen[@]}"; do
      ip="${TID2PEER[$tid]:-}"
      [[ -n "$ip" ]] || continue
      [[ -n "${ip2ports[$ip]:-}" ]] || continue
      echo "${ip}:${ip2ports[$ip]}"
    done
  } > "$tmp_ports"

  if [[ ! -s "$tmp_ports" ]]; then
    echo "[gost-autobalance] Failed to build gost_ports (unexpected)."
    exit 0
  fi

  # If no change, do nothing
  if [[ -f "$GOST_PORTS_FILE" ]] && cmp -s "$tmp_ports" "$GOST_PORTS_FILE"; then
    exit 0
  fi

  # Apply new ports file
  install -m 0644 "$tmp_ports" "$GOST_PORTS_FILE"

  # Rebuild args and restart
  rebuild_gost_args_and_restart

  echo "[gost-autobalance] Updated mapping using GRE: ${chosen[*]}"
}

cmd="${1:-apply}"
case "$cmd" in
  status|"")
    show_status
    ;;
  apply)
    main
    ;;
  *)
    echo "Usage: $(basename "$0") [apply|status]"
    exit 1
    ;;
esac
