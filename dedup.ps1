# IPTV m3u 去重脚本 v3.1 —— 1080P 优先探活版
# 选源标准（用户要求）：只用分辨率 >= 1080 的可用源，其他源不选
# 策略：
#   1. 按频道名分组（跳过"更新时间"伪频道）
#   2. ffprobe 并发实测每个候选流的分辨率（直接调用 + -rw_timeout 自限时）
#   3. 主文件 live_lite_dedup.m3u：每频道选 >=1080 的最高分辨率源
#      备用文件 live_lite_dedup_720p.m3u：无 1080 源的频道给最佳可用源（可选使用）
#   4. 保险丝：保留频道数 < 50 视为异常，抛错阻止提交空/坏文件
#   5. 头部 x-tvg-url 与 logo 去掉 ghfast.top 代理前缀

param(
    [string]$InputFile = "live_lite.m3u",
    [string]$OutputFile = "live_lite_dedup.m3u",
    [string]$OutputFileSd = "live_lite_dedup_720p.m3u",
    [int]$TimeoutSec = 8,
    [int]$Concurrency = 24,
    [int]$MinChannels = 50
)

$ErrorActionPreference = 'Continue'

# ---------- 解析 ----------
$lines = Get-Content $InputFile -Encoding UTF8
$groups = @{}
$order = New-Object System.Collections.Generic.List[string]
$header = "#EXTM3U"
$i = 0
while ($i -lt $lines.Count) {
    $l = $lines[$i]
    if ($l -match '^#EXTM3U') { $header = $l; $i++; continue }
    if ($l -match '^#EXTINF') {
        $name = ($l -split ',')[-1].Trim()
        $url = ''
        $j = $i + 1
        while ($j -lt $lines.Count -and $lines[$j].Trim() -ne '' -and $lines[$j] -notmatch '^#EXT') {
            $url = $lines[$j].Trim(); break
        }
        if ($name -notmatch '^\d{8} \d{2}:\d{2}$' -and $url -ne '') {
            if (-not $groups.ContainsKey($name)) {
                $groups[$name] = New-Object System.Collections.Generic.List[object]
                $order.Add($name)
            }
            $groups[$name].Add(@{ ext = $l; url = $url })
        }
        $i = $j + 1
        continue
    }
    $i++
}

$totalChannels = $order.Count
$totalEntries = ($groups.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Output "解析完成: $totalChannels 个频道, 共 $totalEntries 条候选"

# ---------- ffprobe 并发探活（直接调用，-rw_timeout 微秒级自限时） ----------
$allUrls = @($groups.Values | ForEach-Object { $_.url } | Sort-Object -Unique)
Write-Output "待探测唯一 URL: $($allUrls.Count) 个（并发 $Concurrency，网络超时 ${TimeoutSec}s）"

$probeResults = $allUrls | ForEach-Object -Parallel {
    $u = $_
    $tmo = $using:TimeoutSec
    try {
        $rwus = [int64]$tmo * 1000000
        # 注意：-nostdin 后跟其他选项会报 Option not found；rw_timeout 单位微秒
        $h = & ffprobe -v error -rw_timeout $rwus -analyzeduration 3000000 -probesize 3000000 `
                -select_streams v:0 -show_entries stream=height -of csv=p=0 $u 2>$null
        $ht = "$h".Trim()
        if ($LASTEXITCODE -eq 0 -and $ht -match '^\d+$') { "HD:$ht" } else { 'DEAD' }
    } catch { 'ERR' }
} -ThrottleLimit $Concurrency

$probe = @{}
for ($k = 0; $k -lt $allUrls.Count; $k++) { $probe[$allUrls[$k]] = $probeResults[$k] }
$aliveCount  = @($probe.Values | Where-Object { $_ -match '^HD:' }).Count
$errCount    = @($probe.Values | Where-Object { $_ -eq 'ERR' }).Count
$fhdAlive    = @($probe.Values | Where-Object { $_ -match '^HD:(\d+)$' -and [int]$Matches[1] -ge 1080 }).Count
Write-Output "探测完成: 可用 $aliveCount / $($allUrls.Count)（其中>=1080: $fhdAlive，调用异常: $errCount）"

if ($aliveCount -eq 0) {
    throw "全部源判死（含 $errCount 个调用异常）——疑似系统性故障，拒绝生成文件"
}

# ---------- 选源：主文件严格 >=1080，720p 备用文件给次优 ----------
$outMain = New-Object System.Collections.Generic.List[string]
$outSd   = New-Object System.Collections.Generic.List[string]
$keptFhd = 0; $keptSd = 0
foreach ($name in $order) {
    $bestAny = $null; $bestFhd = $null
    foreach ($cand in $groups[$name]) {
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
        $outMain.Add(($bestFhd.ext -replace 'https://ghfast\.top/', ''))
        $outMain.Add($bestFhd.url)
        $keptFhd++
    } elseif ($bestAny -ne $null) {
        $outSd.Add(($bestAny.ext -replace 'https://ghfast\.top/', ''))
        $outSd.Add($bestAny.url)
        $keptSd++
    }
}

# ---------- 保险丝：主文件频道数异常少则拒绝提交 ----------
if ($keptFhd -lt $MinChannels) {
    throw "仅 $keptFhd 个 >=1080 频道（阈值 $MinChannels）——结果异常，拒绝写入以保护线上文件"
}

$header = $header -replace 'https://ghfast\.top/', ''
(@($header) + $outMain) | Set-Content $OutputFile -Encoding UTF8
(@($header) + $outSd)   | Set-Content $OutputFileSd -Encoding UTF8

Write-Output "主文件 $OutputFile : $keptFhd 个频道（全部 >=1080）"
Write-Output "备用文件 $OutputFileSd : $keptSd 个频道（无1080源的频道，720p等，可选）"
Write-Output "剔除全死频道: $($totalChannels - $keptFhd - $keptSd)"
