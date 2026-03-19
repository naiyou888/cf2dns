#!/bin/bash

# ====================================================
# 专线机场/TikTok直播 全链路 MTU & MSS 优化脚本 v3.0
# 适用：国内中转机、专线出口机、香港/海外落地机
# ====================================================

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行此脚本。"
  exit 1
fi

# 2. 自动安装缺失的工具 (针对精简版系统)
echo "--- 1. 检查并安装必要组件 ---"
if ! command -v iptables &> /dev/null || ! command -v netfilter-persistent &> /dev/null; then
    echo "正在安装 iptables 及持久化工具..."
    apt-get update && apt-get install -y iptables iptables-persistent curl
else
    echo "组件已就绪。"
fi

# 3. 设置核心参数 (专线黄金对齐: 1420/1380)
TARGET_MTU=1420
TARGET_MSS=1380

# 4. 自动定位主网卡
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$MAIN_IFACE" ]; then
    echo "错误: 无法识别主网卡，请检查网络设置。"
    exit 1
fi

echo "--- 2. 清理旧的 TCPMSS 冲突规则 ---"
# 循环清理所有 mangle 表中的旧规则
while iptables -t mangle -L POSTROUTING -n | grep -q "TCPMSS"; do
    RULE_NUM=$(iptables -t mangle -L POSTROUTING --line-numbers | grep "TCPMSS" | awk '{print $1}' | head -n1)
    iptables -t mangle -D POSTROUTING $RULE_NUM
done

while iptables -t mangle -L OUTPUT -n | grep -q "TCPMSS"; do
    RULE_NUM=$(iptables -t mangle -L OUTPUT --line-numbers | grep "TCPMSS" | awk '{print $1}' | head -n1)
    iptables -t mangle -D OUTPUT $RULE_NUM
done
echo "清理完成。"

echo "--- 3. 执行物理 MTU 对齐 ($TARGET_MTU) ---"
# 修改主网卡
ip link set dev "$MAIN_IFACE" mtu $TARGET_MTU

# 修改所有关联的子接口 (如 eth0.2404)
SUB_IFACES=$(ip link show | grep "@$MAIN_IFACE" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
for sub in $SUB_IFACES; do
    echo "同步子接口: $sub"
    ip link set dev "$sub" mtu $TARGET_MTU
done

# 如果存在 docker0，也同步修改
if ip link show docker0 >/dev/null 2>&1; then
    ip link set dev docker0 mtu $TARGET_MTU
fi

echo "--- 4. 应用最优 MSS 规则 ($TARGET_MSS) ---"
# 针对所有经过网卡的 TCP 握手包进行强制限制
iptables -t mangle -I POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS
iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS

echo "--- 5. 持久化配置 (防止重启失效) ---"
if command -v netfilter-persistent >/dev/null 2>&1; then
    # 自动确认保存 (非交互式)
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "规则已保存至 /etc/iptables/rules.v4"
fi

echo "==================== 最终优化结果 ===================="
echo "网卡 MTU 状态:"
ip addr | grep "mtu " | grep -v "lo" | awk '{print $2 " " $9 " " $10}'
echo "----------------------------------------------------"
echo "TCP MSS 规则状态 (应显示两条 1380 规则):"
iptables -t mangle -L -n -v | grep "TCPMSS set $TARGET_MSS"
echo "===================================================="
echo "提示: 如果下方显示有数据包(pkts)计数，说明优化已即时生效。"
