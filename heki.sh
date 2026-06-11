```bash
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/etc/heki"
TARGETS=(
    "/etc/heki/panel-a/blockList"
    "/etc/heki/panel-b/blockList"
)

TMP_FILE="$(mktemp /tmp/heki-blockList.XXXXXX)"

cleanup() {
    rm -f "${TMP_FILE}"
}

trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] 请使用 root 用户运行。"
    exit 1
fi

if [[ ! -d "${BASE_DIR}" ]]; then
    echo "[ERROR] Heki 目录不存在：${BASE_DIR}"
    exit 1
fi

for command_name in docker install cmp mktemp sed sort uniq grep; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "[ERROR] 缺少必要命令：${command_name}"
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    echo "[ERROR] 当前环境无法使用 docker compose。"
    exit 1
fi

cat > "${TMP_FILE}" <<'EOF'
geoip:private
ip:100.64.0.0/10
ip:169.254.0.0/16
ip:198.18.0.0/15
ip:224.0.0.0/4
ip:240.0.0.0/4
ip:ff00::/8
domain:localhost
domain:metadata.google.internal
domain:instance-data.ec2.internal
port:25
geosite:category-pt
domain:xunlei.com
domain:thunderurl.com
domain:sandai.net
domain:gov.cn
domain:cyberpolice.cn
domain:anti-fraud.com.cn
domain:fncsc.org.cn
domain:12377.cn
domain:12315.cn
domain:12321.cn
domain:110.qq.com
domain:falundafa.org
domain:falungong.org
domain:minghui.org
domain:zhengjian.org
domain:epochtimes.com
domain:dajiyuan.com
domain:ntdtv.com
domain:soundofhope.org
domain:mhradio.org
domain:renminbao.com
domain:dongtaiwang.com
domain:wujieliulan.com
domain:tuidang.org
domain:zhuichaguoji.org
domain:epochweekly.com
domain:xinsheng.net
domain:dafahao.com
EOF

# 清除空行、行尾空格和可能存在的 Windows 回车符
sed -i \
    -e 's/\r$//' \
    -e 's/[[:space:]]\+$//' \
    -e '/^[[:space:]]*$/d' \
    "${TMP_FILE}"

if [[ ! -s "${TMP_FILE}" ]]; then
    echo "[ERROR] 生成的 blockList 为空。"
    exit 1
fi

for required_rule in \
    "geoip:private" \
    "port:25" \
    "geosite:category-pt" \
    "domain:gov.cn"; do

    if ! grep -Fqx "${required_rule}" "${TMP_FILE}"; then
        echo "[ERROR] 缺少必要规则：${required_rule}"
        exit 1
    fi
done

DUPLICATES="$(sort "${TMP_FILE}" | uniq -d)"

if [[ -n "${DUPLICATES}" ]]; then
    echo "[ERROR] 存在重复规则："
    echo "${DUPLICATES}"
    exit 1
fi

if grep -Eiq \
    '^(torrent|stratum|subject|helo|smtp|nmap|masscan|sqlmap|metasploit|hydra)$' \
    "${TMP_FILE}"; then

    echo "[ERROR] 检测到高误伤或无效的裸关键词。"
    exit 1
fi

mkdir -p \
    "${BASE_DIR}/panel-a" \
    "${BASE_DIR}/panel-b"

cd "${BASE_DIR}"

echo "[INFO] 检查 Docker Compose 配置……"
docker compose config -q

UNCHANGED=1

for target in "${TARGETS[@]}"; do
    if [[ ! -f "${target}" ]] || ! cmp -s "${TMP_FILE}" "${target}"; then
        UNCHANGED=0
        break
    fi
done

if [[ "${UNCHANGED}" -eq 1 ]]; then
    echo "[INFO] 当前规则没有变化，无需重启。"
    echo "[INFO] 规则数量：$(wc -l < "${TMP_FILE}")"
    exit 0
fi

# 先写入同目录临时文件，再原子替换
for target in "${TARGETS[@]}"; do
    install -m 0644 "${TMP_FILE}" "${target}.new"
done

for target in "${TARGETS[@]}"; do
    mv -f "${target}.new" "${target}"
    echo "[INFO] 已覆盖：${target}"
done

if ! cmp -s "${TARGETS[0]}" "${TARGETS[1]}"; then
    echo "[ERROR] Panel-A 与 Panel-B 的规则不一致。"
    exit 1
fi

echo "[INFO] 正在重启 Heki 服务……"
docker compose restart

ALL_RUNNING=0

for ((attempt = 1; attempt <= 15; attempt++)); do
    mapfile -t CONTAINER_IDS < <(docker compose ps -q)

    if [[ "${#CONTAINER_IDS[@]}" -eq 0 ]]; then
        sleep 2
        continue
    fi

    ALL_RUNNING=1

    for container_id in "${CONTAINER_IDS[@]}"; do
        running="$(
            docker inspect \
                --format '{{.State.Running}}' \
                "${container_id}" 2>/dev/null || echo false
        )"

        if [[ "${running}" != "true" ]]; then
            ALL_RUNNING=0
            break
        fi
    done

    if [[ "${ALL_RUNNING}" -eq 1 ]]; then
        break
    fi

    sleep 2
done

if [[ "${ALL_RUNNING}" -ne 1 ]]; then
    echo "[ERROR] 重启后存在未正常运行的容器。"
    docker compose ps || true
    exit 1
fi

for container_id in "${CONTAINER_IDS[@]}"; do
    health_status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${container_id}" 2>/dev/null || echo unknown
    )"

    if [[ "${health_status}" == "unhealthy" ]]; then
        echo "[ERROR] 容器健康检查失败：${container_id}"
        exit 1
    fi
done

echo "[INFO] 正在检查最近日志……"

LOG_OUTPUT="$(
    docker compose logs \
        --since=90s \
        --tail=1000 \
        2>&1 || true
)"

ERROR_PATTERN='failed to load.*(block|geo|config)|invalid (geosite|geoip)|unknown (geosite|geoip)|parse error|syntax error|configuration error|fatal|panic'

if grep -Eiq "${ERROR_PATTERN}" <<< "${LOG_OUTPUT}"; then
    echo "[ERROR] 检测到疑似配置加载错误："

    grep -Ei "${ERROR_PATTERN}" <<< "${LOG_OUTPUT}" |
        tail -100

    echo
    echo "[WARN] 本脚本未创建备份，无法自动恢复旧 blockList。"
    exit 1
fi

echo
echo "============================================================"
echo "[SUCCESS] Heki blockList 已部署完成"
echo "============================================================"
echo "规则数量：$(wc -l < "${TMP_FILE}")"
echo

docker compose ps
```
