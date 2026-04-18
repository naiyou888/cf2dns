#!/usr/bin/env bash
set -e

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行"
   exit 1
fi

echo "==== 落地机优化（小内存精简版 + MTU 1480）===="

# 获取默认网卡
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo "[+] 目标网卡: $IFACE"

# =====================
# 🧹 第一步：深度清理旧规则
# =====================
echo "[+] 正在清理旧配置..."
ip link set dev $IFACE mtu 1500 || true

# 清理 IPTABLES MSS 规则
while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1000:1500 2>/dev/null; do :; done
while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done

# 清理 sysctl
rm -f /etc/sysctl.d/*bbr*.conf 2>/dev/null || true
rm -f /etc/sysctl.d/*net*.conf 2>/dev/null || true
rm -f /etc/sysctl.d/99-agressive-bbr.conf 2>/dev/null || true
sed -i '/net.core/d' /etc/sysctl.conf
sed -i '/net.ipv4/d' /etc/sysctl.conf
sed -i '/fs.file-max/d' /etc/sysctl.conf
sysctl --system > /dev/null

# =====================
# 📡 第二步：MTU 探测与锁定 (1480)
# =====================
TARGET="1.1.1.1"
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
[[ $REAL_MTU -gt 1480 ]] && FINAL_MTU=1480 || FINAL_MTU=$REAL_MTU
ip link set dev $IFACE mtu $FINAL_MTU

# =====================
# ⚙️ 第三步：写入新 MSS 规则
# =====================
NEW_MSS=$((FINAL_MTU - 40))
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o $IFACE -j TCPMSS --set-mss $NEW_MSS

# =====================
# 🚀 第四步：写入小内存优化版 BBR 配置
# =====================
echo "[+] 应用小内存内核优化参数 (Buffer: 16MB)..."

cat > /etc/sysctl.d/99-lowmem-bbr.conf <<EOF
# 文件句柄限制（小内存适度调低）
fs.file-max=1048576
net.ipv4.ip_local_port_range=1024 65535

# Buffer 优化 - 小内存版 (最大 16MB)
# 既能保证千兆速度，又防止内存溢出
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2

# 队列优化（适度收敛）
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=4096
net.core.netdev_max_backlog=10000
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
net.ipv4.tcp_slow_start_after_idle=0

# Keepalive 优化
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF

sysctl --system > /dev/null

echo " "
echo "==== 优化结果 (小内存版) ===="
echo "网卡 MTU: $(cat /sys/class/net/$IFACE/mtu)"
echo "TCP 缓冲区最大值: 16MB"
echo "BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "============================="
