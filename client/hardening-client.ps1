# Windows 客户端防泄露与加固脚本（管理员权限运行）
# 作用:
# 1. 禁用 Windows 并行多宿主名称解析（彻底消除物理网卡 DNS 泄露）
# 2. 验证 TUN fake-ip 劫持是否生效
# 3. 提供 WebRTC / IPv6 / 出口 IP 检测指引

# 1. 禁用 Windows 智能多宿主名称解析
Write-Host "==> 正在配置注册表: 禁用智能多宿主名称解析 (防止向物理网卡泄露 DNS)..." -ForegroundColor Cyan
$RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
if (!(Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
}
Set-ItemProperty -Path $RegPath -Name "DisableSmartNameResolution" -Value 1 -Type DWord -Force
Write-Host "[OK] 已成功关闭 DisableSmartNameResolution" -ForegroundColor Green

# 2. 验证 DNS 解析是否已走 fake-ip (198.18.x.x)
Write-Host "`n==> 正在检测 claude.ai 的 DNS 解析结果..." -ForegroundColor Cyan
try {
    $dnsResult = Resolve-DnsName -Name "claude.ai" -Type A -ErrorAction Stop
    $ip = $dnsResult.IPAddress | Select-Object -First 1
    Write-Host "解析结果 IP: $ip"
    if ($ip -like "198.18.*") {
        Write-Host "[OK] 已成功命中 TUN fake-ip 隧道 (198.18.x.x)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] 未命中 fake-ip，可能 TUN 模式未开启或仍在使用本地 DNS" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] 解析失败，请确认 Clash Verge TUN 已启动" -ForegroundColor Red
}

# 3. 提示验证网站
Write-Host "`n==> 建议在浏览器中访问以下检测页面进行最终确认：" -ForegroundColor Cyan
Write-Host "1. DNS 泄露检测:     https://browserleaks.com/dns (不应出现国内运营商 DNS)"
Write-Host "2. WebRTC 泄露检测:  https://browserleaks.com/webrtc (Public IP 应为 VPS IP，不得暴露真实公网 IP)"
Write-Host "3. 全面泄露检测:     https://ipleak.net"
