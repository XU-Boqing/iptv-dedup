# IPTV m3u 去重脚本
# 策略：先去重完全相同的 URL，再按频道名去重（同名保留第一个出现的源）
# 跳过"更新时间"伪频道条目，保留 #EXTM3U 头（含 x-tvg-url EPG 声明）

param(
    [string]$InputFile = "live_lite.m3u",
    [string]$OutputFile = "live_lite_dedup.m3u"
)

$lines = Get-Content $InputFile -Encoding UTF8
$out = New-Object System.Collections.Generic.List[string]
$seenNames = @{}
$seenUrls = @{}
$header = "#EXTM3U"
$kept = 0
$skipped = 0
$i = 0

while ($i -lt $lines.Count) {
    $l = $lines[$i]
    if ($l -match '^#EXTM3U') {
        $header = $l
        $i++
        continue
    }
    if ($l -match '^#EXTINF') {
        $name = ($l -split ',')[-1].Trim()
        # 跳过"更新时间"伪频道
        if ($name -match '^\d{8} \d{2}:\d{2}$') {
            # 跳过其 URL 行
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j].Trim() -ne '' -and $lines[$j] -notmatch '^#EXT') { $j++ }
            $i = $j
            continue
        }
        $url = ''
        $j = $i + 1
        while ($j -lt $lines.Count -and $lines[$j].Trim() -ne '' -and $lines[$j] -notmatch '^#EXT') {
            $url = $lines[$j].Trim()
            break
        }
        if ($seenUrls.ContainsKey($url) -or $seenNames.ContainsKey($name)) {
            $skipped++
            $i = $j + 1
            continue
        }
        $seenNames[$name] = $true
        $seenUrls[$url] = $true
        $out.Add($l)
        $out.Add($url)
        $kept++
        $i = $j + 1
        continue
    }
    $i++
}

$final = @($header) + $out
$final | Set-Content $OutputFile -Encoding UTF8

Write-Output "原始频道条目数（不含伪频道）: $($kept + $skipped)"
Write-Output "去重后保留: $kept"
Write-Output "跳过重复: $skipped"
