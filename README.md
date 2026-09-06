# iptv-dedup

[CCSH/IPTV](https://github.com/CCSH/IPTV) `live_lite.m3u` 的**每日自动去重版**。

上游每天更新约 1900+ 条频道条目，但其中大量是同名频道的冗余源（同一个台出现 5~30 次）。本仓库用 GitHub Actions 每天拉取上游最新列表，按"同名频道保留第一个源"策略去重（先剔除重复 URL，再按频道名去重），输出精简列表：

- 上游约 1940 条 → 去重后约 **260+ 个唯一频道**
- 分组保留：央视频道 / 卫视频道 / 港澳台 / 电影 / 电视剧 / NewTV / 综艺 / 体育 等
- 保留 `x-tvg-url` EPG 声明，可配合 CCSH 的 `e.xml.gz` 显示节目单
- 更新时间：北京时间每日 04:30（上游 04:00 更新后半小时）

## 直链

```
https://raw.githubusercontent.com/XU-Boqing/iptv-dedup/main/live_lite_dedup.m3u
```

EPG（可选，来自上游 CCSH）：

```
https://raw.githubusercontent.com/CCSH/IPTV/refs/heads/main/e.xml.gz
```

## 使用

在 Kodi 的 PVR IPTV Simple Client 中把 M3U URL 换成上面的直链即可。也适用于任何支持 m3u 的播放器（VLC / TiviMate / DIYP 等）。

## 文件说明

| 文件 | 说明 |
|------|------|
| `live_lite.m3u` | 上游原始列表（每日同步） |
| `live_lite_dedup.m3u` | **去重版（用这个）** |
| `dedup.ps1` | 去重脚本（PowerShell） |
| `.github/workflows/dedup.yml` | 每日自动更新工作流 |

## 已知取舍

- 同名频道只保留第一个源：上游排序把运营商 CDN 等相对稳定的源排在前面，所以保留的通常是较稳的源；但代价是失去"卡了换下一条"的冗余备份
- 如果某天保留的源失效，第二天 04:30 自动更新会自动换新源
