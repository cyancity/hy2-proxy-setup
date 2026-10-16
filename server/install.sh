#!/usr/bin/env bash
# Hysteria 2 服务端自动化安装与部署脚本
# 适用系统: Ubuntu 20.04+, Debian 11+, CentOS 8+, Alma/Rocky Linux, Oracle Linux
# 运行权限: root 或具有 sudo 权限的用户
set -euo pipefail

PORT="${HY2_PORT:-2443}"
PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)}"
TIMEZONE="${SERVER_TIMEZONE:-Asia/Singapore}"

say() { echo -e "\n\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }

say "1. 检测机器架构与环境"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_ARCH="amd64" ;;
  aarch64|arm64) BIN_ARCH="arm64" ;;
  *) echo "错误: 不支持的 CPU 架构 $ARCH"; exit 1 ;;
esac
echo "CPU 架构: ${ARCH} (匹配二进制: hysteria-linux-${BIN_ARCH})"

# 自动获取外网 IPv4
SERVER_IP="${SERVER_IP:-}"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4s --max-time 5 https://api.ipify.org || curl -4s --max-time 5 https://ifconfig.me || true)
fi
if [ -z "$SERVER_IP" ]; then
  warn "未能自动获取公网 IP，请在客户端配置中手动指定服务器 IP"
  SERVER_IP="<YOUR_SERVER_IP>"
else
  echo "公网 IPv4: ${SERVER_IP}"
fi

say "2. 配置系统时区 (${TIMEZONE})"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "${TIMEZONE}" || true
  echo "当前时区: $(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
fi

say "3. 下载并安装 Hysteria 2 二进制"
DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${BIN_ARCH}"
curl -fsSL -o /tmp/hysteria "${DOWNLOAD_URL}"
sudo install -m 755 /tmp/hysteria /usr/local/bin/hysteria
rm -f /tmp/hysteria
/usr/local/bin/hysteria version | head -n 2

say "4. 生成自签名 TLS 证书"
sudo mkdir -p /etc/hysteria
if [ ! -f /etc/hysteria/server.key ] || [ ! -f /etc/hysteria/server.crt ]; then
  sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -days 3650 \
    -subj "/CN=www.bing.com"
  sudo chmod 600 /etc/hysteria/server.key
  sudo chmod 644 /etc/hysteria/server.crt
  echo "自签名证书生成完毕 (有效期 10 年，伪装域名 www.bing.com)"
else
  echo "检测到已有证书，复用现有证书"
fi

say "5. 生成服务端配置文件 /etc/hysteria/config.yaml"
sudo tee /etc/hysteria/config.yaml >/dev/null <<EOF
listen: :${PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
sudo chmod 600 /etc/hysteria/config.yaml

say "6. 配置 systemd 服务"
sudo tee /etc/systemd/system/hysteria-server.service >/dev/null <<'EOF'
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hysteria-server
sudo systemctl restart hysteria-server

say "7. 开启内核 BBR"
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' | sudo tee /etc/sysctl.d/99-bbr.conf >/dev/null
sudo sysctl --system >/dev/null 2>&1 || true

say "8. 放行系统本地防火墙 UDP 端口 (${PORT})"
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow "${PORT}/udp"
  echo "ufw 已放行 udp/${PORT}"
elif command -v iptables >/dev/null 2>&1; then
  if ! sudo iptables -C INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 1 -p udp --dport "${PORT}" -j ACCEPT
    echo "iptables 已放行 udp/${PORT}"
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save 2>/dev/null || true
  fi
fi

say "9. 服务健康检查"
sleep 1
if sudo systemctl is-active hysteria-server >/dev/null 2>&1; then
  echo "==> hysteria-server 运行正常 (active)"
else
  warn "hysteria-server 启动异常，查看日志: sudo journalctl -u hysteria-server -n 30 --no-pager"
fi

if sudo ss -ulnp | grep -q "${PORT}"; then
  echo "==> UDP 端口 ${PORT} 正在正常监听"
else
  warn "未检测到 UDP 端口 ${PORT} 监听，请排查进程"
fi

echo -e "\n========================================================"
echo -e "\033[1;32m部署成功！请保存下方节点凭据：\033[0m"
echo -e "服务器 IP:   ${SERVER_IP}"
echo -e "连接端口:   ${PORT} (UDP)"
echo -e "连接密码:   ${PASSWORD}"
echo -e "伪装 SNI:   www.bing.com"
echo -e "跳过证书:   true (自签名证书)"
echo -e "========================================================\n"

echo "注意: 若使用的是 AWS / 阿里云 / 腾讯云 / Oracle 等云服务商，"
echo "请务必在云控制台的「安全组 / 网络安全规则」中，添加入站规则放行 UDP ${PORT} 端口！"
