#!/bin/bash

set -e

echo "========================================="
echo "开始执行 VPS 自动配置脚本"
echo "========================================="

echo ""
echo "[1/6] 更新系统并安装基础软件包..."
sudo apt-get update
sudo apt-get install -y iptables sudo ufw expect

echo ""
echo "[2/6] 配置 UFW 防火墙规则..."
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw allow 50000:60000/tcp
sudo ufw allow 10000:60000/tcp
sudo ufw allow 10000:60000/udp
sudo ufw allow 50000:60000/udp
sudo ufw allow 4500/udp
sudo ufw allow 500/udp
sudo ufw allow 5060:5061/udp
sudo ufw allow 38626/udp
sudo ufw allow 38626/tcp

echo "y" | sudo ufw enable
echo "防火墙已启用"

echo ""
echo "[3/6] 检查并配置 IP 转发..."
FORWARD_STATUS=$(sysctl -n net.ipv4.ip_forward)
if [ "$FORWARD_STATUS" -eq 0 ]; then
    echo "IP 转发未启用，正在启用..."
    sudo sysctl -w net.ipv4.ip_forward=1
    
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
    else
        sudo sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    fi
    
    sudo sysctl -p
    echo "IP 转发已启用并保存"
else
    echo "IP 转发已经启用，跳过配置"
fi

echo ""
echo "[4/6] 配置 iptables NAT 规则..."

if ! sudo iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    echo "已添加 MASQUERADE 规则"
else
    echo "MASQUERADE 规则已存在"
fi

if ! sudo iptables -t nat -C PREROUTING -p udp --dport 10000:60000 -j DNAT --to-destination 127.0.0.1 2>/dev/null; then
    sudo iptables -t nat -A PREROUTING -p udp --dport 10000:60000 -j DNAT --to-destination 127.0.0.1
    echo "已添加 DNAT 规则"
else
    echo "DNAT 规则已存在"
fi

echo ""
echo "保存 iptables 规则..."

sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null

if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
    cat << 'EOF' | sudo tee /etc/systemd/system/iptables-restore.service > /dev/null
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

    sudo systemctl daemon-reload
    sudo systemctl enable iptables-restore.service
    echo "已创建 iptables 自动恢复服务"
fi

echo "iptables 规则已永久保存"

echo ""
echo "[5/6] 优化算法和拥塞控制算法..."
bash <(curl -fsSL cnm.sh)
echo "优化算法和拥塞控制算法配置完成"

echo ""
echo "[6/6] 下载并自动安装配置 Xray..."
wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/zxcvos/Xray-script/refs/heads/main/install.sh

expect << 'EOF'
set timeout 300
spawn bash /root/Xray-script.sh

expect {
    "是否更新*" { send "Y\r" }
    timeout { puts "等待更新提示超时"; exit 1 }
}

expect {
    "*请选择操作:*" { send "1\r" }
    timeout { puts "等待主菜单超时"; exit 1 }
}

expect {
    "*请选择操作:*" { send "2\r" }
    timeout { puts "等待安装流程选择超时"; exit 1 }
}

expect {
    "*请选择操作:*" { send "2\r" }
    timeout { puts "等待装载管理选择超时"; exit 1 }
}

expect {
    "*请选择操作:*" { send "2\r" }
    timeout { puts "等待配置选择超时"; exit 1 }
}

expect {
    "*是否重置路由规则*" { send "y\r" }
    timeout { puts "等待路由规则选择超时"; exit 1 }
}

expect {
    "*是否开启 bittorrent 屏蔽*" { send "n\r" }
    timeout { puts "等待 bt 屏蔽选择超时"; exit 1 }
}

expect {
    "*是否开启国内 ip 屏蔽*" { send "n\r" }
    timeout { puts "等待国内 ip 屏蔽选择超时"; exit 1 }
}

expect {
    "*是否开启广告屏蔽*" { send "y\r" }
    timeout { puts "等待广告屏蔽选择超时"; exit 1 }
}

expect {
    "*请输入 port*" { send "38626\r" }
    timeout { puts "等待端口输入超时"; exit 1 }
}

expect {
    "*请输入 UUID*" { send "\r" }
    timeout { puts "等待 UUID 输入超时"; exit 1 }
}

expect {
    "*请输入目标域名 target*" { send "\r" }
    timeout { puts "等待目标域名输入超时"; exit 1 }
}

expect {
    "*请输入 shortId*" { send "\r" }
    timeout { puts "等待 shortId 输入超时"; exit 1 }
}

expect {
    eof { puts "Xray 安装配置完成" }
    timeout { puts "安装过程超时"; exit 1 }
}
EOF

echo "Xray 自动安装配置完成"

echo ""
echo "========================================="
echo "VPS 配置完成！"
echo "========================================="
echo ""
echo "已完成的配置："
echo "✓ 系统更新和基础软件安装"
echo "✓ UFW 防火墙规则配置"
echo "✓ IP 转发启用"
echo "✓ iptables NAT 规则配置"
echo "✓ 优化算法和拥塞控制算法"
echo "✓ Xray 自动安装配置"
echo ""
echo "请使用以下命令检查状态："
echo "  sudo ufw status          # 查看防火墙状态"
echo "  sudo iptables -t nat -L  # 查看 NAT 规则"
echo "  sysctl net.ipv4.ip_forward  # 查看转发状态"
echo ""

