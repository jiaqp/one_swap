#!/usr/bin/env bash
#
# bbr-auto-tune.sh
#
# Automatic Linux TCP/BBR tuning assistant for proxy servers.
# Default mode is safe: detect, measure, calculate, and print a report.
# Use --apply to write /etc/sysctl.d/99-bbr-auto-tune.conf and apply it.

set -uo pipefail

VERSION="1.0.0"
CONF_PATH="/etc/sysctl.d/99-bbr-auto-tune.conf"

APPLY=0
ROLLBACK=0
SHOW_CONFIG=0
JSON=0
NO_NETWORK=0
DEEP=0
SPEEDTEST=0
LIVE_QDISC=1

REGION="china"
TARGETS_RAW=""
PING_COUNT=12
PING_TIMEOUT=2
MTR_COUNT=30

TARGET_BANDWIDTH_MBPS=""
BANDWIDTH_SOURCE="fallback"
CONCURRENCY=4
PROFILE="balanced"
PROTOCOL="mixed"
REQUESTED_CC="bbr"

KERNEL_NAME=""
KERNEL_RELEASE=""
IS_LINUX=0
CPU_CORES=1
CPU_MODEL="unknown"
CPU_AES="unknown"
RAM_MB=0
VIRT_TYPE="unknown"

DEFAULT_IFACE=""
DEFAULT_IFACE6=""
IFACE_MTU=""
IFACE_QDISC=""
NIC_SPEED_MBPS=""
PUBLIC_IP=""
PUBLIC_IPV6=""
PUBLIC_ASN=""
PUBLIC_ORG=""
PUBLIC_COUNTRY=""
PUBLIC_REGION=""
PUBLIC_CITY=""

CURRENT_CC=""
AVAILABLE_CC=""
CURRENT_QDISC=""
BBR_STATE="unknown"

EFFECTIVE_RTT_MS=""
EFFECTIVE_LOSS_PERCENT=""
EFFECTIVE_JITTER_MS=""
BDP_MB=""
LOSS_FACTOR=""
RAW_BUFFER_MB=""
RECOMMENDED_BUFFER_MB=""
RECOMMENDED_BUFFER_BYTES=""
RECOMMENDED_DEFAULT_BYTES=""
RECOMMENDED_BACKLOG=""
RECOMMENDED_SOMAXCONN=""
RECOMMENDED_SYN_BACKLOG=""
RECOMMENDED_CONNTRACK=""
RECOMMENDED_FILE_MAX=""
LINE_QUALITY=""

TARGET_LABELS=()
TARGET_HOSTS=()
PING_LABELS=()
PING_HOSTS=()
PING_STATUS=()
PING_LOSS=()
PING_MIN=()
PING_AVG=()
PING_MAX=()
PING_JITTER=()
MTR_SUMMARIES=()
WARNINGS=()
NOTES=()

usage() {
  cat <<'EOF'
bbr-auto-tune.sh - automatic BBR/network tuning calculator for proxy servers

Usage:
  sudo bash bbr-auto-tune.sh --apply
  bash bbr-auto-tune.sh
  bash bbr-auto-tune.sh --bandwidth 1000 --region china --profile throughput

Safe by default:
  Without --apply, this script only detects, measures, calculates, and prints
  a recommended sysctl config. It does not modify the system.

Common options:
  --apply                 Write config and apply it with sysctl.
  --rollback              Restore the newest backup of the config path.
  --show-config           Print only the recommended sysctl config.
  --json                  Print a machine-readable JSON report.
  --no-network            Skip public IP and ping/MTR/tracepath detection.
  --deep                  Run extra MTR/tracepath checks when available.
  --no-live-qdisc         Do not run 'tc qdisc replace dev IFACE root fq'
                          during --apply. Sysctl config is still written.

Inputs you may override:
  --region NAME           Target client region preset. Default: china.
                          Presets: china, global, asia, us, eu.
  --targets LIST          Custom ping targets, comma-separated.
                          Example: --targets "ct=202.96.128.86,ali=223.5.5.5"
  --bandwidth MBPS        Target server bandwidth in Mbps.
                          If omitted, ethtool speed is used when credible,
                          otherwise 1000 Mbps is assumed.
  --concurrency N         Expected active users/high-speed flows. Default: 4.
  --protocol NAME         tcp, quic, or mixed. Default: mixed.
  --profile NAME          balanced, throughput, latency, or concurrency.
                          Default: balanced.
  --cc NAME               Congestion control to recommend. Default: bbr.

Measurement options:
  --ping-count N          Ping count per target. Default: 12.
  --ping-timeout SEC      Ping timeout per packet. Default: 2.
  --mtr-count N           MTR cycles in --deep mode. Default: 30.

Apply options:
  --config-path PATH      Sysctl config path.
                          Default: /etc/sysctl.d/99-bbr-auto-tune.conf

Recommended workflow:
  1. bash bbr-auto-tune.sh --bandwidth 1000
  2. Review warnings and the generated config.
  3. sudo bash bbr-auto-tune.sh --bandwidth 1000 --apply
  4. ss -tin | grep -i bbr

EOF
}

add_warning() {
  WARNINGS+=("$*")
}

add_note() {
  NOTES+=("$*")
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

json_escape() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

fetch_url() {
  [ "$NO_NETWORK" -eq 1 ] && return 1
  if command_exists curl; then
    curl -fsSL --max-time 5 "$1" 2>/dev/null
    return $?
  fi
  if command_exists wget; then
    wget -qO- --timeout=5 "$1" 2>/dev/null
    return $?
  fi
  return 1
}

parse_json_field() {
  # Small dependency-free JSON field extractor for flat API responses.
  # It intentionally handles only simple string/number fields.
  local field="$1"
  sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p; s/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

get_sysctl() {
  sysctl -n "$1" 2>/dev/null | tr -d '\r'
}

sysctl_key_exists() {
  sysctl -n "$1" >/dev/null 2>&1
}

positive_or_default() {
  local value="${1:-}"
  local fallback="$2"
  if is_number "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

ceil_number() {
  awk -v n="$1" 'BEGIN { if (n <= 0) print 0; else printf "%.0f\n", int(n + 0.999999) }'
}

min_number() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (a < b) print a; else print b }'
}

max_number() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (a > b) print a; else print b }'
}

format_float() {
  local value="$1"
  local digits="${2:-2}"
  awk -v v="$value" -v d="$digits" 'BEGIN { fmt="%." d "f"; printf fmt, v }'
}

bytes_from_mb() {
  awk -v mb="$1" 'BEGIN { printf "%.0f\n", mb * 1024 * 1024 }'
}

add_target() {
  local label="$1"
  local host="$2"
  [ -z "$host" ] && return 0
  TARGET_LABELS+=("$label")
  TARGET_HOSTS+=("$host")
}

load_targets() {
  TARGET_LABELS=()
  TARGET_HOSTS=()

  if [ -n "$TARGETS_RAW" ]; then
    local old_ifs="$IFS"
    local item label host
    IFS=','
    for item in $TARGETS_RAW; do
      item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -z "$item" ] && continue
      if printf '%s' "$item" | grep -q '='; then
        label="${item%%=*}"
        host="${item#*=}"
      else
        label="$item"
        host="$item"
      fi
      add_target "$label" "$host"
    done
    IFS="$old_ifs"
    return 0
  fi

  case "$(to_lower "$REGION")" in
    china|cn)
      add_target "aliyun-dns-cn" "223.5.5.5"
      add_target "dnspod-cn" "119.29.29.29"
      add_target "114dns-cn" "114.114.114.114"
      add_target "baidu-dns-cn" "180.76.76.76"
      ;;
    asia)
      add_target "cloudflare" "1.1.1.1"
      add_target "google-dns" "8.8.8.8"
      add_target "quad9" "9.9.9.9"
      add_target "aliyun-dns-cn" "223.5.5.5"
      ;;
    us|usa)
      add_target "cloudflare" "1.1.1.1"
      add_target "google-dns" "8.8.8.8"
      add_target "quad9" "9.9.9.9"
      ;;
    eu|europe)
      add_target "cloudflare" "1.1.1.1"
      add_target "google-dns" "8.8.8.8"
      add_target "quad9" "9.9.9.9"
      ;;
    global|world)
      add_target "cloudflare" "1.1.1.1"
      add_target "google-dns" "8.8.8.8"
      add_target "quad9" "9.9.9.9"
      add_target "opendns" "208.67.222.222"
      ;;
    *)
      add_warning "Unknown region preset '$REGION'; using China preset. Use --targets for exact probes."
      add_target "aliyun-dns-cn" "223.5.5.5"
      add_target "dnspod-cn" "119.29.29.29"
      add_target "114dns-cn" "114.114.114.114"
      add_target "baidu-dns-cn" "180.76.76.76"
      ;;
  esac
}

detect_platform() {
  KERNEL_NAME="$(uname -s 2>/dev/null || printf unknown)"
  KERNEL_RELEASE="$(uname -r 2>/dev/null || printf unknown)"
  if [ "$KERNEL_NAME" = "Linux" ]; then
    IS_LINUX=1
  else
    IS_LINUX=0
    add_warning "This script is designed for Linux servers. Report mode can run here, but --apply is blocked on non-Linux systems."
  fi
}

detect_system() {
  if command_exists nproc; then
    CPU_CORES="$(nproc 2>/dev/null || printf 1)"
  else
    CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
  fi
  is_integer "$CPU_CORES" || CPU_CORES=1

  if command_exists lscpu; then
    CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')"
    [ -z "$CPU_MODEL" ] && CPU_MODEL="unknown"
    if lscpu 2>/dev/null | grep -qiE 'Flags:.*(^| )aes( |$)|Features:.*(^| )aes( |$)'; then
      CPU_AES="yes"
    else
      CPU_AES="no-or-unknown"
    fi
  elif [ "$KERNEL_NAME" = "Darwin" ]; then
    CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)"
    if sysctl -n machdep.cpu.features 2>/dev/null | grep -qi AES; then
      CPU_AES="yes"
    else
      CPU_AES="no-or-unknown"
    fi
  fi

  if command_exists free; then
    RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2; exit}')"
  elif [ "$KERNEL_NAME" = "Darwin" ]; then
    RAM_MB="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f\n", $1 / 1024 / 1024}')"
  fi
  is_integer "$RAM_MB" || RAM_MB=0
  [ "$RAM_MB" -eq 0 ] && add_warning "Could not detect RAM size; using conservative memory caps."

  if command_exists systemd-detect-virt; then
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || printf none)"
  else
    VIRT_TYPE="unknown"
  fi
}

detect_public_network() {
  [ "$NO_NETWORK" -eq 1 ] && return 0

  local data org
  data="$(fetch_url "https://ipinfo.io/json" 2>/dev/null || true)"
  if [ -z "$data" ]; then
    data="$(fetch_url "http://ip-api.com/json" 2>/dev/null || true)"
  fi

  if [ -n "$data" ]; then
    PUBLIC_IP="$(printf '%s' "$data" | parse_json_field ip)"
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(printf '%s' "$data" | parse_json_field query)"
    PUBLIC_COUNTRY="$(printf '%s' "$data" | parse_json_field country)"
    PUBLIC_REGION="$(printf '%s' "$data" | parse_json_field region)"
    PUBLIC_CITY="$(printf '%s' "$data" | parse_json_field city)"
    PUBLIC_ORG="$(printf '%s' "$data" | parse_json_field org)"
    [ -z "$PUBLIC_ORG" ] && PUBLIC_ORG="$(printf '%s' "$data" | parse_json_field isp)"
    PUBLIC_ASN="$(printf '%s' "$data" | parse_json_field asn)"
    if [ -z "$PUBLIC_ASN" ]; then
      org="$PUBLIC_ORG"
      PUBLIC_ASN="$(printf '%s' "$org" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^AS[0-9]+$/) {print $i; exit}}')"
    fi
  else
    add_warning "Could not fetch public IP/ASN data. Install curl/wget or use --no-network if intentional."
  fi

  if command_exists curl; then
    PUBLIC_IPV6="$(curl -6 -fsSL --max-time 4 https://ifconfig.co 2>/dev/null | head -n 1 || true)"
  fi
}

detect_interface() {
  if command_exists ip; then
    DEFAULT_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    DEFAULT_IFACE6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi

  if [ -n "$DEFAULT_IFACE" ] && command_exists ip; then
    IFACE_MTU="$(ip link show dev "$DEFAULT_IFACE" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}')"
  fi

  if [ -n "$DEFAULT_IFACE" ] && command_exists tc; then
    IFACE_QDISC="$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | head -n 1 | sed 's/[[:space:]]\+/ /g')"
  fi

  if [ -n "$DEFAULT_IFACE" ] && command_exists ethtool; then
    NIC_SPEED_MBPS="$(ethtool "$DEFAULT_IFACE" 2>/dev/null | awk -F: '/Speed:/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    is_integer "$NIC_SPEED_MBPS" || NIC_SPEED_MBPS=""
  fi
}

detect_tcp_state() {
  CURRENT_CC="$(get_sysctl net.ipv4.tcp_congestion_control)"
  AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_available_congestion_control)"
  CURRENT_QDISC="$(get_sysctl net.core.default_qdisc)"

  if printf ' %s ' "$AVAILABLE_CC" | grep -q " $REQUESTED_CC "; then
    BBR_STATE="available"
  elif [ "$REQUESTED_CC" = "bbr" ] && command_exists modinfo && modinfo tcp_bbr >/dev/null 2>&1; then
    BBR_STATE="loadable"
  elif [ "$REQUESTED_CC" = "bbr" ] && command_exists lsmod && lsmod 2>/dev/null | awk '{print $1}' | grep -qx tcp_bbr; then
    BBR_STATE="loaded"
  else
    BBR_STATE="missing-or-unknown"
  fi
}

measure_ping_target() {
  local label="$1"
  local host="$2"
  local out loss min avg max jitter status wait_arg

  if ! command_exists ping; then
    PING_LABELS+=("$label")
    PING_HOSTS+=("$host")
    PING_STATUS+=("no-ping")
    PING_LOSS+=("")
    PING_MIN+=("")
    PING_AVG+=("")
    PING_MAX+=("")
    PING_JITTER+=("")
    return 0
  fi

  if [ "$KERNEL_NAME" = "Darwin" ]; then
    wait_arg=$((PING_TIMEOUT * 1000))
    out="$(ping -c "$PING_COUNT" -W "$wait_arg" "$host" 2>&1 || true)"
  else
    out="$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" 2>&1 || true)"
  fi

  loss="$(printf '%s\n' "$out" | awk -F',' '/packet loss/ {for (i=1;i<=NF;i++) if ($i ~ /packet loss/) {gsub(/[^0-9.]/, "", $i); print $i; exit}}')"
  min="$(printf '%s\n' "$out" | awk -F'=' '/min\/avg\/max|round-trip/ {gsub(/^[ \t]+/, "", $2); split($2, a, "/"); print a[1]; exit}')"
  avg="$(printf '%s\n' "$out" | awk -F'=' '/min\/avg\/max|round-trip/ {gsub(/^[ \t]+/, "", $2); split($2, a, "/"); print a[2]; exit}')"
  max="$(printf '%s\n' "$out" | awk -F'=' '/min\/avg\/max|round-trip/ {gsub(/^[ \t]+/, "", $2); split($2, a, "/"); print a[3]; exit}')"
  jitter="$(printf '%s\n' "$out" | awk -F'=' '/min\/avg\/max/ {gsub(/^[ \t]+/, "", $2); split($2, a, "/"); print a[4]; exit}')"
  jitter="$(printf '%s' "$jitter" | sed 's/[[:space:]]*ms.*//')"

  [ -z "$loss" ] && loss="100"
  if is_number "$avg"; then
    status="ok"
  else
    status="failed"
    min=""
    avg=""
    max=""
    jitter=""
  fi

  PING_LABELS+=("$label")
  PING_HOSTS+=("$host")
  PING_STATUS+=("$status")
  PING_LOSS+=("$loss")
  PING_MIN+=("$min")
  PING_AVG+=("$avg")
  PING_MAX+=("$max")
  PING_JITTER+=("$jitter")
}

measure_paths() {
  load_targets

  if [ "$NO_NETWORK" -eq 1 ]; then
    add_note "Network measurement skipped by --no-network."
    return 0
  fi

  if [ "${#TARGET_HOSTS[@]}" -eq 0 ]; then
    add_warning "No measurement targets were configured."
    return 0
  fi

  local i
  for ((i=0; i<${#TARGET_HOSTS[@]}; i++)); do
    measure_ping_target "${TARGET_LABELS[$i]}" "${TARGET_HOSTS[$i]}"
  done

  if [ "$DEEP" -eq 1 ]; then
    run_deep_measurements
  fi
}

run_deep_measurements() {
  local i label host summary

  if ! command_exists mtr && ! command_exists tracepath; then
    add_note "--deep requested, but neither mtr nor tracepath is installed."
    return 0
  fi

  for ((i=0; i<${#TARGET_HOSTS[@]} && i<2; i++)); do
    label="${TARGET_LABELS[$i]}"
    host="${TARGET_HOSTS[$i]}"
    summary=""

    if command_exists mtr; then
      summary="$(mtr -rwzc "$MTR_COUNT" "$host" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]\+/ /g' || true)"
      [ -n "$summary" ] && MTR_SUMMARIES+=("$label mtr: $summary")
    fi

    if command_exists tracepath; then
      summary="$(tracepath -n "$host" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]\+/ /g' || true)"
      [ -n "$summary" ] && MTR_SUMMARIES+=("$label tracepath: $summary")
    fi
  done
}

percentile_from_args() {
  local percentile="$1"
  shift || true
  [ "$#" -eq 0 ] && return 1
  printf '%s\n' "$@" | awk 'NF {print $1}' | sort -n | awk -v p="$percentile" '
    { a[++n]=$1 }
    END {
      if (n == 0) exit 1
      idx = int((p / 100.0) * n + 0.999999)
      if (idx < 1) idx = 1
      if (idx > n) idx = n
      print a[idx]
    }'
}

fallback_rtt_for_region() {
  case "$(to_lower "$REGION")" in
    china|cn) printf '180' ;;
    asia) printf '100' ;;
    us|usa) printf '80' ;;
    eu|europe) printf '100' ;;
    global|world) printf '120' ;;
    *) printf '180' ;;
  esac
}

derive_effective_path() {
  local rtts=()
  local losses=()
  local jitters=()
  local i

  for ((i=0; i<${#PING_AVG[@]}; i++)); do
    if is_number "${PING_AVG[$i]:-}"; then
      rtts+=("${PING_AVG[$i]}")
      losses+=("$(positive_or_default "${PING_LOSS[$i]:-}" 0)")
      if is_number "${PING_JITTER[$i]:-}"; then
        jitters+=("${PING_JITTER[$i]}")
      fi
    fi
  done

  if [ "${#rtts[@]}" -gt 0 ]; then
    EFFECTIVE_RTT_MS="$(percentile_from_args 75 "${rtts[@]}" 2>/dev/null || true)"
  fi
  if [ "${#losses[@]}" -gt 0 ]; then
    EFFECTIVE_LOSS_PERCENT="$(percentile_from_args 75 "${losses[@]}" 2>/dev/null || true)"
  fi
  if [ "${#jitters[@]}" -gt 0 ]; then
    EFFECTIVE_JITTER_MS="$(percentile_from_args 75 "${jitters[@]}" 2>/dev/null || true)"
  fi

  if ! is_number "$EFFECTIVE_RTT_MS"; then
    EFFECTIVE_RTT_MS="$(fallback_rtt_for_region)"
    add_warning "No successful ping measurement; using fallback RTT ${EFFECTIVE_RTT_MS} ms for region '$REGION'."
  fi
  if ! is_number "$EFFECTIVE_LOSS_PERCENT"; then
    EFFECTIVE_LOSS_PERCENT="1"
    add_warning "No reliable packet-loss measurement; using fallback loss 1%."
  fi
  if ! is_number "$EFFECTIVE_JITTER_MS"; then
    EFFECTIVE_JITTER_MS="0"
  fi
}

choose_bandwidth() {
  if [ -n "$TARGET_BANDWIDTH_MBPS" ]; then
    BANDWIDTH_SOURCE="user"
    return 0
  fi

  if is_integer "$NIC_SPEED_MBPS" && [ "$NIC_SPEED_MBPS" -gt 0 ]; then
    TARGET_BANDWIDTH_MBPS="$NIC_SPEED_MBPS"
    BANDWIDTH_SOURCE="ethtool"
    if [ "$NIC_SPEED_MBPS" -ge 10000 ]; then
      add_warning "NIC reports ${NIC_SPEED_MBPS} Mbps. Virtual NIC speed can exceed the VPS plan; pass --bandwidth if your real plan is lower."
    fi
    return 0
  fi

  TARGET_BANDWIDTH_MBPS="1000"
  BANDWIDTH_SOURCE="fallback"
  add_warning "Could not detect real bandwidth; assuming 1000 Mbps. Pass --bandwidth for best accuracy."
}

loss_factor_for() {
  local loss="$1"
  awk -v loss="$loss" -v profile="$PROFILE" '
    BEGIN {
      if (loss < 0.2) factor = 4
      else if (loss < 1) factor = 6
      else if (loss < 3) factor = 8
      else if (loss < 8) factor = 10
      else factor = 12

      if (profile == "throughput") factor *= 1.25
      else if (profile == "latency") factor *= 0.75
      else if (profile == "concurrency") factor *= 1.10

      if (factor < 3) factor = 3
      printf "%.2f\n", factor
    }'
}

ram_cap_mb() {
  local ram="$1"
  local bw="$2"
  if ! is_integer "$ram" || [ "$ram" -le 0 ]; then
    printf '128'
    return 0
  fi

  if [ "$ram" -lt 768 ]; then
    printf '32'
  elif [ "$ram" -lt 1536 ]; then
    printf '64'
  elif [ "$ram" -lt 3072 ]; then
    printf '128'
  elif [ "$ram" -lt 6144 ]; then
    printf '256'
  elif [ "$ram" -lt 12288 ]; then
    if awk -v b="$bw" 'BEGIN { exit !(b >= 5000) }'; then
      printf '512'
    else
      printf '384'
    fi
  elif [ "$ram" -lt 24576 ]; then
    if awk -v b="$bw" 'BEGIN { exit !(b >= 5000) }'; then
      printf '768'
    else
      printf '512'
    fi
  else
    if awk -v b="$bw" 'BEGIN { exit !(b >= 5000) }'; then
      printf '1024'
    else
      printf '768'
    fi
  fi
}

bucket_buffer_mb() {
  local mb="$1"
  awk -v mb="$mb" '
    BEGIN {
      if (mb <= 32) print 32
      else if (mb <= 64) print 64
      else if (mb <= 96) print 96
      else if (mb <= 128) print 128
      else if (mb <= 192) print 192
      else if (mb <= 256) print 256
      else if (mb <= 384) print 384
      else if (mb <= 512) print 512
      else if (mb <= 768) print 768
      else print 1024
    }'
}

classify_quality() {
  local rtt="$1"
  local loss="$2"
  local jitter="$3"
  awk -v rtt="$rtt" -v loss="$loss" -v jitter="$jitter" '
    BEGIN {
      if (loss < 0.2 && jitter < 10 && rtt < 120) print "excellent"
      else if (loss < 0.5 && jitter < 20 && rtt < 200) print "good"
      else if (loss < 1.5 && jitter < 35 && rtt < 260) print "fair"
      else if (loss < 3.0) print "weak"
      else print "poor"
    }'
}

calculate_recommendations() {
  choose_bandwidth
  derive_effective_path

  BDP_MB="$(awk -v bw="$TARGET_BANDWIDTH_MBPS" -v rtt="$EFFECTIVE_RTT_MS" 'BEGIN { printf "%.2f\n", bw * rtt / 8000.0 }')"
  LOSS_FACTOR="$(loss_factor_for "$EFFECTIVE_LOSS_PERCENT")"
  RAW_BUFFER_MB="$(awk -v bdp="$BDP_MB" -v factor="$LOSS_FACTOR" 'BEGIN { raw = bdp * factor; if (raw < 64) raw = 64; printf "%.2f\n", raw }')"

  local bucket cap final
  bucket="$(bucket_buffer_mb "$RAW_BUFFER_MB")"
  cap="$(ram_cap_mb "$RAM_MB" "$TARGET_BANDWIDTH_MBPS")"
  final="$(min_number "$bucket" "$cap")"
  RECOMMENDED_BUFFER_MB="$final"
  RECOMMENDED_BUFFER_BYTES="$(bytes_from_mb "$RECOMMENDED_BUFFER_MB")"

  if awk -v raw="$RAW_BUFFER_MB" -v final="$RECOMMENDED_BUFFER_MB" 'BEGIN { exit !(final < raw) }'; then
    add_warning "Recommended buffer was capped by RAM policy: wanted about $(format_float "$RAW_BUFFER_MB" 1) MB, capped to ${RECOMMENDED_BUFFER_MB} MB."
  fi

  if [ "$PROTOCOL" = "quic" ] || [ "$PROTOCOL" = "mixed" ]; then
    RECOMMENDED_DEFAULT_BYTES="$(awk -v mb="$RECOMMENDED_BUFFER_MB" 'BEGIN { d = mb / 16; if (d < 1) d = 1; if (d > 8) d = 8; printf "%.0f\n", d * 1024 * 1024 }')"
  else
    RECOMMENDED_DEFAULT_BYTES="$(awk -v mb="$RECOMMENDED_BUFFER_MB" 'BEGIN { d = mb / 32; if (d < 1) d = 1; if (d > 4) d = 4; printf "%.0f\n", d * 1024 * 1024 }')"
  fi

  if awk -v bw="$TARGET_BANDWIDTH_MBPS" -v c="$CONCURRENCY" 'BEGIN { exit !(bw >= 5000 || c >= 500) }'; then
    RECOMMENDED_BACKLOG="250000"
  elif awk -v bw="$TARGET_BANDWIDTH_MBPS" -v c="$CONCURRENCY" 'BEGIN { exit !(bw >= 1000 || c >= 100) }'; then
    RECOMMENDED_BACKLOG="65536"
  else
    RECOMMENDED_BACKLOG="16384"
  fi

  RECOMMENDED_SOMAXCONN="65535"
  RECOMMENDED_SYN_BACKLOG="$RECOMMENDED_SOMAXCONN"
  RECOMMENDED_CONNTRACK="$(awk -v c="$CONCURRENCY" -v ram="$RAM_MB" 'BEGIN {
    target = c * 8192
    if (ram > 0 && ram < 1024) base = 65536
    else base = 262144
    if (target < base) target = base
    if (ram > 0) {
      cap = int((ram * 1024 * 1024) / 512)
      if (target > cap) target = cap
    }
    if (target < 32768) target = 32768
    printf "%.0f\n", target
  }')"
  RECOMMENDED_FILE_MAX="$(awk -v c="$CONCURRENCY" 'BEGIN { v = c * 8192; if (v < 1048576) v = 1048576; printf "%.0f\n", v }')"

  LINE_QUALITY="$(classify_quality "$EFFECTIVE_RTT_MS" "$EFFECTIVE_LOSS_PERCENT" "$EFFECTIVE_JITTER_MS")"

  if [ "$REQUESTED_CC" = "bbr" ] && [ "$BBR_STATE" = "missing-or-unknown" ]; then
    add_warning "BBR is not currently listed as available. --apply will try 'modprobe tcp_bbr'; otherwise upgrade/use a kernel with BBR support."
  fi
  if [ "$CPU_AES" != "yes" ]; then
    add_note "AES acceleration was not detected. TLS/Reality/QUIC proxy throughput may be CPU-limited."
  fi
}

emit_sysctl_if_exists() {
  local key="$1"
  local value="$2"
  if sysctl_key_exists "$key"; then
    printf '%s = %s\n' "$key" "$value"
  else
    printf '# skipped: %s is not available on this kernel\n' "$key"
  fi
}

generate_config() {
  cat <<EOF
# Generated by bbr-auto-tune.sh v$VERSION
# Generated at: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
# Profile: $PROFILE
# Protocol: $PROTOCOL
# Region: $REGION
# Target bandwidth: ${TARGET_BANDWIDTH_MBPS} Mbps ($BANDWIDTH_SOURCE)
# Effective RTT/loss/jitter: ${EFFECTIVE_RTT_MS} ms / ${EFFECTIVE_LOSS_PERCENT}% / ${EFFECTIVE_JITTER_MS} ms
# BDP: ${BDP_MB} MB
# Recommended socket buffer cap: ${RECOMMENDED_BUFFER_MB} MB

EOF

  emit_sysctl_if_exists net.core.default_qdisc fq
  emit_sysctl_if_exists net.ipv4.tcp_congestion_control "$REQUESTED_CC"
  printf '\n'

  emit_sysctl_if_exists net.core.rmem_max "$RECOMMENDED_BUFFER_BYTES"
  emit_sysctl_if_exists net.core.wmem_max "$RECOMMENDED_BUFFER_BYTES"
  emit_sysctl_if_exists net.core.rmem_default "$RECOMMENDED_DEFAULT_BYTES"
  emit_sysctl_if_exists net.core.wmem_default "$RECOMMENDED_DEFAULT_BYTES"
  emit_sysctl_if_exists net.ipv4.tcp_rmem "4096 87380 $RECOMMENDED_BUFFER_BYTES"
  emit_sysctl_if_exists net.ipv4.tcp_wmem "4096 65536 $RECOMMENDED_BUFFER_BYTES"
  printf '\n'

  emit_sysctl_if_exists net.core.netdev_max_backlog "$RECOMMENDED_BACKLOG"
  emit_sysctl_if_exists net.core.somaxconn "$RECOMMENDED_SOMAXCONN"
  emit_sysctl_if_exists net.ipv4.tcp_max_syn_backlog "$RECOMMENDED_SYN_BACKLOG"
  emit_sysctl_if_exists net.ipv4.ip_local_port_range "1024 65535"
  printf '\n'

  emit_sysctl_if_exists net.ipv4.tcp_window_scaling 1
  emit_sysctl_if_exists net.ipv4.tcp_sack 1
  emit_sysctl_if_exists net.ipv4.tcp_timestamps 1
  emit_sysctl_if_exists net.ipv4.tcp_mtu_probing 1
  emit_sysctl_if_exists net.ipv4.tcp_slow_start_after_idle 0
  emit_sysctl_if_exists net.ipv4.tcp_fastopen 3
  printf '\n'

  emit_sysctl_if_exists net.ipv4.tcp_tw_reuse 1
  emit_sysctl_if_exists net.ipv4.tcp_fin_timeout 15
  emit_sysctl_if_exists net.ipv4.tcp_keepalive_time 600
  emit_sysctl_if_exists net.ipv4.tcp_keepalive_intvl 30
  emit_sysctl_if_exists net.ipv4.tcp_keepalive_probes 5
  printf '\n'

  emit_sysctl_if_exists net.ipv4.tcp_syncookies 1
  emit_sysctl_if_exists fs.file-max "$RECOMMENDED_FILE_MAX"
  emit_sysctl_if_exists net.netfilter.nf_conntrack_max "$RECOMMENDED_CONNTRACK"
  printf '\n'

  if [ "$PROTOCOL" = "quic" ] || [ "$PROTOCOL" = "mixed" ]; then
    emit_sysctl_if_exists net.ipv4.udp_rmem_min 8192
    emit_sysctl_if_exists net.ipv4.udp_wmem_min 8192
  fi
}

print_section() {
  printf '\n== %s ==\n' "$1"
}

print_kv() {
  printf '  %-28s %s\n' "$1:" "${2:-unknown}"
}

print_report() {
  printf 'BBR Auto Tune v%s\n' "$VERSION"
  printf 'Mode: %s\n' "$([ "$APPLY" -eq 1 ] && printf apply || printf report)"

  print_section "System"
  print_kv "kernel" "$KERNEL_NAME $KERNEL_RELEASE"
  print_kv "cpu cores" "$CPU_CORES"
  print_kv "cpu model" "$CPU_MODEL"
  print_kv "aes acceleration" "$CPU_AES"
  print_kv "ram" "${RAM_MB} MB"
  print_kv "virtualization" "$VIRT_TYPE"

  print_section "Network"
  print_kv "public ip" "$PUBLIC_IP"
  print_kv "public ipv6" "$PUBLIC_IPV6"
  print_kv "asn/org" "${PUBLIC_ASN:-} ${PUBLIC_ORG:-}"
  print_kv "location" "${PUBLIC_CITY:-unknown}, ${PUBLIC_REGION:-unknown}, ${PUBLIC_COUNTRY:-unknown}"
  print_kv "default iface" "$DEFAULT_IFACE"
  print_kv "iface mtu" "$IFACE_MTU"
  print_kv "iface qdisc" "$IFACE_QDISC"
  print_kv "nic speed" "${NIC_SPEED_MBPS:-unknown} Mbps"

  print_section "TCP State"
  print_kv "current cc" "$CURRENT_CC"
  print_kv "available cc" "$AVAILABLE_CC"
  print_kv "default qdisc" "$CURRENT_QDISC"
  print_kv "requested cc" "$REQUESTED_CC"
  print_kv "requested cc state" "$BBR_STATE"

  print_section "Path Measurements"
  if [ "${#PING_LABELS[@]}" -eq 0 ]; then
    printf '  No ping measurements.\n'
  else
    printf '  %-18s %-16s %-8s %-8s %-10s %-10s %-10s %-10s\n' "label" "host" "status" "loss%" "min" "avg" "max" "jitter"
    local i
    for ((i=0; i<${#PING_LABELS[@]}; i++)); do
      printf '  %-18s %-16s %-8s %-8s %-10s %-10s %-10s %-10s\n' \
        "${PING_LABELS[$i]}" "${PING_HOSTS[$i]}" "${PING_STATUS[$i]}" \
        "${PING_LOSS[$i]:-}" "${PING_MIN[$i]:-}" "${PING_AVG[$i]:-}" \
        "${PING_MAX[$i]:-}" "${PING_JITTER[$i]:-}"
    done
  fi

  if [ "${#MTR_SUMMARIES[@]}" -gt 0 ]; then
    printf '\n'
    local m
    for m in "${MTR_SUMMARIES[@]}"; do
      printf '  %s\n' "$m"
    done
  fi

  print_section "Calculation"
  print_kv "target bandwidth" "${TARGET_BANDWIDTH_MBPS} Mbps ($BANDWIDTH_SOURCE)"
  print_kv "profile/protocol" "$PROFILE / $PROTOCOL"
  print_kv "concurrency" "$CONCURRENCY"
  print_kv "effective rtt" "${EFFECTIVE_RTT_MS} ms"
  print_kv "effective loss" "${EFFECTIVE_LOSS_PERCENT}%"
  print_kv "effective jitter" "${EFFECTIVE_JITTER_MS} ms"
  print_kv "line quality" "$LINE_QUALITY"
  print_kv "bdp" "${BDP_MB} MB"
  print_kv "loss factor" "$LOSS_FACTOR"
  print_kv "raw buffer target" "$(format_float "$RAW_BUFFER_MB" 1) MB"
  print_kv "recommended buffer" "${RECOMMENDED_BUFFER_MB} MB (${RECOMMENDED_BUFFER_BYTES} bytes)"
  print_kv "backlog" "$RECOMMENDED_BACKLOG"
  print_kv "conntrack max" "$RECOMMENDED_CONNTRACK"

  print_section "Recommended sysctl"
  generate_config

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    print_section "Warnings"
    local w
    for w in "${WARNINGS[@]}"; do
      printf '  - %s\n' "$w"
    done
  fi

  if [ "${#NOTES[@]}" -gt 0 ]; then
    print_section "Notes"
    local n
    for n in "${NOTES[@]}"; do
      printf '  - %s\n' "$n"
    done
  fi

  print_section "Next"
  if [ "$APPLY" -eq 1 ]; then
    printf '  Applying config to %s\n' "$CONF_PATH"
  else
    printf '  To apply: sudo bash %s --bandwidth %s --region %s --profile %s --protocol %s --apply\n' "$0" "$TARGET_BANDWIDTH_MBPS" "$REGION" "$PROFILE" "$PROTOCOL"
    printf '  To verify after applying: sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc && ss -tin | grep -i bbr\n'
  fi
}

print_json() {
  local first i
  printf '{\n'
  printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
  printf '  "mode": "%s",\n' "$([ "$APPLY" -eq 1 ] && printf apply || printf report)"
  printf '  "system": {\n'
  printf '    "kernel": "%s",\n' "$(json_escape "$KERNEL_NAME $KERNEL_RELEASE")"
  printf '    "cpu_cores": %s,\n' "$CPU_CORES"
  printf '    "cpu_model": "%s",\n' "$(json_escape "$CPU_MODEL")"
  printf '    "cpu_aes": "%s",\n' "$(json_escape "$CPU_AES")"
  printf '    "ram_mb": %s,\n' "$RAM_MB"
  printf '    "virtualization": "%s"\n' "$(json_escape "$VIRT_TYPE")"
  printf '  },\n'
  printf '  "network": {\n'
  printf '    "public_ip": "%s",\n' "$(json_escape "$PUBLIC_IP")"
  printf '    "public_ipv6": "%s",\n' "$(json_escape "$PUBLIC_IPV6")"
  printf '    "asn": "%s",\n' "$(json_escape "$PUBLIC_ASN")"
  printf '    "org": "%s",\n' "$(json_escape "$PUBLIC_ORG")"
  printf '    "country": "%s",\n' "$(json_escape "$PUBLIC_COUNTRY")"
  printf '    "region": "%s",\n' "$(json_escape "$PUBLIC_REGION")"
  printf '    "city": "%s",\n' "$(json_escape "$PUBLIC_CITY")"
  printf '    "default_iface": "%s",\n' "$(json_escape "$DEFAULT_IFACE")"
  printf '    "mtu": "%s",\n' "$(json_escape "$IFACE_MTU")"
  printf '    "qdisc": "%s",\n' "$(json_escape "$IFACE_QDISC")"
  printf '    "nic_speed_mbps": "%s"\n' "$(json_escape "$NIC_SPEED_MBPS")"
  printf '  },\n'
  printf '  "tcp": {\n'
  printf '    "current_cc": "%s",\n' "$(json_escape "$CURRENT_CC")"
  printf '    "available_cc": "%s",\n' "$(json_escape "$AVAILABLE_CC")"
  printf '    "default_qdisc": "%s",\n' "$(json_escape "$CURRENT_QDISC")"
  printf '    "requested_cc": "%s",\n' "$(json_escape "$REQUESTED_CC")"
  printf '    "requested_cc_state": "%s"\n' "$(json_escape "$BBR_STATE")"
  printf '  },\n'
  printf '  "measurements": [\n'
  for ((i=0; i<${#PING_LABELS[@]}; i++)); do
    [ "$i" -gt 0 ] && printf ',\n'
    printf '    {"label":"%s","host":"%s","status":"%s","loss_percent":"%s","min_ms":"%s","avg_ms":"%s","max_ms":"%s","jitter_ms":"%s"}' \
      "$(json_escape "${PING_LABELS[$i]}")" "$(json_escape "${PING_HOSTS[$i]}")" \
      "$(json_escape "${PING_STATUS[$i]}")" "$(json_escape "${PING_LOSS[$i]:-}")" \
      "$(json_escape "${PING_MIN[$i]:-}")" "$(json_escape "${PING_AVG[$i]:-}")" \
      "$(json_escape "${PING_MAX[$i]:-}")" "$(json_escape "${PING_JITTER[$i]:-}")"
  done
  printf '\n  ],\n'
  printf '  "calculation": {\n'
  printf '    "target_bandwidth_mbps": "%s",\n' "$(json_escape "$TARGET_BANDWIDTH_MBPS")"
  printf '    "bandwidth_source": "%s",\n' "$(json_escape "$BANDWIDTH_SOURCE")"
  printf '    "profile": "%s",\n' "$(json_escape "$PROFILE")"
  printf '    "protocol": "%s",\n' "$(json_escape "$PROTOCOL")"
  printf '    "concurrency": %s,\n' "$CONCURRENCY"
  printf '    "effective_rtt_ms": "%s",\n' "$(json_escape "$EFFECTIVE_RTT_MS")"
  printf '    "effective_loss_percent": "%s",\n' "$(json_escape "$EFFECTIVE_LOSS_PERCENT")"
  printf '    "effective_jitter_ms": "%s",\n' "$(json_escape "$EFFECTIVE_JITTER_MS")"
  printf '    "line_quality": "%s",\n' "$(json_escape "$LINE_QUALITY")"
  printf '    "bdp_mb": "%s",\n' "$(json_escape "$BDP_MB")"
  printf '    "loss_factor": "%s",\n' "$(json_escape "$LOSS_FACTOR")"
  printf '    "raw_buffer_mb": "%s",\n' "$(json_escape "$RAW_BUFFER_MB")"
  printf '    "recommended_buffer_mb": "%s",\n' "$(json_escape "$RECOMMENDED_BUFFER_MB")"
  printf '    "recommended_buffer_bytes": "%s",\n' "$(json_escape "$RECOMMENDED_BUFFER_BYTES")"
  printf '    "backlog": "%s",\n' "$(json_escape "$RECOMMENDED_BACKLOG")"
  printf '    "conntrack_max": "%s"\n' "$(json_escape "$RECOMMENDED_CONNTRACK")"
  printf '  },\n'
  printf '  "warnings": ['
  first=1
  for i in "${WARNINGS[@]}"; do
    [ "$first" -eq 0 ] && printf ', '
    first=0
    printf '"%s"' "$(json_escape "$i")"
  done
  printf '],\n'
  printf '  "notes": ['
  first=1
  for i in "${NOTES[@]}"; do
    [ "$first" -eq 0 ] && printf ', '
    first=0
    printf '"%s"' "$(json_escape "$i")"
  done
  printf ']\n'
  printf '}\n'
}

apply_config() {
  if [ "$IS_LINUX" -ne 1 ]; then
    printf 'ERROR: --apply is only supported on Linux.\n' >&2
    return 1
  fi
  if [ "$(id -u 2>/dev/null || printf 1)" -ne 0 ]; then
    printf 'ERROR: --apply requires root. Re-run with sudo.\n' >&2
    return 1
  fi

  if [ "$REQUESTED_CC" = "bbr" ] && ! printf ' %s ' "$(get_sysctl net.ipv4.tcp_available_congestion_control)" | grep -q ' bbr '; then
    if command_exists modprobe; then
      modprobe tcp_bbr 2>/dev/null || true
    fi
  fi

  local dir tmp backup
  dir="$(dirname "$CONF_PATH")"
  if [ ! -d "$dir" ]; then
    printf 'ERROR: config directory does not exist: %s\n' "$dir" >&2
    return 1
  fi

  tmp="$(mktemp "${dir}/.bbr-auto-tune.XXXXXX")" || return 1
  generate_config > "$tmp"

  if [ -f "$CONF_PATH" ]; then
    backup="${CONF_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CONF_PATH" "$backup"
    printf 'Backup written: %s\n' "$backup"
  fi

  cp "$tmp" "$CONF_PATH"
  rm -f "$tmp"
  printf 'Config written: %s\n' "$CONF_PATH"

  if command_exists sysctl; then
    if sysctl --system >/tmp/bbr-auto-tune-sysctl.log 2>&1; then
      printf 'sysctl --system applied successfully.\n'
    else
      printf 'WARNING: sysctl --system reported errors. Output follows:\n' >&2
      cat /tmp/bbr-auto-tune-sysctl.log >&2
      return 1
    fi
  fi

  if [ "$LIVE_QDISC" -eq 1 ] && command_exists tc && [ -n "$DEFAULT_IFACE" ]; then
    if ! tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | grep -qw fq; then
      if tc qdisc replace dev "$DEFAULT_IFACE" root fq >/dev/null 2>&1; then
        printf 'Live qdisc applied: %s -> fq\n' "$DEFAULT_IFACE"
      else
        printf 'NOTE: could not apply live fq qdisc on %s. The sysctl default is still set; reboot or apply manually if needed.\n' "$DEFAULT_IFACE" >&2
      fi
    fi
  fi

  printf 'Verify:\n'
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
}

rollback_config() {
  if [ "$IS_LINUX" -ne 1 ]; then
    printf 'ERROR: --rollback is only supported on Linux.\n' >&2
    return 1
  fi
  if [ "$(id -u 2>/dev/null || printf 1)" -ne 0 ]; then
    printf 'ERROR: --rollback requires root. Re-run with sudo.\n' >&2
    return 1
  fi

  local backup
  backup="$(ls -t "${CONF_PATH}".bak.* 2>/dev/null | head -n 1 || true)"
  if [ -z "$backup" ]; then
    printf 'ERROR: no backup found for %s\n' "$CONF_PATH" >&2
    return 1
  fi
  cp "$backup" "$CONF_PATH"
  printf 'Restored backup: %s -> %s\n' "$backup" "$CONF_PATH"
  sysctl --system >/tmp/bbr-auto-tune-sysctl.log 2>&1 || {
    printf 'WARNING: sysctl --system reported errors. Output follows:\n' >&2
    cat /tmp/bbr-auto-tune-sysctl.log >&2
    return 1
  }
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --apply)
        APPLY=1
        ;;
      --rollback)
        ROLLBACK=1
        ;;
      --show-config)
        SHOW_CONFIG=1
        ;;
      --json)
        JSON=1
        ;;
      --no-network)
        NO_NETWORK=1
        ;;
      --deep)
        DEEP=1
        ;;
      --no-live-qdisc)
        LIVE_QDISC=0
        ;;
      --speedtest)
        SPEEDTEST=1
        ;;
      --region)
        shift
        REGION="${1:-}"
        ;;
      --targets)
        shift
        TARGETS_RAW="${1:-}"
        ;;
      --bandwidth)
        shift
        TARGET_BANDWIDTH_MBPS="${1:-}"
        ;;
      --concurrency|--users)
        shift
        CONCURRENCY="${1:-}"
        ;;
      --protocol)
        shift
        PROTOCOL="$(to_lower "${1:-}")"
        ;;
      --profile)
        shift
        PROFILE="$(to_lower "${1:-}")"
        ;;
      --cc)
        shift
        REQUESTED_CC="$(to_lower "${1:-}")"
        ;;
      --ping-count)
        shift
        PING_COUNT="${1:-}"
        ;;
      --ping-timeout)
        shift
        PING_TIMEOUT="${1:-}"
        ;;
      --mtr-count)
        shift
        MTR_COUNT="${1:-}"
        ;;
      --config-path)
        shift
        CONF_PATH="${1:-}"
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  if ! is_number "$TARGET_BANDWIDTH_MBPS" && [ -n "$TARGET_BANDWIDTH_MBPS" ]; then
    printf 'ERROR: --bandwidth must be a number in Mbps.\n' >&2
    exit 2
  fi
  if ! is_integer "$CONCURRENCY" || [ "$CONCURRENCY" -lt 1 ]; then
    printf 'ERROR: --concurrency must be a positive integer.\n' >&2
    exit 2
  fi
  if ! is_integer "$PING_COUNT" || [ "$PING_COUNT" -lt 1 ]; then
    printf 'ERROR: --ping-count must be a positive integer.\n' >&2
    exit 2
  fi
  if ! is_integer "$PING_TIMEOUT" || [ "$PING_TIMEOUT" -lt 1 ]; then
    printf 'ERROR: --ping-timeout must be a positive integer.\n' >&2
    exit 2
  fi
  if ! is_integer "$MTR_COUNT" || [ "$MTR_COUNT" -lt 1 ]; then
    printf 'ERROR: --mtr-count must be a positive integer.\n' >&2
    exit 2
  fi

  case "$PROFILE" in
    balanced|throughput|latency|concurrency) ;;
    *)
      printf 'ERROR: --profile must be balanced, throughput, latency, or concurrency.\n' >&2
      exit 2
      ;;
  esac

  case "$PROTOCOL" in
    tcp|quic|mixed) ;;
    *)
      printf 'ERROR: --protocol must be tcp, quic, or mixed.\n' >&2
      exit 2
      ;;
  esac

  if [ "$SPEEDTEST" -eq 1 ]; then
    add_note "--speedtest is reserved for future use; no third-party speedtest is run automatically."
  fi
}

main() {
  parse_args "$@"
  detect_platform

  if [ "$ROLLBACK" -eq 1 ]; then
    rollback_config
    exit $?
  fi

  detect_system
  detect_public_network
  detect_interface
  detect_tcp_state
  measure_paths
  calculate_recommendations

  if [ "$SHOW_CONFIG" -eq 1 ]; then
    generate_config
  elif [ "$JSON" -eq 1 ]; then
    print_json
  else
    print_report
  fi

  if [ "$APPLY" -eq 1 ]; then
    apply_config
  fi
}

main "$@"
