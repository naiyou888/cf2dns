#!/bin/bash
# 专线落地机/中转机 全自动清理并对齐脚本 (2026 优化版)

TARGET_MTU=1420
TARGET_MSS=1380

# 1. 自动定位主网卡
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$MAIN_IFACE" ]; then
    echo "错误: 无法识别主网卡。"
    exit 1
fi

echo "--- 开始清理旧配置并执行专线优化 ---"

# 2. 清理所有旧的 TCPMSS 规则 (防止多条规则冲突)
# 这一步会遍历并删除所有 mangle 表中关于 TCPMSS 的条目
echo "正在清理旧的 iptables MSS 规则..."
while iptables -t mangle -L POSTROUTING -n | grep -q "TCPMSS"; do
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1480 2>/dev/null
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1448 2>/dev/null
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null
    # 万能清理：直接按 target 名称清理该链下所有 TCPMSS
    RULE_NUM=$(iptables -t mangle -L POSTROUTING --line-numbers | grep "TCPMSS" | awk '{print $1}' | head -n1)
    if [ -z "$RULE_NUM" ]; then break; fi
    iptables -t mangle -D POSTROUTING $RULE_NUM
done

while iptables -t mangle -L OUTPUT -n | grep -q "TCPMSS"; do
    RULE_NUM=$(iptables -t mangle -L OUTPUT --line-numbers | grep "TCPMSS" | awk '{print $1}' | head -n1)
    if [ -z "$RULE_NUM" ]; then break; fi
    iptables -t mangle -D OUTPUT $RULE_NUM
done

# 3. 强制对齐网卡 MTU (物理接口 + 子接口)
echo "正在对齐网卡 MTU 至 $TARGET_MTU..."
ip link set dev "$MAIN_IFACE" mtu $TARGET_MTU

SUB_IFACES=$(ip link show | grep "@$MAIN_IFACE" | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
for sub in $SUB_IFACES; do
    echo "同步子接口: $sub"
    ip link set dev "$sub" mtu $TARGET_MTU
done

# 4. 插入最新的最优 MSS 规则
echo "正在应用新规则: MSS $TARGET_MSS..."
iptables -t mangle -I POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS
iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS

# 5. 持久化
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
fi

echo "--- 优化完成！ ---"
echo "当前有效 MSS 规则:"
iptables -t mangle -L -n -v | grep "TCPMSS set $TARGET_MSS"
