# iptv-dedup

多源聚合的**实测探活 + 1080P 优先** IPTV 直播列表，GitHub Actions 每日自动更新。

上游合并 best-fan/iptv-sources 与 CCSH/IPTV 两个每日更新源，频道名归一化合并后，
用 ffprobe 逐个实测每个候选流的**真实分辨率**，每个频道只保留一个**可播放且 ≥1080P** 的源。

当前线上：主文件约 119 个频道（全部 ≥1080P），备用文件约 41 个（无 1080 源的频道）。

## 直链（Kodi / VLC / TiviMate 等直接订阅）

| 文件 | 内容 | 直链 |
|------|------|------|
| **live_lite_dedup.m3u**（主推） | ~119 个频道，全部 ≥1080P | `https://raw.githubusercontent.com/XU-Boqing/iptv-dedup/main/live_lite_dedup.m3u` |
| live_lite_dedup_720p.m3u（备用） | ~41 个无 1080 源的频道（720p 次优） | `https://raw.githubusercontent.com/XU-Boqing/iptv-dedup/main/live_lite_dedup_720p.m3u` |

## 工作原理（每日 04:30，北京时间）

1. **拉取上游**（缓存不入库）：
   - [best-fan/iptv-sources](https://github.com/best-fan/iptv-sources) `cn_all.m3u8`（约 200 条，实测存活率 ~67%）
   - [CCSH/IPTV](https://github.com/CCSH/IPTV) `live_lite.m3u`（约 1900 条，实测存活率 ~24%）
2. **频道名归一化合并**：`CCTV-1 (720p)`、`CCTV1`、`CCTV-1` 视为同一频道
3. **实测探活**：每频道取前 8 个候选，ffprobe 硬超时 10s、并发 40 实测真实分辨率
4. **选源**：≥1080 的最高清源进主文件；无 1080 源的进备用文件；全死剔除
5. **保险丝**：产出 <30 频道视为异常，拒绝提交（保护线上文件不被坏结果覆盖）

## 本地重跑（可选）

探活视角影响结果：GitHub Actions 在海外，对中国运营商 CDN 的可达性与国内直连不同。
若想用国内视角刷新，在本机（需 PowerShell 7 + ffprobe）执行：

```powershell
pwsh ./dedup.ps1 -InputFiles @('bestfan.m3u8','live_lite.m3u') -TopN 8 -MinChannels 30
# 上游文件可先手动下载，或直接用仓库 .gitignore 排除的同名缓存
```

跑完 `git add live_lite_dedup*.m3u && git commit && git push` 即可发布。

## 文件说明

| 文件 | 说明 |
|------|------|
| `live_lite_dedup.m3u` | **主输出（用这个）**：全 ≥1080P 频道 |
| `live_lite_dedup_720p.m3u` | 备用输出：仅 720p 等次优源的频道 |
| `dedup.ps1` | 去重探活脚本（PowerShell 7+，需 ffprobe） |
| `.github/workflows/dedup.yml` | 每日自动更新工作流 |
| `.gitignore` | 排除上游缓存与中间产物 |

## 已知取舍

- 每频道只留一个源：失去"卡了换下一条"的冗余，换取干净列表；源失效后第二天自动换新
- 海外视角可能漏掉仅国内可见的源；介意可本地重跑（见上）
