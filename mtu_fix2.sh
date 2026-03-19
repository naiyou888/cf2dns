#!/bin/bash
# 专线落地机/中转机 全自动清理并对齐脚本 (增强结果显示版)

TARGET_MTU=1420
TARGET_MSS=1380

# 1. 自动定位主网卡
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$MAIN_IFACE" ]; then
    echo "错误: 无法识别主网卡。"
    exit 1
fi

echo "===================================================="
echo "--- 1. 开始清理旧配置 ---"

# 清理所有旧的 TCPMSS 规则
while iptables -t mangle -L POSTROUTING -n | grep -q "TCPMSS"; do
    RULE_NUM=$(iptables -t mangle -L POSTROUTING --line-numbers | grep "TCPMSS" | awk '{print $1}' | head -n1)
    iptables -t mangle -D POSTROUTING $RULE_NUM
done

while iptables -t mangle -L OUTPUT -n | grep -q "TCPMSS"; do
    RULE_NUM=$(iptables -t mangle -L OUTPUT --line-numbers | grep "TCPMSS" | awk '{print $1}' | head -n1)
    iptables -t mangle -D OUTPUT $RULE_NUM
done
echo "清理完成。"

echo "--- 2. 执行 MTU 对齐 ($TARGET_MTU) ---"
# 修改物理网卡
ip link set dev "$MAIN_IFACE" mtu $TARGET_MTU

# 修改子接口
SUB_IFACES=$(ip link show | grep "@$MAIN_IFACE" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
for sub in $SUB_IFACES; do
    ip link set dev "$sub" mtu $TARGET_MTU
done

# 如果有 docker0 且存在，也改掉
if ip link show docker0 >/dev/null 2>&1; then
    ip link set dev docker0 mtu $TARGET_MTU
fi

echo "--- 3. 应用新 MSS 规则 ($TARGET_MSS) ---"
iptables -t mangle -I POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS
iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS

echo "--- 4. 持久化配置 ---"
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
fi

echo "==================== 最终优化结果 ===================="
echo "网卡 MTU 状态:"
ip addr | grep "mtu $TARGET_MTU" | awk '{print $2 " " $9 " " $10}'
echo "----------------------------------------------------"
echo "TCP MSS 规则状态:"
iptables -t mangle -L -n -v | grep "TCPMSS set $TARGET_MSS"
echo "===================================================="
