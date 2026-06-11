#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/heki"
PANEL_A="/etc/heki/panel-a/blockList"
PANEL_B="/etc/heki/panel-b/blockList"
TMP_FILE="/tmp/heki-blockList"

if [ "$(id -u)" -ne 0 ]; then
echo "[ERROR] 请使用 root 用户运行"
exit 1
fi

if [ ! -d "$BASE_DIR" ]; then
echo "[ERROR] 目录不存在：$BASE_DIR"
exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
echo "[ERROR] 未安装 Docker"
exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
echo "[ERROR] docker compose 不可用"
exit 1
fi

cat > "$TMP_FILE" <<'EOF'
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

sed -i 's/\r$//' "$TMP_FILE"
sed -i '/^[[:space:]]*$/d' "$TMP_FILE"

if [ ! -s "$TMP_FILE" ]; then
echo "[ERROR] 规则文件为空"
exit 1
fi

grep -Fqx 'geoip:private' "$TMP_FILE"
grep -Fqx 'port:25' "$TMP_FILE"
grep -Fqx 'geosite:category-pt' "$TMP_FILE"
grep -Fqx 'domain:gov.cn' "$TMP_FILE"

mkdir -p /etc/heki/panel-a
mkdir -p /etc/heki/panel-b

cd "$BASE_DIR"

echo "[INFO] 检查 Docker Compose 配置"
docker compose config -q

install -m 0644 "$TMP_FILE" "$PANEL_A"
install -m 0644 "$TMP_FILE" "$PANEL_B"

rm -f "$TMP_FILE"

echo "[INFO] 已替换两个 blockList"
echo "[INFO] 正在重启 Heki"

docker compose restart

echo
echo "========== 容器状态 =========="
docker compose ps

echo
echo "========== 文件一致性 =========="

if cmp -s "$PANEL_A" "$PANEL_B"; then
echo "[SUCCESS] Panel-A 与 Panel-B 规则一致"
else
echo "[ERROR] 两份规则文件不一致"
exit 1
fi

echo
echo "========== 关键规则 =========="
grep -E '^(geoip:private|port:25|geosite:category-pt|domain:gov.cn)$' "$PANEL_A"

echo
echo "[SUCCESS] Heki blockList 部署完成"
echo "规则数量：$(wc -l < "$PANEL_A")"
