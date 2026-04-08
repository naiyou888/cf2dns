#!/bin/bash

# ==========================================
# 网络优化脚本（安全版 - 适配 v2bx / sing-box）
# 仅保留 BBR + 缓冲优化，移除 MTU/MSS 强制
# ==========================================

if [ "$EUID" -ne 0 ]; then 
  echo "请用 root 运行"
  exit 1
fi

echo "--- 安装基础组件 ---"
apt-get update -y -q
apt-get install -y -q iptables iptables-persistent irqbalance

systemctl enable --now irqbalance 2>/dev/null

echo "--- 清理旧 MTU / MSS 干扰 ---"

# 删除 MSS 锁定规则
iptables -t mangle -F POSTROUTING 2>/dev/null
iptables -t mangle -F OUTPUT 2>/dev/null

# 恢复默认 MTU（通常 1500）
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
ip link set dev "$MAIN_IFACE" mtu 1500

echo "--- 应用 sysctl 优化 (BBR + UDP友好) ---"

cat > /etc/sysctl.d/99-v2bx.conf << EOF
fs.file-max=6553560

# TCP 基础优化
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1

# 队列
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096

# 缓冲区（重点：避免 too long）
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 65536 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# conntrack（防止爆连接）
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=60
net.netfilter.nf_conntrack_udp_timeout_stream=120

# BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 端口范围
net.ipv4.ip_local_port_range=1024 65535
EOF

sysctl --system

echo "======================================"
echo "BBR: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
echo "MTU: $(ip link show $MAIN_IFACE | grep -o 'mtu [0-9]*')"
echo "MSS: 已恢复系统自动"
echo "======================================"
