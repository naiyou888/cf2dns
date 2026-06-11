#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/etc/heki"
PANEL_A="${BASE_DIR}/panel-a/blockList"
PANEL_B="${BASE_DIR}/panel-b/blockList"
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

if ! command -v docker >/dev/null 2>&1; then
echo "[ERROR] 未安装 Docker。"
exit 1
fi

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

sed -i 
-e 's/\r$//' 
-e 's/[[:space:]]+$//' 
-e '/^[[:space:]]*$/d' 
"${TMP_FILE}"

if [[ ! -s "${TMP_FILE}" ]]; then
echo "[ERROR] 规则文件为空。"
exit 1
fi

for rule in 
"geoip:private" 
"port:25" 
"geosite:category-pt" 
"domain:gov.cn"
do
if ! grep -Fqx "${rule}" "${TMP_FILE}"; then
echo "[ERROR] 缺少必要规则：${rule}"
exit 1
fi
done

mkdir -p 
"${BASE_DIR}/panel-a" 
"${BASE_DIR}/panel-b"

cd "${BASE_DIR}"

echo "[INFO] 检查 Docker Compose 配置……"
docker compose config -q

if [[ -f "${PANEL_A}" ]] &&
[[ -f "${PANEL_B}" ]] &&
cmp -s "${TMP_FILE}" "${PANEL_A}" &&
cmp -s "${TMP_FILE}" "${PANEL_B}"; then

```
echo "[INFO] 当前规则没有变化，无需重启。"
docker compose ps
exit 0
```

fi

install -m 0644 "${TMP_FILE}" "${PANEL_A}.new"
install -m 0644 "${TMP_FILE}" "${PANEL_B}.new"

mv -f "${PANEL_A}.new" "${PANEL_A}"
mv -f "${PANEL_B}.new" "${PANEL_B}"

if ! cmp -s "${PANEL_A}" "${PANEL_B}"; then
echo "[ERROR] Panel-A 和 Panel-B 规则不一致。"
exit 1
fi

echo "[INFO] 已覆盖：${PANEL_A}"
echo "[INFO] 已覆盖：${PANEL_B}"

echo "[INFO] 正在重启 Heki……"
docker compose restart

sleep 3

echo
echo "========== 容器状态 =========="
docker compose ps

echo
echo "========== 规则检查 =========="
grep -E 
'^(geoip:private|port:25|geosite:category-pt|domain:gov.cn)$' 
"${PANEL_A}"

echo
echo "========== 最近错误日志 =========="
docker compose logs --since=2m --tail=300 2>&1 |
grep -Ei 
'failed|invalid|unknown geosite|unknown geoip|parse error|syntax error|fatal|panic' 
|| true

echo
echo "========================================"
echo "[SUCCESS] Heki blockList 已部署完成"
echo "规则数量：$(wc -l < "${PANEL_A}")"
echo "========================================"
