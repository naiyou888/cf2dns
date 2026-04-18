#!/usr/bin/env bash
set -e

[[ $EUID -ne 0 ]] && echo "请以 root 权限运行" && exit 1

echo "==== 落地机网络优化 (1GB+ 内存激进版) ===="

# 自动获取网卡
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# --- 第一步：深度清理旧规则 ---
ip link set dev $IFACE mtu 1500 || true
iptables -t mangle -F || true
rm -f /etc/sysctl.d/*bbr*.conf /etc/sysctl.d/*net*.conf 2>/dev/null || true
sed -i '/net.core/d; /net.ipv4/d; /fs.file-max/d' /etc/sysctl.conf

# --- 第二步：MTU 探测与锁定 1480 ---
probe_mtu() {
    local MIN=1200; local MAX=1480; local BEST=1400
    while [ $MIN -le $MAX ]; do
        MID=$(( (MIN + MAX) / 2 ))
        if ping -c 1 -W 1 -M do -s $((MID-28)) 1.1.1.1 > /dev/null 2>&1; then
            BEST=$MID; MIN=$((MID + 1))
        else
            MAX=$((MID - 1))
        fi
    done
    echo $BEST
}
FINAL_MTU=$(probe_mtu)
[[ $FINAL_MTU -gt 1480 ]] && FINAL_MTU=1480
ip link set dev $IFACE mtu $FINAL_MTU

# --- 第三步：MSS 钳制 ---
FINAL_MSS=$((FINAL_MTU - 40))
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o $IFACE -j TCPMSS --set-mss $FINAL_MSS

# --- 第四步：激进版 Sysctl 参数 ---
cat > /etc/sysctl.d/99-agressive-bbr.conf <<EOF
fs.file-max=6553560
net.ipv4.ip_local_port_range=1024 65535
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_max_syn_backlog=16384
net.core.somaxconn=65535
net.core.netdev_max_backlog=262144
net.ipv4.tcp_abort_on_overflow=0
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
EOF

sysctl --system > /dev/null
echo "完成！MTU: $FINAL_MTU, MSS: $FINAL_MSS, 模式: 激进版"
