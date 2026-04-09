#!/usr/bin/env bash
set -e

echo "==== 万金油网络优化（清理 + MTU + MSS + BBR）===="

# 获取默认网卡
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo "[+] 网卡: $IFACE"

# =====================
# 🧹 第一步：清理旧配置
# =====================

echo "[+] 清理旧配置..."

# 恢复 MTU 默认
ip link set dev $IFACE mtu 1500 || true

# 清理 MSS 规则（只动 mangle）
iptables -t mangle -F || true

# 删除旧 sysctl 优化
rm -f /etc/sysctl.d/*bbr*.conf 2>/dev/null || true
rm -f /etc/sysctl.d/*net*.conf 2>/dev/null || true

# 清理旧 qdisc
tc qdisc del dev $IFACE root 2>/dev/null || true

# 应用默认参数
sysctl --system > /dev/null

echo "[+] 清理完成"

# =====================
# 📡 第二步：多目标 MTU 探测
# =====================

TARGETS=(
    "1.1.1.1"
    "8.8.8.8"
    "9.9.9.9"
)

probe_mtu() {
    local TARGET=$1
    local MIN=1200
    local MAX=1500
    local BEST=1400

    while [ $MIN -le $MAX ]; do
        MID=$(( (MIN + MAX) / 2 ))
        if ping -c 1 -W 1 -M do -s $((MID-28)) $TARGET > /dev/null 2>&1; then
            BEST=$MID
            MIN=$((MID + 1))
        else
            MAX=$((MID - 1))
        fi
    done

    echo $BEST
}

echo "[+] 开始 MTU 探测..."

RESULTS=()

for T in "${TARGETS[@]}"; do
    echo "    -> 测试 $T"
    MTU=$(probe_mtu $T)

    if [ "$MTU" -ge 1300 ]; then
        RESULTS+=($MTU)
        echo "       MTU=$MTU"
    else
        echo "       MTU异常($MTU)，忽略"
    fi
done

# fallback
if [ ${#RESULTS[@]} -eq 0 ]; then
    echo "[!] 探测失败，使用默认 MTU 1400"
    BEST_MTU=1400
else
    BEST_MTU=$(printf "%s\n" "${RESULTS[@]}" | sort -n | head -n1)
fi

echo "[+] 最终 MTU: $BEST_MTU"

# 设置 MTU
ip link set dev $IFACE mtu $BEST_MTU

# =====================
# ⚙️ 第三步：MSS 优化
# =====================

MSS=$((BEST_MTU - 40))
echo "[+] MSS: $MSS"

iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o $IFACE -j TCPMSS --set-mss $MSS

echo "[+] MSS 已设置"

# =====================
# 🚀 第四步：BBR + 自动MTU修复
# =====================

cat > /etc/sysctl.d/99-auto-net.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_mtu_probe_floor=552

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
EOF

sysctl --system > /dev/null

# =====================
# 📊 第五步：结果输出
# =====================

echo "==== 当前状态 ===="
ip link show $IFACE | grep mtu
sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'

echo "==== 完成（稳定万金油版）===="
