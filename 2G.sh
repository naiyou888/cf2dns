#!/usr/bin/env bash
set -e

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行"
   exit 1
fi

echo "==== 落地机深度优化（先清理后应用）===="

# 获取默认网卡
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo "[+] 目标网卡: $IFACE"

# =====================
# 🧹 第一步：深度清理旧规则
# =====================
echo "[+] 正在执行深度清理..."

# 1. 恢复 MTU 默认值（通常是 1500）以便重新探测
ip link set dev $IFACE mtu 1500 || true

# 2. 清理 IPTABLES 中的 MSS 钳制规则
# 查找所有包含 TCPMSS 的规则并删除，避免重复堆叠
while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1000:1500 2>/dev/null; do :; done
while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
# 或者直接重置 mangle 表（慎用，如果你有其他 mangle 规则）
# iptables -t mangle -F

# 3. 清理 sysctl 冲突项
# 删除可能干扰的子配置文件
rm -f /etc/sysctl.d/*bbr*.conf 2>/dev/null || true
rm -f /etc/sysctl.d/*net*.conf 2>/dev/null || true
rm -f /etc/sysctl.d/99-agressive-bbr.conf 2>/dev/null || true

# 4. 清理 /etc/sysctl.conf 中的旧参数（防止主文件干扰子文件）
sed -i '/net.core/d' /etc/sysctl.conf
sed -i '/net.ipv4/d' /etc/sysctl.conf
sed -i '/fs.file-max/d' /etc/sysctl.conf

# 应用一次默认系统参数
sysctl --system > /dev/null
echo "[+] 旧规则清理完成"

# =====================
# 📡 第二步：MTU 探测与锁定 (1480)
# =====================
TARGET="1.1.1.1"
echo "[+] 正在探测链路最佳 MTU..."

probe_mtu() {
    local MIN=1200
    local MAX=1480 
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

REAL_MTU=$(probe_mtu)
# 强制最终上限为 1480
[[ $REAL_MTU -gt 1480 ]] && FINAL_MTU=1480 || FINAL_MTU=$REAL_MTU

echo "[+] 最终设置 MTU: $FINAL_MTU"
ip link set dev $IFACE mtu $FINAL_MTU

# =====================
# ⚙️ 第三步：写入新 MSS 规则
# =====================
NEW_MSS=$((FINAL_MTU - 40))
echo "[+] 注入新 MSS 钳制: $NEW_MSS"
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o $IFACE -j TCPMSS --set-mss $NEW_MSS

# =====================
# 🚀 第四步：写入激进版 BBR 配置
# =====================
echo "[+] 应用激进版内核优化参数..."

cat > /etc/sysctl.d/99-agressive-bbr.conf <<EOF
# 文件句柄
fs.file-max=6553560
net.ipv4.ip_local_port_range=1024 65535

# Buffer 激进版 (64MB)
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2

# 队列优化
net.ipv4.tcp_max_syn_backlog=16384
net.core.somaxconn=65535
net.core.netdev_max_backlog=262144
net.ipv4.tcp_abort_on_overflow=0

# 连接回收
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# BBR 核心配置
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# MTU 自动探测
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_sack=1

# 协议栈优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0

# Keepalive
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF

sysctl --system > /dev/null

echo " "
echo "==== 结果确认 ===="
echo "网卡 MTU: $(cat /sys/class/net/$IFACE/mtu)"
echo "MSS 规则: $(iptables -t mangle -L POSTROUTING -v -n | grep TCPMSS)"
echo "BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "=================="
