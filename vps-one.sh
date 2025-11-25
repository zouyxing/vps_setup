#!/bin/bash

# 设置：遇到错误立即退出，提高脚本健壮性
set -e

# =========================================
# 配置变量
# -----------------------------------------
# 自定义 SSH 端口（根据您的偏好，从 22622 更改为其他端口）
SSH_PORT=22622

# 函数：检测主网络接口
get_main_interface() {
    # 获取默认路由使用的接口
    # 依赖：iproute2 包 (apt-get install iproute2)
    ip route | grep default | awk '{print $5}' | head -n1
}

MAIN_INTERFACE=$(get_main_interface)

if [ -z "$MAIN_INTERFACE" ]; then
    echo "❌ 错误：无法检测到主网络接口"
    exit 1
fi

# 生成随机端口（30000-65000）用于 Xray
RANDOM_PORT=$((30000 + RANDOM % 35001))

echo "========================================="
echo "开始执行 VPS 自动配置脚本"
echo "========================================="
echo ""
echo "🔐 Xray 随机端口: ${RANDOM_PORT}"
echo "🔒 SSH 自定义端口: ${SSH_PORT}"
echo "🌐 检测到主网络接口: ${MAIN_INTERFACE}"
echo ""

# 确保所有后续操作都以 root 权限执行
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 警告：脚本未以 root 权限运行。请使用 'sudo -i' 切换到 root 后再执行。"
    exit 1
fi

echo ""
echo "[1/7] 更新系统并安装基础软件包..."
# =========================================
# 锁文件修复逻辑 (FIXED)
# -----------------------------------------
APT_LOCK="/var/lib/dpkg/lock-frontend"
if [ -f "$APT_LOCK" ]; then
    echo "⚠️ 检测到 APT 锁文件，可能由后台进程持有。"
    echo "   尝试强制清理锁并修复数据库..."
    # 强制终止可能占用锁的进程
    killall -9 apt-get || true
    killall -9 dpkg || true
    
    # 强制删除锁文件
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
    
    # 强制配置未完成的包，修复数据库
    dpkg --configure -a || true
    echo "✓ 锁文件清理和数据库修复完成。"
fi
# =========================================

# 由于是以 root 身份运行，不需要 sudo
apt-get update
# 确保安装了 iproute2 (ip route 命令) 和 net-tools (ss 命令)
apt-get install -y iptables sudo ufw expect curl wget iproute2 net-tools

echo ""
echo "[2/7] 配置 UFW 防火墙规则 (兼容 Xray, VoWiFi 和 Poste.io 邮件服务)..."

# 1. 开放自定义 SSH 端口，并删除默认 22 端口 (增强安全)
ufw allow ${SSH_PORT}/tcp comment 'Custom Secure SSH Port'
ufw delete allow 22/tcp 2>/dev/null || true # 确保删除 IPv4 和 IPv6 规则

# 2. 开放 Poste.io 邮件服务端口
ufw allow 25,465,587/tcp comment 'Mail - SMTP/Submission'
ufw allow 993,995/tcp comment 'Mail - IMAP/POP3'
ufw allow 80,443/tcp comment 'Mail - Webmail/Admin/Cert'

# 3. 开放 Wi-Fi Calling/VoIP 必需的 UDP 端口 (IKEv2, NAT Traversal, SIP, RTP/RTCP)
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 5060:5061/udp
# 媒体流 (RTP/RTCP)，开放宽泛 UDP 范围
ufw allow 10000:60000/udp 

# 4. 开放 Xray 端口
ufw allow ${RANDOM_PORT}/udp
ufw allow ${RANDOM_PORT}/tcp

echo "y" | ufw enable
echo "✓ 防火墙已启用（自定义 SSH: ${SSH_PORT}，Xray: ${RANDOM_PORT}，邮件端口已开放）"

echo ""
echo "[3/7] 检查并配置 IP 转发..."
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
echo "[4/7] 配置 iptables NAT 规则..."

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
echo "[5/7] 优化网络算法和拥塞控制算法..."
# 注意：cnm.sh 脚本的可靠性取决于其内容
if bash <(curl -fsSL cnm.sh) 2>/dev/null; then
    echo "✓ 网络优化配置完成"
else
    echo "⚠️  网络优化脚本执行失败，跳过此步骤（不影响主要功能）"
fi

echo ""
echo "[6/7] 下载并自动安装配置 Xray..."

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
echo "[7/7] 配置并启用自定义 SSH 端口 ${SSH_PORT}..."

# 1. 备份原始配置
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# 2. 使用 sed 确保所有 Port 行被注释 (包括默认的 22)
sed -i '/^Port/ s/^/#&/' /etc/ssh/sshd_config 

# 3. 在文件末尾添加自定义端口
echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config

# 4. 启用 SSH 服务自启动（防止重启后无法连接）
systemctl enable ssh 2>/dev/null || true

# 5. 重启 Systemd Socket 和 SSH 服务以使端口更改生效
systemctl daemon-reload
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart ssh

echo "✓ SSH 端口已更改为 ${SSH_PORT} 并启用自启动"

echo ""
echo "========================================="
echo "✅ VPS 配置完成！请立即测试新端口连接！"
echo "========================================="
echo ""
echo "重要提示："
echo "1. 您的旧 SSH 会话已过时，请立即使用新端口进行连接！"
echo "   ssh root@您的IP -p ${SSH_PORT}"
echo "2. 如果连接失败，问题很可能出在 **Berohost 平台级防火墙/安全组** 上，请联系客服开放 ${SSH_PORT}。"
echo ""
echo "已完成的配置："
echo "  ✓ SSH 端口已安全切换到 ${SSH_PORT} (${SSH_PORT})"
echo "  ✓ Poste.io 邮件服务端口已开放 (25, 80, 443, 465, 587, 993, 995)"
echo "  ✓ 系统更新和基础软件安装"
echo "  ✓ UFW 防火墙规则配置 (兼容 Xray 和 VoWiFi)"
echo "  ✓ IP 转发启用"
echo "  ✓ iptables NAT 规则配置 (MASQUERADE, Xray DNAT: ${RANDOM_PORT})"
echo "  ✓ 网络优化算法和拥塞控制算法"
echo "  ✓ Xray 自动安装配置"
echo ""
echo "请使用以下命令检查状态："
echo "  ufw status                # 查看防火墙状态"
echo "  systemctl status ssh      # 查看 SSH 运行状态"
echo "  systemctl status xray     # 查看 Xray 运行状态"
echo ""
