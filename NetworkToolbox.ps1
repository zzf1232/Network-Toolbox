# ============================================================
#  网络工具箱 (PowerShell 版)
#  依赖：Windows 自带 PowerShell，无需安装任何其他组件
# ============================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PresetFile = Join-Path $ScriptRoot 'presets.json'
$SpeedFile  = Join-Path $ScriptRoot 'speed-history.csv'

# 启用 TLS 1.2，否则 Invoke-RestMethod 在旧系统上会连不上 HTTPS
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

try { $Host.UI.RawUI.WindowTitle = '网络工具箱' } catch {}

# 适当放大控制台窗口，保证分组菜单不被滚动截断
try {
    $raw = $Host.UI.RawUI
    $max = $raw.MaxWindowSize
    $w = [math]::Min(100, $max.Width)
    $h = [math]::Min(46, $max.Height)
    $raw.WindowSize = New-Object Management.Automation.Host.Size($w, $h)
    $raw.BufferSize = New-Object Management.Automation.Host.Size($w, [math]::Max($raw.BufferSize.Height, 300))
} catch { }

# ============================================================
#  输出辅助
# ============================================================
function TitleMsg { param($t) Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }
function InfoMsg  { param($m) Write-Host $m }
function OkMsg    { param($m) Write-Host $m -ForegroundColor Green }
function WarnMsg  { param($m) Write-Host $m -ForegroundColor Yellow }
function ErrMsg   { param($m) Write-Host $m -ForegroundColor Red }
function AskPause {
    Write-Host ''
    Write-Host '按回车返回主菜单...' -NoNewline
    [void][Console]::ReadLine()
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

$IsAdmin = Test-Admin

# ============================================================
#  网卡读取
# ============================================================
function Get-NicConfig {
    param([int]$idx)
    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            return Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                   Where-Object { $_.InterfaceIndex -eq $idx } | Select-Object -First 1
        }
        return Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
               Where-Object { $_.InterfaceIndex -eq $idx } | Select-Object -First 1
    } catch { return $null }
}

function Get-Adapters {
    $list = @()
    $lines = @(netsh interface ipv4 show interfaces 2>$null)
    foreach ($l in $lines) {
        $t = "$l".Trim()
        if ($t -notmatch '^(\d+)\s{2,}(\d+)\s{2,}(\d+)\s{2,}(\S+)\s{2,}(.+)$') { continue }
        $idx   = [int]$Matches[1]
        $state = $Matches[4]
        $name  = $Matches[5].Trim()
        $conn  = ($state -eq 'connected' -or $state -like '已连接*')
        $obj = [pscustomobject]@{
            Index     = $idx
            Name      = $name
            State     = $state
            Connected = $conn
            IP        = ''
            Mask      = ''
            Gateway   = ''
            Dns       = @()
            Mac       = ''
            Dhcp      = $false
        }
        $c = Get-NicConfig $idx
        if ($c) {
            foreach ($x in @($c.IPAddress)) {
                if ($x -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $obj.IP = $x; break }
            }
            foreach ($x in @($c.IPSubnet)) {
                if ($x -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $obj.Mask = $x; break }
            }
            foreach ($x in @($c.DefaultIPGateway)) {
                if ($x -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $obj.Gateway = $x; break }
            }
            if ($c.DNSServerSearchOrder) { $obj.Dns = @($c.DNSServerSearchOrder) }
            if ($c.MACAddress) { $obj.Mac = $c.MACAddress }
            if ($c.DHCPEnabled) { $obj.Dhcp = [bool]$c.DHCPEnabled }
        }
        $list += $obj
    }
    return $list
}

function Get-ActiveAdapter {
    $all = @(Get-Adapters)
    $conn = @($all | Where-Object {
        $_.Connected -and $_.Name -notlike '*Loopback*' -and $_.Name -notlike '*回环*'
    })
    if ($conn.Count -eq 0) { return $null }
    $withIp = @($conn | Where-Object { $_.IP -and $_.IP -ne '0.0.0.0' })
    if ($withIp.Count -gt 0) { return $withIp[0] }
    return $conn[0]
}

function Get-Gateway {
    param($adapter)
    if ($adapter -and $adapter.Gateway) { return $adapter.Gateway }
    return ''
}

# ============================================================
#  1. 随机换IP
# ============================================================
function Do-RandomIP {
    TitleMsg '随机换IP'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    if (-not $a.IP -or -not $a.Gateway) { ErrMsg '错误：无法读取当前IP或网关。'; return }

    InfoMsg "网卡: $($a.Name)"
    InfoMsg "网关: $($a.Gateway)"
    InfoMsg "原IP: $($a.IP)"

    $p = $a.IP -split '\.'
    if ($p.Count -ne 4) { ErrMsg '错误：IP格式异常。'; return }
    $prefix = "$($p[0]).$($p[1]).$($p[2])"
    $r = Get-Random -Minimum 30 -Maximum 230
    $new = "$prefix.$r"
    if ($new -eq $a.IP) { $new = "$prefix.$((Get-Random -Minimum 30 -Maximum 230))" }

    InfoMsg "目标IP: $new"
    InfoMsg '正在应用配置...'

    netsh interface ipv4 set address "$($a.Name)" static $new 255.255.255.0 $a.Gateway 1 2>&1 | Out-Null
    netsh interface ipv4 set dnsservers "$($a.Name)" static 114.114.114.114 primary 2>&1 | Out-Null
    ipconfig /flushdns 2>&1 | Out-Null

    InfoMsg '等待网络重新连接...'
    $check = ''
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $t = Get-ActiveAdapter
        if ($t -and $t.IP) { $check = $t.IP }
        if ($check -eq $new) { break }
    }
    InfoMsg "新IP: $check"
    if ($check -eq $new) { OkMsg '成功！IP修改已生效。' }
    else { WarnMsg '提示：IP未变更，该IP可能被占用，或需要以管理员身份运行。' }
}

# ============================================================
#  2. 手动设IP
# ============================================================
function Do-ManualIP {
    TitleMsg '手动设IP'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    InfoMsg "网卡: $($a.Name)"
    InfoMsg "当前IP: $($a.IP)   网关: $($a.Gateway)"

    $ip = Read-Host '新IP（留空取消）'
    if (-not $ip) { WarnMsg '已取消。'; return }
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { ErrMsg 'IP格式错误。'; return }

    $mask = Read-Host "子网掩码（回车默认 255.255.255.0）"
    if (-not $mask) { $mask = '255.255.255.0' }
    $gw = Read-Host "网关（回车默认 $($a.Gateway)）"
    if (-not $gw) { $gw = $a.Gateway }

    InfoMsg '正在应用配置...'
    netsh interface ipv4 set address "$($a.Name)" static $ip $mask $gw 1 2>&1 | Out-Null
    ipconfig /flushdns 2>&1 | Out-Null

    InfoMsg '等待网络重新连接...'
    $check = ''
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $t = Get-ActiveAdapter
        if ($t -and $t.IP) { $check = $t.IP }
        if ($check -eq $ip) { break }
    }
    InfoMsg "新IP: $check"
    if ($check -eq $ip) { OkMsg '成功！' } else { WarnMsg '提示：IP未变更，请检查IP是否冲突。' }
}

# ============================================================
#  3. 自动获取IP (DHCP)
# ============================================================
function Do-DHCP {
    TitleMsg '自动获取IP (DHCP)'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    InfoMsg "网卡: $($a.Name)"
    InfoMsg "原IP: $($a.IP)"
    InfoMsg '正在切换为DHCP...'

    netsh interface ipv4 set address "$($a.Name)" dhcp 2>&1 | Out-Null
    netsh interface ipv4 set dnsservers "$($a.Name)" dhcp 2>&1 | Out-Null
    ipconfig /release 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    ipconfig /renew 2>&1 | Out-Null

    $newIp = ''
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $t = Get-ActiveAdapter
        if ($t -and $t.IP) { $newIp = $t.IP; break }
    }
    InfoMsg "新IP: $(if ($newIp) { $newIp } else { '(暂未获取到)' })"
    if ($newIp -and $newIp -eq $a.IP) {
        WarnMsg '提示：IP未变化属正常，DHCP服务器通常给同一网卡分配同一地址。'
    }
    OkMsg 'DHCP已启用。'
}

# ============================================================
#  4. 网络信息
# ============================================================
function Do-NetworkInfo {
    TitleMsg '网络信息'
    $all = @(Get-Adapters)
    if ($all.Count -eq 0) { ErrMsg '未读取到任何网卡。'; return }
    foreach ($a in $all) {
        $stateTxt = if ($a.Connected) { '已连接' } else { '未连接' }
        Write-Host "----- [$($a.Index)] $($a.Name)  ($stateTxt) -----" -ForegroundColor Cyan
        InfoMsg "  IP地址  : $(if ($a.IP) { $a.IP } else { '-' })"
        InfoMsg "  子网掩码: $(if ($a.Mask) { $a.Mask } else { '-' })"
        InfoMsg "  默认网关: $(if ($a.Gateway) { $a.Gateway } else { '-' })"
        InfoMsg "  DNS     : $(if ($a.Dns.Count -gt 0) { $a.Dns -join ', ' } else { '-' })"
        InfoMsg "  MAC     : $(if ($a.Mac) { $a.Mac } else { '-' })"
        InfoMsg "  DHCP    : $(if ($a.Dhcp) { '是' } else { '否（静态IP）' })"
    }
}

# ============================================================
#  5. DNS切换
# ============================================================
function Do-DNSSwitch {
    TitleMsg 'DNS切换'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    InfoMsg "网卡: $($a.Name)"
    InfoMsg "当前DNS: $(if ($a.Dns.Count -gt 0) { $a.Dns -join ', ' } else { '自动获取' })"
    Write-Host ''
    InfoMsg '  1. 114DNS        (114.114.114.114 / 114.114.115.115)'
    InfoMsg '  2. 阿里DNS       (223.5.5.5 / 223.6.6.6)'
    InfoMsg '  3. 腾讯DNS       (119.29.29.29 / 182.254.116.116)'
    InfoMsg '  4. Google DNS    (8.8.8.8 / 8.8.4.4)'
    InfoMsg '  5. Cloudflare    (1.1.1.1 / 1.0.0.1)'
    InfoMsg '  6. 恢复自动获取'
    $sel = Read-Host '请选择'
    switch ($sel) {
        '1' { $p = '114.114.114.114'; $s = '114.114.115.115' }
        '2' { $p = '223.5.5.5';       $s = '223.6.6.6' }
        '3' { $p = '119.29.29.29';    $s = '182.254.116.116' }
        '4' { $p = '8.8.8.8';         $s = '8.8.4.4' }
        '5' { $p = '1.1.1.1';         $s = '1.0.0.1' }
        '6' {
            netsh interface ipv4 set dnsservers "$($a.Name)" dhcp 2>&1 | Out-Null
            ipconfig /flushdns 2>&1 | Out-Null
            OkMsg 'DNS已恢复为自动获取。'
            return
        }
        default { ErrMsg '无效选择。'; return }
    }
    netsh interface ipv4 set dnsservers "$($a.Name)" static $p primary 2>&1 | Out-Null
    netsh interface ipv4 add dnsservers "$($a.Name)" $s index=2 2>&1 | Out-Null
    ipconfig /flushdns 2>&1 | Out-Null
    OkMsg "DNS已设置为 $p / $s"
}

# ============================================================
#  6. 网络诊断
# ============================================================
function Do-Diagnostics {
    TitleMsg '网络诊断'
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    InfoMsg "网卡: $($a.Name)   IP: $($a.IP)   网关: $($a.Gateway)"

    InfoMsg ''
    InfoMsg '[1/4] 检查网卡状态'
    if ($a.Connected -and $a.IP) { OkMsg "  网卡正常，IP: $($a.IP)" } else { ErrMsg '  网卡未连接或未获取IP' }

    InfoMsg ''
    InfoMsg '[2/4] 检查网关连通性'
    if ($a.Gateway) {
        $r = Test-Connection -ComputerName $a.Gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($r) { OkMsg "  网关 $($a.Gateway) 可达" } else { ErrMsg "  网关 $($a.Gateway) 不可达" }
    } else { WarnMsg '  无网关，跳过' }

    InfoMsg ''
    InfoMsg '[3/4] 检查外部网络'
    $outOk = $false
    foreach ($t in @('223.5.5.5', 'www.baidu.com', '114.114.114.114')) {
        if (Test-Connection -ComputerName $t -Count 2 -Quiet -ErrorAction SilentlyContinue) {
            OkMsg "  外网可达（测试点 $t）"
            $outOk = $true
            break
        }
    }
    if (-not $outOk) { ErrMsg '  外网不可达' }

    InfoMsg ''
    InfoMsg '[4/4] 检查DNS解析'
    try {
        $d = Resolve-DnsName 'www.baidu.com' -ErrorAction Stop
        $addr = @($d | Where-Object { $_.IPAddress -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' } | Select-Object -First 1)
        if ($addr.Count -gt 0) { OkMsg "  DNS解析正常: $($addr[0].IPAddress)" }
        else { OkMsg '  DNS解析正常（仅返回IPv6地址）' }
    } catch { ErrMsg '  DNS解析失败' }
}

# ============================================================
#  7. 网络修复
# ============================================================
function Do-Repair {
    TitleMsg '网络修复'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    WarnMsg '将重置网络协议栈，修复完成后建议重启电脑。'
    $go = Read-Host '继续？(Y/N)'
    if ($go -notmatch '[Yy]') { WarnMsg '已取消。'; return }

    InfoMsg '清理DNS缓存...'
    ipconfig /flushdns 2>&1 | Out-Null
    InfoMsg '清理ARP表...'
    arp -d * 2>&1 | Out-Null
    InfoMsg '重置Winsock...'
    netsh winsock reset 2>&1 | Out-Null
    InfoMsg '重置IPv4协议栈...'
    netsh int ip reset 2>&1 | Out-Null
    InfoMsg '重新注册DNS...'
    ipconfig /registerdns 2>&1 | Out-Null
    InfoMsg '重新获取IP...'
    ipconfig /release 2>&1 | Out-Null
    ipconfig /renew 2>&1 | Out-Null

    OkMsg '修复完成。建议重启电脑使设置完全生效。'
}

# ============================================================
#  8. 预设管理
# ============================================================
function Load-Presets {
    $list = @()
    if (Test-Path $PresetFile) {
        try {
            $raw = Get-Content $PresetFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($item in @($raw)) { if ($null -ne $item) { $list += $item } }
        } catch { $list = @() }
    }
    return $list
}

function Save-Presets {
    param($list)
    $arr = @($list)
    if ($arr.Count -eq 0) {
        Set-Content -Path $PresetFile -Value '[]' -Encoding UTF8
        return
    }
    ConvertTo-Json -InputObject $arr -Depth 4 | Set-Content -Path $PresetFile -Encoding UTF8
}

function Do-PresetManager {
    TitleMsg '预设管理'
    $presets = @(Load-Presets)
    Write-Host ''
    InfoMsg '  1. 保存当前配置为预设'
    InfoMsg '  2. 应用已有预设'
    InfoMsg '  3. 删除预设'
    InfoMsg '  4. 查看预设列表'
    $sel = Read-Host '请选择'
    switch ($sel) {
        '1' {
            $a = Get-ActiveAdapter
            if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
            $name = Read-Host '预设名称'
            if (-not $name) { WarnMsg '已取消。'; return }
            $new = [pscustomobject]@{
                Name = $name; IP = $a.IP; Mask = $a.Mask; Gateway = $a.Gateway; Dns = @($a.Dns)
            }
            $kept = @($presets | Where-Object { $_.Name -ne $name })
            Save-Presets ($kept + $new)
            OkMsg "已保存预设：$name ($($a.IP))"
        }
        '2' {
            if ($presets.Count -eq 0) { WarnMsg '暂无预设。'; return }
            for ($i = 0; $i -lt $presets.Count; $i++) { InfoMsg "  $($i+1). $($presets[$i].Name)  [$($presets[$i].IP)]" }
            $n = Read-Host '选择编号'
            if ($n -notmatch '^\d+$') { ErrMsg '无效。'; return }
            $idx = [int]$n - 1
            if ($idx -lt 0 -or $idx -ge $presets.Count) { ErrMsg '编号超范围。'; return }
            $p = $presets[$idx]
            $a = Get-ActiveAdapter
            if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
            netsh interface ipv4 set address "$($a.Name)" static $p.IP $p.Mask $p.Gateway 1 2>&1 | Out-Null
            $dns = @($p.Dns)
            if ($dns.Count -gt 0) {
                netsh interface ipv4 set dnsservers "$($a.Name)" static $dns[0] primary 2>&1 | Out-Null
                for ($k = 1; $k -lt $dns.Count; $k++) {
                    netsh interface ipv4 add dnsservers "$($a.Name)" $dns[$k] "index=$($k+1)" 2>&1 | Out-Null
                }
            }
            ipconfig /flushdns 2>&1 | Out-Null
            OkMsg "已应用预设：$($p.Name)"
        }
        '3' {
            if ($presets.Count -eq 0) { WarnMsg '暂无预设。'; return }
            for ($i = 0; $i -lt $presets.Count; $i++) { InfoMsg "  $($i+1). $($presets[$i].Name)" }
            $n = Read-Host '选择要删除的编号'
            if ($n -notmatch '^\d+$') { ErrMsg '无效。'; return }
            $idx = [int]$n - 1
            if ($idx -lt 0 -or $idx -ge $presets.Count) { ErrMsg '编号超范围。'; return }
            $target = $presets[$idx].Name
            $rest = @()
            for ($i = 0; $i -lt $presets.Count; $i++) {
                if ($i -ne $idx) { $rest += $presets[$i] }
            }
            Save-Presets $rest
            OkMsg "已删除预设：$target"
        }
        '4' {
            if ($presets.Count -eq 0) { WarnMsg '暂无预设。'; return }
            foreach ($p in $presets) {
                InfoMsg "  $($p.Name): $($p.IP)  掩码 $($p.Mask)  网关 $($p.Gateway)"
            }
        }
        default { ErrMsg '无效选择。' }
    }
}

# ============================================================
#  9. 注册轮换模式
# ============================================================
function Do-RegistrationMode {
    TitleMsg '注册轮换模式'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    $a0 = Get-ActiveAdapter
    if (-not $a0 -or -not $a0.IP) { ErrMsg '错误：未检测到已连接的网卡。'; return }

    Write-Host ''
    InfoMsg '  1. DHCP 释放/续约（更快）'
    InfoMsg '  2. 静态随机IP（同网段）'
    $strategy = Read-Host '选择方式'
    if ($strategy -ne '2') { $strategy = '1' }

    $round = 0
    while ($true) {
        $round++
        $a = Get-ActiveAdapter
        if (-not $a -or -not $a.IP) { ErrMsg '错误：未检测到网卡。'; break }
        InfoMsg ''
        InfoMsg "----- 第 $round 轮 -----"
        InfoMsg "轮换前IP: $($a.IP)"

        # 清理缓存
        ipconfig /flushdns 2>&1 | Out-Null
        $localApp = $env:LOCALAPPDATA
        if ($localApp) {
            $cookies = @(
                "$localApp\Google\Chrome\User Data\Default\Network\Cookies",
                "$localApp\Microsoft\Edge\User Data\Default\Network\Cookies",
                "$localApp\BraveSoftware\Brave-Browser\User Data\Default\Network\Cookies"
            )
            foreach ($c in $cookies) { if (Test-Path $c) { Remove-Item $c -Force -ErrorAction SilentlyContinue } }
        }

        if ($strategy -eq '1') {
            ipconfig /release 2>&1 | Out-Null
            Start-Sleep -Milliseconds 800
            ipconfig /renew 2>&1 | Out-Null
        } else {
            $p = $a.IP -split '\.'
            if ($p.Count -eq 4 -and $a.Gateway) {
                $newIp = "$($p[0]).$($p[1]).$($p[2]).$((Get-Random -Minimum 30 -Maximum 230))"
                netsh interface ipv4 set address "$($a.Name)" static $newIp 255.255.255.0 $a.Gateway 1 2>&1 | Out-Null
            }
        }

        $newIpNow = ''
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 1
            $t = Get-ActiveAdapter
            if ($t -and $t.IP) { $newIpNow = $t.IP; break }
        }
        OkMsg "轮换后IP: $newIpNow"
        InfoMsg 'Cookie 和 DNS 缓存已清理。'

        $next = Read-Host '输入 R 再轮换一次，Q 退出'
        if ($next -notmatch '[Rr]') { break }
    }
    InfoMsg '已退出注册轮换模式。'
}

# ============================================================
#  10. 查询公网IP
# ============================================================
function Do-PublicIP {
    TitleMsg '查询公网IP'
    InfoMsg '正在查询...'

    # 依次尝试多个来源
    $sources = @(
        @{ Type = 'text'; Url = 'https://myip.ipip.net';                 Regex = '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})' },
        @{ Type = 'json'; Url = 'https://api.ipify.org?format=json';    Field = 'ip' },
        @{ Type = 'text'; Url = 'https://ifconfig.me/ip';               Regex = '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})' },
        @{ Type = 'json'; Url = 'https://ipinfo.io/json';               Field = 'ip' },
        @{ Type = 'json'; Url = 'https://ip-api.com/json/?lang=zh-CN';  Field = 'query' }
    )

    $ip = ''
    foreach ($s in $sources) {
        try {
            if ($s.Type -eq 'json') {
                $r = Invoke-RestMethod -Uri $s.Url -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
                $ip = [string]$r.$($s.Field)
            } else {
                $r = Invoke-RestMethod -Uri $s.Url -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
                if ("$r" -match $s.Regex) { $ip = $Matches[1] }
            }
        } catch { }
        if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { break }
        $ip = ''
    }

    if (-not $ip) { ErrMsg '查询失败，请检查网络连接或稍后重试。'; return }
    OkMsg "公网IP: $ip"

    # 补充归属地信息（失败不影响主结果）
    try {
        $info = Invoke-RestMethod -Uri "https://ip-api.com/json/$ip`?lang=zh-CN" -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
        if ($info.country) { InfoMsg "归属地: $($info.country) $($info.regionName) $($info.city)" }
        if ($info.isp)     { InfoMsg "运营商: $($info.isp)" }
    } catch { }
}

# ============================================================
#  11. WiFi扫描
# ============================================================
function Do-WiFiScan {
    TitleMsg 'WiFi扫描'
    $raw = @(netsh wlan show networks mode=bssid 2>&1)
    if (-not $raw -or ($raw -join '').Trim() -eq '') { ErrMsg '未检测到WiFi适配器。'; return }
    foreach ($l in $raw) { InfoMsg $l }
}

# ============================================================
#  12. 局域网扫描
# ============================================================
function Do-LanScan {
    TitleMsg '局域网扫描'
    $a = Get-ActiveAdapter
    if (-not $a -or -not $a.IP) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    $p = $a.IP -split '\.'
    $prefix = "$($p[0]).$($p[1]).$($p[2])"
    InfoMsg "扫描范围: $prefix.1 - $prefix.254"
    InfoMsg '正在扫描（约30秒，Ctrl+C 可中断）...'

    $tasks = @()
    for ($i = 1; $i -le 254; $i++) {
        $target = "$prefix.$i"
        if ($target -eq $a.IP) { continue }
        $ping = New-Object System.Net.NetworkInformation.Ping
        $tasks += [pscustomobject]@{ IP = $target; Task = $ping.SendPingAsync($target, 900) }
    }

    $alive = @()
    foreach ($t in $tasks) {
        try {
            $r = $t.Task.Result
            if ($r -and $r.Status -eq 'Success') { $alive += $t.IP }
        } catch { }
    }

    # 读取ARP表补充MAC
    $arp = @{}
    foreach ($l in @(arp -a 2>&1)) {
        if ($l -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+(?:[^\s]+\s+)?([0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2})') {
            $arp[$Matches[1]] = $Matches[2]
        }
    }

    InfoMsg ''
    OkMsg "发现 $($alive.Count) 台在线设备："
    foreach ($ip in ($alive | Sort-Object { [int]($_ -split '\.')[3] })) {
        $mac = if ($arp.ContainsKey($ip)) { $arp[$ip] } else { '-' }
        InfoMsg "  $ip    MAC: $mac"
    }
}

# ============================================================
#  13. 网络测速
# ============================================================
function Do-SpeedTest {
    TitleMsg '网络测速'
    $url = Read-Host '测速地址（回车使用默认 10MB 源）'
    if (-not $url) { $url = 'https://speed.cloudflare.com/__down?bytes=10000000' }
    $bytes = [int64]10000000
    if ($url -match 'bytes=(\d+)') { $bytes = [int64]$Matches[1] }

    InfoMsg '正在下载测速数据...'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        [void]$wc.DownloadData($url)
    } catch {
        ErrMsg "测速失败：$($_.Exception.Message)"
        return
    }
    $sw.Stop()
    $sec = $sw.Elapsed.TotalSeconds
    if ($sec -le 0) { $sec = 0.001 }

    $mbps = [math]::Round(($bytes * 8 / 1000000) / $sec, 2)
    $MBs  = [math]::Round(($bytes / 1MB) / $sec, 2)
    OkMsg "下载速度: $mbps Mbps   ($MBs MB/s)"
    OkMsg "耗时    : $([math]::Round($sec, 2)) 秒"

    if (-not (Test-Path $SpeedFile)) {
        Set-Content -Path $SpeedFile -Value '时间,Mbps,MBs' -Encoding UTF8
    }
    Add-Content -Path $SpeedFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$mbps,$MBs" -Encoding UTF8
    InfoMsg "已记录到 speed-history.csv"
}

# ============================================================
#  14. 智能DNS选优
# ============================================================
function Do-SmartDNS {
    TitleMsg '智能DNS选优'
    $servers = @(
        @{ Name = '114DNS';      IP = '114.114.114.114' },
        @{ Name = '阿里DNS';     IP = '223.5.5.5' },
        @{ Name = '腾讯DNS';     IP = '119.29.29.29' },
        @{ Name = 'Google DNS';  IP = '8.8.8.8' },
        @{ Name = 'Cloudflare';  IP = '1.1.1.1' }
    )
    InfoMsg '正在测试各 DNS 延迟...'
    $result = @()
    foreach ($s in $servers) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try { $r = $ping.Send($s.IP, 2000) } catch { $r = $null }
        if ($r -and $r.Status -eq 'Success') {
            $result += [pscustomobject]@{ Name = $s.Name; IP = $s.IP; Ms = $r.RoundtripTime }
            InfoMsg ("  {0,-12} {1,-16} {2} ms" -f $s.Name, $s.IP, $r.RoundtripTime)
        } else {
            InfoMsg ("  {0,-12} {1,-16} 超时" -f $s.Name, $s.IP)
        }
    }
    if ($result.Count -eq 0) { ErrMsg '全部超时。'; return }
    $best = $result | Sort-Object Ms | Select-Object -First 1
    OkMsg "最快的DNS: $($best.Name)  $($best.IP)  延迟 $($best.Ms)ms"

    $yes = Read-Host '是否切换到最快DNS？(Y/N)'
    if ($yes -match '[Yy]') {
        $a = Get-ActiveAdapter
        if (-not $a) { ErrMsg '未检测到活动网卡。'; return }
        netsh interface ipv4 set dnsservers "$($a.Name)" static $best.IP primary 2>&1 | Out-Null
        ipconfig /flushdns 2>&1 | Out-Null
        OkMsg "已切换到 $($best.IP)"
    }
}

# ============================================================
#  15. WiFi热点
# ============================================================
function Do-WiFiHotspot {
    TitleMsg 'WiFi热点'
    if (-not $IsAdmin) { ErrMsg '错误：本功能需要管理员权限。'; return }
    Write-Host ''
    InfoMsg '  1. 开启热点'
    InfoMsg '  2. 关闭热点'
    InfoMsg '  3. 查看状态'
    $sel = Read-Host '请选择'
    switch ($sel) {
        '1' {
            $ssid = Read-Host '热点名称 (SSID)'
            if (-not $ssid) { WarnMsg '已取消。'; return }
            $key = Read-Host '密码（8位以上）'
            if ($key.Length -lt 8) { ErrMsg '密码至少8位。'; return }
            netsh wlan set hostednetwork mode=allow "ssid=$ssid" "key=$key" 2>&1 | Out-Null
            $r = netsh wlan start hostednetwork 2>&1
            InfoMsg ($r -join "`n")
            WarnMsg '若提示不支持承载网络，说明该网卡驱动或系统不支持此功能。'
            WarnMsg '如无法上网，请在"网络适配器"中把热点网络与已联网网卡共享。'
        }
        '2' { netsh wlan stop hostednetwork 2>&1 | Out-Null; OkMsg '热点已关闭。' }
        '3' { $r = netsh wlan show hostednetwork 2>&1; foreach ($l in $r) { InfoMsg $l } }
        default { ErrMsg '无效选择。' }
    }
}

# ============================================================
#  16. 谁在偷流量
# ============================================================
function Do-TrafficMonitor {
    TitleMsg '谁在偷流量'
    InfoMsg '[当前网络连接数统计 - 按进程]'
    $rows = @()
    foreach ($l in @(netstat -ano 2>&1)) {
        if ($l -match 'TCP|UDP') {
            $parts = ($l.Trim() -split '\s+')
            if ($parts.Count -ge 5) {
                $rows += [pscustomobject]@{ Proto = $parts[0]; Local = $parts[1]; Remote = $parts[2]; State = $parts[3]; Pid = $parts[-1] }
            }
        }
    }
    $procs = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $procs[[string]$p.Id] = $p.ProcessName }

    $grouped = $rows | Group-Object Pid | Sort-Object Count -Descending
    foreach ($g in ($grouped | Select-Object -First 15)) {
        $pname = if ($procs.ContainsKey($g.Name)) { $procs[$g.Name] } else { '(未知)' }
        $eth = @($g.Group | Where-Object { $_.State -eq 'ESTABLISHED' }).Count
        InfoMsg ("  {0,-28} PID {1,-7} 连接 {2,3}  活跃 {3}" -f $pname, $g.Name, $g.Count, $eth)
    }

    InfoMsg ''
    InfoMsg '[局域网设备 ARP 表]'
    foreach ($l in @(arp -a 2>&1)) {
        if ($l -match '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') { InfoMsg "  $($l.Trim())" }
    }
    WarnMsg '如有陌生IP，可能是蹭网设备，可在路由器中拉黑。'
}

# ============================================================
#  17. 子网计算器
# ============================================================
function Do-SubnetCalc {
    TitleMsg '子网计算器'
    $input = Read-Host '请输入地址/掩码，如 192.168.1.62/24'
    if ($input -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        ErrMsg '格式错误，示例：192.168.1.62/24'
        return
    }
    $bits = [int]$Matches[5]
    if ($bits -lt 1 -or $bits -gt 32) { ErrMsg '掩码位数需在 1-32。'; return }

    $ipInt = [int64]$Matches[1] * 16777216 + [int64]$Matches[2] * 65536 + [int64]$Matches[3] * 256 + [int64]$Matches[4]
    $hostBits = 32 - $bits
    $maskInt = [int64]4294967295 - ([int64][math]::Pow(2, $hostBits) - 1)
    $netInt  = $ipInt -band $maskInt
    $bcastInt = $netInt + [int64]([math]::Pow(2, $hostBits) - 1)

    $toIp = {
        param([int64]$v)
        "$([math]::Floor($v / 16777216) % 256).$([math]::Floor($v / 65536) % 256).$([math]::Floor($v / 256) % 256).$($v % 256)"
    }

    $usable = 0
    if ($bits -le 30) { $usable = [math]::Pow(2, $hostBits) - 2 }
    elseif ($bits -eq 31) { $usable = 2 }

    InfoMsg ''
    OkMsg "网络地址  : $(& $toIp $netInt)/$bits"
    InfoMsg "子网掩码  : $(& $toIp $maskInt)"
    InfoMsg "广播地址  : $(& $toIp $bcastInt)"
    if ($bits -le 30) {
        InfoMsg "可用范围  : $(& $toIp ($netInt + 1)) - $(& $toIp ($bcastInt - 1))"
    } else {
        InfoMsg "可用范围  : $(& $toIp $netInt) - $(& $toIp $bcastInt)"
    }
    InfoMsg "可用主机数: $([int]$usable)"
    InfoMsg "随机换IP可选段: $(& $toIp ($netInt + 1)) 起的同网段地址"
}

# ============================================================
#  18. 测速记录曲线
# ============================================================
function Do-SpeedHistory {
    TitleMsg '测速记录曲线'
    if (-not (Test-Path $SpeedFile)) { WarnMsg '暂无记录，请先做一次「网络测速」。'; return }
    $lines = @(Get-Content $SpeedFile -Encoding UTF8)
    if ($lines.Count -le 1) { WarnMsg '暂无记录。'; return }

    $recs = @()
    foreach ($l in ($lines | Select-Object -Skip 1)) {
        $parts = $l -split ','
        if ($parts.Count -ge 2 -and $parts[1] -match '^\d') {
            $recs += [pscustomobject]@{ Time = $parts[0]; Mbps = [double]$parts[1] }
        }
    }
    if ($recs.Count -eq 0) { WarnMsg '记录格式异常。'; return }

    $max = ($recs | Measure-Object Mbps -Maximum).Maximum
    if ($max -le 0) { $max = 1 }
    foreach ($r in $recs) {
        $bar = [int]([math]::Round(($r.Mbps / $max) * 40))
        if ($bar -lt 1) { $bar = 1 }
        InfoMsg ("{0}  {1,7} Mbps  {2}" -f $r.Time, $r.Mbps, ('#' * $bar))
    }
    InfoMsg ''
    $avg = [math]::Round(($recs | Measure-Object Mbps -Average).Average, 2)
    OkMsg "记录数: $($recs.Count)   最高: $max Mbps   平均: $avg Mbps"
}

# ============================================================
#  19. Ping测试
# ============================================================
function Do-PingTest {
    TitleMsg 'Ping测试'
    $hostName = Read-Host '目标地址（回车默认 www.baidu.com）'
    if (-not $hostName) { $hostName = 'www.baidu.com' }
    $count = Read-Host '次数（回车默认 10）'
    if ($count -notmatch '^\d+$') { $count = 10 }

    $ok = 0; $fail = 0; $times = @()
    InfoMsg "正在 Ping $hostName，共 $count 次..."
    for ($i = 1; $i -le [int]$count; $i++) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try { $r = $ping.Send($hostName, 2000) } catch { $r = $null }
        if ($r -and $r.Status -eq 'Success') {
            $ok++
            $times += $r.RoundtripTime
            $ttl = if ($r.Options) { $r.Options.Ttl } else { '' }
            if ($ttl) { InfoMsg "  第 $i 次: $($r.RoundtripTime) ms  TTL=$ttl" }
            else      { InfoMsg "  第 $i 次: $($r.RoundtripTime) ms" }
        } else {
            $fail++
            InfoMsg "  第 $i 次: 超时"
        }
        Start-Sleep -Milliseconds 300
    }
    InfoMsg ''
    $loss = [math]::Round(($fail / [int]$count) * 100, 1)
    OkMsg "成功 $ok / $fail 失败   丢包率 $loss%"
    if ($times.Count -gt 0) {
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
        OkMsg "延迟    最小 $min ms   最大 $max ms   平均 $avg ms"
    }
}

# ============================================================
#  20. 路由追踪
# ============================================================
function Do-TraceRoute {
    TitleMsg '路由追踪'
    $hostName = Read-Host '目标地址（回车默认 www.baidu.com）'
    if (-not $hostName) { $hostName = 'www.baidu.com' }
    InfoMsg "正在追踪到 $hostName 的路由（Ctrl+C 可中断）..."
    InfoMsg ''
    tracert -d -w 1500 $hostName 2>&1 | ForEach-Object { InfoMsg $_ }
}

# ============================================================
#  常用 OUI 厂商表（MAC 前3字节）
# ============================================================
$OuiTable = @{
    '000C29'='VMware'; '005056'='VMware'; '001C42'='Parallels'
    '080027'='VirtualBox'; '0A0027'='VirtualBox'
    '0050F2'='MicroSoft'; '00155D'='Microsoft Hyper-V'; '0017FA'='Microsoft'
    '04CCBC'='H3C/新华三'; '60E0C4'='H3C/新华三'
    '00304F'='PLANET'; '0024A5'='H3C'; '0023'='-'
    'B4A4E3'='Hikvision 海康'; '44A9B3'='Hikvision 海康'; 'A0E6A1'='Hikvision 海康'
    'C0D67B'='Hikvision 海康'; '54010C'='Hikvision 海康'
    '04E229'='Dahua 大华'; '9C1412'='Dahua 大华'; '3CEF8C'='Dahua 大华'
    'D0B0C5'='TP-Link'; '1C5EE6'='TP-Link'; '60A4D4'='TP-Link'
    '001D0F'='TP-Link'; 'F0A0B1'='TP-Link'
    '00E0FC'='Huawei 华为'; '781DBA'='Huawei 华为'; 'AC85E8'='Huawei 华为'
    '002598'='Ruijie 锐捷'; 'D4F9A1'='Ruijie 锐捷'
    '001A2F'='Cisco'; '000C85'='Cisco'; '00D0B7'='Cisco'
    '0014D1'='Dell'; '0026B9'='Dell'; 'B0A460'='Dell'
    '0050BA'='D-Link'; '001CF0'='D-Link'; 'F0B2B9'='D-Link'
    '001B63'='Apple'; 'A45E60'='Apple'; 'F0766F'='Apple'
    '24B2B9'='Intel'; '3C5A87'='Intel'; '8C1645'='Intel'
    '001A11'='Google'; '0022FB'='Intel'; '00248C'='Intel'
    'D853BC'='Realtek 网卡'; '001A8C'='Realtek 网卡'
    '70B2D8'='Xiaomi 小米'; 'F8A45F'='Xiaomi 小米'
    '0017A4'='HP'; '0025B1'='HP'; '3CA82A'='HP'
    'F0DEE7'='Winstars'; '005069'='Linksys'; '00248F'='Realtek/网卡'
}

function Get-OuiVendor {
    param([string]$mac)
    if (-not $mac) { return '' }
    $hex = ($mac -replace '[-:\.]', '').ToUpper()
    if ($hex.Length -lt 6) { return '' }
    $prefix = $hex.Substring(0, 6)
    if ($OuiTable.ContainsKey($prefix)) { return $OuiTable[$prefix] }
    # 本地表查不到时尝试在线查询（失败静默）
    try {
        $r = Invoke-RestMethod -Uri "https://api.macvendors.com/$prefix" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($r) { return "$r" }
    } catch { }
    return '未知厂商'
}

# ============================================================
#  21. 网络健康检查
# ============================================================
function Do-HealthCheck {
    TitleMsg '网络健康检查'
    $a = Get-ActiveAdapter
    $pass = 0
    $total = 6

    if ($a -and $a.IP -and $a.IP -ne '0.0.0.0') {
        $pass++; OkMsg '[1/6] 网卡与IP  — 通过'
        InfoMsg "        $($a.Name)  $($a.IP)"
    } else { ErrMsg '[1/6] 网卡与IP  — 失败（未获取到IPv4地址）' }

    $gwOk = $false
    if ($a -and $a.Gateway) {
        $gwOk = Test-Connection -ComputerName $a.Gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
    }
    if ($gwOk) { $pass++; OkMsg "[2/6] 网关连通  — 通过  ($($a.Gateway))" }
    else { ErrMsg '[2/6] 网关连通  — 失败' }

    $loss = 100
    if ($a -and $a.Gateway) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $okCnt = 0
        for ($i = 0; $i -lt 5; $i++) {
            try { if ($ping.Send($a.Gateway, 1200).Status -eq 'Success') { $okCnt++ } } catch { }
        }
        $loss = [math]::Round((5 - $okCnt) / 5 * 100)
        if ($loss -le 20) { $pass++; OkMsg "[3/6] 丢包率    — 通过  ($($loss)%)" }
        else { WarnMsg "[3/6] 丢包率    — 偏高  ($($loss)%)" }
    } else { WarnMsg '[3/6] 丢包率    — 跳过（无网关）' }

    $dnsOk = $false
    try {
        $d = Resolve-DnsName 'www.baidu.com' -ErrorAction Stop
        if (@($d | Where-Object { $_.IPAddress }).Count -gt 0) { $dnsOk = $true }
    } catch { }
    if ($dnsOk) { $pass++; OkMsg '[4/6] DNS解析   — 通过' } else { ErrMsg '[4/6] DNS解析   — 失败' }

    $httpOk = $false
    foreach ($u in @('http://www.baidu.com', 'http://www.qq.com')) {
        try {
            $r = Invoke-WebRequest -Uri $u -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $httpOk = $true; break }
        } catch { }
    }
    if ($httpOk) { $pass++; OkMsg '[5/6] 外网HTTP  — 通过' } else { ErrMsg '[5/6] 外网HTTP  — 失败' }

    $pubOk = $false
    foreach ($s in @('223.5.5.5', '119.29.29.29', '8.8.8.8')) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try { if ($ping.Send($s, 2000).Status -eq 'Success') { $pubOk = $true; break } } catch { }
    }
    if ($pubOk) { $pass++; OkMsg '[6/6] 公共DNS   — 通过' } else { ErrMsg '[6/6] 公共DNS   — 失败' }

    $score = [int]([math]::Round($pass / $total * 100))
    $barLen = [int]([math]::Round($score / 100 * 30))
    InfoMsg ''
    $color = if ($score -ge 80) { 'Green' } elseif ($score -ge 50) { 'Yellow' } else { 'Red' }
    Write-Host ("  评分  [{0}{1}] {2} 分  ({3}/{4} 项通过)" -f ('#' * $barLen), ('-' * (30 - $barLen)), $score, $pass, $total) -ForegroundColor $color
}

# ============================================================
#  22. 端口扫描
# ============================================================
$PortServices = @{
    20='FTP数据'; 21='FTP'; 22='SSH'; 23='Telnet'; 25='SMTP'; 53='DNS'
    67='DHCP'; 68='DHCP'; 80='HTTP'; 81='HTTP备用'; 110='POP3'; 135='RPC'
    139='NetBIOS'; 143='IMAP'; 161='SNMP'; 389='LDAP'; 443='HTTPS'
    445='SMB'; 465='SMTPS'; 554='RTSP'; 587='SMTP'; 636='LDAPS'
    993='IMAPS'; 995='POP3S'; 1433='SQL Server'; 1521='Oracle'
    2049='NFS'; 2375='Docker'; 3306='MySQL'; 3389='远程桌面'
    5060='SIP'; 5432='PostgreSQL'; 5900='VNC'; 6379='Redis'
    8000='HTTP/摄像头'; 8001='摄像头'; 8080='HTTP代理'; 8081='HTTP'
    8443='HTTPS备用'; 8888='HTTP'; 9000='PHP-FPM'; 9100='打印机'
    37777='大华摄像头'; 11211='Memcached'; 27017='MongoDB'
}

function Do-PortScan {
    TitleMsg '端口扫描'
    $a = Get-ActiveAdapter
    $defaultHost = if ($a -and $a.Gateway) { $a.Gateway } else { '127.0.0.1' }
    $hostName = Read-Host "目标地址（回车默认 $defaultHost）"
    if (-not $hostName) { $hostName = $defaultHost }

    $portStr = Read-Host '端口（逗号分隔，回车扫描常用端口）'
    $ports = @()
    if ($portStr) {
        foreach ($x in ($portStr -split '[,\s]+')) { if ($x -match '^\d+$') { $ports += [int]$x } }
    }
    if ($ports.Count -eq 0) {
        $ports = @(21,22,23,25,53,80,135,139,443,445,554,1433,3306,3389,5060,8000,8080,8443,8888,37777)
    }

    InfoMsg "扫描 $hostName 的 $($ports.Count) 个端口..."
    $pending = @()
    foreach ($p in $ports) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $t = $c.ConnectAsync($hostName, $p)
            $pending += [pscustomobject]@{ Port = $p; Client = $c; Task = $t }
        } catch { try { $c.Close() } catch { } }
    }

    $open = @()
    foreach ($x in $pending) {
        try {
            if ($x.Task.Wait(1500) -and $x.Client.Connected) { $open += $x.Port }
        } catch { }
        try { $x.Client.Close() } catch { }
    }

    InfoMsg ''
    if ($open.Count -eq 0) { WarnMsg '没有发现开放端口（可能主机不在线或全部被过滤）。'; return }
    OkMsg "发现 $($open.Count) 个开放端口："
    foreach ($p in ($open | Sort-Object)) {
        $svc = if ($PortServices.ContainsKey($p)) { $PortServices[$p] } else { '未知服务' }
        InfoMsg ("  {0,-6} {1}" -f $p, $svc)
    }
}

# ============================================================
#  23. 主机发现（ARP + 厂商识别 + 全网段探测）
# ============================================================
function Read-ArpTable {
    $tbl = @()
    foreach ($l in @(arp -a 2>&1)) {
        if ($l -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+(?:[^\s]+\s+)?([0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2}-[0-9a-fA-F]{2})') {
            $tbl += [pscustomobject]@{ IP = $Matches[1]; Mac = ($Matches[2] -replace '-', ':').ToUpper() }
        }
    }
    return $tbl
}

function Do-HostDiscovery {
    TitleMsg '主机发现'
    $a = Get-ActiveAdapter
    if (-not $a -or -not $a.IP) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    $p = $a.IP -split '\.'
    $prefix = "$($p[0]).$($p[1]).$($p[2])"

    InfoMsg '  1. 快速模式（读 ARP 表）'
    InfoMsg '  2. 全网段探测（Ping 254 个地址，较慢）'
    $mode = Read-Host '请选择（回车默认 1）'

    $alive = @()
    if ($mode -eq '2') {
        InfoMsg "正在探测 $prefix.1 - $prefix.254 ..."
        $tasks = @()
        for ($i = 1; $i -le 254; $i++) {
            $target = "$prefix.$i"
            $ping = New-Object System.Net.NetworkInformation.Ping
            $tasks += [pscustomobject]@{ IP = $target; Task = $ping.SendPingAsync($target, 900) }
        }
        foreach ($t in $tasks) {
            try { if ($t.Task.Result.Status -eq 'Success') { $alive += $t.IP } } catch { }
        }
    }

    $arp = @(Read-ArpTable)
    $rows = @{}
    foreach ($r in $arp) {
        if ($r.IP -notmatch "^$([regex]::Escape($prefix))\.\d+$") { continue }
        if ($r.IP -like '*.255' -or $r.IP -like '224.*' -or $r.IP -like '239.*') { continue }
        $rows[$r.IP] = $r.Mac
    }
    foreach ($ip in $alive) {
        if (-not $rows.ContainsKey($ip)) { $rows[$ip] = '-' }
    }

    if ($rows.Count -eq 0) { WarnMsg '未发现局域网设备。'; return }

    InfoMsg ''
    OkMsg "发现 $($rows.Count) 台设备："
    InfoMsg ("  {0,-16} {1,-20} {2}" -f 'IP地址', 'MAC地址', '厂商')
    InfoMsg ('  ' + ('-' * 62))
    foreach ($ip in ($rows.Keys | Sort-Object { [int]($_ -split '\.')[3] })) {
        $mac = $rows[$ip]
        $vendor = if ($mac -eq '-') { '-' } else { Get-OuiVendor $mac }
        InfoMsg ("  {0,-16} {1,-20} {2}" -f $ip, $mac, $vendor)
    }
}

# ============================================================
#  24. 内网测速（对端延迟 / 丢包 / 抖动）
# ============================================================
function Do-LanTest {
    TitleMsg '内网测速（对端延迟/丢包）'
    $a = Get-ActiveAdapter
    $def = if ($a -and $a.Gateway) { $a.Gateway } else { '' }
    $target = Read-Host "对端地址（回车默认网关 $def）"
    if (-not $target) { $target = $def }
    if (-not $target) { ErrMsg '未指定地址。'; return }
    $count = Read-Host '测试次数（回车默认 20）'
    if ($count -notmatch '^\d+$') { $count = 20 }

    $ok = 0; $times = @()
    InfoMsg "正在测试 $target ..."
    for ($i = 1; $i -le [int]$count; $i++) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try { $r = $ping.Send($target, 1500) } catch { $r = $null }
        if ($r -and $r.Status -eq 'Success') { $ok++; $times += $r.RoundtripTime }
        Start-Sleep -Milliseconds 150
    }

    $loss = [math]::Round(($count - $ok) / $count * 100, 1)
    InfoMsg ''
    OkMsg "成功 $ok / $count    丢包 $loss%"
    if ($times.Count -gt 0) {
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
        $jitter = [math]::Round($max - $min, 1)
        OkMsg "延迟 最小 $min ms   最大 $max ms   平均 $avg ms   抖动 $jitter ms"
        if ($avg -lt 3) { OkMsg '结论：链路质量优秀（有线千兆正常水平）' }
        elseif ($avg -lt 10) { OkMsg '结论：链路质量良好' }
        elseif ($avg -lt 30) { WarnMsg '结论：延迟偏高，检查是否 WiFi 或链路拥塞' }
        else { ErrMsg '结论：延迟很高，检查线路、干扰或设备负载' }
    }
}

# ============================================================
#  25. DHCP 检测
# ============================================================
function Do-DhcpCheck {
    TitleMsg 'DHCP 检测'
    $all = @(Get-Adapters)
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }

    $raw = @(ipconfig /all 2>&1)
    $dhcpServer = ''; $leaseStart = ''; $leaseEnd = ''
    $inSection = $false
    foreach ($l in $raw) {
        if ($l -match [regex]::Escape($a.Name)) { $inSection = $true }
        elseif ($l -match '适配器|Adapter' -and $l -notmatch [regex]::Escape($a.Name)) { $inSection = $false }
        if (-not $inSection) { continue }
        if ($l -match 'DHCP\s*服务器|DHCP Server') { $dhcpServer = ($l -split ':', 2)[1].Trim() }
        if ($l -match '租约获得|Lease Obtained')  { $leaseStart = ($l -split ':', 2)[1].Trim() }
        if ($l -match '租约过期|Lease Expires')  { $leaseEnd   = ($l -split ':', 2)[1].Trim() }
    }

    InfoMsg "网卡      : $($a.Name)"
    InfoMsg "DHCP状态  : $(if ($a.Dhcp) { '已启用（动态）' } else { '未启用（静态IP）' })"
    InfoMsg "当前IP    : $($a.IP)"
    InfoMsg "子网掩码  : $($a.Mask)"
    InfoMsg "网关      : $($a.Gateway)"
    InfoMsg "DHCP服务器: $(if ($dhcpServer) { $dhcpServer } else { '(未获取)' })"
    InfoMsg "租约开始  : $(if ($leaseStart) { $leaseStart } else { '-' })"
    InfoMsg "租约到期  : $(if ($leaseEnd) { $leaseEnd } else { '-' })"

    if ($a.IP -match '^169\.254\.') {
        ErrMsg '警告：IP 为 169.254.x.x（APIPA），说明未拿到 DHCP 地址，网线或交换机可能有问题。'
    }
    if ($a.Mask -and $a.IP) {
        $p = $a.IP -split '\.'
        InfoMsg ''
        InfoMsg "子网范围  : $($p[0]).$($p[1]).$($p[2]).1 - $($p[0]).$($p[1]).$($p[2]).254（按 /24 估算）"
    }

    # 检测多个 DHCP 服务器（私接路由风险）
    $dhcpCnt = @($raw | Where-Object { $_ -match 'DHCP\s*服务器|DHCP Server' }).Count
    if ($dhcpCnt -gt 1) { WarnMsg "警告：检测到 $dhcpCnt 处 DHCP 服务器记录，可能存在私接路由，建议排查。" }
}

# ============================================================
#  26. IP 冲突检测
# ============================================================
function Do-IpConflict {
    TitleMsg 'IP 冲突检测'
    $a = Get-ActiveAdapter
    if (-not $a -or -not $a.IP) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    InfoMsg "本机IP: $($a.IP)   MAC: $($a.Mac)"

    $arp = @(Read-ArpTable)
    $dupIp = @{}
    foreach ($r in $arp) {
        if (-not $dupIp.ContainsKey($r.IP)) { $dupIp[$r.IP] = @() }
        if ($dupIp[$r.IP] -notcontains $r.Mac) { $dupIp[$r.IP] += $r.Mac }
    }

    $conflicts = @()
    foreach ($ip in $dupIp.Keys) { if ($dupIp[$ip].Count -gt 1) { $conflicts += $ip } }

    # 同一 MAC 对应多个 IP（IP 冲突的典型特征）
    $macIps = @{}
    foreach ($r in $arp) {
        if (-not $macIps.ContainsKey($r.Mac)) { $macIps[$r.Mac] = @() }
        $macIps[$r.Mac] += $r.IP
    }
    $multiIpMacs = @($macIps.Keys | Where-Object { $macIps[$_].Count -gt 1 })

    InfoMsg ''
    if ($conflicts.Count -gt 0) {
        ErrMsg "发现 $($conflicts.Count) 个 IP 被多个 MAC 占用："
        foreach ($ip in $conflicts) { ErrMsg "  $ip  ->  $($dupIp[$ip] -join ', ')" }
    } else {
        OkMsg 'ARP 表中未发现同一 IP 对应多个 MAC。'
    }

    if ($multiIpMacs.Count -gt 0) {
        WarnMsg "注意：以下 MAC 对应多个 IP（可能是代理ARP、双网卡或网关）："
        foreach ($m in $multiIpMacs) { WarnMsg "  $m  ->  $($macIps[$m] -join ', ')" }
    }

    # 检查本机 IP 是否在 ARP 表里被别的 MAC 占用
    foreach ($r in $arp) {
        if ($r.IP -eq $a.IP -and $a.Mac -and $r.Mac -ne ($a.Mac -replace '-', ':')) {
            ErrMsg "严重：本机IP $($a.IP) 被另一个 MAC $($r.Mac) 占用，确认存在 IP 冲突！"
        }
    }

    InfoMsg ''
    InfoMsg '提示：如需更准确结果，可先运行「主机发现 - 全网段探测」刷新 ARP 表后再检测。'
}

# ============================================================
#  27. 会话数测试（TCP 状态统计）
# ============================================================
function Do-SessionStats {
    TitleMsg '会话数测试（TCP连接状态）'
    $states = @{}
    $total = 0
    foreach ($l in @(netstat -ano 2>&1)) {
        if ($l -notmatch '^\s*TCP\s') { continue }
        $parts = ($l.Trim() -split '\s+')
        if ($parts.Count -lt 5) { continue }
        $st = $parts[3]
        if (-not $states.ContainsKey($st)) { $states[$st] = 0 }
        $states[$st]++
        $total++
    }
    if ($total -eq 0) { WarnMsg '未读取到 TCP 连接。'; return }

    OkMsg "TCP 连接总数: $total"
    InfoMsg ''
    $max = ($states.Values | Measure-Object -Maximum).Maximum
    foreach ($k in ($states.Keys | Sort-Object { $states[$_] } -Descending)) {
        $cnt = $states[$k]
        $bar = [int]([math]::Round($cnt / $max * 25))
        if ($bar -lt 1) { $bar = 1 }
        InfoMsg ("  {0,-14} {1,4}  {2}" -f $k, $cnt, ('#' * $bar))
    }
    InfoMsg ''
    if ($states.ContainsKey('TIME_WAIT') -and $states['TIME_WAIT'] -gt 500) {
        WarnMsg 'TIME_WAIT 偏多，可能是大量短连接，可考虑排查程序连接池设置。'
    }
    if ($states.ContainsKey('CLOSE_WAIT') -and $states['CLOSE_WAIT'] -gt 100) {
        ErrMsg 'CLOSE_WAIT 偏多，存在程序未正确关闭连接的问题。'
    }
}

# ============================================================
#  28. 路由表
# ============================================================
function Do-RouteTable {
    TitleMsg '路由表'
    $r = @(route print -4 2>&1)
    foreach ($l in $r) { InfoMsg $l }
}

# ============================================================
#  29. 环路检测
# ============================================================
function Do-LoopCheck {
    TitleMsg '环路检测'
    $a = Get-ActiveAdapter
    if (-not $a) { ErrMsg '错误：未检测到已连接的网卡。'; return }
    InfoMsg '正交检测（基于路由表 / ARP / 网关重复），仅供参考。'
    InfoMsg ''

    $risk = 0

    # 1 多个默认网关
    $gws = @{}
    foreach ($ad in @(Get-Adapters)) {
        if ($ad.Gateway) {
            if (-not $gws.ContainsKey($ad.Gateway)) { $gws[$ad.Gateway] = @() }
            $gws[$ad.Gateway] += $ad.Name
        }
    }
    $dupGw = @($gws.Keys | Where-Object { $gws[$_].Count -gt 1 })
    if ($dupGw.Count -gt 0) {
        ErrMsg '检测到多个网卡配置了同一网关（大概率形成环路）：'
        foreach ($g in $dupGw) { ErrMsg "  网关 $g 出现在: $($gws[$g] -join ', ')" }
        $risk++
    } else { OkMsg '默认网关唯一，正常。' }

    # 2 同一 MAC 出现在多个 IP
    $arp = @(Read-ArpTable)
    $macIps = @{}
    foreach ($r in $arp) {
        if (-not $macIps.ContainsKey($r.Mac)) { $macIps[$r.Mac] = @() }
        if ($macIps[$r.Mac] -notcontains $r.IP) { $macIps[$r.Mac] += $r.IP }
    }
    $multi = @($macIps.Keys | Where-Object { $macIps[$_].Count -gt 2 })
    if ($multi.Count -gt 0) {
        WarnMsg '以下 MAC 对应多个 IP，存在二层环路或代理ARP的可能：'
        foreach ($m in $multi) { WarnMsg "  $m  ->  $($macIps[$m] -join ', ')" }
        $risk++
    } else { OkMsg 'ARP 表中无同一 MAC 多 IP 现象。' }

    # 3 广播地址/组播占比异常
    $bcast = @($arp | Where-Object { $_.IP -like '*.255' -or $_.IP -like '224.*' -or $_.IP -like '239.*' }).Count
    if ($bcast -gt 10) { WarnMsg "ARP 表中广播/组播条目较多（$bcast 条），广播风暴风险偏高。" ; $risk++ }

    InfoMsg ''
    if ($risk -eq 0) { OkMsg '未发现明显环路迹象。' }
    else { ErrMsg "发现 $risk 项风险，建议检查交换机 STP 配置和接线。" }
    InfoMsg '深层检测需交换机支持（查看 STP / MAC 表）。'
}

# ============================================================
#  30. 摄像头扫描
# ============================================================
function Test-TcpPort {
    param([string]$ip, [int]$port, [int]$timeout = 800)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ip, $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($timeout)) { $c.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Get-HttpFingerprint {
    param([string]$ip, [int]$port = 80, [int]$timeout = 1500)
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($ip, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeout)) { return '' }
        $c.EndConnect($iar)
        $s = $c.GetStream()
        $s.ReadTimeout = $timeout
        $req = "GET / HTTP/1.0`r`nHost: $ip`r`nUser-Agent: Mozilla/5.0`r`n`r`n"
        $buf = [Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($buf, 0, $buf.Length)
        $sb = New-Object Text.StringBuilder
        $tmp = New-Object byte[] 2048
        $deadline = (Get-Date).AddMilliseconds($timeout)
        while ((Get-Date) -lt $deadline -and $sb.Length -lt 8192) {
            if (-not $s.DataAvailable) { Start-Sleep -Milliseconds 40; continue }
            $n = $s.Read($tmp, 0, $tmp.Length)
            if ($n -le 0) { break }
            [void]$sb.Append([Text.Encoding]::ASCII.GetString($tmp, 0, $n))
        }
        return $sb.ToString()
    } catch { return '' } finally { if ($c) { try { $c.Close() } catch { } } }
}

function Get-CameraVendorByText {
    param([string]$text, [int[]]$openPorts)
    if ($text) {
        if ($text -match 'Hikvision|DNVRS|Hikvision-Webs|webClient|IVMS') { return '海康威视' }
        if ($text -match 'Dahua|DAHUA|WebService|DahuaTech') { return '大华' }
        if ($text -match 'Kedacom|科达') { return '科达' }
        if ($text -match 'Uniview|UNV|uniview') { return '宇视' }
        if ($text -match 'TP-LINK|TP-Link|tplink|TL-IPC') { return 'TP-LINK' }
        if ($text -match 'Xiongmai|Netwave|XMEye|xm030') { return '雄迈/天视通' }
        if ($text -match 'Huawei|华为') { return '华为' }
        if ($text -match 'Server: Boa') { return '嵌入式设备(Boa)' }
    }
    if ($openPorts -contains 37777) { return '大华(端口37777)' }
    if ($openPorts -contains 8000)  { return '海康/摄像头(端口8000)' }
    if ($openPorts -contains 34567) { return '雄迈(端口34567)' }
    if ($openPorts -contains 554)   { return 'RTSP设备(端口554)' }
    return '未知设备'
}

function Do-CameraScan {
    TitleMsg '摄像头扫描'
    WarnMsg '说明：扫描基于 ICMP + 端口 + HTTP 指纹识别，仅用于自有内网排查。'
    $a = Get-ActiveAdapter
    if (-not $a -or -not $a.IP) { ErrMsg '错误：未获取到本机IP，无法确定网段。'; return }
    $seg = (($a.IP -split '\.')[0..2] -join '.')
    InfoMsg "本机: $($a.IP)   扫描网段: $seg.0/24"

    $sIn = Read-Host '起始地址 1-254（回车默认 1）'
    $eIn = Read-Host '结束地址 1-254（回车默认 120）'
    if ($sIn -notmatch '^\d+$') { $sIn = 1 }
    if ($eIn -notmatch '^\d+$') { $eIn = 120 }
    $s = [int]$sIn; $e = [int]$eIn
    if ($s -lt 1) { $s = 1 }; if ($e -gt 254) { $e = 254 }; if ($e -lt $s) { $e = $s }

    InfoMsg "正在探测 $seg.$s - $seg.$e ..."
    $tasks = @()
    for ($i = $s; $i -le $e; $i++) {
        $ip = "$seg.$i"
        try {
            $pg = New-Object System.Net.NetworkInformation.Ping
            $tasks += [pscustomobject]@{ Ip = $ip; Task = $pg.SendPingAsync($ip, 700) }
        } catch { }
    }
    $online = @()
    foreach ($t in $tasks) {
        try { if ($t.Task.Wait(1500) -and $t.Task.Result.Status -eq 'Success') { $online += $t.Ip } } catch { }
    }
    InfoMsg "在线主机: $($online.Count) 台"

    $probePorts = @(80, 8000, 8080, 81, 554, 37777, 34567)
    $arpNow = @(Read-ArpTable)
    $found = @()
    foreach ($ip in $online) {
        Write-Host "  检测 $ip ..." -ForegroundColor DarkGray
        $open = @()
        foreach ($p in $probePorts) { if (Test-TcpPort -ip $ip -port $p -timeout 500) { $open += $p } }
        if ($open.Count -eq 0) { continue }

        $text = ''
        foreach ($hp in @(80, 8000, 8080, 81)) {
            if ($open -contains $hp) { $text = Get-HttpFingerprint -ip $ip -port $hp; if ($text) { break } }
        }
        $vendor = Get-CameraVendorByText -text $text -openPorts $open
        if ($vendor -eq '未知设备') {
            $macRow = @($arpNow | Where-Object { $_.Ip -eq $ip } | Select-Object -First 1)
            if ($macRow.Count -gt 0) {
                $ov = Get-OuiVendor $macRow[0].Mac
                if ($ov -and $ov -ne '未知厂商') { $vendor = "$ov (通用设备)" }
            }
        }
        $found += [pscustomobject]@{ Ip = $ip; Vendor = $vendor; Ports = ($open -join ','); HasRtsp = ($open -contains 554); HasHttp = ($text -ne '') }
    }

    InfoMsg ''
    if ($found.Count -eq 0) {
        WarnMsg '未发现带常见摄像头端口的在线设备。'
        InfoMsg '可能原因：设备不在线 / 跨网段 / 已改端口 / 防火墙拦截。'
        return
    }
    Write-Host '  IP地址          厂商 / 类型                     开放端口        RTSP  Web' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------------------------' -ForegroundColor DarkCyan
    foreach ($f in $found) {
        $rtsp = if ($f.HasRtsp) { '是' } else { '否' }
        $web  = if ($f.HasHttp) { '是' } else { '否' }
        InfoMsg ("  {0,-15} {1,-30} {2,-14} {3,-5} {4}" -f $f.Ip, $f.Vendor, $f.Ports, $rtsp, $web)
    }
    InfoMsg ''
    OkMsg "共发现 $($found.Count) 台疑似网络摄像机/网络设备。"
    WarnMsg '提示：预览画面、改密码、升级固件需要厂商 SDK 与登录凭据，本工具不提供。'
}

# ============================================================
#  31. MAC 厂商查询
# ============================================================
function Do-MacLookup {
    TitleMsg 'MAC 厂商查询'
    $mac = Read-Host 'MAC地址（如 AA:BB:CC:DD:EE:FF，回车取消）'
    if (-not $mac) { WarnMsg '已取消。'; return }
    $hex = ($mac -replace '[-:\.\s]', '')
    if ($hex -notmatch '^[0-9A-Fa-f]{6,12}$') { ErrMsg 'MAC格式错误。'; return }
    $prefix = $hex.Substring(0, 6).ToUpper()
    InfoMsg "MAC: $($mac.ToUpper())"
    InfoMsg "OUI: $prefix"
    $v = Get-OuiVendor $mac
    OkMsg "厂商: $v"
}

# ============================================================
#  32. WiFi 已保存网络 + 密码查看
# ============================================================
function Do-WifiProfiles {
    TitleMsg 'WiFi 已保存网络 / 密码'
    $raw = @(netsh wlan show profiles 2>&1)
    $names = @()
    foreach ($l in $raw) {
        if ($l -match '^\s*(?:所有用户配置文件|All User Profile)\s*:\s*(.+?)\s*$') { $names += $Matches[1] }
    }
    if ($names.Count -eq 0) { WarnMsg '未读取到已保存的 WiFi 配置（或无线网卡未启用）。'; return }

    InfoMsg "已保存网络 ($($names.Count) 个)："
    for ($i = 0; $i -lt $names.Count; $i++) { InfoMsg ("  {0,2}. {1}" -f ($i + 1), $names[$i]) }
    InfoMsg ''
    $sel = Read-Host '输入编号查看该网络详情与密码（回车取消）'
    if ($sel -notmatch '^\d+$') { WarnMsg '已取消。'; return }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $names.Count) { ErrMsg '编号超出范围。'; return }

    $ssid = $names[$idx]
    $det = @(netsh wlan show profile name="$ssid" key=clear 2>&1)
    $auth = ''; $cipher = ''; $key = ''
    foreach ($l in $det) {
        if ($l -match '^\s*(?:身份验证|Authentication)\s*:\s*(.+?)\s*$') { $auth = $Matches[1] }
        elseif ($l -match '^\s*(?:密码|Cipher)\s*:\s*(.+?)\s*$') { $cipher = $Matches[1] }
        elseif ($l -match '^\s*(?:关键内容|Key Content)\s*:\s*(.+?)\s*$') { $key = $Matches[1] }
    }
    InfoMsg ''
    Write-Host "----- $ssid -----" -ForegroundColor Cyan
    InfoMsg "  认证方式: $(if ($auth) { $auth } else { '-' })"
    InfoMsg "  加密方式: $(if ($cipher) { $cipher } else { '-' })"
    if ($key) { OkMsg "  密码    : $key" }
    else { WarnMsg '  密码    : 未保存（开放网络 / 未勾选保存密码 / 无权限）' }
    InfoMsg ''
    InfoMsg '若未显示密码，请确认以管理员身份运行。'
}

# ============================================================
#  33. 串口工具
# ============================================================
function Read-SerialData {
    param($port, [int]$waitMs = 400)
    $end = (Get-Date).AddMilliseconds($waitMs)
    $sb = New-Object Text.StringBuilder
    while ((Get-Date) -lt $end) {
        try {
            if ($port.BytesToRead -gt 0) {
                $n = $port.BytesToRead
                $buf = New-Object byte[] $n
                [void]$port.Read($buf, 0, $n)
                [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf))
            }
        } catch { }
        Start-Sleep -Milliseconds 50
    }
    return $sb.ToString()
}

$PtzCmds = @(
    @{ N='云台上';   H='FF010008002029FF' },
    @{ N='云台下';   H='FF010010002031FF' },
    @{ N='云台左';   H='FF010004200025FF' },
    @{ N='云台右';   H='FF010002200023FF' },
    @{ N='变倍+';    H='FF010020000021FF' },
    @{ N='变倍-';    H='FF010040000041FF' },
    @{ N='停止';     H='FF010000000001FF' }
)

function Do-SerialTool {
    TitleMsg '串口工具'
    $ports = @()
    try { $ports = @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { }
    if ($ports.Count -eq 0) {
        WarnMsg '未检测到串口设备。'
        InfoMsg '常见原因：USB转串口驱动未安装（CH340 / CP2102 / FT232 / PL2303），或设备未插好。'
        return
    }
    InfoMsg "检测到串口: $($ports -join ', ')"
    $pname = Read-Host '选择串口（如 COM3，回车取消）'
    if (-not $pname) { WarnMsg '已取消。'; return }
    $pname = "$pname".Trim().ToUpper()
    if ($ports -notcontains $pname) { ErrMsg '该串口不存在。'; return }

    $baudS = Read-Host '波特率（回车默认 9600，常用 9600/19200/38400/115200）'
    if ($baudS -notmatch '^\d+$') { $baudS = 9600 }

    $port = $null
    try {
        $port = New-Object System.IO.Ports.SerialPort $pname, [int]$baudS, 'None', 8, 'One'
        $port.ReadTimeout = 500
        $port.WriteTimeout = 500
        $port.Open()
    } catch {
        ErrMsg "打开串口失败：$($_.Exception.Message)"
        WarnMsg '若串口被其他软件占用（组态软件/调试工具），请先关闭它。'
        return
    }
    OkMsg "已打开 $pname @ $baudS (8N1)"
    InfoMsg '直接输入文本回车发送 | hex:FF0100080020FF 按十六进制发送 | ptz 查看485云台指令 | r 读取 | q 退出'

    while ($true) {
        Write-Host '串口> ' -NoNewline
        $line = [Console]::ReadLine()
        if ($null -eq $line) { break }
        $line = "$line".Trim()
        if ($line -eq '') { continue }
        if ($line -eq 'q' -or $line -eq 'Q') { break }
        if ($line -eq 'r' -or $line -eq 'R') {
            $d = Read-SerialData -port $port -waitMs 1000
            if ($d) { InfoMsg "收到: $d" } else { WarnMsg '(无数据)' }
            continue
        }
        if ($line -eq 'ptz') {
            InfoMsg '485云台指令（Pelco-D，地址1，速度0x20）：'
            foreach ($c in $PtzCmds) { InfoMsg ("  {0,-8} {1}" -f $c.N, $c.H) }
            InfoMsg '发送示例：hex:FF010008002029FF'
            continue
        }
        try {
            if ($line -match '^hex:\s*([0-9A-Fa-f\s]+)$') {
                $hx = ($Matches[1] -replace '\s', '')
                if ($hx.Length % 2 -ne 0) { ErrMsg '十六进制长度必须为偶数。'; continue }
                $bytes = New-Object byte[] ([int]($hx.Length / 2))
                for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hx.Substring($i * 2, 2), 16) }
                $port.Write($bytes, 0, $bytes.Length)
                InfoMsg "已发送 $($bytes.Length) 字节"
            } else {
                $port.Write($line)
                InfoMsg "已发送: $line"
            }
            $d = Read-SerialData -port $port -waitMs 500
            if ($d) { InfoMsg "收到: $d" }
        } catch { ErrMsg "发送失败：$($_.Exception.Message)" }
    }
    try { $port.Close() } catch { }
    OkMsg '串口已关闭。'
}

# ============================================================
#  34. WOL 网络唤醒
# ============================================================
function Do-WOL {
    TitleMsg 'WOL 网络唤醒'
    $macIn = Read-Host '目标MAC（如 AA:BB:CC:DD:EE:FF，回车取消）'
    if (-not $macIn) { WarnMsg '已取消。'; return }
    $hex = ($macIn -replace '[-:\.\s]', '')
    if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { ErrMsg 'MAC格式错误，需要12位十六进制。'; return }

    $macBytes = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    $pkt = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $pkt[$i] = 0xFF }
    for ($i = 1; $i -le 16; $i++) {
        for ($j = 0; $j -lt 6; $j++) { $pkt[$i * 6 + $j] = $macBytes[$j] }
    }
    InfoMsg "魔术包: 6字节FF + MAC×16 = $($pkt.Length) 字节"

    $targets = @()
    $a = Get-ActiveAdapter
    if ($a -and $a.IP) {
        $seg = (($a.IP -split '\.')[0..2] -join '.')
        $targets += "$seg.255"
    }
    $targets += '255.255.255.255'

    $udp = $null
    $sent = 0
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.EnableBroadcast = $true
        foreach ($t in $targets) {
            foreach ($pt in @(9, 7)) {
                try {
                    [void]$udp.Send($pkt, $pkt.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($t), $pt)))
                    $sent++
                    OkMsg "已发送 -> ${t}:$pt"
                } catch { ErrMsg "发送失败 $t`:$pt - $($_.Exception.Message)" }
            }
        }
    } catch { ErrMsg "创建UDP失败：$($_.Exception.Message)" }
    finally { if ($udp) { $udp.Close() } }

    InfoMsg ''
    if ($sent -gt 0) { OkMsg "共发送 $sent 个魔术包。" }
    InfoMsg '若目标机没开机，请检查：BIOS 中 Wake on LAN 已开启、网卡属性"关机网络唤醒"已启用、目标与本机在同一广播域。'
}

# ============================================================
#  35. 防火墙配置
# ============================================================
function Do-Firewall {
    TitleMsg '防火墙配置'
    while ($true) {
        InfoMsg '当前防火墙状态：'
        $ok = $false
        try {
            $profs = @(Get-NetFirewallProfile -ErrorAction Stop)
            foreach ($p in $profs) {
                $st = if ($p.Enabled) { '已启用' } else { '已关闭' }
                $col = if ($p.Enabled) { 'Green' } else { 'Yellow' }
                Write-Host ("  {0,-10} : {1}" -f $p.Name, $st) -ForegroundColor $col
            }
            $ok = $true
        } catch { }
        if (-not $ok) {
            foreach ($l in @(netsh advfirewall show allprofiles state 2>&1)) { InfoMsg "  $l" }
        }
        InfoMsg ''
        InfoMsg '  1. 开启全部配置文件防火墙'
        InfoMsg '  2. 关闭全部配置文件防火墙（排查临时使用）'
        InfoMsg '  0. 返回主菜单'
        $c = Read-Host '请选择'
        if ($null -eq $c) { return }
        $c = "$c".Trim()
        if ($c -eq '0' -or $c -eq '') { return }
        if (-not $IsAdmin) { ErrMsg '需要管理员权限。'; continue }
        if ($c -eq '1') {
            $r = netsh advfirewall set allprofiles state on 2>&1
            foreach ($l in @($r)) { InfoMsg "  $l" }
            OkMsg '已请求开启防火墙。'
        } elseif ($c -eq '2') {
            WarnMsg '关闭防火墙会让本机暴露在局域网扫描风险中，仅建议临时排查使用。'
            $yn = Read-Host '确认关闭？输入 y 确认'
            if ($yn -ne 'y' -and $yn -ne 'Y') { WarnMsg '已取消。'; continue }
            $r = netsh advfirewall set allprofiles state off 2>&1
            foreach ($l in @($r)) { InfoMsg "  $l" }
            WarnMsg '防火墙已关闭。'
        } else { ErrMsg '无效选择。' }
    }
}

# ============================================================
#  36. 端口映射 (netsh portproxy)
# ============================================================
function Do-PortProxy {
    TitleMsg '端口映射 (portproxy)'
    if (-not $IsAdmin) { WarnMsg '提示：查看无需权限，增删需要管理员权限。' }
    while ($true) {
        InfoMsg '当前 v4tov4 规则：'
        foreach ($l in @(netsh interface portproxy show v4tov4 2>&1)) { InfoMsg "  $l" }
        InfoMsg ''
        InfoMsg '  1. 添加规则'
        InfoMsg '  2. 删除规则'
        InfoMsg '  3. 清空所有规则'
        InfoMsg '  0. 返回主菜单'
        $c = Read-Host '请选择'
        if ($null -eq $c) { return }
        $c = "$c".Trim()
        if ($c -eq '0' -or $c -eq '') { return }

        if ($c -eq '1') {
            if (-not $IsAdmin) { ErrMsg '需要管理员权限。'; continue }
            $la = Read-Host '监听地址（回车默认 0.0.0.0）'
            if (-not $la) { $la = '0.0.0.0' }
            $lp = Read-Host '监听端口（如 8080）'
            $ca = Read-Host '目标地址（如 192.168.1.100）'
            $cp = Read-Host '目标端口（如 80）'
            if ($lp -notmatch '^\d+$' -or $cp -notmatch '^\d+$' -or -not $ca) { ErrMsg '参数不完整或格式错误。'; continue }
            InfoMsg "netsh interface portproxy add v4tov4 listenaddress=$la listenport=$lp connectaddress=$ca connectport=$cp"
            foreach ($l in @(netsh interface portproxy add v4tov4 "listenaddress=$la" "listenport=$lp" "connectaddress=$ca" "connectport=$cp" 2>&1)) { InfoMsg "  $l" }
            OkMsg '添加完成。'
        } elseif ($c -eq '2') {
            if (-not $IsAdmin) { ErrMsg '需要管理员权限。'; continue }
            $la = Read-Host '监听地址（回车默认 0.0.0.0）'
            if (-not $la) { $la = '0.0.0.0' }
            $lp = Read-Host '监听端口'
            if ($lp -notmatch '^\d+$') { ErrMsg '端口格式错误。'; continue }
            foreach ($l in @(netsh interface portproxy delete v4tov4 "listenaddress=$la" "listenport=$lp" 2>&1)) { InfoMsg "  $l" }
            OkMsg '删除完成。'
        } elseif ($c -eq '3') {
            if (-not $IsAdmin) { ErrMsg '需要管理员权限。'; continue }
            $yn = Read-Host '确认清空所有映射规则？输入 y 确认'
            if ($yn -ne 'y' -and $yn -ne 'Y') { WarnMsg '已取消。'; continue }
            foreach ($l in @(netsh interface portproxy reset 2>&1)) { InfoMsg "  $l" }
            OkMsg '已清空。'
        } else { ErrMsg '无效选择。' }
    }
}

# ============================================================
#  37. 抓包分析
# ============================================================
$CaptureDir = Join-Path $env:TEMP 'NetworkToolboxCaptures'

function Get-TSharkPath {
    $c = Get-Command tshark -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $env:ProgramFiles 'Wireshark\tshark.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Wireshark\tshark.exe'),
        'C:\Program Files\Wireshark\tshark.exe',
        'C:\Program Files (x86)\Wireshark\tshark.exe'
    )
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }
    return ''
}

function Ensure-CaptureDir {
    if (-not (Test-Path $CaptureDir)) { New-Item -ItemType Directory -Path $CaptureDir -Force | Out-Null }
}

function Do-CaptureMenu {
    TitleMsg '抓包分析'
    $ts = Get-TSharkPath
    if ($ts) { OkMsg "已检测到 TShark 引擎: $ts" }
    else {
        WarnMsg '未检测到 TShark（Wireshark 命令行）。将使用系统自带 netsh trace 抓包。'
        InfoMsg 'netsh 抓的是 ETL 格式，协议解析能力弱于 Wireshark；装 Wireshark 后本工具会自动使用 TShark。'
    }
    while ($true) {
        InfoMsg ''
        InfoMsg '  1. 列出可用网卡'
        InfoMsg '  2. 开始抓包'
        InfoMsg '  3. 停止抓包 / 转换文件'
        InfoMsg '  4. 分析最近的抓包文件'
        InfoMsg '  0. 返回主菜单'
        $c = Read-Host '请选择'
        if ($null -eq $c) { return }
        $c = "$c".Trim()
        if ($c -eq '0' -or $c -eq '') { return }

        if ($c -eq '1') {
            if ($ts) {
                InfoMsg "引擎: TShark"
                foreach ($l in @(& $ts -D 2>&1)) { InfoMsg "  $l" }
            } else {
                foreach ($l in @(netsh trace show interfaces 2>&1)) { InfoMsg "  $l" }
            }
        }
        elseif ($c -eq '2') {
            if (-not $IsAdmin) { ErrMsg '抓包需要管理员权限。'; continue }
            Ensure-CaptureDir
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            if ($ts) {
                $iface = Read-Host '网卡编号（见「列出可用网卡」的序号，如 3）'
                if ($iface -notmatch '^\d+$') { ErrMsg '网卡编号错误。'; continue }
                $dur = Read-Host '抓包时长秒数（回车默认 15）'
                if ($dur -notmatch '^\d+$') { $dur = 15 }
                $out = Join-Path $CaptureDir "$stamp.pcapng"
                InfoMsg "正在抓包 $dur 秒，文件：$out"
                $task = Start-Process -FilePath $ts -ArgumentList @('-i', $iface, '-w', "`"$out`"", '-a', "duration:$dur") -NoNewWindow -PassThru
                $task.WaitForExit()
                if (Test-Path $out) { OkMsg "抓包完成: $out" } else { ErrMsg '抓包失败，请检查网卡编号和权限。' }
            } else {
                $out = Join-Path $CaptureDir "$stamp.etl"
                $dur = Read-Host '抓包时长秒数（回车默认 15）'
                if ($dur -notmatch '^\d+$') { $dur = 15 }
                InfoMsg "正在抓包 $dur 秒，文件：$out"
                $r1 = netsh trace start capture=yes tracefile="$out" maxsize=200 overwrite=yes 2>&1
                foreach ($l in @($r1)) { InfoMsg "  $l" }
                for ($i = $dur; $i -gt 0; $i--) {
                    Write-Host "`r  剩余 $i 秒 ..." -NoNewline -ForegroundColor DarkGray
                    Start-Sleep -Seconds 1
                }
                Write-Host ''
                foreach ($l in @(netsh trace stop 2>&1)) { InfoMsg "  $l" }
                if (Test-Path $out) { OkMsg "抓包完成: $out" } else { ErrMsg '抓包失败。' }
            }
        }
        elseif ($c -eq '3') {
            if (-not $IsAdmin) { ErrMsg '需要管理员权限。'; continue }
            foreach ($l in @(netsh trace stop 2>&1)) { InfoMsg "  $l" }
            $etl = @(Get-ChildItem -Path $CaptureDir -Filter *.etl -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($etl.Count -eq 0) { WarnMsg '没有找到 .etl 文件。'; continue }
            $src = $etl[0].FullName
            $dstCap = [IO.Path]::ChangeExtension($src, '.cap')
            InfoMsg "转换 $src"
            $r = netsh trace convert input="$src" output="$dstCap" dump=cap overwrite=yes 2>&1
            foreach ($l in @($r)) { InfoMsg "  $l" }
            if (Test-Path $dstCap) { OkMsg "已生成 $dstCap（可用 Wireshark 打开）" }
            else {
                WarnMsg 'cap 转换不可用，改用文本格式。'
                $dstTxt = [IO.Path]::ChangeExtension($src, '.txt')
                foreach ($l in @(netsh trace convert input="$src" output="$dstTxt" dump=txt overwrite=yes 2>&1)) { InfoMsg "  $l" }
                if (Test-Path $dstTxt) { OkMsg "已生成 $dstTxt" }
            }
        }
        elseif ($c -eq '4') {
            if (-not (Test-Path $CaptureDir)) { WarnMsg '还没有任何抓包文件。'; continue }
            $files = @(Get-ChildItem -Path $CaptureDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($files.Count -eq 0) { WarnMsg '还没有任何抓包文件。'; continue }
            for ($i = 0; $i -lt $files.Count -and $i -lt 15; $i++) {
                InfoMsg ("  {0,2}. {1}  {2:N1} KB" -f ($i + 1), $files[$i].Name, ($files[$i].Length / 1KB))
            }
            $sel = Read-Host '选择要分析的文件编号'
            if ($sel -notmatch '^\d+$') { continue }
            $idx = [int]$sel - 1
            if ($idx -lt 0 -or $idx -ge $files.Count) { ErrMsg '编号超出范围。'; continue }
            $f = $files[$idx]

            if ($ts -and $f.Extension -in @('.pcap', '.pcapng', '.cap')) {
                $n = Read-Host '显示前多少个数据包（回车默认 30）'
                if ($n -notmatch '^\d+$') { $n = 30 }
                InfoMsg "数据包摘要（TShark）："
                $targs = @('-r', $f.FullName, '-c', $n, '-T', 'fields',
                          '-e', 'frame.number', '-e', 'frame.time_relative',
                          '-e', 'ip.src', '-e', 'ip.dst',
                          '-e', '_ws.col.Protocol', '-e', '_ws.col.Info',
                          '-E', 'separator=|')
                foreach ($l in @(& $ts @targs 2>&1)) {
                    $p = "$l" -split '\|'
                    if ($p.Count -ge 6) {
                        InfoMsg ("  #{0,-5} {1,8}s  {2,-15} -> {3,-15} {4,-8} {5}" -f $p[0], $p[1], $p[2], $p[3], $p[4], $p[5])
                    } else { InfoMsg "  $l" }
                }
                InfoMsg ''
                InfoMsg '协议统计：'
                foreach ($l in @(& $ts -r $f.FullName -q -z 'io,phs' 2>&1 | Select-Object -First 40)) { InfoMsg "  $l" }
            }
            elseif ($f.Extension -eq '.txt') {
                $lines = @(Get-Content $f.FullName -TotalCount 120)
                foreach ($l in $lines) { InfoMsg "  $l" }
            }
            else {
                WarnMsg '该格式需要 Wireshark/TShark 才能解析。'
                InfoMsg '本工具可做的事：上面第 3 项「停止抓包 / 转换文件」可把 ETL 转成 .cap。'
                InfoMsg '安装 Wireshark 后，本工具会自动启用 TShark 数据包列表与协议统计。'
            }
        }
        else { ErrMsg '无效选择。' }
    }
}

# ============================================================
#  38. 运维命令库
# ============================================================
$DevCmds = @(
    @{ Name = '华为 / H3C 交换机'; Cmds = @(
        @{ C='基础'; K='display version'; D='查看版本与运行时间' },
        @{ C='基础'; K='display current-configuration'; D='查看当前配置' },
        @{ C='基础'; K='display interface brief'; D='端口状态总览' },
        @{ C='基础'; K='display mac-address'; D='MAC地址表（查终端接哪个口）' },
        @{ C='基础'; K='display arp all'; D='ARP表' },
        @{ C='VLAN'; K='display vlan'; D='VLAN信息' },
        @{ C='VLAN'; K='vlan 10 / port link-type access / port default vlan 10'; D='华为配置接入VLAN' },
        @{ C='VLAN'; K='interface GigabitEthernet0/0/1 / port link-type trunk / port trunk allow-pass vlan 10 20'; D='华为配置Trunk' },
        @{ C='排障'; K='display cpu-usage / display memory-usage'; D='CPU与内存占用' },
        @{ C='排障'; K='display logbuffer'; D='查看日志（告警/端口up-down）' },
        @{ C='排障'; K='display stp brief'; D='生成树状态（查环路）' },
        @{ C='排障'; K='reset counters interface'; D='清零端口计数（重新统计错包）' }
    )},
    @{ Name = 'Cisco'; Cmds = @(
        @{ C='基础'; K='show version'; D='版本信息' },
        @{ C='基础'; K='show running-config'; D='当前配置' },
        @{ C='基础'; K='show ip interface brief'; D='接口IP与状态' },
        @{ C='基础'; K='show mac address-table'; D='MAC地址表' },
        @{ C='基础'; K='show arp'; D='ARP表' },
        @{ C='VLAN'; K='show vlan brief'; D='VLAN信息' },
        @{ C='VLAN'; K='switchport mode trunk / switchport trunk allowed vlan 10,20'; D='配置Trunk' },
        @{ C='排障'; K='show interfaces status / show interfaces counters errors'; D='端口状态与错包统计' },
        @{ C='排障'; K='show spanning-tree'; D='生成树（查环路）' },
        @{ C='排障'; K='show logging'; D='日志' }
    )},
    @{ Name = '锐捷 Ruijie'; Cmds = @(
        @{ C='基础'; K='show version'; D='版本信息' },
        @{ C='基础'; K='show running-config'; D='当前配置' },
        @{ C='基础'; K='show interfaces status'; D='端口状态' },
        @{ C='基础'; K='show mac-address-table'; D='MAC地址表' },
        @{ C='基础'; K='show arp'; D='ARP表' },
        @{ C='排障'; K='show spanning-tree summary'; D='生成树（查环路）' },
        @{ C='排障'; K='show cpu / show memory'; D='资源占用' }
    )},
    @{ Name = 'Windows'; Cmds = @(
        @{ C='网络'; K='ipconfig /all'; D='完整网络配置' },
        @{ C='网络'; K='ipconfig /release 与 ipconfig /renew'; D='释放与重新获取IP' },
        @{ C='网络'; K='ipconfig /flushdns'; D='清空DNS缓存' },
        @{ C='网络'; K='netsh interface ipv4 show interfaces'; D='网卡列表与索引' },
        @{ C='网络'; K='netsh int ipv4 set address "以太网" static 192.168.1.10 255.255.255.0 192.168.1.1'; D='设置静态IP' },
        @{ C='网络'; K='netsh int ipv4 set dnsservers "以太网" static 223.5.5.5 primary'; D='设置DNS' },
        @{ C='排障'; K='ping -t / ping -l 1472 -f'; D='长ping 与 MTU 测试' },
        @{ C='排障'; K='tracert -d 8.8.8.8'; D='路由追踪' },
        @{ C='排障'; K='arp -a'; D='ARP表（查IP冲突）' },
        @{ C='排障'; K='netstat -ano | findstr :80'; D='查端口占用' },
        @{ C='排障'; K='tasklist | findstr PID'; D='按PID查进程' },
        @{ C='排障'; K='netsh winsock reset'; D='重置Winsock（网络异常修复，需重启）' },
        @{ C='排障'; K='netsh int ip reset'; D='重置TCP/IP（需重启）' },
        @{ C='抓包'; K='netsh trace start capture=yes tracefile=c:\trace.etl'; D='开始抓包' },
        @{ C='抓包'; K='netsh trace stop'; D='停止抓包' },
        @{ C='抓包'; K='pktmon start --etw -m real-time'; D='Win10+ 内置抓包' }
    )},
    @{ Name = 'Linux'; Cmds = @(
        @{ C='网络'; K='ip a / ip r'; D='地址与路由' },
        @{ C='网络'; K='ss -tunlp'; D='监听端口与进程' },
        @{ C='网络'; K='ping / traceroute / mtr'; D='连通性与路径' },
        @{ C='网络'; K='curl -I http://x'; D='HTTP头测试' },
        @{ C='网络'; K='tcpdump -i eth0 -nn -c 100'; D='抓包前100个' },
        @{ C='网络'; K='nmcli device status / nmtui'; D='网卡状态与图形配置' },
        @{ C='日志'; K='journalctl -u NetworkManager -n 50'; D='网络服务日志' },
        @{ C='日志'; K='dmesg | tail -50'; D='内核日志' }
    )}
)

function Do-DevCmds {
    TitleMsg '运维命令库'
    for ($i = 0; $i -lt $DevCmds.Count; $i++) { InfoMsg ("  {0}. {1}" -f ($i + 1), $DevCmds[$i].Name) }
    InfoMsg '  0. 返回主菜单'
    $sel = Read-Host '请选择厂商'
    if ($null -eq $sel) { return }
    $sel = "$sel".Trim()
    if ($sel -eq '0' -or $sel -eq '') { return }
    if ($sel -notmatch '^\d+$') { ErrMsg '请输入数字。'; return }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $DevCmds.Count) { ErrMsg '编号超出范围。'; return }

    $dev = $DevCmds[$idx]
    InfoMsg ''
    Write-Host "===== $($dev.Name) 常用命令 =====" -ForegroundColor Cyan
    foreach ($c in $dev.Cmds) {
        Write-Host ("[{0}] {1}" -f $c.C, $c.K) -ForegroundColor Yellow
        InfoMsg "        $($c.D)"
    }
}

# ============================================================
#  39. 弱电计算
# ============================================================
function Do-ElecCalc {
    while ($true) {
        TitleMsg '弱电计算'
        InfoMsg '  1. 供电功率计算（设备总功耗 + 电源余量）'
        InfoMsg '  2. 机柜散热计算（功率 -> BTU/h）'
        InfoMsg '  3. 网线预算（点位数量 -> 装箱数）'
        InfoMsg '  4. PoE 供电预算（摄像头数量 -> 交换机 PoE 需求）'
        InfoMsg '  0. 返回主菜单'
        $c = Read-Host '请选择'
        if ($null -eq $c) { return }
        $c = "$c".Trim()
        if ($c -eq '0' -or $c -eq '') { return }

        if ($c -eq '1') {
            $n = Read-Host '设备数量'
            $p = Read-Host '单台功耗 W（如摄像头 8，交换机 30）'
            if ($n -notmatch '^\d+(\.\d+)?$' -or $p -notmatch '^\d+(\.\d+)?$') { ErrMsg '请输入数字。'; continue }
            $t = [double]$n * [double]$p
            OkMsg "设备总功耗: $([math]::Round($t, 1)) W"
            InfoMsg "建议电源容量(1.3倍余量): $([math]::Round($t * 1.3, 1)) W"
            InfoMsg "建议线径: $([math]::Round($t / 12, 2)) A@12V / $([math]::Round($t / 24, 2)) A@24V"
        }
        elseif ($c -eq '2') {
            $w = Read-Host '机柜总功耗 W'
            if ($w -notmatch '^\d+(\.\d+)?$') { ErrMsg '请输入数字。'; continue }
            $btu = [double]$w * 3.412
            OkMsg "发热量: $([math]::Round($btu, 0)) BTU/h"
            InfoMsg "制冷量需求: 约 $([math]::Round($btu / 12000, 2)) 冷吨（RT）"
            InfoMsg "换气风量参考: 约 $([math]::Round($btu / 1.08 / 10, 0)) CFM（温差10℉估算）"
        }
        elseif ($c -eq '3') {
            $n = Read-Host '信息点数量'
            $L = Read-Host '平均单点长度 米（含两端预留，如 35）'
            if ($n -notmatch '^\d+$' -or $L -notmatch '^\d+(\.\d+)?$') { ErrMsg '请输入数字。'; continue }
            $total = [int]$n * [double]$L * 1.10
            $boxes = [math]::Ceiling($total / 305)
            OkMsg "总长度(含10%损耗): $([math]::Round($total, 0)) 米"
            InfoMsg "按305米/箱: 需要 $boxes 箱"
            InfoMsg "水晶头参考: 约 $([int]$n * 4) 个（含两端与损坏）"
            InfoMsg "面板/模块: 各 $n 个"
        }
        elseif ($c -eq '4') {
            $n = Read-Host 'PoE 设备数量'
            $p = Read-Host '单台功率 W（球机约15，枪机约8，AP约10）'
            if ($n -notmatch '^\d+$' -or $p -notmatch '^\d+(\.\d+)?$') { ErrMsg '请输入数字。'; continue }
            $total = [int]$n * [double]$p
            OkMsg "PoE 总需求: $([math]::Round($total, 1)) W"
            InfoMsg "建议交换机 PoE 预算: $([math]::Round($total * 1.25, 0)) W 以上（留25%余量）"
            InfoMsg "参考: 8口PoE常为120W，16口约240W，24口约370W（机型不同需核实）"
            $L = Read-Host '最长线路长度 米（回车跳过压降估算）'
            if ($L -match '^\d+(\.\d+)?$') {
                $drop = [double]$L * 0.0075 * ([double]$p / 12)
                InfoMsg "超五类线压降估算: 约 $([math]::Round($drop, 2)) V（仅供参考，长距离建议用六类/加粗线）"
            }
        }
        else { ErrMsg '无效选择。' }
        InfoMsg ''
    }
}

# ============================================================
#  40. 电池 / UPS 状态
# ============================================================
function Do-Battery {
    TitleMsg '电池 / UPS 状态'
    $bat = $null
    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        } else {
            $bat = @(Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue)
        }
    } catch { }
    if (-not $bat -or $bat.Count -eq 0 -or $null -eq $bat[0]) {
        WarnMsg '未检测到电池或 UPS 设备。'
        InfoMsg '说明：Windows 只能识别通过 HID/厂商驱动上报的 UPS（如 APC、山特 USB 型号）。'
        InfoMsg '串口/网络管理卡型 UPS 需使用厂商软件（PowerChute 等），本工具无法读取。'
        return
    }
    foreach ($b in $bat) {
        Write-Host "----- $($b.Name) -----" -ForegroundColor Cyan
        $stTxt = switch ($b.BatteryStatus) {
            1 { '放电中（未接市电）' }
            2 { '接通市电（交流供电）' }
            3 { '充满' }
            4 { '低电量' }
            6 { '充电中' }
            7 { '充电中（高）' }
            8 { '充电中（低）' }
            9 { '充电中（中）' }
            11 { '部分充电' }
            default { "状态码 $($b.BatteryStatus)" }
        }
        InfoMsg "  状态      : $stTxt"
        if ($b.EstimatedChargeRemaining -ne $null) {
            $pct = [int]$b.EstimatedChargeRemaining
            $bar = [int][math]::Round($pct / 100 * 30)
            $color = if ($pct -ge 60) { 'Green' } elseif ($pct -ge 25) { 'Yellow' } else { 'Red' }
            Write-Host ("  剩余电量  : [{0}{1}] {2}%" -f ('#' * $bar), ('-' * (30 - $bar)), $pct) -ForegroundColor $color
        }
        if ($b.EstimatedRunTime -ne $null -and $b.EstimatedRunTime -ne 71582788) {
            InfoMsg "  预计续航  : $($b.EstimatedRunTime) 分钟"
        }
        if ($b.DesignVoltage) { InfoMsg "  设计电压  : $($b.DesignVoltage) mV" }
        if ($b.Chemistry) { InfoMsg "  电池化学  : $($b.Chemistry)" }
    }
    InfoMsg ''
    WarnMsg '注意：本机笔记本电池也会被此命令列出，请按设备名称区分是否为真 UPS。'
}

# ============================================================
#  41. AI 运维助手（离线知识库）
# ============================================================
$AiKb = @(
    @{ K='无法上网,没有网,获取不到ip,169.254,apipa,连不上网'; T='无法上网 / 获取不到IP' ; A=@(
        '1) ipconfig /all 看是否有 169.254.x.x —— 这是APIPA地址，说明没拿到DHCP。',
        '2) 检查网线/水晶头/交换机口指示灯；换一个端口再试。',
        '3) netsh int ipv4 set address "以太网" dhcp 然后 ipconfig /renew。',
        '4) 确认同网段其他电脑能否上网：只有这一台故障多为本机问题。',
        '5) 若是新装的私接路由，检查是否又开了一层DHCP（会造成双DHCP冲突）。',
        '6) netsh winsock reset + netsh int ip reset 后重启（排除系统协议栈异常）。'
    )},
    @{ K='ip冲突,地址冲突,arp冲突'; T='IP地址冲突' ; A=@(
        '1) 本工具「IP冲突检测」：ARP表中同一IP出现多个MAC即为冲突。',
        '2) 冲突另一台设备可能是手工设置了同IP，或私接路由开了同网段DHCP。',
        '3) 处理：把本机改成DHCP，或在路由器上把冲突IP从DHCP池排除。',
        '4) 也可用 arp -a 后逐个ping，结合MAC厂商判断是哪台设备。'
    )},
    @{ K='丢包,时断时续,断线,闪断,延迟高,抖动'; T='网络丢包 / 时断时续' ; A=@(
        '1) 先 ping 网关：ping -t 网关，看是否丢包。丢包说明是内网问题。',
        '2) 网关不丢外网丢：问题在出口线路或运营商，联系宽带。',
        '3) 内网丢包常见原因：网线水晶头压接不良、水晶头进水、交换机口氧化、电磁干扰（与强电同槽）。',
        '4) 逐级ping（本机->交换机->路由器->外网）定位断点。',
        '5) 交换机 display interface 看错包计数（CRC/丢包），错包增长的端口就是故障口。'
    )},
    @{ K='网速慢,很慢,卡,下载慢,带宽'; T='网速慢' ; A=@(
        '1) 本工具「外网测速」先测是否达到签约带宽。',
        '2) 「谁在偷流量」看是否有设备在大量下载/上传。',
        '3) 检查是否被限速、是否有人开P2P下载、是否WiFi被邻居蹭网。',
        '4) 百兆交换机跑不满千兆：确认交换机、网线（超五类以上）、网卡都是千兆。',
        '5) 网线过长（超100米）或劣质线会导致协商降速，看协商速率是否为1000Mbps。'
    )},
    @{ K='摄像头,监控,不在线,预览不了,画面,录像机,nvr'; T='摄像头不在线' ; A=@(
        '1) 本工具「摄像头扫描」确认设备IP是否在线、端口是否开放。',
        '2) ping 摄像头IP：不通则查供电（PoE是否够功率）、网线、交换机口。',
        '3) 通但预览不了：多为网段/端口/协议问题，检查RTSP 554端口和账号密码。',
        '4) 用 rtsp://user:pass@ip:554/... 在VLC里测试取流。',
        '5) NVR搜不到：确认摄像头与NVR同网段，或已在NVR手动添加。',
        '6) PoE供电不足的典型症状：白天正常、晚上红外一开就掉线。'
    )},
    @{ K='wifi,无线,信号弱,信号差,掉线,漫游,信道'; T='WiFi信号弱 / 掉线' ; A=@(
        '1) 本工具「WiFi扫描」看信道占用：2.4G只用1/6/11，避免重叠。',
        '2) 信号强度 -65dBm 以上较好，-75dBm 以下易掉线。',
        '3) AP 尽量吸顶安装，避免放在金属箱内、墙角、微波炉旁。',
        '4) 高密场所用 5G 频段，2.4G 留给穿墙/远距离终端。',
        '5) 多AP部署要设不同信道并开漫游，避免同信道互相干扰。'
    )},
    @{ K='环路,广播风暴,交换机卡死,全网卡,灯全闪'; T='网络环路 / 广播风暴' ; A=@(
        '1) 症状：全网变慢或瘫痪，交换机指示灯高频同闪。',
        '2) 常见原因：一根网线的两端插在同一台交换机的两个口（最常见的低级事故）。',
        '3) 排查：逐个拔线，拔出哪根网络恢复，就是那根/那一路。',
        '4) 交换机开 STP/RSTP；查看 display stp brief 找 Blocking 异常口。',
        '5) 本工具「环路检测」可做基础筛查（同网关多网卡、同MAC多IP、ARP异常）。'
    )},
    @{ K='不通,跨网段,不同网段,vlan,访问不到,单向'; T='跨网段不通 / VLAN 隔离' ; A=@(
        '1) 确认两端IP与掩码：掩码写错是最常见原因（如该/24写成/16）。',
        '2) 同VLAN才能二层直达；跨VLAN必须经过三层（路由器/三层交换机）并配好网关。',
        '3) 在核心交换机查 display vlan / display interface brief 确认VLAN与端口划分。',
        '4) 检查ACL：很多"不通"其实是ACL把流量拦掉了。',
        '5) tracert 看在哪一跳断掉。'
    )},
    @{ K='dns,解析,打不开网页,域名,不能访问网站'; T='DNS 解析异常' ; A=@(
        '1) nslookup www.baidu.com：请求超时=DNS服务器不通；返回错误=域名问题。',
        '2) 本工具「智能DNS选优」自动测速选最快DNS。',
        '3) ipconfig /flushdns 清缓存；ipconfig /displaydns 看缓存内容。',
        '4) 能ping通IP但打不开网页，基本都是DNS问题。',
        '5) 内网有域控/内部域名时，DNS必须指向内网DNS服务器，别写成公共DNS。'
    )},
    @{ K='端口占用,端口被占,80被占,启动失败,address already in use'; T='端口被占用' ; A=@(
        '1) netstat -ano | findstr :8080 找到占用端口的PID。',
        '2) tasklist | findstr 那个PID 查是哪个进程。',
        '3) 结束进程：taskkill /PID 1234 /F（确认可结束再操作）。',
        '4) 本工具「端口扫描」可确认端口是否真的对外开放（本机防火墙可能拦了）。',
        '5) 本机测试通、别人连不上：多为防火墙入站规则没放行，放行该端口即可。'
    )}
)

function Do-AiHelp {
    TitleMsg 'AI 运维助手（离线知识库）'
    InfoMsg '支持的问题方向：'
    foreach ($k in $AiKb) { InfoMsg "  - $($k.T)" }
    InfoMsg ''
    $q = Read-Host '请描述你的问题（回车取消）'
    if (-not $q) { WarnMsg '已取消。'; return }
    $q = "$q".Trim()

    $best = $null; $bestHit = 0
    foreach ($k in $AiKb) {
        $hit = 0
        foreach ($w in ($k.K -split ',')) {
            if ($w -and $q -like "*$w*") { $hit++ }
        }
        if ($hit -gt $bestHit) { $bestHit = $hit; $best = $k }
    }
    InfoMsg ''
    if ($best -and $bestHit -gt 0) {
        Write-Host "【$($best.T)】 排查步骤：" -ForegroundColor Cyan
        foreach ($s in $best.A) { InfoMsg "  $s" }
    } else {
        WarnMsg '未匹配到知识库条目，请换关键词，例如：丢包 / 环路 / 摄像头不在线 / DNS。'
        InfoMsg '通用排查顺序：本机IP -> 网关 -> DNS -> 外网 -> 目标服务端口。'
    }
    InfoMsg ''
    InfoMsg '提示：本功能为离线规则库匹配，不联网、不上传任何数据。'
}

# ============================================================
#  42. 远程工具 / 设备清单
# ============================================================
function Do-RemoteTools {
    TitleMsg '远程工具 / 设备清单'
    $a = Get-ActiveAdapter
    if ($a -and $a.IP) { InfoMsg "本机: $($a.IP)   网关: $($a.Gateway)" }
    InfoMsg ''
    InfoMsg '--- ARP 设备清单 ---'
    $arp = @(Read-ArpTable)
    if ($arp.Count -eq 0) { WarnMsg 'ARP表为空，可能尚未与任何设备通信。' }
    else {
        Write-Host '  IP地址           MAC地址             厂商' -ForegroundColor Cyan
        foreach ($x in $arp) {
            $v = Get-OuiVendor $x.Mac
            InfoMsg ("  {0,-15} {1,-19} {2}" -f $x.Ip, $x.Mac, $v)
        }
    }
    InfoMsg ''
    InfoMsg '--- 本机串口设备 ---'
    try {
        $ports = @([System.IO.Ports.SerialPort]::GetPortNames())
        if ($ports.Count -gt 0) { InfoMsg "  $($ports -join ', ')" } else { WarnMsg '  未检测到串口。' }
    } catch { WarnMsg '  读取串口失败。' }
    InfoMsg ''
    InfoMsg '--- 常用远程端口速查 ---'
    InfoMsg '  3389 RDP 远程桌面 | 5900 VNC | 22 SSH | 23 Telnet'
    InfoMsg '  80/443 Web管理 | 8000 海康 | 37777 大华 | 554 RTSP'
    InfoMsg '  161 SNMP | 8291 华为AP | 5000 群晖NAS | 8080 Web管理'
    InfoMsg ''
    InfoMsg '如需远程登录设备，可使用系统自带 mstsc（远程桌面）、ssh、telnet 客户端。'
    WarnMsg '提示：设备登录凭据请自行保管，本工具不保存任何密码。'
}

# ============================================================
#  43. 子网划分（等分）
# ============================================================
function Do-SubnetDivide {
    TitleMsg '子网划分（等分）'
    $in = Read-Host '请输入网络地址/前缀，如 192.168.1.0/24'
    if ($in -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        ErrMsg '格式错误，示例：192.168.1.0/24'; return
    }
    $o1 = [int]$Matches[1]; $o2 = [int]$Matches[2]; $o3 = [int]$Matches[3]; $o4 = [int]$Matches[4]
    $bits = [int]$Matches[5]
    if ($bits -lt 1 -or $bits -gt 30) { ErrMsg '前缀需在 1-30 之间。'; return }
    $need = Read-Host '要划分成几个子网（2/4/8/16/32...）'
    if ($need -notmatch '^\d+$') { ErrMsg '请输入数字。'; return }
    $need = [int]$need
    if ($need -lt 2) { ErrMsg '至少需要 2 个子网。'; return }

    $addBits = [int][math]::Ceiling([math]::Log($need, 2))
    $newBits = $bits + $addBits
    if ($newBits -gt 30) { ErrMsg "划分后前缀 /$newBits 超出可用范围（>30）。"; return }
    $actual = [int][math]::Pow(2, $addBits)

    $ipInt = [int64]$o1 * 16777216 + [int64]$o2 * 65536 + [int64]$o3 * 256 + [int64]$o4
    $hostBits = 32 - $bits
    $maskInt = [int64]4294967295 - ([int64][math]::Pow(2, $hostBits) - 1)
    $netInt  = $ipInt -band $maskInt

    $toIp = {
        param([int64]$v)
        "$([math]::Floor($v / 16777216) % 256).$([math]::Floor($v / 65536) % 256).$([math]::Floor($v / 256) % 256).$($v % 256)"
    }

    $subSize = [int64][math]::Pow(2, 32 - $newBits)
    $newMask = [int64]4294967295 - ([int64][math]::Pow(2, 32 - $newBits) - 1)

    InfoMsg ''
    OkMsg "原网络  : $(& $toIp $netInt)/$bits"
    InfoMsg "划分为  : $actual 个子网（你要求 $need 个）"
    InfoMsg "新前缀  : /$newBits    新掩码: $(& $toIp $newMask)"
    InfoMsg "每段地址: $subSize 个（可用 $($subSize - 2) 个）"
    InfoMsg ''
    Write-Host '  序号  网络地址              可用范围                            广播地址' -ForegroundColor Cyan
    $showMax = [math]::Min($actual, 32)
    for ($i = 0; $i -lt $showMax; $i++) {
        $sNet = $netInt + $i * $subSize
        $sBc  = $sNet + $subSize - 1
        InfoMsg ("  {0,3}   {1,-20} {2,-34} {3}" -f ($i + 1), "$(& $toIp $sNet)/$newBits", "$(& $toIp ($sNet + 1)) - $(& $toIp ($sBc - 1))", $(& $toIp $sBc))
    }
    if ($actual -gt $showMax) { InfoMsg "  ... 其余 $($actual - $showMax) 个子网按同样步长递增（每段 +$subSize）。" }
}

# ============================================================
#  主菜单
# ============================================================
$MenuData = @(
    @{ Group = '网络配置'; Items = @(
        @{ T = '随机换IP';           F = { Do-RandomIP } },
        @{ T = '手动设IP';           F = { Do-ManualIP } },
        @{ T = '自动获取IP (DHCP)';   F = { Do-DHCP } },
        @{ T = '预设管理';            F = { Do-PresetManager } },
        @{ T = '注册轮换模式';        F = { Do-RegistrationMode } }
    )},
    @{ Group = '网络检测'; Items = @(
        @{ T = '网络信息';            F = { Do-NetworkInfo } },
        @{ T = '网络健康检查';        F = { Do-HealthCheck } },
        @{ T = '网络诊断';            F = { Do-Diagnostics } },
        @{ T = '网络修复';            F = { Do-Repair } },
        @{ T = 'Ping测试';            F = { Do-PingTest } },
        @{ T = '路由追踪';            F = { Do-TraceRoute } },
        @{ T = '端口扫描';            F = { Do-PortScan } },
        @{ T = '主机发现 (ARP)';      F = { Do-HostDiscovery } },
        @{ T = '会话数统计';          F = { Do-SessionStats } },
        @{ T = '路由表';              F = { Do-RouteTable } }
    )},
    @{ Group = '测速与流量'; Items = @(
        @{ T = '外网测速';            F = { Do-SpeedTest } },
        @{ T = '内网测速';            F = { Do-LanTest } },
        @{ T = '测速记录曲线';        F = { Do-SpeedHistory } },
        @{ T = '谁在偷流量';          F = { Do-TrafficMonitor } }
    )},
    @{ Group = 'DNS 与网络服务'; Items = @(
        @{ T = 'DNS切换';             F = { Do-DNSSwitch } },
        @{ T = '智能DNS选优';         F = { Do-SmartDNS } },
        @{ T = '查询公网IP';          F = { Do-PublicIP } },
        @{ T = 'DHCP检测';            F = { Do-DhcpCheck } }
    )},
    @{ Group = '无线与安全'; Items = @(
        @{ T = 'WiFi扫描';            F = { Do-WiFiScan } },
        @{ T = 'WiFi已保存密码';      F = { Do-WifiProfiles } },
        @{ T = '防火墙配置';          F = { Do-Firewall } },
        @{ T = 'IP冲突检测';          F = { Do-IpConflict } },
        @{ T = '环路检测';            F = { Do-LoopCheck } }
    )},
    @{ Group = '工程工具'; Items = @(
        @{ T = '摄像头扫描';          F = { Do-CameraScan } },
        @{ T = '局域网扫描';          F = { Do-LanScan } },
        @{ T = '网络唤醒 (WOL)';      F = { Do-WOL } },
        @{ T = '串口工具';            F = { Do-SerialTool } },
        @{ T = '子网计算器';          F = { Do-SubnetCalc } },
        @{ T = '子网划分 (等分)';     F = { Do-SubnetDivide } },
        @{ T = 'MAC厂商查询';         F = { Do-MacLookup } }
    )},
    @{ Group = '运维工具'; Items = @(
        @{ T = '端口映射';            F = { Do-PortProxy } },
        @{ T = '抓包分析';            F = { Do-CaptureMenu } },
        @{ T = '运维命令库';          F = { Do-DevCmds } },
        @{ T = '弱电计算';            F = { Do-ElecCalc } },
        @{ T = 'AI运维助手';          F = { Do-AiHelp } },
        @{ T = '远程工具/设备清单';   F = { Do-RemoteTools } }
    )},
    @{ Group = '其他'; Items = @(
        @{ T = '电池 / UPS 状态';     F = { Do-Battery } },
        @{ T = 'WiFi热点';            F = { Do-WiFiHotspot } }
    )}
)

# 扁平化，用于按编号派发
$MenuFlat = @()
foreach ($g in $MenuData) {
    foreach ($it in $g.Items) {
        $MenuFlat += @{ Group = $g.Group; T = $it.T; F = $it.F }
    }
}

function Show-Menu {
    Clear-Host
    Write-Host '=================================================' -ForegroundColor DarkCyan
    Write-Host '                网  络  工  具  箱                ' -ForegroundColor Cyan
    Write-Host '=================================================' -ForegroundColor DarkCyan

    $a = Get-ActiveAdapter
    if ($a) {
        $adminTxt = if ($IsAdmin) { '管理员' } else { '普通用户' }
        Write-Host (" 网卡 {0}  IP {1}  网关 {2}  [{3}]" -f $a.Name, $a.IP, $a.Gateway, $adminTxt) -ForegroundColor DarkGray
    } else {
        Write-Host ' 未检测到已连接的网卡' -ForegroundColor DarkYellow
    }
    Write-Host '-------------------------------------------------' -ForegroundColor DarkCyan

    $n = 0
    foreach ($g in $MenuData) {
        Write-Host ''
        Write-Host "  【$($g.Group)】" -ForegroundColor Yellow
        $its = @($g.Items)
        for ($i = 0; $i -lt $its.Count; $i += 2) {
            $n++
            $left = ('{0,2}. {1}' -f $n, $its[$i].T).PadRight(26)
            $right = ''
            if ($i + 1 -lt $its.Count) {
                $n++
                $right = '{0,2}. {1}' -f $n, $its[$i + 1].T
            }
            Write-Host "   $left$right"
        }
    }
    Write-Host ''
    Write-Host '   0. 退出' -ForegroundColor DarkGray
    Write-Host '-------------------------------------------------' -ForegroundColor DarkCyan
}

if (-not $IsAdmin) {
    Write-Host ''
    WarnMsg '当前不是管理员权限，部分功能（改IP/DNS/修复/热点/防火墙）无法使用。'
    WarnMsg '请使用「启动工具箱.bat」运行以自动提权，或右键 PowerShell 选择"以管理员身份运行"。'
    Write-Host ''
    Write-Host '按回车继续...' -NoNewline
    [void][Console]::ReadLine()
}

while ($true) {
    Show-Menu
    $sel = Read-Host "请输入功能编号 (1-$($MenuFlat.Count))"
    if ($null -eq $sel) { break }        # 输入流结束，退出
    $sel = "$sel".Trim()
    if ($sel -eq '') { continue }        # 直接回车，重绘菜单
    if ($sel -eq '0' -or $sel -eq 'q' -or $sel -eq 'Q') { break }
    if ($sel -notmatch '^\d+$') { ErrMsg '请输入数字编号。'; Start-Sleep -Seconds 1; continue }

    $n = [int]$sel
    if ($n -lt 1 -or $n -gt $MenuFlat.Count) {
        ErrMsg "无效编号，请输入 1-$($MenuFlat.Count)。"
        Start-Sleep -Seconds 1
        continue
    }
    $item = $MenuFlat[$n - 1]
    & $item.F
    AskPause
}

Write-Host ''
Write-Host '已退出网络工具箱。' -ForegroundColor DarkGray
