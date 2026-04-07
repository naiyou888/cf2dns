#!/bin/bash

# ====================================================
# 专线全自动优化脚本 v4.0 (完全无人值守版)
# 解决安装 iptables-persistent 时的弹窗卡死问题
# ====================================================

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行。"
  exit 1
fi

echo "--- 1. 检查并静默安装必要组件 ---"
# 使用 noninteractive 模式跳过所有安装弹窗
if ! command -v iptables &> /dev/null || ! command -v netfilter-persistent &> /dev/null; then
    echo "正在静默安装组件，请稍候..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y -q iptables iptables-persistent curl
else
    echo "组件已就绪。"
fi

# 2. 设置核心参数
TARGET_MTU=1380
TARGET_MSS=1340

# 3. 自动定位主网卡
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$MAIN_IFACE" ]; then
    echo "错误: 无法识别主网卡。"
    exit 1
fi

echo "--- 2. 清理旧的 TCPMSS 冲突规则 ---"
# 清理所有已存在的 TCPMSS 规则
iptables -t mangle -F POSTROUTING 2>/dev/null
iptables -t mangle -F OUTPUT 2>/dev/null
echo "清理完成。"

echo "--- 3. 执行物理 MTU 对齐 ($TARGET_MTU) ---"
# 修改主网卡
ip link set dev "$MAIN_IFACE" mtu $TARGET_MTU

# 修改所有关联的子接口
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
iptables -t mangle -I POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS
iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TARGET_MSS

echo "--- 5. 持久化配置 (静默保存) ---"
if command -v netfilter-persistent &> /dev/null; then
    # 强制保存当前规则到配置文件
    netfilter-persistent save >/dev/null 2>&1
    echo "规则已保存，重启不失效。"
fi

echo "==================== 最终优化结果 ===================="
echo "网卡 MTU 状态:"
ip addr | grep "mtu " | grep -v "lo" | awk '{print $2 " " $9 " " $10}'
echo "----------------------------------------------------"
echo "TCP MSS 规则状态:"
iptables -t mangle -L -n -v | grep "TCPMSS set $TARGET_MSS"
echo "===================================================="
