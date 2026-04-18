#!/usr/bin/env bash
set -e

# 权限检查
[[ $EUID -ne 0 ]] && echo "请以 root 权限运行" && exit 1

echo "==== 正在恢复默认网络设置（清理 MTU/MSS，保留 BBR） ===="

# 1. 自动获取主网卡
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo "[+] 目标网卡: $IFACE"

# ==========================================
# 🧹 第一步：彻底清理所有 MTU 和 MSS 限制
# ==========================================
echo "[+] 正在撤销所有手动 MTU/MSS 规则..."

# 恢复网卡 MTU 为标准默认值 (1500)
ip link set dev $IFACE mtu 1500 || true

# 暴力清空所有 mangle 表规则（彻底清理所有 MSS 钳制）
iptables -t mangle -F
iptables -t mangle -X

echo "[+] MTU 已恢复默认 (1500)，MSS 限制已移除。"

# ==========================================
# 🚀 第二步：重新应用你认为“还行”的 BBR 参数
# ==========================================
echo "[+] 正在重新应用激进版内核参数..."

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

# 探测优化 (改为默认探测模式)
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_sack=1

# 协议栈优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_slow_start_after_idle=0

# Keepalive
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF

sysctl --system > /dev/null

echo " "
echo "==== 结果确认 ===="
echo "网卡 MTU: $(cat /sys/class/net/$IFACE/mtu) (应为 1500)"
echo "MSS 规则: $(iptables -t mangle -L POSTROUTING -v -n) (应为空)"
echo "BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "=================="
echo "设置已完成。建议重启你的代理软件以获得最佳效果。"
