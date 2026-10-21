# macapp

macOS 软件卸载工具。目标只有一个：**卸得干净，且删了能后悔**。

纯 Python 3 标准库实现，无第三方依赖，不需要 root。

## 使用

```sh
./macapp.sh list                 # 看谁在占地方（按体积排序）
./macapp.sh inspect Doubao       # 只扫描不改动，先看会清掉什么
./macapp.sh uninstall Doubao     # 交互确认后卸载
./macapp.sh history              # 卸载记录
./macapp.sh restore 20261021-1936 # 后悔了，原样还原
```

`inspect` 和 `uninstall` 都接受三种写法：应用名（支持模糊，唯一时自动命中）、Bundle ID、`.app` 完整路径。

常用参数：

| 参数 | 作用 |
|---|---|
| `-y, --yes` | 跳过确认，适合脚本 |
| `--include-low` | 纳入低置信度项（Group Containers 这类模糊匹配） |
| `--keep-config` | 只删程序，保留偏好与用户数据 |
| `--force-quit` | 进程不退出时强制结束 |
| `--no-quit` | 完全不尝试退出应用 |
| `--json` | 机器可读输出（`list` / `inspect`） |

## 它怎么找残留

四路并行，结果按置信度标注：

1. **规则模板**：`rules.json` 里 30 多条路径模板，用 bundle id / 应用名填充。命中 bundle id 的标"高"，命中应用名的标"中"。
2. **前缀 glob**：`~/Library/Caches/<bundle_id>*` 这类，抓 Electron 应用的 `.browser`、`.helper` 等变体。
3. **Group Containers**：沙盒应用的共享容器只能模糊匹配，一律标"低"，默认不纳入。
4. **pkg 收据**：`pkgutil --file-info` 反查这个 App 由哪个安装包写入，再用 `pkgutil --files` 拿到官方文件清单，标"高"。

## 安全机制

- **只移不删**：所有东西进 `~/.Trash`，同名自动加时间戳，不会覆盖已有的废纸篓文件。
- **可还原**：每次卸载写一份 manifest 到 `~/.macapp/history/`，`restore` 按原路径搬回，父目录自动重建。
- **白名单**：只在 `/Applications`、`~/Applications`、`~/Library` 下若干子目录内操作。
- **禁区**：`/System`、`/usr`、`/bin`、`/etc`、`/private`、`~/Documents`、`~/Desktop`、`~/Downloads`、`~/.ssh`、`~/Library/Keychains` 等，任何情况下不碰。
- **共享目录只删子项**：`~/Library/Application Support` 本身永不删除。
- **先检查再动手**：`uninstall` 默认要确认；非交互环境必须显式 `-y`；废纸篓不可写时直接中止，一个文件都不动。
- **失败即停**：应用本体删不掉就中止，不继续动残留文件。

`/Library` 下的 LaunchDaemons、PrivilegedHelperTools 需要 root，本工具**只列出不处理**，并给出对应的 `sudo rm` 命令，由你自己决定要不要执行。

## 自检

```sh
python3 selftest.py
```

覆盖 19 条路径安全用例（含 `..` 穿越、符号链接、禁区判定）、废纸篓移入/还原往返、全量扫描结果的安全校验。

## 当前边界

- 只处理 `/Applications` 和 `~/Applications`，不扫 `/System/Applications`（系统自带应用本来也不该卸）。
- 没有图形界面，M4 之后再套 SwiftUI 菜单栏壳，引擎可直接复用。
- 安装功能（dmg / pkg / zip）属于 M3，尚未实现。
- 已卸载但残留还在的情况（只知道 bundle id）暂不支持，后续加 `macapp clean <bundle-id>`。
