# 更新日志

## v1.3 — 2026-10-21

**修复一次真实事故：残留扫描误判微信容器。**

三个漏洞叠在一起，导致 12.08 GB 微信本地数据被当成「孤儿目录」彻底删除：

1. 应用发现只扫 `/Applications` 和 `~/Applications`。微信装在 iCloud Drive 里，扫描器认为「微信没装」，它的 12 GB 容器就成了无主数据。→ 改用 Spotlight 全盘索引（`mdfind`），bundle id 从 15 个涨到 327 个。
2. Group Containers 的团队 ID 前缀没处理，`5A4RE8SF68.com.tencent.xinWeChat`、`243LU875E5.groups.com.apple.podcasts` 全都认不出来，连 Apple 自家的容器都被列成残留。→ 剥掉 10 位团队 ID 和 `group.`/`groups.` 前缀再判定。
3. 没有体积红线，且清理只有「彻底删除」一条路。12 GB 和 4 KB 在界面上长得一样。→ 超过 200 MB 的容器强制降为中置信度；清理默认移入废纸篓，彻底删除要额外勾选；超过 500 MB 的项单独高亮。

教训：**「残留」这个判断一旦错了，代价是不可逆的**。现在的原则是「宁可漏报，不可错杀」，并且默认留退路。

## v1.2 — 2026-10-21

**修复权限探测 + 卸载时列出本地文件。**

- 授权 bug：旧版拿 `~/Library/Application Support/com.apple.TCC/TCC.db` 当探针，这个文件在新版 macOS 上根本不存在，导致无论怎么授权都显示未授权。改成三态多路探测（已授权 / 被拒绝 / 无法判断）。
- TCC 判定按进程缓存，授权后必须重启才生效 → 加「重启应用」按钮。
- 从 dmg 里直接运行会被 App Translocation 挂到随机路径，授权留不住 → 能识别并提示。
- 卸载时新增「本地文件」分组：扫用户文件夹下的一级条目，按应用名 / 文件名 / bundle id 匹配，默认不勾选，且只会移入废纸篓。
- 应用不再把自己列进可卸载清单。

## v1.1 — 2026-10-21

**新增残留扫描。**

不再依赖「先选中某个 .app 再卸载」，直接判断「应用已经不在、数据还留着」，扫 10 个位置：`Containers`、`Group Containers`、`Application Support`、`Caches`、`HTTPStorages`、`WebKit`、`Saved Application State`、`Logs`、`LaunchAgents`、`Preferences`。

## v1.0 — 2026-10-21

**首个可用版本。**

- 图形界面：应用列表 + 残留清单 + 勾选确认
- 两种删除方式：移入废纸篓（可还原）、彻底删除（不留副本）
- 安装 dmg / pkg / zip / app
- 卸载记录与一键还原
- 路径白名单与禁区校验
