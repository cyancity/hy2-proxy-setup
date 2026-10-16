# Hysteria 2 服务端与客户端防泄露完整部署指南

本目录包含将任意 Linux 服务器配置为 Hysteria 2 节点所需的全部服务端脚本、内核参数、systemd 单元以及客户端分流与防泄露配置。文档已格式化为可直接交付给 AI Agent（或运维人员）读取并执行的 SOP。

---

## 一、文件结构说明

```
server-hy2-setup/
├── README.md                          # 本说明与 Agent 执行指引
├── server/
│   ├── install.sh                     # 服务端一键安装脚本（自动判架构/自签名/BBR/防火墙/配置服务）
│   ├── config.yaml.template           # /etc/hysteria/config.yaml 配置模板
│   ├── hysteria-server.service        # /etc/systemd/system/hysteria-server.service 单元文件
│   └── 99-bbr.conf                    # /etc/sysctl.d/99-bbr.conf 内核 BBR 配置
└── client/
    ├── node.yaml                      # 单节点配置（可直接粘贴进已有的 Clash proxies 列表）
    ├── clash-verge-mihomo.yaml        # 完整 Clash Verge Rev / Mihomo 配置文件（含分流与防封规则）
    └── hardening-client.ps1           # Windows 客户端防 DNS 泄露加固脚本
```

---

## 二、给远端服务器 Agent 的执行指引

如果目标服务器上有 AI Agent（或通过 SSH 远程执行），让 Agent 完整执行以下指令即可全自动装好服务端：

```bash
# 1. 下载或写入 install.sh 到目标服务器
# 2. 赋予执行权限并执行（支持传入 HY2_PORT、HY2_PASSWORD、SERVER_TIMEZONE）
export HY2_PORT=2443
export SERVER_TIMEZONE="Asia/Singapore" # 可根据 VPS 所在地调整（如 America/Los_Angeles）
bash server/install.sh
```

### 部署脚本特性
1. **自动识别架构**：自动区分 `x86_64` (amd64) 与 `aarch64` (arm64)，下载对应的官方 Hysteria 2 二进制。
2. **自动生成凭据**：未预设密码时自动生成 16 位强随机密码，自动探测公网 IPv4。
3. **自签证书**：自动签发 10 年有效期的 EC prime256v1 证书，伪装域名设为 `www.bing.com`。
4. **内核 BBR 调优**：写入 `/etc/sysctl.d/99-bbr.conf` 并立即生效。
5. **防火墙放行**：自动识别 `ufw` 或 `iptables` 并放行 UDP 对应端口。
6. **BBR 自适应跑满带宽**：默认不设置固定 `bandwidth` 限速，完全由 Hysteria 2 拥塞控制根据实际链路跑满带宽。

---

## 三、时区与地区（Timezone & Locale）对齐原则

AI 服务（特别是 Claude / Anthropic 和 OpenAI）会在前端通过 JavaScript 调用 `Intl.DateTimeFormat().resolvedOptions().timeZone` 读取客户端浏览器的本地时区。

| 场景 | 风险与表现 | 应对方案 |
|---|---|---|
| **服务端时区** | 服务器时区与系统时间若错乱，会导致 TLS 证书握手校验失败或 systemd 日志排查困难。 | `install.sh` 已默认设置 `timedatectl set-timezone Asia/Singapore`（或根据节点所在地设置）。 |
| **客户端与出口 IP 属地一致** | 节点 IP 属地为新加坡/马来西亚（UTC+8），国内客户端默认也是 UTC+8（Asia/Shanghai），两者时区一致，无特征冲突。 | 无需额外修改，保持现状即可。 |
| **客户端与出口 IP 属地冲突** | 节点 IP 为美国（如 America/Los_Angeles），而客户端仍为 Asia/Shanghai，JS 会向风控接口上报不一致的时区信号，极易触发人机验证或封号。 | 1. 为 AI 业务建立独立的 Chrome / Edge Profile。<br>2. 安装 **Spoof Timezone** 等扩展，强制将该 Profile 的浏览器时区伪装为 VPS 所在时区。<br>3. 避免在系统全局硬改时区影响日常办公。 |

---

## 四、WebRTC / IPv6 / DNS 泄露防范与加固

根据本项目真实排查与测试记录，以下四项是导致真实位置暴露或 AI 连接异常的核心泄露面：

### 1. WebRTC 泄露
- **原理**：浏览器通过 WebRTC STUN 探测本机的真实 IP 地址用于 P2P 穿透。
- **现状与结论**：在 Clash Verge Rev 的 TUN 模式下，STUN 请求会被 TUN 虚拟网卡全量接管并走代理出栈。因此 WebRTC 探测出的公网 IP（`srflx`）就是代理 VPS 的出口 IP；仅剩一个本地局域网 IP（`host candidate`，如 `192.168.x.x`，属于 RFC 1918 私网保留地址，不可路由，无实质泄露风险）。
- **彻底阻断（可选）**：若需完全杜绝内网 IP 特征暴露，可在 Chrome 中设置 `webrtc.ip_handling_policy` 为 `disable_non_proxied_udp`，或安装 **WebRTC Control** 扩展彻底关闭 WebRTC。

### 2. IPv6 泄露
- **原理**：国内运营商通常分配公网 IPv6。如果代理客户端未妥善配置 IPv6，浏览器请求双栈站点时会通过物理网卡的 IPv6 直连目标网站，瞬间穿透代理暴露真实位置。
- **配置应对**：
  - 客户端配置 `client/clash-verge-mihomo.yaml` 中严格声明：
    ```yaml
    ipv6: false
    dns:
      ipv6: false
    ```
  - Windows 网卡层（可选）：在物理网卡属性中取消勾选「Internet 协议版本 6 (TCP/IPv6)」。

### 3. Windows 并行多宿主 DNS 泄露
- **原理**：Windows 的“智能多宿主名称解析”机制会向物理网卡和 TUN 虚拟网卡**同时**发送 DNS 查询。即使 TUN 劫持了流量，本地运营商和路由器仍能截获对境外域名的解析记录。
- **配置应对**：
  运行 `client/hardening-client.ps1`（管理员权限 PowerShell），写入注册表策略：
  ```powershell
  Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name DisableSmartNameResolution -Value 1 -Type DWord
  ```
  关闭后 Windows 仅使用优先级最高的 TUN 网卡（Metric 0）的 fake-ip 解析（`198.18.x.x`）。

### 4. QUIC (UDP:443) 阻断回退
- **原理**：AI 站点（如 Claude）普遍启用 HTTP/3 (QUIC)。在 TUN 虚拟网卡进行二次 UDP 封装转发时容易产生丢包重传冲突，导致网页长时间卡在白屏或握手失败。
- **配置应对**：
  在规则表前置以下规则：
  ```yaml
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  ```
  强制浏览器 QUIC 握手失败并回退到稳定的 HTTP/2 (TCP) 经由 Hysteria 2 隧道转发。

### 5. AI 三方依赖防误杀（Statsig 等）
- **原理**：Anthropic / OpenAI 前端依赖大量的灰度发布（Statsig）、验证码（Turnstile / Arkoselabs）、登录鉴权（Auth0）与监控（Sentry / Datadog）。主流广告拦截规则集（如 Loyalsoldier 的 `reject`）将 `statsig.com`、`datadoghq.com` 视为追踪器并 REJECT，导致页面加载白屏或功能异常。
- **配置应对**：
  `client/clash-verge-mihomo.yaml` 已将这些域名显式放在 `RULE-SET,reject` **之前**放行走代理。

---

## 五、验收与验证步骤

### 1. 服务端状态验证（服务器执行）
```bash
# 1. 检查服务是否 active
systemctl is-active hysteria-server

# 2. 检查 UDP 端口是否监听
sudo ss -ulnp | grep 2443

# 3. 检查 BBR 拥塞控制是否生效
sysctl net.ipv4.tcp_congestion_control
# 输出应包含: bbr
```

### 2. 客户端连通与防泄露验证（本机执行）
1. 将 `client/node.yaml` 填入真实 IP 和密码，导入客户端并开启 TUN 模式。
2. **DNS 劫持验证**（PowerShell）：
   ```powershell
   Resolve-DnsName claude.ai
   ```
   解析出的 IP 必须形如 `198.18.x.x`（fake-ip），不得为公网真实 IP。
3. **网页防泄露测试**：
   - 访问 `https://browserleaks.com/dns`：DNS 服务器必须全部为海外 IP，无国内运营商 DNS。
   - 访问 `https://browserleaks.com/webrtc`：Public IP 必须为服务器 IP，无真实国内 IP。
   - 访问 `https://ipleak.net`：IPv6 检测项应显示为“未检测到”或“走代理”。
