# Mac 软件管家 · 配置与实施计划

一个本地运行的 macOS 软件安装 / 卸载工具。核心诉求：装的时候省事，卸的时候干净——把 App 和它散落在系统各处的残留一起找出来，且**删了能后悔**。

---

## 1. 形态选型

| 方案 | 说明 | 成本 | 适合 |
|---|---|---|---|
| **A. CLI 工具（推荐起步）** | Python 3 单入口 + 子命令，终端里 `macapp uninstall 微信` | 低，半天出可用版 | 自己用、要可靠 |
| B. 菜单栏 App | SwiftUI + MenuBarExtra，拖拽安装、列表卸载 | 中，需 Xcode + 签名/公证 | 要给别人用、要好看 |
| C. 本地网页界面 | 本地 HTTP 服务 + 浏览器 | 中，权限交互割裂 | 不推荐 |

**建议路径：先做 A 的内核引擎，稳定后套 B 的壳。** 引擎（扫描/校验/删除）与界面解耦，换壳不用重写。

## 2. 功能清单

**MVP（第一版必须有）**
- `install <路径|名称>`：识别 `.dmg` / `.pkg` / `.zip` / `.app`，校验架构与代码签名，装入 `/Applications`
- `inspect <名称>`：只扫描不改动，输出该 App 关联的全部文件与体积（dry-run）
- `uninstall <名称>`：退出进程 → 列残留清单 → 确认 → 全部移入废纸篓
- `list`：已装 App、体积、上次使用时间，按体积排序找"谁在占地方"

**二期**
- Homebrew cask 桥接（`brew install --cask` / `--zap`）
- 残留知识库：按 bundle id 匹配已知路径模板，识别率从 70% 提到 90%+
- 批量卸载 + 卸载报告导出（Markdown/CSV）
- 权限提升 helper，处理 `/Library` 下的守护进程与特权工具

## 3. 技术方案

| 环节 | 实现 |
|---|---|
| 挂载镜像 | `hdiutil attach -nobrowse -readonly`，结束 `detach` |
| 架构校验 | `lipo -archs`，非 arm64/x86_64 或纯 Intel 老包给出警告 |
| 签名/公证 | `codesign -dv --verbose=4`、`spctl -a -vv`，未签名给出风险提示 |
| 复制安装 | `ditto`（保留权限位与扩展属性），不用 `cp -R` |
| pkg 安装 | `installer -pkg X.pkg -target /`（需管理员） |
| Bundle ID | `mdls -name kMDItemCFBundleIdentifier` 或读 `Info.plist` |
| 残留定位 | 已知路径模板枚举 + `mdfind` 全盘按 bundle id 兜底 |
| pkg 残留 | `pkgutil --files <pkgid>` 拿文件清单；`pkgutil --forget` 清收据 |
| 删除 | `osascript` 移到废纸篓（可恢复），**不用 `rm`** |
| 提权 | `osascript ... with administrator privileges` 按需弹窗，不做常驻 root |

**残留扫描覆盖的目录**
```
~/Library/{Application Support, Caches, Preferences, Logs, HTTPStorages,
           Saved Application State, WebKit, Cookies, Containers, Group Containers}
~/Library/LaunchAgents
/Library/{Application Support, Caches, Preferences, Logs, LaunchAgents,
          LaunchDaemons, PrivilegedHelperTools, Receipts}
```

## 4. 安全红线（这部分比功能重要）

1. **白名单操作区**：只在 `/Applications`、`~/Applications`、上述 Library 子目录内动手
2. **黑名单**：`/System`、`/usr`、`/bin`、`/sbin`、`/etc`、`/private`、`~` 本身、`~/Documents`、`~/Desktop`、`~/Downloads`
3. **默认 dry-run**：不加 `--yes` 只打印清单，绝不执行
4. **共享目录只删子项**：`~/Library/Application Support` 本身永不删除，只删它下面属于该 App 的子目录
5. **批量上限 10 个/批**，逐批核对，出错立即停
6. **全量日志**：每次操作写 `~/.macapp/history.log`，记录删了什么、从哪来、能否还原

## 5. 目录结构

```
macapp/
├── cli.py          # 入口，argparse 子命令
├── scan.py         # 残留扫描与体积统计
├── install.py      # dmg/pkg/zip 安装
├── uninstall.py    # 退出进程 + 移废纸篓 + 日志
├── safety.py       # 白名单/黑名单校验，所有删除必经此处
└── rules.json      # 残留路径模板库
```

## 6. 里程碑

| 阶段 | 交付 | 验收标准 |
|---|---|---|
| M1 | 扫描 + dry-run | 对一个 App 能准确列出全部关联文件与总占用 |
| M2 | 卸载 | 移入废纸篓，可从废纸篓完整还原 |
| M3 | 安装 | dmg/pkg/zip 三种格式均能装上并可直接打开 |
| M4 | 增强 | brew 桥接、批量、报告导出 |

## 7. 需要你拍板的三件事

1. **形态**：直接上菜单栏 GUI，还是先 CLI 后加壳？（推荐后者）
2. **安装来源**：只处理本地下载的 dmg/pkg，还是要一并接 Homebrew / App Store？
3. **卸载激进程度**：
   - 保守：只删 `.app`
   - 标准：`.app` + Library 下的偏好/缓存/支持文件（推荐）
   - 深度：再加上 Containers、Group Containers、pkg 收据与 LaunchDaemons
