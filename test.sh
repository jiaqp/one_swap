#!/usr/bin/env bash
#
# bbr-auto-tune.sh
#
# Automatic Linux TCP/BBR tuning assistant for proxy servers.
# Default mode is safe: detect, measure, calculate, and print a report.
# Use --apply to write /etc/sysctl.d/99-bbr-auto-tune.conf and apply it.

set -uo pipefail

VERSION="1.5.0"
CONF_PATH="/etc/sysctl.d/99-bbr-auto-tune.conf"

APPLY=0
ROLLBACK=0
SHOW_CONFIG=0
JSON=0
NO_NETWORK=0
DEEP=0
SPEEDTEST=0
LIVE_QDISC=1
INTERACTIVE=0
PROGRESS=0
QUIET_REQUESTED=0

REGION="china"
TARGETS_RAW=""
CHINA_CARRIER="public"
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
PING_COMMAND_MISSING_NOTED=0

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
bbr-auto-tune.sh - 面向代理服务器的 BBR/TCP 自动优化计算脚本

用法：
  bash bbr-auto-tune.sh
  sudo bash bbr-auto-tune.sh --interactive
  bash bbr-auto-tune.sh --bandwidth 1000 --region china --profile throughput

默认安全：
  直接运行脚本会进入中文向导。未选择 --apply 时，只检测、测速、计算并打印推荐配置，
  不会修改系统。

常用选项：
  --interactive, -i       打开中文菜单向导。
  --non-interactive       不询问，使用命令行参数和自动默认值。
  --progress              实时显示检测进度。
  --quiet                 关闭实时进度提示。
  --apply                 写入配置并执行 sysctl 应用。
  --rollback              回滚到最近一次备份。
  --show-config           只打印推荐的 sysctl 配置。
  --json                  输出机器可读的 JSON 报告。
  --no-network            跳过公网 IP、ping、MTR、tracepath 检测。
  --deep                  开启更深入的 MTR/tracepath 检测。
  --no-live-qdisc         应用时不立即执行 'tc qdisc replace dev IFACE root fq'。
                          sysctl 配置仍会写入。

可覆盖的输入：
  --region NAME           主要客户端地区。默认 china。
                          可选：china, global, asia, us, eu。
  --china-carrier NAME    中国大陆探测线路。可选：all, ct, cu, cm, public。
                          all=三网九点，ct=电信，cu=联通，cm=移动，public=公共 DNS。
  --targets LIST          自定义 ping 探测目标，用英文逗号分隔。
                          示例：--targets "ct=202.96.128.86,ali=223.5.5.5"
  --bandwidth MBPS        服务器套餐带宽，单位 Mbps。
                          不填写时优先尝试 ethtool，识别不到则按 1000 Mbps 估算。
  --concurrency N         预计同时活跃用户/高速连接数。默认 4。
  --protocol NAME         代理协议类型：tcp, quic, mixed。默认 mixed。
  --profile NAME          优化目标：balanced, throughput, latency, concurrency。
                          默认 balanced。
  --cc NAME               推荐使用的拥塞控制算法。默认 bbr。

检测选项：
  --ping-count N          每个目标 ping 次数。默认 12。
  --ping-timeout SEC      每个 ping 包超时时间，单位秒。默认 2。
  --mtr-count N           深度检测时 MTR 轮数。默认 30。

应用选项：
  --config-path PATH      sysctl 配置路径。
                          默认：/etc/sysctl.d/99-bbr-auto-tune.conf

推荐流程：
  1. bash bbr-auto-tune.sh
  2. 按中文菜单先生成报告。
  3. 确认没问题后，用 sudo 重新运行并在菜单里选择“应用优化”。
  4. 验证：sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
     以及：ss -tin | grep -i bbr

EOF
}

add_warning() {
  WARNINGS+=("$*")
}

add_note() {
  NOTES+=("$*")
}

progress() {
  [ "$PROGRESS" -eq 1 ] || return 0
  printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null || printf now)" "$*" >&2
}

progress_inline() {
  [ "$PROGRESS" -eq 1 ] || return 0
  printf '[%s] %s' "$(date '+%H:%M:%S' 2>/dev/null || printf now)" "$*" >&2
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

can_prompt() {
  [ -t 0 ] || { [ -r /dev/tty ] && [ -w /dev/tty ]; }
}

prompt_read() {
  local prompt="$1"
  PROMPT_REPLY=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r PROMPT_REPLY </dev/tty || PROMPT_REPLY=""
  else
    printf '%s' "$prompt"
    IFS= read -r PROMPT_REPLY || PROMPT_REPLY=""
  fi
}

prompt_yes_no() {
  local question="$1"
  local default="${2:-y}"
  local hint answer

  if [ "$default" = "y" ]; then
    hint="[Y/n]"
  else
    hint="[y/N]"
  fi

  while true; do
    prompt_read "$question $hint "
    answer="$(to_lower "$PROMPT_REPLY")"
    [ -z "$answer" ] && answer="$default"
    case "$answer" in
      y|yes|1|是|好)
        return 0
        ;;
      n|no|0|否|不)
        return 1
        ;;
      *)
        printf '请输入 y 或 n。\n'
        ;;
    esac
  done
}

join_words() {
  local out="" item
  for item in "$@"; do
    if [ -z "$out" ]; then
      out="$item"
    else
      out="$out $item"
    fi
  done
  printf '%s' "$out"
}

ensure_detection_tools() {
  [ "$NO_NETWORK" -eq 1 ] && return 0
  [ "$IS_LINUX" -eq 1 ] || return 0

  local missing_names=()
  local apt_pkgs=()

  if ! command_exists ping; then
    missing_names+=("ping")
    apt_pkgs+=("iputils-ping")
  fi
  if ! command_exists curl && ! command_exists wget; then
    missing_names+=("curl/wget")
    apt_pkgs+=("curl")
  fi
  if ! command_exists ethtool; then
    missing_names+=("ethtool")
    apt_pkgs+=("ethtool")
  fi
  if [ "$DEEP" -eq 1 ]; then
    if ! command_exists mtr; then
      missing_names+=("mtr")
      apt_pkgs+=("mtr-tiny")
    fi
    if ! command_exists tracepath; then
      missing_names+=("tracepath")
      apt_pkgs+=("iputils-tracepath")
    fi
  fi

  [ "${#missing_names[@]}" -eq 0 ] && return 0

  add_warning "系统缺少检测工具：$(join_words "${missing_names[@]}")。缺少 ping 会导致所有目标显示“无 ping”。"

  if [ "$INTERACTIVE" -eq 1 ] && [ "$(id -u 2>/dev/null || printf 1)" -eq 0 ] && command_exists apt-get; then
    if prompt_yes_no "检测到缺少工具：$(join_words "${missing_names[@]}")。是否自动安装？" "y"; then
      progress "安装检测工具: $(join_words "${apt_pkgs[@]}")"
      if apt-get update && apt-get install -y "${apt_pkgs[@]}"; then
        progress "检测工具安装完成"
      else
        add_warning "自动安装检测工具失败，请手动执行：sudo apt-get update && sudo apt-get install -y $(join_words "${apt_pkgs[@]}")"
      fi
    else
      add_warning "已跳过检测工具安装。建议手动执行：sudo apt-get update && sudo apt-get install -y $(join_words "${apt_pkgs[@]}")"
    fi
  elif command_exists apt-get; then
    add_warning "建议安装检测工具：sudo apt-get update && sudo apt-get install -y $(join_words "${apt_pkgs[@]}")"
  fi
}

china_ct_targets() {
  printf '%s' 'ct-bj=219.141.136.10,ct-sh=202.96.209.133,ct-gd=202.96.128.86'
}

china_cu_targets() {
  printf '%s' 'cu-bj=202.106.0.20,cu-sh=210.22.70.3,cu-gd=221.5.88.88'
}

china_cm_targets() {
  printf '%s' 'cm-bj=221.130.33.52,cm-sh=211.136.112.50,cm-gd=211.136.192.6'
}

china_public_targets() {
  printf '%s' 'aliyun-dns-cn=223.5.5.5,dnspod-cn=119.29.29.29,114dns-cn=114.114.114.114,baidu-dns-cn=180.76.76.76'
}

china_precise_targets() {
  printf '%s,%s,%s' "$(china_ct_targets)" "$(china_cu_targets)" "$(china_cm_targets)"
}

china_targets_for_carrier() {
  case "$(to_lower "${1:-public}")" in
    all|three|3|sanwang)
      china_precise_targets
      ;;
    ct|telecom|dianxin)
      china_ct_targets
      ;;
    cu|unicom|liantong)
      china_cu_targets
      ;;
    cm|mobile|yidong)
      china_cm_targets
      ;;
    public|dns|"")
      china_public_targets
      ;;
    *)
      add_warning "未知中国线路选择 '$1'，已改用公共 DNS 探测目标。"
      china_public_targets
      ;;
  esac
}

interactive_wizard() {
  if ! can_prompt; then
    printf '错误：交互模式需要终端。请下载脚本后在 shell 里运行，或使用 --non-interactive。\n' >&2
    exit 2
  fi

  [ "$QUIET_REQUESTED" -eq 1 ] || PROGRESS=1

  printf '\nBBR Auto Tune 中文向导 v%s\n' "$VERSION"
  printf '直接回车使用推荐值；默认先生成报告，不会修改系统。\n\n'

  while true; do
    cat <<'EOF'
请选择运行模式：
  1) 只检测并生成报告（推荐先跑这个）
  2) 检测后直接应用优化（需要 sudo/root）
  3) 只打印推荐 sysctl 配置
  4) 输出 JSON，方便程序读取
  5) 回滚上一次应用前的备份
EOF
    prompt_read "模式 [1]: "
    case "${PROMPT_REPLY:-1}" in
      1|"")
        APPLY=0
        SHOW_CONFIG=0
        JSON=0
        ROLLBACK=0
        break
        ;;
      2)
        APPLY=1
        SHOW_CONFIG=0
        JSON=0
        ROLLBACK=0
        break
        ;;
      3)
        APPLY=0
        SHOW_CONFIG=1
        JSON=0
        ROLLBACK=0
        break
        ;;
      4)
        APPLY=0
        SHOW_CONFIG=0
        JSON=1
        ROLLBACK=0
        break
        ;;
      5)
        ROLLBACK=1
        return 0
        ;;
      *)
        printf '请输入 1-5。\n'
        ;;
    esac
  done

  if prompt_yes_no "是否进行公网、延迟、丢包自动探测？" "y"; then
    NO_NETWORK=0
  else
    NO_NETWORK=1
  fi

  if [ "$NO_NETWORK" -eq 0 ]; then
    while true; do
      cat <<'EOF'

请选择主要客户端地区：
  1) 中国大陆（推荐：自动按国内线路计算）
  2) 亚洲
  3) 全球
  4) 美国
  5) 欧洲
  6) 自定义探测目标
EOF
      prompt_read "地区 [1]: "
      case "${PROMPT_REPLY:-1}" in
        1|"")
          REGION="china"
          break
          ;;
        2)
          REGION="asia"
          break
          ;;
        3)
          REGION="global"
          break
          ;;
        4)
          REGION="us"
          break
          ;;
        5)
          REGION="eu"
          break
          ;;
        6)
          REGION="custom"
          prompt_read "请输入探测目标，例如 ct=202.96.128.86,cu=202.106.0.20: "
          TARGETS_RAW="$PROMPT_REPLY"
          break
          ;;
        *)
          printf '请输入 1-6。\n'
          ;;
      esac
    done

    if [ "$REGION" = "china" ] && [ -z "$TARGETS_RAW" ]; then
      while true; do
        cat <<'EOF'

中国线路探测目标：
  1) 中国三网九点：电信/联通/移动，北京/上海/广东（推荐）
  2) 仅电信：北京/上海/广东
  3) 仅联通：北京/上海/广东
  4) 仅移动：北京/上海/广东
  5) 真实用户 IP：只按你输入的中国客户端 IP 计算
  6) 简洁公共 DNS：阿里/腾讯/114/百度（更快，但可能被 Anycast 影响）
  7) 手动输入完整目标列表
EOF
        prompt_read "目标 [1]: "
        case "${PROMPT_REPLY:-1}" in
          1|"")
            CHINA_CARRIER="all"
            TARGETS_RAW="$(china_precise_targets)"
            break
            ;;
          2)
            CHINA_CARRIER="ct"
            TARGETS_RAW="$(china_ct_targets)"
            break
            ;;
          3)
            CHINA_CARRIER="cu"
            TARGETS_RAW="$(china_cu_targets)"
            break
            ;;
          4)
            CHINA_CARRIER="cm"
            TARGETS_RAW="$(china_cm_targets)"
            break
            ;;
          5)
            CHINA_CARRIER="user"
            prompt_read "请输入真实用户公网 IP，可多个，用英文逗号分隔，例如 1.2.3.4,5.6.7.8: "
            TARGETS_RAW="$(printf '%s' "$PROMPT_REPLY" | awk -F',' '{
              out=""
              for (i=1;i<=NF;i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", $i)
                if ($i == "") continue
                item = $i
                if (item !~ /=/) item = "user" i "=" item
                if (out == "") out = item; else out = out "," item
              }
              printf "%s", out
            }')"
            break
            ;;
          6)
            CHINA_CARRIER="public"
            TARGETS_RAW="$(china_public_targets)"
            break
            ;;
          7)
            CHINA_CARRIER="custom"
            prompt_read "请输入探测目标，例如 ct-bj=219.141.136.10,cm-gd=211.136.192.6: "
            TARGETS_RAW="$PROMPT_REPLY"
            break
            ;;
          *)
            printf '请输入 1-7。\n'
            ;;
        esac
      done
    fi
  fi

  while true; do
    cat <<'EOF'

请选择服务器套餐带宽：
  1) 自动识别/不知道（识别不到会按 1000 Mbps 估算）
  2) 100 Mbps
  3) 200 Mbps
  4) 500 Mbps
  5) 1000 Mbps / 1Gbps
  6) 2500 Mbps / 2.5Gbps
  7) 10000 Mbps / 10Gbps
  8) 手动输入
EOF
    prompt_read "带宽 [1]: "
    case "${PROMPT_REPLY:-1}" in
      1|"")
        TARGET_BANDWIDTH_MBPS=""
        break
        ;;
      2)
        TARGET_BANDWIDTH_MBPS="100"
        break
        ;;
      3)
        TARGET_BANDWIDTH_MBPS="200"
        break
        ;;
      4)
        TARGET_BANDWIDTH_MBPS="500"
        break
        ;;
      5)
        TARGET_BANDWIDTH_MBPS="1000"
        break
        ;;
      6)
        TARGET_BANDWIDTH_MBPS="2500"
        break
        ;;
      7)
        TARGET_BANDWIDTH_MBPS="10000"
        break
        ;;
      8)
        while true; do
          prompt_read "请输入带宽 Mbps，例如 1000: "
          if is_number "$PROMPT_REPLY"; then
            TARGET_BANDWIDTH_MBPS="$PROMPT_REPLY"
            break
          fi
          printf '带宽必须是数字。\n'
        done
        break
        ;;
      *)
        printf '请输入 1-8。\n'
        ;;
    esac
  done

  while true; do
    cat <<'EOF'

请选择代理协议类型：
  1) mixed：混合/不确定（推荐）
  2) tcp：Xray/Reality/WS/gRPC/Nginx/Haproxy 等 TCP 类
  3) quic：Hysteria2/TUIC/HTTP3 等 QUIC/UDP 类
EOF
    prompt_read "协议 [1]: "
    case "${PROMPT_REPLY:-1}" in
      1|"")
        PROTOCOL="mixed"
        break
        ;;
      2)
        PROTOCOL="tcp"
        break
        ;;
      3)
        PROTOCOL="quic"
        break
        ;;
      *)
        printf '请输入 1-3。\n'
        ;;
    esac
  done

  while true; do
    cat <<'EOF'

请选择优化目标：
  1) throughput：极致吞吐/测速优先（跨境代理推荐）
  2) balanced：稳定均衡
  3) latency：低延迟/交互优先
  4) concurrency：高并发/多人使用
EOF
    prompt_read "目标 [1]: "
    case "${PROMPT_REPLY:-1}" in
      1|"")
        PROFILE="throughput"
        break
        ;;
      2)
        PROFILE="balanced"
        break
        ;;
      3)
        PROFILE="latency"
        break
        ;;
      4)
        PROFILE="concurrency"
        break
        ;;
      *)
        printf '请输入 1-4。\n'
        ;;
    esac
  done

  while true; do
    prompt_read "预计同时活跃用户/高速连接数 [4]: "
    [ -z "$PROMPT_REPLY" ] && PROMPT_REPLY="4"
    if is_integer "$PROMPT_REPLY" && [ "$PROMPT_REPLY" -ge 1 ]; then
      CONCURRENCY="$PROMPT_REPLY"
      break
    fi
    printf '并发数必须是正整数。\n'
  done

  while true; do
    cat <<'EOF'

请选择探测精度：
  1) 快速：每个目标 ping 6 次
  2) 标准：每个目标 ping 12 次（推荐）
  3) 精细：每个目标 ping 30 次
EOF
    prompt_read "精度 [2]: "
    case "${PROMPT_REPLY:-2}" in
      1)
        PING_COUNT=6
        break
        ;;
      2|"")
        PING_COUNT=12
        break
        ;;
      3)
        PING_COUNT=30
        break
        ;;
      *)
        printf '请输入 1-3。\n'
        ;;
    esac
  done

  if prompt_yes_no "是否启用深度路由检测 mtr/tracepath？会更慢。" "n"; then
    DEEP=1
  else
    DEEP=0
  fi

  if prompt_yes_no "是否打开高级设置？" "n"; then
    prompt_read "拥塞控制算法 [bbr]: "
    [ -n "$PROMPT_REPLY" ] && REQUESTED_CC="$(to_lower "$PROMPT_REPLY")"

    while true; do
      prompt_read "ping 超时时间秒数 [2]: "
      [ -z "$PROMPT_REPLY" ] && PROMPT_REPLY="2"
      if is_integer "$PROMPT_REPLY" && [ "$PROMPT_REPLY" -ge 1 ]; then
        PING_TIMEOUT="$PROMPT_REPLY"
        break
      fi
      printf '超时时间必须是正整数。\n'
    done

    while true; do
      prompt_read "MTR 轮数 [30]: "
      [ -z "$PROMPT_REPLY" ] && PROMPT_REPLY="30"
      if is_integer "$PROMPT_REPLY" && [ "$PROMPT_REPLY" -ge 1 ]; then
        MTR_COUNT="$PROMPT_REPLY"
        break
      fi
      printf 'MTR 轮数必须是正整数。\n'
    done

    prompt_read "sysctl 配置路径 [$CONF_PATH]: "
    [ -n "$PROMPT_REPLY" ] && CONF_PATH="$PROMPT_REPLY"

    if prompt_yes_no "应用时是否立即把当前网卡 qdisc 切到 fq？" "y"; then
      LIVE_QDISC=1
    else
      LIVE_QDISC=0
    fi
  fi

  printf '\n即将使用以下设置：\n'
  printf '  模式: %s\n' "$([ "$APPLY" -eq 1 ] && printf '检测并应用' || { [ "$SHOW_CONFIG" -eq 1 ] && printf '只打印配置' || { [ "$JSON" -eq 1 ] && printf 'JSON 输出' || printf '只生成报告'; }; })"
  printf '  地区: %s\n' "$REGION"
  if [ "$REGION" = "china" ] || [ "$REGION" = "cn" ]; then
    printf '  中国线路: %s\n' "$(cn_china_carrier "$CHINA_CARRIER")"
  fi
  printf '  探测目标: %s\n' "${TARGETS_RAW:-自动预设}"
  printf '  带宽: %s\n' "${TARGET_BANDWIDTH_MBPS:-自动识别/默认 1000 Mbps}"
  printf '  协议/目标: %s / %s\n' "$PROTOCOL" "$PROFILE"
  printf '  并发: %s\n' "$CONCURRENCY"
  printf '  ping 次数: %s\n' "$PING_COUNT"
  printf '  深度检测: %s\n' "$([ "$DEEP" -eq 1 ] && printf '开启' || printf '关闭')"
  printf '  网络探测: %s\n' "$([ "$NO_NETWORK" -eq 1 ] && printf '跳过' || printf '开启')"
  printf '  实时进度: %s\n' "$([ "$PROGRESS" -eq 1 ] && printf '开启' || printf '关闭')"

  if ! prompt_yes_no "开始执行？" "y"; then
    printf '已取消。\n'
    exit 0
  fi
  printf '\n'
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

parse_targets_list() {
  local raw="$1"
  local old_ifs="$IFS"
  local item label host
  IFS=','
  for item in $raw; do
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
}

load_targets() {
  TARGET_LABELS=()
  TARGET_HOSTS=()

  if [ -n "$TARGETS_RAW" ]; then
    parse_targets_list "$TARGETS_RAW"
    return 0
  fi

  case "$(to_lower "$REGION")" in
    china|cn)
      parse_targets_list "$(china_targets_for_carrier "$CHINA_CARRIER")"
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
      add_warning "未知地区预设 '$REGION'，已改用中国预设。如需精确探测，请使用 --targets。"
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
    add_warning "此脚本面向 Linux 服务器。当前系统只能生成报告，非 Linux 系统禁止使用 --apply。"
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
  [ "$RAM_MB" -eq 0 ] && add_warning "未能检测到内存大小，已使用保守内存上限。"

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
    add_warning "未能获取公网 IP/ASN 信息。请安装 curl/wget；如果是有意跳过网络检测，可使用 --no-network。"
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

  progress "Ping 开始: ${label} (${host})，次数 ${PING_COUNT}，单包超时 ${PING_TIMEOUT}s"

  if ! command_exists ping; then
    PING_LABELS+=("$label")
    PING_HOSTS+=("$host")
    PING_STATUS+=("no-ping")
    PING_LOSS+=("")
    PING_MIN+=("")
    PING_AVG+=("")
    PING_MAX+=("")
    PING_JITTER+=("")
    progress "Ping 跳过: 系统没有 ping 命令"
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

  if [ "$status" = "ok" ]; then
    progress "Ping 完成: $label loss=${loss}% avg=${avg}ms min=${min}ms max=${max}ms jitter=${jitter:-0}ms"
  else
    progress "Ping 失败: $label loss=${loss}% 这个目标会在计算时自动降权/忽略"
  fi
}

measure_paths() {
  load_targets

  if [ "$NO_NETWORK" -eq 1 ]; then
    add_note "已按 --no-network 跳过网络探测。"
    return 0
  fi

  if [ "${#TARGET_HOSTS[@]}" -eq 0 ]; then
    add_warning "没有配置任何探测目标。"
    return 0
  fi

  if ! command_exists ping && [ "$PING_COMMAND_MISSING_NOTED" -eq 0 ]; then
    add_warning "系统没有 ping 命令，无法测 RTT/丢包。Ubuntu/Debian 可安装：sudo apt-get install -y iputils-ping"
    PING_COMMAND_MISSING_NOTED=1
  fi

  progress "网络探测开始: 共 ${#TARGET_HOSTS[@]} 个目标"
  local i
  for ((i=0; i<${#TARGET_HOSTS[@]}; i++)); do
    progress "目标 $((i + 1))/${#TARGET_HOSTS[@]}"
    measure_ping_target "${TARGET_LABELS[$i]}" "${TARGET_HOSTS[$i]}"
  done

  if [ "$DEEP" -eq 1 ]; then
    run_deep_measurements
  fi

  progress "网络探测完成"
}

run_deep_measurements() {
  local i label host summary

  if ! command_exists mtr && ! command_exists tracepath; then
    add_note "已请求 --deep 深度检测，但系统未安装 mtr 或 tracepath。"
    return 0
  fi

  for ((i=0; i<${#TARGET_HOSTS[@]} && i<2; i++)); do
    label="${TARGET_LABELS[$i]}"
    host="${TARGET_HOSTS[$i]}"
    summary=""

    if command_exists mtr; then
      progress "MTR 开始: $label ($host)，轮数 $MTR_COUNT"
      summary="$(mtr -rwzc "$MTR_COUNT" "$host" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]\+/ /g' || true)"
      [ -n "$summary" ] && MTR_SUMMARIES+=("$label mtr: $summary")
      progress "MTR 完成: $label ${summary:-无摘要}"
    fi

    if command_exists tracepath; then
      progress "tracepath 开始: $label ($host)"
      summary="$(tracepath -n "$host" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]\+/ /g' || true)"
      [ -n "$summary" ] && MTR_SUMMARIES+=("$label tracepath: $summary")
      progress "tracepath 完成: $label ${summary:-无摘要}"
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
    add_warning "没有成功的 ping 探测结果，已按地区 '$REGION' 使用备用 RTT：${EFFECTIVE_RTT_MS} ms。"
  fi
  if ! is_number "$EFFECTIVE_LOSS_PERCENT"; then
    EFFECTIVE_LOSS_PERCENT="1"
    add_warning "没有可靠的丢包率数据，已使用备用丢包率 1%。"
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
      add_warning "网卡报告速率为 ${NIC_SPEED_MBPS} Mbps。虚拟网卡速率可能高于 VPS 套餐；如果真实套餐更低，请手动传入 --bandwidth。"
    fi
    return 0
  fi

  TARGET_BANDWIDTH_MBPS="1000"
  BANDWIDTH_SOURCE="fallback"
  add_warning "未能检测真实带宽，暂按 1000 Mbps 估算。为了更准确，请手动传入 --bandwidth。"
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
    add_warning "推荐 buffer 已受内存策略限制：算法期望约 $(format_float "$RAW_BUFFER_MB" 1) MB，实际限制为 ${RECOMMENDED_BUFFER_MB} MB。"
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
    target = c * 512
    if (ram > 0 && ram < 1024) base = 65536
    else base = 262144
    if (target < base) target = base

    if (ram > 0 && ram < 2048) cap = 262144
    else if (ram > 0 && ram < 8192) cap = 524288
    else if (ram > 0 && ram < 32768) cap = 1048576
    else cap = 2097152

    rounded = 1
    while (rounded < target) rounded *= 2
    target = rounded
    if (target > cap) target = cap
    if (target < 32768) target = 32768
    printf "%.0f\n", target
  }')"
  RECOMMENDED_FILE_MAX="$(awk -v c="$CONCURRENCY" -v ram="$RAM_MB" 'BEGIN {
    v = c * 1024
    if (v < 1048576) v = 1048576

    if (ram > 0 && ram < 2048) cap = 1048576
    else if (ram > 0 && ram < 8192) cap = 2097152
    else if (ram > 0 && ram < 32768) cap = 4194304
    else cap = 8388608

    if (v > cap) v = cap
    printf "%.0f\n", v
  }')"

  LINE_QUALITY="$(classify_quality "$EFFECTIVE_RTT_MS" "$EFFECTIVE_LOSS_PERCENT" "$EFFECTIVE_JITTER_MS")"

  if [ "$REQUESTED_CC" = "bbr" ] && [ "$BBR_STATE" = "missing-or-unknown" ]; then
    add_warning "当前可用拥塞控制算法中未看到 BBR。使用 --apply 时会尝试执行 'modprobe tcp_bbr'；如仍不可用，请升级或更换支持 BBR 的内核。"
  fi
  if printf '%s' "$IFACE_QDISC" | grep -q '^qdisc mq ' && [ "$CURRENT_QDISC" = "fq" ]; then
    add_note "默认网卡使用多队列 root qdisc：mq。这在云服务器上很常见；系统 default_qdisc 已是 fq，应用时会跳过强制替换 root qdisc，避免网络闪断。"
  fi
  if [ "$CPU_AES" != "yes" ]; then
    add_note "未检测到 AES 加速。TLS/Reality/QUIC 类代理吞吐可能受 CPU 限制。"
  fi
}

emit_sysctl_if_exists() {
  local key="$1"
  local value="$2"
  if sysctl_key_exists "$key"; then
    printf '%s = %s\n' "$key" "$value"
  else
    printf '# 已跳过：当前内核不支持 %s\n' "$key"
  fi
}

generate_config() {
  cat <<EOF
# 由 bbr-auto-tune.sh v$VERSION 生成
# 生成时间：$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
# 优化目标：$PROFILE
# 协议类型：$PROTOCOL
# 客户端地区：$REGION
# 中国线路：$([ "$(to_lower "$REGION")" = "china" ] || [ "$(to_lower "$REGION")" = "cn" ] && cn_china_carrier "$CHINA_CARRIER" || printf '不适用')
# 目标带宽：${TARGET_BANDWIDTH_MBPS} Mbps ($(cn_source "$BANDWIDTH_SOURCE"))
# 有效 RTT/丢包/抖动：${EFFECTIVE_RTT_MS} ms / ${EFFECTIVE_LOSS_PERCENT}% / ${EFFECTIVE_JITTER_MS} ms
# BDP: ${BDP_MB} MB
# 推荐 socket buffer 上限：${RECOMMENDED_BUFFER_MB} MB

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
  local value="${2:-未知}"
  [ "$value" = "unknown" ] && value="未知"
  printf '  %-28s %s\n' "$1:" "$value"
}

cn_aes() {
  case "${1:-}" in
    yes) printf '支持' ;;
    no-or-unknown|"") printf '未检测到/未知' ;;
    *) printf '%s' "$1" ;;
  esac
}

cn_bbr_state() {
  case "${1:-}" in
    available) printf '可用' ;;
    loadable) printf '可加载' ;;
    loaded) printf '已加载' ;;
    missing-or-unknown|"") printf '缺失或未知' ;;
    *) printf '%s' "$1" ;;
  esac
}

cn_quality() {
  case "${1:-}" in
    excellent) printf '极好' ;;
    good) printf '良好' ;;
    fair) printf '一般' ;;
    weak) printf '偏弱' ;;
    poor) printf '较差' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

cn_source() {
  case "${1:-}" in
    user) printf '手动输入' ;;
    ethtool) printf '网卡检测' ;;
    fallback) printf '默认估算' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

cn_status() {
  case "${1:-}" in
    ok) printf '成功' ;;
    failed) printf '失败' ;;
    no-ping) printf '无 ping' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

cn_profile() {
  case "${1:-}" in
    throughput) printf '极致吞吐(throughput)' ;;
    balanced) printf '稳定均衡(balanced)' ;;
    latency) printf '低延迟(latency)' ;;
    concurrency) printf '高并发(concurrency)' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

cn_protocol() {
  case "${1:-}" in
    tcp) printf 'TCP 类(tcp)' ;;
    quic) printf 'QUIC/UDP 类(quic)' ;;
    mixed) printf '混合/不确定(mixed)' ;;
    *) printf '%s' "${1:-未知}" ;;
  esac
}

cn_china_carrier() {
  case "$(to_lower "${1:-}")" in
    all|three|3|sanwang) printf '三网全部' ;;
    ct|telecom|dianxin) printf '仅电信' ;;
    cu|unicom|liantong) printf '仅联通' ;;
    cm|mobile|yidong) printf '仅移动' ;;
    public|dns|"") printf '公共 DNS' ;;
    user) printf '真实用户 IP' ;;
    custom) printf '自定义目标' ;;
    *) printf '%s' "$1" ;;
  esac
}

script_display_path() {
  local base
  base="$(basename "$0" 2>/dev/null || printf '')"
  case "$base" in
    bash|sh|dash|zsh|-bash|"")
      printf 'bbr-auto-tune.sh'
      ;;
    *)
      printf '%s' "$0"
      ;;
  esac
}

print_report() {
  local self_path carrier_arg targets_arg
  self_path="$(script_display_path)"
  carrier_arg=""
  targets_arg=""

  if [ "$(to_lower "$REGION")" = "china" ] || [ "$(to_lower "$REGION")" = "cn" ]; then
    case "$CHINA_CARRIER" in
      public|dns|"") ;;
      *)
        carrier_arg=" --china-carrier $CHINA_CARRIER"
        ;;
    esac
  fi
  if [ -n "$TARGETS_RAW" ]; then
    case "$CHINA_CARRIER" in
      all|ct|cu|cm) ;;
      *)
        targets_arg=" --targets \"$TARGETS_RAW\""
        ;;
    esac
  fi

  printf 'BBR Auto Tune v%s\n' "$VERSION"
  printf '运行模式：%s\n' "$([ "$APPLY" -eq 1 ] && printf '应用优化' || printf '只生成报告')"

  print_section "系统信息"
  print_kv "内核" "$KERNEL_NAME $KERNEL_RELEASE"
  print_kv "CPU 核心数" "$CPU_CORES"
  print_kv "CPU 型号" "$CPU_MODEL"
  print_kv "AES 加速" "$(cn_aes "$CPU_AES")"
  print_kv "内存" "${RAM_MB} MB"
  print_kv "虚拟化" "$VIRT_TYPE"

  print_section "网络信息"
  print_kv "公网 IPv4" "$PUBLIC_IP"
  print_kv "公网 IPv6" "$PUBLIC_IPV6"
  print_kv "asn/org" "${PUBLIC_ASN:-} ${PUBLIC_ORG:-}"
  print_kv "位置" "${PUBLIC_CITY:-未知}, ${PUBLIC_REGION:-未知}, ${PUBLIC_COUNTRY:-未知}"
  print_kv "默认网卡" "$DEFAULT_IFACE"
  print_kv "网卡 MTU" "$IFACE_MTU"
  print_kv "网卡 qdisc" "$IFACE_QDISC"
  print_kv "网卡速率" "${NIC_SPEED_MBPS:-未知} Mbps"

  print_section "TCP 状态"
  print_kv "当前拥塞控制" "$CURRENT_CC"
  print_kv "可用拥塞控制" "$AVAILABLE_CC"
  print_kv "默认 qdisc" "$CURRENT_QDISC"
  print_kv "目标拥塞控制" "$REQUESTED_CC"
  print_kv "目标算法状态" "$(cn_bbr_state "$BBR_STATE")"

  print_section "链路探测"
  if [ "${#PING_LABELS[@]}" -eq 0 ]; then
    printf '  没有 ping 探测结果。\n'
  else
    printf '  %-18s %-16s %-8s %-8s %-10s %-10s %-10s %-10s\n' "标签" "目标" "状态" "丢包%" "最小" "平均" "最大" "抖动"
    local i
    for ((i=0; i<${#PING_LABELS[@]}; i++)); do
      printf '  %-18s %-16s %-8s %-8s %-10s %-10s %-10s %-10s\n' \
        "${PING_LABELS[$i]}" "${PING_HOSTS[$i]}" "$(cn_status "${PING_STATUS[$i]}")" \
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

  print_section "计算结果"
  print_kv "目标带宽" "${TARGET_BANDWIDTH_MBPS} Mbps ($(cn_source "$BANDWIDTH_SOURCE"))"
  print_kv "优化目标/协议" "$(cn_profile "$PROFILE") / $(cn_protocol "$PROTOCOL")"
  if [ "$(to_lower "$REGION")" = "china" ] || [ "$(to_lower "$REGION")" = "cn" ]; then
    print_kv "中国线路" "$(cn_china_carrier "$CHINA_CARRIER")"
  fi
  print_kv "并发数" "$CONCURRENCY"
  print_kv "有效 RTT" "${EFFECTIVE_RTT_MS} ms"
  print_kv "有效丢包" "${EFFECTIVE_LOSS_PERCENT}%"
  print_kv "有效抖动" "${EFFECTIVE_JITTER_MS} ms"
  print_kv "线路质量" "$(cn_quality "$LINE_QUALITY")"
  print_kv "bdp" "${BDP_MB} MB"
  print_kv "丢包系数" "$LOSS_FACTOR"
  print_kv "原始 buffer 目标" "$(format_float "$RAW_BUFFER_MB" 1) MB"
  print_kv "推荐 buffer" "${RECOMMENDED_BUFFER_MB} MB (${RECOMMENDED_BUFFER_BYTES} bytes)"
  print_kv "backlog" "$RECOMMENDED_BACKLOG"
  print_kv "conntrack 上限" "$RECOMMENDED_CONNTRACK"

  print_section "推荐 sysctl 配置"
  generate_config

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    print_section "警告"
    local w
    for w in "${WARNINGS[@]}"; do
      printf '  - %s\n' "$w"
    done
  fi

  if [ "${#NOTES[@]}" -gt 0 ]; then
    print_section "提示"
    local n
    for n in "${NOTES[@]}"; do
      printf '  - %s\n' "$n"
    done
  fi

  print_section "下一步"
  if [ "$APPLY" -eq 1 ]; then
    printf '  正在应用配置到 %s\n' "$CONF_PATH"
  else
    printf '  交互式应用：sudo bash %s --interactive\n' "$self_path"
    printf '  命令行应用：sudo bash %s --bandwidth %s --region %s%s --profile %s --protocol %s%s --apply\n' "$self_path" "$TARGET_BANDWIDTH_MBPS" "$REGION" "$carrier_arg" "$PROFILE" "$PROTOCOL" "$targets_arg"
    printf '  应用后验证：sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc && ss -tin | grep -i bbr\n'
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
  progress "应用阶段开始"
  if [ "$IS_LINUX" -ne 1 ]; then
    printf '错误：--apply 只支持 Linux。\n' >&2
    return 1
  fi
  if [ "$(id -u 2>/dev/null || printf 1)" -ne 0 ]; then
    printf '错误：--apply 需要 root 权限，请使用 sudo 重新运行。\n' >&2
    return 1
  fi

  if [ "$REQUESTED_CC" = "bbr" ] && ! printf ' %s ' "$(get_sysctl net.ipv4.tcp_available_congestion_control)" | grep -q ' bbr '; then
    if command_exists modprobe; then
      progress "尝试加载 tcp_bbr 模块"
      modprobe tcp_bbr 2>/dev/null || true
    fi
  fi

  local dir tmp backup
  dir="$(dirname "$CONF_PATH")"
  if [ ! -d "$dir" ]; then
    printf '错误：配置目录不存在：%s\n' "$dir" >&2
    return 1
  fi

  tmp="$(mktemp "${dir}/.bbr-auto-tune.XXXXXX")" || return 1
  progress "生成 sysctl 配置临时文件"
  generate_config > "$tmp"

  if [ -f "$CONF_PATH" ]; then
    backup="${CONF_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    progress "备份旧配置: $backup"
    cp "$CONF_PATH" "$backup"
    printf '已备份旧配置：%s\n' "$backup"
  fi

  progress "写入配置: $CONF_PATH"
  cp "$tmp" "$CONF_PATH"
  rm -f "$tmp"
  printf '已写入配置：%s\n' "$CONF_PATH"

  if command_exists sysctl; then
    progress "执行 sysctl --system"
    if sysctl --system >/tmp/bbr-auto-tune-sysctl.log 2>&1; then
      printf 'sysctl --system 已成功应用。\n'
    else
      printf '警告：sysctl --system 报错，输出如下：\n' >&2
      cat /tmp/bbr-auto-tune-sysctl.log >&2
      return 1
    fi
  fi

  if [ "$LIVE_QDISC" -eq 1 ] && command_exists tc && [ -n "$DEFAULT_IFACE" ]; then
    local root_qdisc_line
    root_qdisc_line="$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | head -n 1 | sed 's/[[:space:]]\+/ /g' || true)"
    if printf '%s' "$root_qdisc_line" | grep -q '^qdisc mq '; then
      printf '提示：检测到 %s 使用多队列 root qdisc：mq。已跳过实时替换 root qdisc，避免网络闪断。\n' "$DEFAULT_IFACE"
    elif ! printf '%s' "$root_qdisc_line" | grep -qw fq; then
      progress "尝试立即把当前网卡 $DEFAULT_IFACE 的 qdisc 切到 fq"
      if tc qdisc replace dev "$DEFAULT_IFACE" root fq >/dev/null 2>&1; then
        printf '已立即应用 qdisc：%s -> fq\n' "$DEFAULT_IFACE"
      else
        printf '提示：未能立即把 %s 的 qdisc 切到 fq。sysctl 默认值已经设置；如有需要，可重启或手动应用。\n' "$DEFAULT_IFACE" >&2
      fi
    fi
  fi

  printf '验证：\n'
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  progress "应用阶段完成"
}

rollback_config() {
  if [ "$IS_LINUX" -ne 1 ]; then
    printf '错误：--rollback 只支持 Linux。\n' >&2
    return 1
  fi
  if [ "$(id -u 2>/dev/null || printf 1)" -ne 0 ]; then
    printf '错误：--rollback 需要 root 权限，请使用 sudo 重新运行。\n' >&2
    return 1
  fi

  local backup
  backup="$(ls -t "${CONF_PATH}".bak.* 2>/dev/null | head -n 1 || true)"
  if [ -z "$backup" ]; then
    printf '错误：没有找到 %s 的备份。\n' "$CONF_PATH" >&2
    return 1
  fi
  cp "$backup" "$CONF_PATH"
  printf '已恢复备份：%s -> %s\n' "$backup" "$CONF_PATH"
  sysctl --system >/tmp/bbr-auto-tune-sysctl.log 2>&1 || {
    printf '警告：sysctl --system 报错，输出如下：\n' >&2
    cat /tmp/bbr-auto-tune-sysctl.log >&2
    return 1
  }
}

parse_args() {
  local original_argc="$#"
  if [ "$original_argc" -eq 0 ] && can_prompt; then
    INTERACTIVE=1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --interactive|-i)
        INTERACTIVE=1
        ;;
      --non-interactive)
        INTERACTIVE=0
        ;;
      --progress)
        PROGRESS=1
        ;;
      --quiet)
        PROGRESS=0
        QUIET_REQUESTED=1
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
      --china-carrier)
        shift
        CHINA_CARRIER="$(to_lower "${1:-}")"
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
        printf '未知选项：%s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  if [ "$INTERACTIVE" -eq 1 ]; then
    interactive_wizard
  fi

  validate_options
}

validate_options() {
  if ! is_number "$TARGET_BANDWIDTH_MBPS" && [ -n "$TARGET_BANDWIDTH_MBPS" ]; then
    printf '错误：--bandwidth 必须是数字，单位 Mbps。\n' >&2
    exit 2
  fi
  if ! is_integer "$CONCURRENCY" || [ "$CONCURRENCY" -lt 1 ]; then
    printf '错误：--concurrency 必须是正整数。\n' >&2
    exit 2
  fi
  if ! is_integer "$PING_COUNT" || [ "$PING_COUNT" -lt 1 ]; then
    printf '错误：--ping-count 必须是正整数。\n' >&2
    exit 2
  fi
  if ! is_integer "$PING_TIMEOUT" || [ "$PING_TIMEOUT" -lt 1 ]; then
    printf '错误：--ping-timeout 必须是正整数。\n' >&2
    exit 2
  fi
  if ! is_integer "$MTR_COUNT" || [ "$MTR_COUNT" -lt 1 ]; then
    printf '错误：--mtr-count 必须是正整数。\n' >&2
    exit 2
  fi

  case "$PROFILE" in
    balanced|throughput|latency|concurrency) ;;
    *)
      printf '错误：--profile 必须是 balanced、throughput、latency 或 concurrency。\n' >&2
      exit 2
      ;;
  esac

  case "$PROTOCOL" in
    tcp|quic|mixed) ;;
    *)
      printf '错误：--protocol 必须是 tcp、quic 或 mixed。\n' >&2
      exit 2
      ;;
  esac

  case "$CHINA_CARRIER" in
    all|ct|cu|cm|public|dns|three|3|sanwang|telecom|dianxin|unicom|liantong|mobile|yidong|user|custom|"") ;;
    *)
      printf '错误：--china-carrier 必须是 all、ct、cu、cm 或 public。\n' >&2
      exit 2
      ;;
  esac

  if [ "$(to_lower "$REGION")" = "china" ] || [ "$(to_lower "$REGION")" = "cn" ]; then
    case "$CHINA_CARRIER" in
      user|custom)
        if [ -z "$TARGETS_RAW" ]; then
          printf '错误：--china-carrier %s 需要同时提供 --targets，例如 --targets "home=1.2.3.4"。\n' "$CHINA_CARRIER" >&2
          exit 2
        fi
        ;;
    esac
  fi

  if [ "$SPEEDTEST" -eq 1 ]; then
    add_note "--speedtest 是预留选项，当前不会自动运行第三方 speedtest。"
  fi
}

main() {
  parse_args "$@"
  progress "启动 BBR Auto Tune v$VERSION"
  progress "检测系统平台"
  detect_platform

  if [ "$ROLLBACK" -eq 1 ]; then
    progress "执行回滚"
    rollback_config
    exit $?
  fi

  progress "检查检测工具是否齐全"
  ensure_detection_tools
  progress "检测 CPU、内存、虚拟化环境"
  detect_system
  progress "检测公网 IP、ASN、地理位置"
  detect_public_network
  progress "检测默认网卡、MTU、qdisc、网卡速率"
  detect_interface
  progress "检测当前 TCP 拥塞控制和 BBR 可用性"
  detect_tcp_state
  progress "开始链路质量探测"
  measure_paths
  progress "根据 BDP、丢包、内存、并发计算推荐参数"
  calculate_recommendations
  progress "计算完成: RTT=${EFFECTIVE_RTT_MS}ms loss=${EFFECTIVE_LOSS_PERCENT}% buffer=${RECOMMENDED_BUFFER_MB}MB"

  if [ "$SHOW_CONFIG" -eq 1 ]; then
    progress "输出 sysctl 配置"
    generate_config
  elif [ "$JSON" -eq 1 ]; then
    progress "输出 JSON 报告"
    print_json
  else
    progress "输出人类可读报告"
    print_report
  fi

  if [ "$APPLY" -eq 1 ]; then
    apply_config
  fi

  progress "全部完成"
}

main "$@"
