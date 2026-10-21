# Mac 软件管家

macOS 上的软件安装 / 卸载 / 残留清理工具。原生 SwiftUI 图形界面，不依赖 Python 运行时，数据全部在本机，不联网。

卸载一个应用时，它会把散落在系统各处的文件全部列出来——应用本体、`~/Library` 下的数据、缓存、偏好设置、沙盒容器、登录项——勾选确认后一次性清理。另外还有一条独立的「残留扫描」通道，专门处理「应用早就删了、数据还留着」的情况。

![界面](macapp-gui/docs/screenshot.png)

## 两个版本

| 目录 | 形态 | 说明 |
| --- | --- | --- |
| [`macapp-gui/`](macapp-gui/) | SwiftUI 图形应用 | 主力版本，打包成 `.app` / `.dmg`，双击即用 |
| [`macapp/`](macapp/) | Python 命令行 | 早期版本，逻辑与 GUI 版一致，适合脚本化和审计 |

两边的卸载记录格式相同（`~/.macapp/history/*.json`），可以互相还原。

## 功能

**安装**：支持 `.dmg`（自动挂载 → 复制 → 卸载卷）、`.zip`、`.app`、`.pkg`，也可以直接把文件拖进窗口。目标位置已有同名应用时，旧版本先进废纸篓。

**卸载**：选应用 → 看清单 → 勾选 → 移入废纸篓 / 彻底删除。每条标置信度，低置信度的模糊匹配默认不勾选。

**本地文件**：应用在你自己的文件夹（`~/Documents`、`~/Desktop`、`~/Downloads` 等）里留下的东西，单独列一组让你决定。默认不勾选，而且**只会移入废纸篓**——哪怕你选的是「彻底删除」。

**残留扫描**：不管应用什么时候删的、用什么删的，只要数据还在、应用已经不在，就能一次扫出来清掉。判定原则是「宁可漏报，不可错杀」。

**还原**：走「移入废纸篓」的卸载都有记录，可以一键搬回原位置。

## 安全设计

| 机制 | 说明 |
| --- | --- |
| 默认可恢复 | 用系统 `trashItem` API，支持访达「放回原处」 |
| 白名单 | 只在 `/Applications`、`~/Applications`、`~/Library` 若干子目录内操作 |
| 禁区 | `/System`、`/usr`、`~/Documents`、`~/.ssh`、`~/Library/Keychains` 等，任何情况不碰 |
| 共享目录只删子项 | `~/Library/Application Support` 本身永不删除 |
| 先预检再动手 | 废纸篓不可写就整体中止，一个文件都不动 |
| 本地文件只进废纸篓 | 用户文档永远不会被彻底删除 |
| 残留默认进废纸篓 | 彻底删除需二次勾选；超过 500 MB 的项单独高亮警告 |

## 安装

```sh
open "macapp-gui/dist/Mac软件管家-1.3.dmg"
```

把 `Mac软件管家` 拖进「应用程序」文件夹即可。已做 ad-hoc 签名，本机双击就能用。

> 首次打开如果提示「无法验证开发者」，右键点击图标选「打开」。本应用没有经过苹果公证。

## 从源码构建

```sh
cd macapp-gui
./build.sh      # 输出 dist/Mac软件管家.app
./package.sh    # 输出 dist/Mac软件管家-1.3.dmg
```

需要 macOS 14+ 与命令行工具。注意 **macOS 27 SDK 里的 SwiftUI 把 `@State` 等属性包装器改成了宏**，而命令行工具不附带 `SwiftUIMacros` 插件，直接编译会报 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`，所以 `build.sh` 固定使用 `MacOSX26.5.sdk`。

命令行版：

```sh
cd macapp
./macapp.sh list
./macapp.sh inspect <应用名>
./macapp.sh uninstall <应用名>
```

## 自检

```sh
"macapp-gui/dist/Mac软件管家.app/Contents/MacOS/MacApp" --selftest
python3 macapp/selftest.py
```

图形版覆盖 117 项：路径安全、通配符匹配、应用发现、扫描结果合法性、废纸篓往返、彻底删除、残留判定、本地文件校验、权限探测。

## 已知限制

- 只构建了 arm64，Intel Mac 需要改 `build.sh` 里的 target
- 「残留」终究是猜的。Spotlight 没索引到的应用仍可能被误判，所以清理默认走废纸篓，别跳过
- ad-hoc 签名，每次重新构建签名都会变，旧的 TCC 授权可能失效
- 本地文件只按名字匹配，中英文名对不上时会漏

## 相关文档

- [配置计划](mac-app-manager-plan.md) —— 最初的设计方案与取舍
- [图形版说明](macapp-gui/README.md) —— TCC 权限、构建细节、调试入口
- [命令行版说明](macapp/README.md)
- [更新日志](CHANGELOG.md)
