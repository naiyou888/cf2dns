```bash
#!/usr/bin/env bash
# =====================================================================
# Heki blockList 最终保守生产版
# 目标：基础安全、低误伤、自动备份、失败回滚、不升级镜像
# =====================================================================

set -Eeuo pipefail

BASE_DIR="/etc/heki"

TARGETS=(
    "/etc/heki/panel-a/blockList"
    "/etc/heki/panel-b/blockList"
)

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TMP_FILE="$(mktemp /tmp/heki-blockList.XXXXXX)"

declare -A HAD_ORIGINAL
DEPLOYED=0

cleanup() {
    rm -f "${TMP_FILE}"
}

trap cleanup EXIT

# ---------------------------------------------------------------------
# 1. 检查必要命令
# ---------------------------------------------------------------------

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

# ---------------------------------------------------------------------
# 2. 写入最终低误伤规则
# ---------------------------------------------------------------------

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

# 去除空白行和行尾空格，避免解析器兼容问题
sed -i \
    -e 's/[[:space:]]\+$//' \
    -e '/^[[:space:]]*$/d' \
    "${TMP_FILE}"

# ---------------------------------------------------------------------
# 3. 本地静态检查
# ---------------------------------------------------------------------

if [[ ! -s "${TMP_FILE}" ]]; then
    echo "[ERROR] 生成的 blockList 为空。"
    exit 1
fi

if ! grep -qx 'geoip:private' "${TMP_FILE}"; then
    echo "[ERROR] 缺少 geoip:private。"
    exit 1
fi

if ! grep -qx 'port:25' "${TMP_FILE}"; then
    echo "[ERROR] 缺少 SMTP 25 端口规则。"
    exit 1
fi

if ! grep -qx 'domain:gov.cn' "${TMP_FILE}"; then
    echo "[ERROR] 缺少 gov.cn 规则。"
    exit 1
fi

if ! grep -qx 'geosite:category-pt' "${TMP_FILE}"; then
    echo "[ERROR] 缺少 PT 分类规则。"
    exit 1
fi

DUPLICATES="$(
    sort "${TMP_FILE}" |
    uniq -d
)"

if [[ -n "${DUPLICATES}" ]]; then
    echo "[ERROR] blockList 存在重复规则："
    echo "${DUPLICATES}"
    exit 1
fi

# 禁止重新混入高误伤或无效裸关键词
if grep -Eiq \
    '^(torrent|stratum|Subject|HELO|SMTP|nmap|masscan|sqlmap|metasploit|hydra)$' \
    "${TMP_FILE}"; then

    echo "[ERROR] 检测到不应存在的裸关键词。"
    exit 1
fi

# ---------------------------------------------------------------------
# 4. 创建目标目录并验证 Compose 配置
# ---------------------------------------------------------------------

mkdir -p \
    "${BASE_DIR}/panel-a" \
    "${BASE_DIR}/panel-b"

if [[ ! -d "${BASE_DIR}" ]]; then
    echo "[ERROR] Heki 工作目录不存在：${BASE_DIR}"
    exit 1
fi

cd "${BASE_DIR}"

echo "[INFO] 正在验证 Docker Compose 配置格式……"
docker compose config -q

# ---------------------------------------------------------------------
# 5. 内容没有变化时直接退出
# ---------------------------------------------------------------------

UNCHANGED=1

for target in "${TARGETS[@]}"; do
    if [[ ! -f "${target}" ]] || ! cmp -s "${TMP_FILE}" "${target}"; then
        UNCHANGED=0
        break
    fi
done

if [[ "${UNCHANGED}" -eq 1 ]]; then
    echo "[INFO] 当前 blockList 已经是最终版本，无需覆盖或重启。"
    echo "[INFO] 规则数量：$(wc -l < "${TMP_FILE}")"
    exit 0
fi

# ---------------------------------------------------------------------
# 6. 备份当前规则
# ---------------------------------------------------------------------

for target in "${TARGETS[@]}"; do
    if [[ -f "${target}" ]]; then
        HAD_ORIGINAL["${target}"]=1
        cp -a "${target}" "${target}.bak.${TIMESTAMP}"
        echo "[INFO] 已备份：${target}.bak.${TIMESTAMP}"
    else
        HAD_ORIGINAL["${target}"]=0
        echo "[WARN] 原文件不存在，将初始化创建：${target}"
    fi
done

# ---------------------------------------------------------------------
# 7. 部署失败自动回滚
# ---------------------------------------------------------------------

rollback() {
    local exit_code=$?

    trap - ERR
    set +e

    if [[ "${DEPLOYED}" -eq 1 ]]; then
        echo "[ERROR] 部署或服务检查失败，正在自动回滚……"

        for target in "${TARGETS[@]}"; do
            if [[ "${HAD_ORIGINAL[${target}]:-0}" -eq 1 ]] &&
               [[ -f "${target}.bak.${TIMESTAMP}" ]]; then

                cp -a "${target}.bak.${TIMESTAMP}" "${target}"
                echo "[INFO] 已恢复：${target}"
            else
                rm -f "${target}"
                echo "[INFO] 已移除本次新建文件：${target}"
            fi
        done

        cd "${BASE_DIR}" || true
        docker compose restart || true

        echo "[ERROR] 回滚完成，请检查："
        echo "        docker compose ps"
        echo "        docker compose logs --since=10m"
    fi

    exit "${exit_code}"
}

trap rollback ERR

# ---------------------------------------------------------------------
# 8. 同目录写入并原子替换
# ---------------------------------------------------------------------

for target in "${TARGETS[@]}"; do
    install -m 0644 "${TMP_FILE}" "${target}.new"
    mv -f "${target}.new" "${target}"
    echo "[INFO] 已部署：${target}"
done

DEPLOYED=1

# 确保两份规则完全一致
if ! cmp -s "${TARGETS[0]}" "${TARGETS[1]}"; then
    echo "[ERROR] Panel-A 与 Panel-B 的规则不一致。"
    false
fi

# ---------------------------------------------------------------------
# 9. 重启服务
# ---------------------------------------------------------------------

echo "[INFO] 正在重启 Heki 服务……"
docker compose restart

# ---------------------------------------------------------------------
# 10. 等待容器恢复运行
# ---------------------------------------------------------------------

ALL_RUNNING=0

for _ in $(seq 1 15); do
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
    false
fi

# ---------------------------------------------------------------------
# 11. 检查容器健康状态
# ---------------------------------------------------------------------

for container_id in "${CONTAINER_IDS[@]}"; do
    health_status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${container_id}" 2>/dev/null || echo unknown
    )"

    if [[ "${health_status}" == "unhealthy" ]]; then
        echo "[ERROR] 容器健康检查失败：${container_id}"
        false
    fi
done

# ---------------------------------------------------------------------
# 12. 检查加载日志
# ---------------------------------------------------------------------

echo "[INFO] 正在检查最近的配置加载日志……"

LOG_OUTPUT="$(
    docker compose logs \
        --since=90s \
        --tail=1000 \
        2>&1 || true
)"

ERROR_PATTERN='failed to load.*(block|geo|config)|invalid (geosite|geoip)|unknown (geosite|geoip)|parse error|syntax error|configuration error|fatal|panic'

if grep -Eiq "${ERROR_PATTERN}" <<< "${LOG_OUTPUT}"; then
    echo "[ERROR] 检测到疑似规则或配置加载错误："

    grep -Ei "${ERROR_PATTERN}" <<< "${LOG_OUTPUT}" |
        tail -100

    false
fi

# ---------------------------------------------------------------------
# 13. 部署成功
# ---------------------------------------------------------------------

trap - ERR
DEPLOYED=0

echo
echo "============================================================"
echo "[SUCCESS] Heki blockList 最终保守版部署完成"
echo "============================================================"
echo "备份时间戳：${TIMESTAMP}"
echo "规则数量：$(wc -l < "${TMP_FILE}")"
echo
echo "当前未屏蔽："
echo "  银行、银联、支付宝、微信支付、PayPal"
echo "  外汇平台、TradingView、游戏充值网站"
echo "  BBC、纽约时报、RFA、VOA 等普通新闻媒体"
echo "  Shodan、FOFA、Nmap 等安全研究网站"
echo "  Tor 官网、矿池官网、临时邮箱、广告域名"
echo
echo "当前主要屏蔽："
echo "  私网、链路本地、云元数据及不可公开路由地址"
echo "  出站 SMTP 目标端口 25"
echo "  PT 站点及迅雷核心域名"
echo "  中国大陆 GOV、反诈、举报及网警相关域名"
echo "  明确列入政策范围的相关站点"
echo
docker compose ps
```
