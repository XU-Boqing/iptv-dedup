# IPTV m3u 去重脚本 v5 —— 每频道限量候选 + 进程硬超时
# 选源标准（用户要求）：分辨率 >= 1080 优先，其他源不选
# 关键设计：
#   1. 每频道只测前 TopN 个候选（上游 CCSH 已按速度排序，前几个已是优源，大幅减少探测量）
#   2. ffprobe 用进程级硬超时（WaitForExit + Kill），不依赖 -rw_timeout（它在 TCP 连接阶段无效且 Windows 实现有差异）
#   3. 主文件严格 >=1080；无 1080 源的频道进备用文件
#   4. 保险丝：产出异常少时拒绝写文件
# 运行环境：本地中国网络视角（推荐）或 GitHub Actions（海外视角存活率低）

param(
    [string[]]$InputFiles = @("live_lite.m3u"),
    [string]$OutputFile = "live_lite_dedup.m3u",
    [string]$OutputFileSd = "live_lite_dedup_720p.m3u",
    [int]$TopN = 6,             # 每频道最多探测前 N 个候选
    [int]$HardTimeoutSec = 10,  # 单个 ffprobe 进程硬超时
    [int]$Concurrency = 40,
    [int]$MinChannels = 30
)

$ErrorActionPreference = 'Continue'

# ---------- 工具路径解析 ----------
$ffprobe = $null
try { $ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source } catch {}
if (-not $ffprobe -or $ffprobe -match 'WindowsApps') {
    foreach ($c in @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffprobe.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\ffmpeg*\bin\ffprobe.exe",
        "/usr/bin/ffprobe"
    )) {
        $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $ffprobe = $found.FullName; break }
    }
}
if (-not $ffprobe) { throw "找不到 ffprobe" }
Write-Output "ffprobe: $ffprobe"

# ---------- 解析（支持多输入文件合并） ----------
$groups = @{}
$order = New-Object System.Collections.Generic.List[string]
$header = "#EXTM3U"
foreach ($InputFile in $InputFiles) {
    $lines = Get-Content $InputFile -Encoding UTF8
    $i = 0
    while ($i -lt $lines.Count) {
        $l = $lines[$i]
        if ($l -match '^#EXTM3U') {
            # 保留第一个非默认 x-tvg-url 头（含 EPG 声明）
            if ($header -eq '#EXTM3U' -and $l -match 'x-tvg-url') { $header = $l }
            $i++; continue
        }
        if ($l -match '^#EXTINF') {
            $name = ($l -split ',')[-1].Trim()
            # 频道名归一化：去括号分辨率后缀与多余空格（CCTV-1 (720p) -> CCTV-1）
            $norm = $name -replace '\s*\(\d+p\)\s*$', '' -replace '\s+', ' '
            # 进一步归一化：去连字符与全角空格差异（CCTV-1 / CCTV1 视为同一频道）
            $norm = $norm -replace '-', '' -replace '\u3000', ''
            $url = ''
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j].Trim() -ne '' -and $lines[$j] -notmatch '^#EXT') {
                $url = $lines[$j].Trim(); break
            }
            if ($norm -notmatch '^\d{8} \d{2}:\d{2}$' -and $url -ne '') {
                if (-not $groups.ContainsKey($norm)) {
                    $groups[$norm] = New-Object System.Collections.Generic.List[object]
                    $order.Add($norm)
                }
                $groups[$norm].Add(@{ ext = $l; url = $url })
            }
            $i = $j + 1
            continue
        }
        $i++
    }
}
$totalChannels = $order.Count
$totalEntries = ($groups.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Output "解析完成: $totalChannels 个频道, 共 $totalEntries 条候选"

# ---------- 构建探测任务：每频道前 TopN 个 ----------
$tasks = New-Object System.Collections.Generic.List[object]
foreach ($name in $order) {
    $n = [Math]::Min($TopN, $groups[$name].Count)
    for ($k = 0; $k -lt $n; $k++) { $tasks.Add($groups[$name][$k]) }
}
$uniqUrls = @($tasks | ForEach-Object { $_.url } | Sort-Object -Unique)
Write-Output "探测任务: 每频道前 $TopN 候选，共 $($tasks.Count) 条 / 唯一 URL $($uniqUrls.Count) 个（并发 $Concurrency，硬超时 ${HardTimeoutSec}s）"

# ---------- ffprobe 探测（进程硬超时版） ----------
$probeResults = $uniqUrls | ForEach-Object -Parallel {
    $u = $_
    $tmo = $using:HardTimeoutSec
    $ffp = $using:ffprobe
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ffp
        $psi.Arguments = "-v error -analyzeduration 3000000 -probesize 3000000 -select_streams v:0 -show_entries stream=height -of csv=p=0 `"$u`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        if ($IsLinux -or $IsMacOS) { $psi.EnvironmentVariables['PATH'] = "/usr/bin:/bin:$($psi.EnvironmentVariables['PATH'])" }
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($tmo * 1000)) {
            try { $p.Kill($true) } catch { $p.Kill() }
            return 'DEAD'
        }
        $h = $p.StandardOutput.ReadToEnd()
        # 注意：HLS 主播放列表会输出多行分辨率（多码率变体），取最大值
        $hts = @($h -split "`r?`n" | Where-Object { $_ -match '^\s*(\d+)\s*$' } | ForEach-Object { [int]($_.Trim()) })
        if ($p.ExitCode -eq 0 -and $hts.Count -gt 0) {
            $max = ($hts | Measure-Object -Maximum).Maximum
            "HD:$max"
        } else { 'DEAD' }
    } catch { 'ERR' }
} -ThrottleLimit $Concurrency

$probe = @{}
for ($k = 0; $k -lt $uniqUrls.Count; $k++) { $probe[$uniqUrls[$k]] = $probeResults[$k] }
$aliveCount = @($probe.Values | Where-Object { $_ -match '^HD:' }).Count
$fhdAlive  = @($probe.Values | Where-Object { $_ -match '^HD:(\d+)$' -and [int]$Matches[1] -ge 1080 }).Count
$errCount  = @($probe.Values | Where-Object { $_ -eq 'ERR' }).Count
Write-Output "探测完成: 可播 $aliveCount / $($uniqUrls.Count)（>=1080: $fhdAlive，调用异常: $errCount）"

if ($aliveCount -lt 10) { throw "仅 $aliveCount 个可播（异常 $errCount），疑似系统性故障，拒绝产出" }

# ---------- 选源 ----------
$outMain = New-Object System.Collections.Generic.List[string]
$outSd   = New-Object System.Collections.Generic.List[string]
$keptFhd = 0; $keptSd = 0
foreach ($name in $order) {
    $bestAny = $null; $bestFhd = $null
    $n = [Math]::Min($TopN, $groups[$name].Count)
    for ($k = 0; $k -lt $n; $k++) {
        $cand = $groups[$name][$k]
        $pr = $probe[$cand.url]
        if ($pr -match '^HD:(\d+)$') {
            $height = [int]$Matches[1]
            if ($bestAny -eq $null -or $height -gt $bestAny.height) {
                $bestAny = @{ ext = $cand.ext; url = $cand.url; height = $height }
            }
            if ($height -ge 1080 -and ($bestFhd -eq $null -or $height -gt $bestFhd.height)) {
                $bestFhd = @{ ext = $cand.ext; url = $cand.url; height = $height }
            }
        }
    }
    if ($bestFhd -ne $null) {
        # 输出行用归一化后的频道名重写 EXTINF 尾部，保持名称一致
        $ext = $bestFhd.ext -replace 'https://ghfast\.top/', ''
        $ext = $ext -replace ',[^,]*$', ",$name"
        $outMain.Add($ext)
        $outMain.Add($bestFhd.url)
        $keptFhd++
    } elseif ($bestAny -ne $null) {
        $ext = $bestAny.ext -replace 'https://ghfast\.top/', ''
        $ext = $ext -replace ',[^,]*$', ",$name"
        $outSd.Add($ext)
        $outSd.Add($bestAny.url)
        $keptSd++
    }
}

if ($keptFhd -lt $MinChannels) {
    throw "仅 $keptFhd 个 >=1080 频道（阈值 $MinChannels），拒绝产出以保护线上文件"
}

$header = $header -replace 'https://ghfast\.top/', ''
(@($header) + $outMain) | Set-Content $OutputFile -Encoding UTF8
(@($header) + $outSd)   | Set-Content $OutputFileSd -Encoding UTF8

Write-Output "主文件 $OutputFile : $keptFhd 个频道（全部 >=1080）"
Write-Output "备用 $OutputFileSd : $keptSd 个频道（无1080源的频道）"
Write-Output "剔除全死频道: $($totalChannels - $keptFhd - $keptSd)"
