#!/bin/bash

# ====================================================
# 节点网络全能优化脚本 v6.0 (最终整合版)
# 功能：BBR + MTU/MSS 锁定 + UDP 优化 + 彻底禁用 IPv6
# ====================================================

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行。"
  exit 1
fi

echo "--- 1. 安装基础组件 ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q iptables iptables-persistent curl irqbalance localepurge

# 启动中断平衡，降低 RTT 抖动
systemctl enable --now irqbalance 2>/dev/null

# 2. 设置核心参数
TARGET_MTU=1380
TARGET_MSS=1340

# 3. 自动定位主网卡
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$MAIN_IFACE" ]; then
    echo "错误: 无法识别主网卡。"
    exit 1
fi

echo "--- 2. 应用内核参数 (BBR + UDP + 禁用 IPv6) ---"
cat > /etc/sysctl.d/99-v2bx-optimized.conf << EOF
# 彻底禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# 文件描述符限制
fs.file-max=6553560

# 基础 TCP 优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=4096
net.ipv4.tcp_abort_on_overflow=1

# 缓冲区优化 (解决 message too long)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 65536 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# 连接追踪优化 (解决 Operation not permitted)
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=60
net.netfilter.nf_conntrack_udp_timeout_stream=120

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 端口范围
net.ipv4.ip_local_port_range=1024 65535
EOF

# 应用参数
sysctl -p /etc/sysctl.d/99-v2bx-optimized.conf

echo "--- 3. 执行物理 MTU 对齐 ($TARGET_MTU) ---"
ip link set dev "$MAIN_IFACE" mtu $TARGET_MTU

# 同步子接口与 Docker
SUB_IFACES=$(ip link show | grep "@$MAIN_IFACE" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
for sub in $SUB_IFACES; do
    ip link set dev "$sub" mtu $TARGET_MTU
done
[ -d /sys/class/net/docker0 ] && ip link set dev docker0 mtu $TARGET_MTU

echo "--- 4. 应用 TCP MSS 锁定 ($TARGET_MSS) ---"
# 清理旧规则并插入
iptables -t mangle -F POSTROUTING 2>/dev/null
iptables -t mangle -F OUTPUT 2>/dev/null
iptables -t mangle -I POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS
iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS

# 5. 持久化并清理 IPv6 残留
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save >/dev/null 2>&1
fi

echo "==================== 最终优化结果 ===================="
echo "BBR 状态: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
echo "IPv6 状态: $([ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 1 ] && echo "已禁用" || echo "启用中")"
echo "网卡 MTU: $(ip link show $MAIN_IFACE | grep -o 'mtu [0-9]*')"
echo "TCP MSS: $TARGET_MSS"
echo "----------------------------------------------------"
echo "提示：IPv6 已禁用，V2bX 流量将强制走 IPv4 路径。"
echo "===================================================="
