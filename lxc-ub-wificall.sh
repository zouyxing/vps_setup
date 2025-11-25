#!/bin/bash

# 设置：遇到错误立即退出，提高脚本健壮性
set -e

# =========================================
# 函数：检测主网络接口
# -----------------------------------------
get_main_interface() {
    # 获取默认路由使用的接口
    # 依赖：iproute2 包
    ip route | grep default | awk '{print $5}' | head -n1
}

MAIN_INTERFACE=$(get_main_interface)

if [ -z "$MAIN_INTERFACE" ]; then
    echo "❌ 错误：无法检测到主网络接口"
    exit 1
fi

# 生成随机端口（30000-65000）
RANDOM_PORT=$((30000 + RANDOM % 35001))

echo "========================================="
echo "开始执行 VPS 自动配置脚本"
echo "========================================="
echo ""
echo "🔐 已生成随机端口: ${RANDOM_PORT}"
echo "🌐 检测到主网络接口: ${MAIN_INTERFACE}"
echo ""

# 确保所有后续操作都以 root 权限执行 (如果脚本是以 sudo -i 启动，则已满足)
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 警告：脚本未以 root 权限运行。请使用 'sudo -i' 切换到 root 后再执行。"
    exit 1
fi

echo ""
echo "[1/6] 更新系统并安装基础软件包..."
# 由于是以 root 身份运行，不需要 sudo
apt-get update
apt-get install -y iptables sudo ufw expect curl wget

echo ""
echo "[2/6] 配置 UFW 防火墙规则 (兼容 Xray 和 Wi-Fi Calling)..."
# --- 新增：强制清空所有现有 UFW 规则 ---
echo "⚠️ 正在强制删除所有现有 UFW 规则..."
# --force 参数确保无需人工确认
ufw --force reset
echo "✓ UFW 规则已清空"
# ----------------------------------------

# 开放 SSH 端口 (推荐)
ufw allow 22/tcp 

# 开放 Wi-Fi Calling/VoIP 必需的 UDP 端口 (IKEv2, NAT Traversal, SIP, RTP/RTCP)
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 5060:5061/udp
# 媒体流 (RTP/RTCP)，仅开放 UDP，避免宽泛 TCP 端口带来的安全风险
ufw allow 10000:60000/udp 

# 开放 Xray 端口
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

    # 直接使用 tee 写入，无需 grep/sed 复杂判断
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

# --- 新增：清空 iptables NAT 表中的所有规则 ---
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

# 2. DNAT 规则 (仅针对 Xray 的 ${RANDOM_PORT}，实现 IP 转发模式)
if ! iptables -t nat -C PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
    iptables -t nat -A PREROUTING -p udp --dport ${RANDOM_PORT} -j DNAT --to-destination 127.0.0.1
    echo "✓ 已添加 Xray 端口的精确 DNAT 规则 (端口: ${RANDOM_PORT})"
else
    echo "✓ Xray 端口的精确 DNAT 规则已存在"
fi


echo ""
echo "保存 iptables 规则..."

mkdir -p /etc/iptables
iptables-save | tee /etc/iptables/rules.v4 > /dev/null

if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
    cat << 'EOF' | tee /etc/systemd/system/iptables-restore.service > /dev/null
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable iptables-restore.service
    echo "✓ 已创建 iptables 自动恢复服务"
fi

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
echo "[6/6] 下载并自动安装配置 Xray..."

# 检查并卸载旧配置
if systemctl is-active --quiet xray 2>/dev/null || [ -f "/usr/local/bin/xray" ]; then
    echo "检测到已安装的 Xray，正在卸载..."
    
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    
    # 彻底清理旧脚本痕迹（以 root 身份执行，无需 sudo）
    rm -rf /usr/local/xray-script 2>/dev/null || true
    rm -rf /root/.xray-script 2>/dev/null || true
    rm -rf /usr/local/etc/xray 2>/dev/null || true
    rm -rf /usr/local/bin/xray 2>/dev/null || true
    rm -rf /usr/local/share/xray 2>/dev/null || true
    rm -rf /etc/systemd/system/xray.service 2>/dev/null || true
    rm -rf /etc/systemd/system/xray@.service 2>/dev/null || true
    
    systemctl daemon-reload 2>/dev/null || true
    
    echo "✓ 卸载完成！"
else
    echo "未检测到已安装的 Xray"
fi

echo "等待 2 秒后开始全新安装..."
sleep 2

wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/zxcvos/Xray-script/refs/heads/main/install.sh

# 添加执行权限
chmod +x ${HOME}/Xray-script.sh

# 将端口号和脚本路径导出为环境变量供 expect 使用
export RANDOM_PORT
export SCRIPT_PATH="${HOME}/Xray-script.sh"

expect << 'EXPECT_EOF'
set timeout 600
log_user 1
spawn bash $env(SCRIPT_PATH)

sleep 2

# 第一步：处理语言选择和更新提示
expect {
    -re {中文.*English} {
        send "1\r"
        exp_continue
    }
    -re {是否更新} {
        send "Y\r"
        exp_continue
    }
    -re {请选择操作} {}
    timeout { exit 1 }
}

# 第二步：主菜单选择 1（完整安装）
send "1\r"

# 安装流程：自定义配置 → 输入 2
expect {
    -re {请选择操作} { send "2\r" }
    timeout { exit 1 }
}

# 装载管理：稳定版 → 输入 2
expect {
    -re {请选择操作} { send "2\r" }
    timeout { exit 1 }
}

# 可选配置：VLESS+Vision+REALITY → 输入 2
expect {
    -re {请选择操作} { send "2\r" }
    timeout { exit 1 }
}

sleep 1

# 处理路由规则配置并等待 bittorrent
expect {
    -re {是否重置路由规则} {
        send "y\r"
        expect {
            -re {是否开启 bittorrent 屏蔽|bittorrent 屏蔽} { send "n\r" }
            timeout { exit 1 }
        }
    }
    -re {是否开启 bittorrent 屏蔽|bittorrent 屏蔽} {
        send "n\r"
    }
    -re {配置原文件存在} {
        exp_continue
    }
    timeout { exit 1 }
}

# 是否开启国内 ip 屏蔽 → 输入 n
expect {
    -re {是否开启国内 ip 屏蔽} { send "n\r" }
    timeout { exit 1 }
}

# 是否开启广告屏蔽 → 输入 Y
expect {
    -re {是否开启广告屏蔽|广告屏蔽} { send "Y\r" }
    timeout { exit 1 }
}

# 端口 → 使用随机生成的端口
expect {
    -re {请输入 port} { send "$env(RANDOM_PORT)\r" }
    timeout { exit 1 }
}

# UUID → 默认自动生成
expect {
    -re {请输入 UUID} { send "\r" }
    timeout { exit 1 }
}

# target → 默认
expect {
    -re {请输入目标域名} { send "\r" }
    timeout { exit 1 }
}

# shortId → 默认
expect {
    -re {请输入 shortId} { send "\r" }
    timeout { exit 1 }
}

# 等待安装完成
expect {
    eof {}
    timeout { exit 1 }
}
EXPECT_EOF

echo "✓ Xray 自动安装配置完成"

echo ""
echo "========================================="
echo "✅ VPS 配置完成！"
echo "========================================="
echo ""
echo "已完成的配置："
echo "  ✓ 系统更新和基础软件安装"
echo "  ✓ UFW 防火墙规则配置 (已清空旧规则，并兼容 Xray 和 VoWiFi)"
echo "  ✓ IP 转发启用"
echo "  ✓ iptables NAT 规则配置 (已清空旧规则，并配置 MASQUERADE, Xray DNAT: ${RANDOM_PORT})"
echo "  ✓ 网络优化算法和拥塞控制算法"
echo "  ✓ Xray 自动安装配置"
echo ""
echo "🔐 使用的端口: ${RANDOM_PORT}"
echo "🌐 网络接口: ${MAIN_INTERFACE}"
echo ""
echo "请使用以下命令检查状态："
echo "  ufw status                    # 查看防火墙状态"
echo "  iptables -t nat -L            # 查看 NAT 规则"
echo "  sysctl net.ipv4.ip_forward    # 查看转发状态"
echo "  systemctl status xray         # 查看 Xray 运行状态"
echo ""
