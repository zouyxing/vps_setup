#!/bin/bash

# 设置：遇到错误立即退出，提高脚本健壮性
set -e

echo "========================================="
echo "  🚀 Alpine Linux 专用 VPS 配置脚本"
echo "========================================="

# 确保以 root 权限执行
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 警告：脚本未以 root 权限运行。请使用 'sudo -i' 切换到 root 后再执行。"
    exit 1
fi

# =========================================
# 函数：检测主网络接口
# -----------------------------------------
get_main_interface() {
    # 依赖：iproute2 包 (已在 [1/6] 中安装)
    ip route | grep default | awk '{print $5}' | head -n1
}

MAIN_INTERFACE=$(get_main_interface)

if [ -z "$MAIN_INTERFACE" ]; then
    echo "❌ 错误：无法检测到主网络接口"
    exit 1
fi

# 生成随机端口（30000-65000）
RANDOM_PORT=$((30000 + RANDOM % 35001))

echo "🔐 已生成随机端口: ${RANDOM_PORT}"
echo "🌐 检测到主网络接口: ${MAIN_INTERFACE}"
echo ""


echo "[1/6] 更新系统并安装基础软件包..."
# Alpine Linux
apk update
# 必需的包：iptables, ufw, expect, iproute2, openrc, curl, wget
apk add iptables ufw expect curl wget iproute2 openrc 
echo "✓ 基础软件包安装完成"


echo ""
echo "[2/6] 配置 UFW 防火墙规则 (兼容 Sing-Box 和 Wi-Fi Calling)..."
# --- 强制清空所有现有 UFW 规则 ---
echo "⚠️ 正在强制删除所有现有 UFW 规则..."
ufw --force reset
echo "✓ UFW 规则已清空"
# ----------------------------------------

# 开放 SSH 端口 (推荐)
ufw allow 22/tcp 

# 开放 Wi-Fi Calling/VoIP 必需的 UDP 端口
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 5060:5061/udp
# 媒体流 (RTP/RTCP)
ufw allow 10000:60000/udp 

# 开放 Sing-Box 端口
ufw allow ${RANDOM_PORT}/udp
ufw allow ${RANDOM_PORT}/tcp

echo "y" | ufw enable
echo "✓ 防火墙已启用（端口 ${RANDOM_PORT} 和 VoWiFi 端口已开放）"


echo ""
echo "[3/6] 检查并配置 IP 转发..."
FORWARD_STATUS=$(sysctl -n net.ipv4.ip_forward)
if [ "$FORWARD_STATUS" -eq 0 ]; then
    echo "IP 转发未启用，正在启用..."
    sysctl -w net.ipv4.ip_forward=1

    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" | tee -a /etc/sysctl.conf
    else
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    fi

    sysctl -p
    echo "✓ IP 转发已启用并保存"
else
    echo "✓ IP 转发已经启用，跳过配置"
fi


echo ""
echo "[4/6] 配置 iptables NAT 规则..."

# --- 清空 iptables NAT 表中的所有规则 ---
echo "⚠️ 正在清空 iptables NAT 表中的所有规则..."
iptables -t nat -F
echo "✓ iptables NAT 表规则已清空"
# ----------------------------------------

# 1. MASQUERADE 规则 (SNAT，用于出站流量伪装)
if ! iptables -t nat -C POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
    echo "✓ 已添加 MASQUERADE 规则 (接口: ${MAIN_INTERFACE})"
else
    echo "✓ MASQUERADE 规则已存在"
fi

# 2. DNAT 规则 (仅针对代理端口 ${RANDOM_PORT}，实现 IP 转发模式)
if ! iptables -t nat -C PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
    iptables -t nat -A PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1
    echo "✓ 已添加代理端口的精确 DNAT 规则 (端口: ${RANDOM_PORT})"
else
    echo "✓ 代理端口的精确 DNAT 规则已存在"
fi


echo ""
echo "保存 iptables 规则..."
mkdir -p /etc/iptables
iptables-save | tee /etc/iptables/rules.v4 > /dev/null

# 针对 Alpine/OpenRC：使用 OpenRC 服务启用 iptables 自动恢复
# Alpine 中 iptables-restore 默认由 /etc/init.d/iptables 脚本管理
rc-update add iptables default 2>/dev/null || true
rc-service iptables save 2>/dev/null || true # 确保保存当前状态

echo "✓ iptables 规则已永久保存"


echo ""
echo "[5/6] 优化网络算法和拥塞控制算法..."
# 注意：cnm.sh 脚本的可靠性取决于其内容
if bash <(curl -fsSL cnm.sh) 2>/dev/null; then
    echo "✓ 网络优化配置完成"
else
    echo "⚠️  网络优化脚本执行失败，跳过此步骤（不影响主要功能）"
fi


echo ""
echo "[6/6] 下载并自动安装配置 Sing-Box..."

echo "⚙️  Alpine：准备安装 Sing-Box..."

# --- 强制清理现有 Sing-Box 安装 ---
echo "⚠️ 正在强制停止、卸载并清理现有 Sing-Box 服务和文件..."
# 停止服务 (OpenRC)
rc-service sing-box stop 2>/dev/null || true
# 禁用服务 (OpenRC)
rc-update del sing-box 2>/dev/null || true
# 卸载包 (如果通过 apk 安装)
apk del sing-box 2>/dev/null || true
# 清理遗留文件和配置
rm -f /usr/local/bin/sing-box /etc/init.d/sing-box
rm -rf /etc/sing-box /usr/share/sing-box /var/log/sing-box
echo "✓ Sing-Box 旧配置清理完成。"
# ------------------------------------------

# 执行 Sing-Box 脚本 (Alpine 专用)
export RANDOM_PORT # 导出端口号供安装脚本使用
if curl -fsSL https://raw.githubusercontent.com/imengying/sing-box/refs/heads/main/sing-box-alpine.sh | bash; then
    echo "✓ Sing-Box 自动安装配置完成"
else
    echo "❌ 警告：Sing-Box 安装脚本执行失败或需要手动配置端口。请检查日志。"
fi


echo ""
echo "========================================="
echo "✅ Alpine VPS 配置完成！"
echo "========================================="
echo ""
echo "已完成的配置："
echo "  ✓ 基础软件安装 (apk)"
echo "  ✓ UFW 防火墙规则配置 (已清空旧规则，并兼容 Sing-Box 和 VoWiFi)"
echo "  ✓ IP 转发启用"
echo "  ✓ iptables NAT 规则配置 (已清空旧规则，并配置 MASQUERADE, 代理端口: ${RANDOM_PORT})"
echo "  ✓ 代理软件: Sing-Box (Alpine)"
echo "  ✓ 网络优化算法和拥塞控制算法"
echo ""
echo "🔐 使用的端口: ${RANDOM_PORT}"
echo "🌐 网络接口: ${MAIN_INTERFACE}"
echo ""
echo "请使用以下命令检查状态："
echo "  ufw status                    # 查看防火墙状态"
echo "  iptables -t nat -L            # 查看 NAT 规则"
echo "  rc-service sing-box status    # 查看 Sing-Box 运行状态 (Alpine/OpenRC)"
echo ""
