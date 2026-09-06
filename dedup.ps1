# IPTV m3u 去重脚本 v3 —— 分辨率优先探活版
# 选源标准（按用户要求）：分辨率 >= 1080 的可用源优先，其他源延迟再低也不选
# 策略：
#   1. 按频道名分组（跳过"更新时间"伪频道）
#   2. 用 ffprobe 并发实测每个候选流的分辨率 + 可用性（读取一个 TS 段）
#   3. 每频道选：可用源中分辨率最高的；全死频道剔除
#   4. 头部 x-tvg-url 与 logo 去掉 ghfast.top 代理前缀
# 输出统计：>=1080 的频道数、仅 <1080 的频道数、死频道数

param(
    [string]$InputFile = "live_lite.m3u",
    [string]$OutputFile = "live_lite_dedup.m3u",
    [int]$TimeoutSec = 10,
    [int]$Concurrency = 24
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

# ---------- ffprobe 并发探活 + 实测分辨率 ----------
$allUrls = @($groups.Values | ForEach-Object { $_.url } | Sort-Object -Unique)
Write-Output "待探测唯一 URL: $($allUrls.Count) 个（并发 $Concurrency，超时 ${TimeoutSec}s）"

$probeResults = $allUrls | ForEach-Object -Parallel {
    $u = $_
    $timeoutSec = $using:TimeoutSec
    try {
        # 强制 IPv4、禁用 stdin，避免卡住
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ffprobe'
        $psi.Arguments = "-hide_banner -loglevel error -nostdin -vn -select_streams v:0 -show_entries stream=height -of csv=p=0 `"$u`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($timeoutSec * 1000)) {
            $p.Kill()
            return 'DEAD'
        }
        $h = $p.StandardOutput.ReadToEnd().Trim()
        if ($p.ExitCode -eq 0 -and $h -match '^\d+$') { "HD:$h" } else { 'DEAD' }
    } catch { 'DEAD' }
} -ThrottleLimit $Concurrency

$probe = @{}
for ($k = 0; $k -lt $allUrls.Count; $k++) { $probe[$allUrls[$k]] = $probeResults[$k] }
$aliveCount = @($probe.Values | Where-Object { $_ -ne 'DEAD' }).Count
Write-Output "探测完成: $aliveCount / $($allUrls.Count) 个源可用"

# ---------- 每频道选分辨率最高的可用源 ----------
$out = New-Object System.Collections.Generic.List[string]
$kept = 0; $fhd = 0; $sd = 0
foreach ($name in $order) {
    $best = $null
    foreach ($cand in $groups[$name]) {
        $pr = $probe[$cand.url]
        if ($pr -ne $null -and $pr -match '^HD:(\d+)$') {
            $height = [int]$Matches[1]
            if ($best -eq $null -or $height -gt $best.height) {
                $best = @{ ext = $cand.ext; url = $cand.url; height = $height }
            }
        }
    }
    if ($best -ne $null) {
        $ext = $best.ext -replace 'https://ghfast\.top/', ''
        $out.Add($ext)
        $out.Add($best.url)
        $kept++
        if ($best.height -ge 1080) { $fhd++ } else { $sd++ }
    }
}

# ---------- 输出 ----------
$header = $header -replace 'https://ghfast\.top/', ''
$final = @($header) + $out
$final | Set-Content $OutputFile -Encoding UTF8

Write-Output "结果: 保留 $kept 个频道 | >=1080: $fhd | <1080: $sd | 剔除全死: $($totalChannels - $kept)"
Write-Output "输出: $OutputFile ($($final.Count) 行)"
