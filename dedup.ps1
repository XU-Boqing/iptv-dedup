# IPTV m3u 去重脚本 v2 —— 探活版
# 策略：
#   1. 按频道名分组（跳过"更新时间"伪频道）
#   2. 对所有候选 URL 并发探活（GET 前 512 字节，要求 HTTP 200 且内容为 #EXT 开头的 m3u8）
#   3. 每个频道保留第一个探活成功的源；全部失败的频道直接剔除
#   4. 头部 x-tvg-url 与 logo 去掉 ghfast.top 代理前缀，改用直链（避免代理拖慢 Kodi 加载）

param(
    [string]$InputFile = "live_lite.m3u",
    [string]$OutputFile = "live_lite_dedup.m3u",
    [int]$TimeoutSec = 6,
    [int]$Concurrency = 40
)

$lines = Get-Content $InputFile -Encoding UTF8

# ---------- 解析：按频道名分组，保留出现顺序 ----------
$groups = @{}          # name -> List of @{ext=...; url=...}
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
        # 跳过"更新时间"伪频道（形如 20260906 05:47）
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

# ---------- 收集去重后的候选 URL，并发探活 ----------
$allUrls = @($groups.Values | ForEach-Object { $_.url } | Sort-Object -Unique)
Write-Output "待探活唯一 URL: $($allUrls.Count) 个（并发 $Concurrency，超时 ${TimeoutSec}s）"

$probeResults = $allUrls | ForEach-Object -Parallel {
    $u = $_
    $timeoutMs = $using:TimeoutSec * 1000
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::Expect100Continue = $false
        $req = [System.Net.HttpWebRequest]::Create($u)
        $req.Timeout = $timeoutMs
        $req.ReadWriteTimeout = $timeoutMs
        $req.AllowAutoRedirect = $true
        $req.UserAgent = 'Kodi/21'
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        try {
            $stream = $resp.GetResponseStream()
            $buf = New-Object byte[] 512
            $read = $stream.Read($buf, 0, 512)
            $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
            if ($text -match '^#EXT') { 'OK' } else { 'BAD' }
        } finally { $resp.Close() }
    } catch { 'BAD' }
} -ThrottleLimit $Concurrency

$probe = @{}
for ($k = 0; $k -lt $allUrls.Count; $k++) { $probe[$allUrls[$k]] = $probeResults[$k] }
$okCount = @($probe.Values | Where-Object { $_ -eq 'OK' }).Count
Write-Output "探活完成: $okCount / $($allUrls.Count) 个 URL 可用"

# ---------- 每个频道保留第一个可用源 ----------
$out = New-Object System.Collections.Generic.List[string]
$kept = 0
foreach ($name in $order) {
    foreach ($cand in $groups[$name]) {
        if ($probe[$cand.url] -eq 'OK') {
            $ext = $cand.ext -replace 'https://ghfast\.top/', ''
            $out.Add($ext)
            $out.Add($cand.url)
            $kept++
            break
        }
    }
}
$dropped = $totalChannels - $kept

# ---------- 头部：x-tvg-url 改为直链 ----------
$header = $header -replace 'https://ghfast\.top/', ''

$final = @($header) + $out
$final | Set-Content $OutputFile -Encoding UTF8

Write-Output "结果: 保留 $kept 个频道（全部探活可用），剔除 $dropped 个全死频道"
Write-Output "输出: $OutputFile ($($final.Count) 行)"
