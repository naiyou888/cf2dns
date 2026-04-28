#!/usr/bin/env bash
# Landing Server BBR/TCP Auto Optimizer
# Generic Debian/Ubuntu Linux TCP tuning script for TCP landing/proxy servers.
# Default behavior: auto-detect and apply recommended BBR/fq sysctl settings.

set -Eeuo pipefail

VERSION="2026.04.28-final"

CONF_FILE="/etc/sysctl.d/99-landing-bbr-auto.conf"
LIMITS_FILE="/etc/security/limits.d/99-landing-bbr-nofile.conf"
SYSTEMD_MANAGER_DIR="/etc/systemd/system.conf.d"
SYSTEMD_MANAGER_FILE="${SYSTEMD_MANAGER_DIR}/99-landing-bbr-nofile.conf"
BACKUP_ROOT="/var/backups/landing-bbr-auto"

MODE="apply"
PROFILE="auto"
APPLY_TC=1
FORCE_TC=0
ROLLBACK=0
INSTALL_DEPS=1
LINK_MBPS="${LINK_MBPS:-}"
RTT_MS="${RTT_MS:-180}"
NET_STABLE="${NET_STABLE:-auto}"

MiB=$((1024 * 1024))
GiB=$((1024 * 1024 * 1024))

SYSCTL_LINES=()
WARNINGS=()
SKIPPED_KEYS=()

log() { printf '[landing-bbr-auto] %s\n' "$*"; }
warn() { WARNINGS+=("$*"); }

usage() {
  cat <<USAGE
Landing Server BBR/TCP Auto Optimizer v${VERSION}

Default behavior with no args: auto-detect and APPLY recommended settings.

Usage:
  sudo bash landing-bbr-auto.sh
  sudo bash landing-bbr-auto.sh --dry-run
  sudo bash landing-bbr-auto.sh --rollback

Options:
  --dry-run                         Preview only, do not apply.
  --apply                           Apply settings. This is the default.
  --no-tc                           Do not immediately replace current NIC qdisc.
  --force-tc                        Force qdisc replacement even if current qdisc looks custom.
  --rollback                        Restore latest backup made by this script.
  --profile auto|safe|balanced|aggressive
                                    Default: auto.
  --link-mbps N                     Override detected link speed. Useful on VPS.
  --rtt-ms N                        RTT assumption for TCP buffer sizing. Default: 180.
  --net-stable auto|0|1             1 = stable network, tcp_slow_start_after_idle=0.
                                    0 = unstable network, tcp_slow_start_after_idle=1.
  --no-install-deps                 Do not install missing Debian/Ubuntu helper packages.
  -h, --help

GitHub one-liner examples:
  curl -fsSL RAW_GITHUB_URL | sudo bash
  curl -fsSL RAW_GITHUB_URL | sudo bash -s -- --dry-run
  curl -fsSL RAW_GITHUB_URL | sudo bash -s -- --rollback
USAGE
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: this action requires root. Use sudo." >&2
    exit 1
  fi
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
max() { (( $1 > $2 )) && echo "$1" || echo "$2"; }
min() { (( $1 < $2 )) && echo "$1" || echo "$2"; }

clamp() {
  local val="$1" lo="$2" hi="$3"
  if (( val < lo )); then
    echo "$lo"
  elif (( val > hi )); then
    echo "$hi"
  else
    echo "$val"
  fi
}

human_bytes() {
  local b="$1"
  if (( b >= GiB )); then
    printf '%dG' $((b / GiB))
  elif (( b >= MiB )); then
    printf '%dM' $((b / MiB))
  else
    printf '%dK' $((b / 1024))
  fi
}

sysctl_path() { printf '/proc/sys/%s' "${1//./\/}"; }
sysctl_exists() { [[ -e "$(sysctl_path "$1")" ]]; }

add_sysctl() {
  local key="$1" value="$2"
  if sysctl_exists "$key"; then
    SYSCTL_LINES+=("$key = $value")
  else
    SKIPPED_KEYS+=("$key")
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --no-tc) APPLY_TC=0; shift ;;
    --force-tc) FORCE_TC=1; APPLY_TC=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --link-mbps) LINK_MBPS="${2:-}"; shift 2 ;;
    --rtt-ms) RTT_MS="${2:-}"; shift 2 ;;
    --net-stable) NET_STABLE="${2:-}"; shift 2 ;;
    --no-install-deps) INSTALL_DEPS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! "$PROFILE" =~ ^(auto|safe|balanced|aggressive)$ ]]; then
  echo "ERROR: --profile must be auto, safe, balanced, or aggressive." >&2
  exit 1
fi
if ! is_int "$RTT_MS" || (( RTT_MS < 1 )); then
  echo "ERROR: --rtt-ms must be a positive integer." >&2
  exit 1
fi
if [[ -n "$LINK_MBPS" ]] && ! is_int "$LINK_MBPS"; then
  echo "ERROR: --link-mbps must be an integer." >&2
  exit 1
fi
if [[ ! "$NET_STABLE" =~ ^(auto|0|1)$ ]]; then
  echo "ERROR: --net-stable must be auto, 0, or 1." >&2
  exit 1
fi

read_os_field() {
  local field="$1"
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "$field" in
      pretty) printf '%s' "${PRETTY_NAME:-${ID:-unknown}}" ;;
      id) printf '%s' "${ID:-unknown}" ;;
      version) printf '%s' "${VERSION_ID:-}" ;;
      *) printf 'unknown' ;;
    esac
  else
    printf 'unknown'
  fi
}

OS_NAME="$(read_os_field pretty)"
OS_ID="$(read_os_field id)"

install_deps_if_needed() {
  (( INSTALL_DEPS == 1 )) || return 0
  [[ "$MODE" == "apply" ]] || return 0
  [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" ]] || return 0

  local missing=() cmd pkg

  for cmd in ip tc sysctl modprobe ping; do
    if command -v "$cmd" >/dev/null 2>&1; then
      continue
    fi

    case "$cmd" in
      ip|tc) pkg="iproute2" ;;
      sysctl) pkg="procps" ;;
      modprobe) pkg="kmod" ;;
      ping) pkg="iputils-ping" ;;
      *) pkg="" ;;
    esac

    [[ -n "$pkg" ]] || continue
    [[ " ${missing[*]} " == *" $pkg "* ]] || missing+=("$pkg")
  done

  if ((${#missing[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    log "installing missing packages: ${missing[*]}"
    apt-get update -y >/dev/null
    apt-get install -y "${missing[@]}" >/dev/null
  fi
}

detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt 2>/dev/null || true
  else
    printf 'unknown'
  fi
}

kernel_ge() {
  local want_major="$1" want_minor="$2" raw major minor
  raw="$(uname -r)"
  major="${raw%%.*}"
  minor="${raw#*.}"
  minor="${minor%%.*}"
  minor="${minor%%-*}"
  is_int "$major" || major=0
  is_int "$minor" || minor=0
  (( major > want_major || (major == want_major && minor >= want_minor) ))
}

detect_default_iface() {
  local iface=""
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -z "$iface" ]]; then
      iface="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
  fi
  printf '%s' "${iface:-unknown}"
}

detect_link_mbps() {
  local iface="$1" speed=""

  if [[ -n "$LINK_MBPS" ]]; then
    printf '%s' "$LINK_MBPS"
    return
  fi

  if [[ "$iface" != "unknown" && -r "/sys/class/net/${iface}/speed" ]]; then
    speed="$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)"
    if is_int "$speed" && (( speed > 0 && speed < 1000000 )); then
      printf '%s' "$speed"
      return
    fi
  fi

  warn "无法读取网卡速率，按 1000 Mbps 估算。VPS 常见，可用 --link-mbps 覆盖。"
  printf '1000'
}

detect_qdisc_now() {
  local iface="$1"
  if command -v tc >/dev/null 2>&1 && [[ "$iface" != "unknown" ]]; then
    tc qdisc show dev "$iface" 2>/dev/null | head -n 1 || true
  fi
}

qdisc_is_safe_to_replace() {
  local q="$1"
  [[ -z "$q" ]] && return 0
  [[ "$q" == *"fq "* ]] && return 0
  [[ "$q" == *"fq_codel"* ]] && return 0
  [[ "$q" == *"pfifo_fast"* ]] && return 0
  [[ "$q" == *"noqueue"* ]] && return 0
  [[ "$q" == *"mq "* ]] && return 0
  return 1
}

qdisc_available_fq() {
  modprobe sch_fq >/dev/null 2>&1 || true
  if [[ -d /sys/module/sch_fq ]]; then
    return 0
  fi
  if command -v modinfo >/dev/null 2>&1 && modinfo sch_fq >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

detect_congestion_control() {
  local avail cc

  modprobe tcp_bbr >/dev/null 2>&1 || true
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  for cc in bbr3 bbr2 bbr; do
    if [[ " $avail " == *" $cc "* ]]; then
      printf '%s' "$cc"
      return
    fi
  done

  if [[ " $avail " == *" cubic "* ]]; then
    warn "当前内核没有 bbr/bbr2/bbr3，回退 cubic。建议使用 Debian/Ubuntu 官方新内核后再运行。"
    printf 'cubic'
    return
  fi

  warn "无法读取 tcp_available_congestion_control，保留系统默认拥塞控制。"
  printf ''
}

detect_net_stable() {
  if [[ "$NET_STABLE" == "0" || "$NET_STABLE" == "1" ]]; then
    printf '%s' "$NET_STABLE"
    return
  fi

  if ! command -v ping >/dev/null 2>&1; then
    warn "未找到 ping，无法探测丢包，默认按稳定网络处理。"
    printf '1'
    return
  fi

  local out loss loss_int
  out="$(ping -c 5 -W 1 1.1.1.1 2>/dev/null || true)"
  loss="$(printf '%s\n' "$out" | awk -F',' '/packet loss/ {gsub(/% packet loss/,"",$3); gsub(/ /,"",$3); print $3; exit}')"
  loss_int="${loss%%.*}"

  if is_int "$loss_int" && (( loss_int >= 1 )); then
    warn "探测到 ping 丢包约 ${loss}%，tcp_slow_start_after_idle 将设为 1。"
    printf '0'
  else
    printf '1'
  fi
}

choose_profile() {
  local mem_mb="$1" cpu="$2" link_mbps="$3"

  if [[ "$PROFILE" != "auto" ]]; then
    printf '%s' "$PROFILE"
    return
  fi

  if (( mem_mb < 1024 || cpu <= 1 )); then
    printf 'safe'
  elif (( mem_mb >= 8192 && cpu >= 4 && link_mbps >= 1000 )); then
    printf 'aggressive'
  else
    printf 'balanced'
  fi
}

make_backup() {
  local now dir line key value
  now="$(date +%Y%m%d-%H%M%S)"
  dir="${BACKUP_ROOT}/${now}"
  mkdir -p "$dir"

  [[ -f "$CONF_FILE" ]] && cp -a "$CONF_FILE" "$dir/sysctl.conf.bak" || : > "$dir/sysctl.conf.absent"
  [[ -f "$LIMITS_FILE" ]] && cp -a "$LIMITS_FILE" "$dir/limits.conf.bak" || : > "$dir/limits.conf.absent"
  [[ -f "$SYSTEMD_MANAGER_FILE" ]] && cp -a "$SYSTEMD_MANAGER_FILE" "$dir/systemd-manager.conf.bak" || : > "$dir/systemd-manager.conf.absent"

  : > "$dir/sysctl-values.tsv"
  for line in "${SYSCTL_LINES[@]}"; do
    key="${line%% = *}"
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    printf '%s\t%s\n' "$key" "$value" >> "$dir/sysctl-values.tsv"
  done

  ln -sfn "$dir" "$BACKUP_ROOT/latest"
  log "backup saved: $dir"
}

rollback() {
  need_root

  local dir="$BACKUP_ROOT/latest" key value

  if [[ ! -e "$dir" ]]; then
    echo "ERROR: no backup found at $dir" >&2
    exit 1
  fi

  dir="$(readlink -f "$dir")"

  if [[ -f "$dir/sysctl.conf.bak" ]]; then
    cp -a "$dir/sysctl.conf.bak" "$CONF_FILE"
  else
    rm -f "$CONF_FILE"
  fi

  if [[ -f "$dir/limits.conf.bak" ]]; then
    cp -a "$dir/limits.conf.bak" "$LIMITS_FILE"
  else
    rm -f "$LIMITS_FILE"
  fi

  if [[ -f "$dir/systemd-manager.conf.bak" ]]; then
    mkdir -p "$SYSTEMD_MANAGER_DIR"
    cp -a "$dir/systemd-manager.conf.bak" "$SYSTEMD_MANAGER_FILE"
  else
    rm -f "$SYSTEMD_MANAGER_FILE"
  fi

  if [[ -f "$dir/sysctl-values.tsv" ]]; then
    while IFS=$'\t' read -r key value; do
      [[ -n "${key:-}" ]] || continue
      sysctl -w "$key=$value" >/dev/null 2>&1 || true
    done < "$dir/sysctl-values.tsv"
  fi

  sysctl --system >/dev/null 2>&1 || true
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true

  log "rollback completed from: $dir"
}

if (( ROLLBACK == 1 )); then
  rollback
  exit 0
fi

if [[ "$MODE" == "apply" ]]; then
  need_root
  install_deps_if_needed
fi

KERNEL="$(uname -r)"
VIRT_TYPE="$(detect_virt)"
MEM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_MB=$((MEM_KB / 1024))
MEM_BYTES=$((MEM_KB * 1024))
CPU_COUNT="$(command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN || echo 1)"
PAGE_SIZE="$(getconf PAGE_SIZE 2>/dev/null || echo 4096)"
IFACE="$(detect_default_iface)"
LINK_Mbps="$(detect_link_mbps "$IFACE")"
CURRENT_QDISC="$(detect_qdisc_now "$IFACE")"
CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
SELECTED_CC="$(detect_congestion_control)"
NET_IS_STABLE="$(detect_net_stable)"
SELECTED_PROFILE="$(choose_profile "$MEM_MB" "$CPU_COUNT" "$LINK_Mbps")"

case "$OS_ID" in
  debian|ubuntu) ;;
  *) warn "当前系统不是 Debian/Ubuntu：${OS_NAME}。脚本仍会按通用 Linux sysctl 方式尝试。" ;;
esac

case "$VIRT_TYPE" in
  openvz|lxc|docker|podman|container)
    warn "检测到容器/受限虚拟化：${VIRT_TYPE}。部分 sysctl 或 tc qdisc 可能无法应用。"
    ;;
esac

if [[ -n "$SELECTED_CC" && "$SELECTED_CC" == bbr* ]] && ! kernel_ge 4 9; then
  warn "内核版本低于 4.9，但检测到了 ${SELECTED_CC}。请确认是否为发行版回移植或自定义内核。"
fi

case "$SELECTED_PROFILE" in
  safe)
    PROFILE_BUF_CAP=$((8 * MiB))
    SOMAX=4096
    SYN_BACKLOG=4096
    NETDEV_BACKLOG=4096
    TCP_MEM_PCT=8
    NOFILE_TARGET=262144
    ;;
  balanced)
    PROFILE_BUF_CAP=$((32 * MiB))
    SOMAX=8192
    SYN_BACKLOG=8192
    NETDEV_BACKLOG=16384
    TCP_MEM_PCT=12
    NOFILE_TARGET=524288
    ;;
  aggressive)
    PROFILE_BUF_CAP=$((64 * MiB))
    SOMAX=16384
    SYN_BACKLOG=16384
    NETDEV_BACKLOG=32768
    TCP_MEM_PCT=16
    NOFILE_TARGET=1048576
    ;;
esac

# TCP buffer sizing:
# BDP = bandwidth * RTT. Use 2x BDP but cap by RAM/profile to avoid memory pressure.
BDP_BYTES=$(( LINK_Mbps * 1000000 / 8 * RTT_MS / 1000 ))
TARGET_BUF=$(( BDP_BYTES * 2 ))
RAM_BUF_CAP=$(( MEM_BYTES / 64 ))
RAM_BUF_CAP="$(max "$RAM_BUF_CAP" $((4 * MiB)))"
EFFECTIVE_BUF_CAP="$(min "$PROFILE_BUF_CAP" "$RAM_BUF_CAP")"
TCP_BUF_MAX="$(clamp "$TARGET_BUF" $((4 * MiB)) "$EFFECTIVE_BUF_CAP")"

RMEM_DEFAULT="$(clamp $((TCP_BUF_MAX / 16)) 131072 $((1 * MiB)))"
WMEM_DEFAULT="$(clamp $((TCP_BUF_MAX / 32)) 65536 $((1 * MiB)))"

TCP_MEM_MAX_PAGES=$(( MEM_BYTES * TCP_MEM_PCT / 100 / PAGE_SIZE ))
TCP_MEM_PRESSURE_PAGES=$(( TCP_MEM_MAX_PAGES * 3 / 4 ))
TCP_MEM_MIN_PAGES=$(( TCP_MEM_MAX_PAGES / 2 ))

CURRENT_FILE_MAX="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
CURRENT_NR_OPEN="$(sysctl -n fs.nr_open 2>/dev/null || echo 0)"
FILE_MAX_TARGET=$(( MEM_MB * 4096 ))
FILE_MAX_TARGET="$(clamp "$FILE_MAX_TARGET" 262144 8388608)"
FILE_MAX="$(max "$CURRENT_FILE_MAX" "$FILE_MAX_TARGET")"
NOFILE="$(max "$CURRENT_NR_OPEN" "$NOFILE_TARGET")"
NOFILE="$(clamp "$NOFILE" "$NOFILE_TARGET" 1048576)"

TW_BUCKETS="$(clamp $((MEM_MB * 1024)) 262144 2000000)"

if [[ "$NET_IS_STABLE" == "1" ]]; then
  SLOW_START_AFTER_IDLE=0
else
  SLOW_START_AFTER_IDLE=1
fi

if [[ "$SELECTED_CC" == bbr* ]]; then
  if qdisc_available_fq; then
    QDISC="fq"
  else
    QDISC="fq_codel"
    warn "未确认 sch_fq 可用，qdisc 回退 fq_codel。"
  fi
else
  QDISC="fq_codel"
fi

# Core BBR/fq
add_sysctl net.core.default_qdisc "$QDISC"
[[ -n "$SELECTED_CC" ]] && add_sysctl net.ipv4.tcp_congestion_control "$SELECTED_CC"

# Port range and TIME_WAIT handling
add_sysctl net.ipv4.ip_local_port_range "1024 65535"
add_sysctl net.ipv4.tcp_timestamps 1
add_sysctl net.ipv4.tcp_tw_reuse 1
add_sysctl net.ipv4.tcp_fin_timeout 15
add_sysctl net.ipv4.tcp_max_tw_buckets "$TW_BUCKETS"

# Queues and backlog
add_sysctl net.ipv4.tcp_max_syn_backlog "$SYN_BACKLOG"
add_sysctl net.core.somaxconn "$SOMAX"
add_sysctl net.core.netdev_max_backlog "$NETDEV_BACKLOG"
add_sysctl net.ipv4.tcp_abort_on_overflow 1
add_sysctl net.ipv4.tcp_syncookies 1

# TCP behavior
add_sysctl net.ipv4.tcp_slow_start_after_idle "$SLOW_START_AFTER_IDLE"
add_sysctl net.ipv4.tcp_mtu_probing 1
add_sysctl net.ipv4.tcp_sack 1
add_sysctl net.ipv4.tcp_window_scaling 1
add_sysctl net.ipv4.tcp_moderate_rcvbuf 1
add_sysctl net.ipv4.tcp_no_metrics_save 1

# Memory and file limits
add_sysctl vm.swappiness 10
add_sysctl fs.file-max "$FILE_MAX"
add_sysctl fs.nr_open "$NOFILE"

# TCP buffers
add_sysctl net.core.rmem_max "$TCP_BUF_MAX"
add_sysctl net.core.wmem_max "$TCP_BUF_MAX"
add_sysctl net.core.rmem_default "$RMEM_DEFAULT"
add_sysctl net.core.wmem_default "$WMEM_DEFAULT"
add_sysctl net.ipv4.tcp_mem "$TCP_MEM_MIN_PAGES $TCP_MEM_PRESSURE_PAGES $TCP_MEM_MAX_PAGES"
add_sysctl net.ipv4.tcp_rmem "4096 131072 $TCP_BUF_MAX"
add_sysctl net.ipv4.tcp_wmem "4096 65536 $TCP_BUF_MAX"

print_report() {
  echo
  echo "================ Landing BBR Auto Optimizer v${VERSION} ================"
  echo "Mode:                 ${MODE}"
  echo "OS:                   ${OS_NAME}"
  echo "Kernel:               ${KERNEL}"
  echo "Virt:                 ${VIRT_TYPE:-unknown}"
  echo "CPU/RAM:              ${CPU_COUNT} core(s), ${MEM_MB} MB"
  echo "Default iface:        ${IFACE}"
  echo "Link estimate:        ${LINK_Mbps} Mbps"
  echo "RTT assumption:       ${RTT_MS} ms"
  echo "Current CC:           ${CURRENT_CC:-unknown}"
  echo "Available CC:         ${AVAILABLE_CC:-unknown}"
  echo "Selected CC:          ${SELECTED_CC:-keep-current}"
  echo "Current qdisc:        ${CURRENT_QDISC:-unknown}"
  echo "Selected qdisc:       ${QDISC}"
  echo "Auto profile:         ${SELECTED_PROFILE}"
  echo "TCP buffer max:       $(human_bytes "$TCP_BUF_MAX")"
  echo "tcp_mem pages:        ${TCP_MEM_MIN_PAGES} ${TCP_MEM_PRESSURE_PAGES} ${TCP_MEM_MAX_PAGES}"
  echo "somaxconn/backlog:    ${SOMAX}/${SYN_BACKLOG}"
  echo "NOFILE target:        ${NOFILE}"

  if ((${#WARNINGS[@]})); then
    echo
    echo "================ Warnings ================"
    printf -- '- %s\n' "${WARNINGS[@]}"
  fi

  if ((${#SKIPPED_KEYS[@]})); then
    echo
    echo "================ Skipped unsupported sysctl keys ================"
    printf -- '- %s\n' "${SKIPPED_KEYS[@]}"
  fi

  echo
  echo "================ Generated sysctl ================"
  cat <<HEADER
# Generated by landing-bbr-auto.sh v${VERSION} on $(date -Is)
# Generic landing/proxy server TCP optimization
# OS=${OS_NAME}
# Kernel=${KERNEL}
# CPU=${CPU_COUNT}
# RAM=${MEM_MB}MB
# iface=${IFACE}
# link=${LINK_Mbps}Mbps
# rtt=${RTT_MS}ms
# profile=${SELECTED_PROFILE}
# selected_cc=${SELECTED_CC:-keep-current}
# qdisc=${QDISC}
HEADER
  printf '%s\n' "${SYSCTL_LINES[@]}"
}

write_files() {
  mkdir -p "$(dirname "$CONF_FILE")" "$(dirname "$LIMITS_FILE")" "$SYSTEMD_MANAGER_DIR"

  {
    cat <<HEADER
# Generated by landing-bbr-auto.sh v${VERSION} on $(date -Is)
# Generic landing/proxy server TCP optimization
# OS=${OS_NAME}
# Kernel=${KERNEL}
# CPU=${CPU_COUNT}
# RAM=${MEM_MB}MB
# iface=${IFACE}
# link=${LINK_Mbps}Mbps
# rtt=${RTT_MS}ms
# profile=${SELECTED_PROFILE}
# selected_cc=${SELECTED_CC:-keep-current}
# qdisc=${QDISC}
HEADER
    printf '%s\n' "${SYSCTL_LINES[@]}"
  } > "$CONF_FILE"

  cat > "$LIMITS_FILE" <<LIMITS
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
LIMITS

  cat > "$SYSTEMD_MANAGER_FILE" <<SYSTEMD
[Manager]
DefaultLimitNOFILE=${NOFILE}
SYSTEMD
}

apply_tc() {
  (( APPLY_TC == 1 )) || return 0

  if [[ "$IFACE" == "unknown" ]]; then
    warn "无法识别默认网卡，跳过 tc qdisc replace。"
    return 0
  fi
  if ! command -v tc >/dev/null 2>&1; then
    warn "未找到 tc，跳过 qdisc 即时替换。"
    return 0
  fi
  if (( FORCE_TC != 1 )) && ! qdisc_is_safe_to_replace "$CURRENT_QDISC"; then
    warn "当前 qdisc 看起来是自定义规则，已跳过替换：${CURRENT_QDISC}。如需强制替换，加 --force-tc。"
    return 0
  fi

  if tc qdisc replace dev "$IFACE" root "$QDISC"; then
    log "qdisc on ${IFACE} replaced with ${QDISC}"
  else
    warn "tc qdisc replace 失败，可能是 VPS/容器限制；sysctl 配置仍已写入。"
  fi
}

print_report

if [[ "$MODE" == "dry-run" ]]; then
  echo
  log "dry-run only. No changes made."
  exit 0
fi

make_backup
write_files

if sysctl -p "$CONF_FILE"; then
  log "sysctl applied: ${CONF_FILE}"
else
  warn "sysctl -p 返回错误，部分参数可能因内核/虚拟化限制未生效。"
fi

apply_tc

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

echo
log "applied. Config file: ${CONF_FILE}"
log "verify: sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc && tc qdisc show dev ${IFACE} && ss -s && free -m"
log "rollback: sudo bash landing-bbr-auto.sh --rollback"
