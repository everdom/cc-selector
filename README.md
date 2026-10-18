# cc-selector (ccs)

**一个 Claude Code 多配置启动器** —— 从 [cc-switch](https://github.com/farion1231/cc-switch) 读取所有供应商配置，按需选择启动，不同配置可**同时并行**运行，随时在不同模型/供应商之间切换。

## 为什么需要它

cc-switch 通过改写全局 `~/.claude/settings.json` 来切换配置，切换后只有一个配置生效。如果你正在用一个配置跑任务，想同时用另一个模型开个新会话，就得来回切换。

cc-selector 换了一种方式：**不动全局配置**。它把选中的配置写到临时 settings 文件，以 `claude --settings <临时文件>` 启动，因此：

- ✅ 多个不同配置的 Claude Code **同时运行**，互不干扰
- ✅ cc-switch 本身继续正常使用，两边互不影响
- ✅ 内置权限模式选择（yolo / plan / acceptEdits），不用手写参数

## 特性

- 🔍 **模糊搜索选择**：输入即过滤，↑↓ 选择（缺 prompt_toolkit 时降级为编号列表）
- 🚀 **权限模式**：`-m yolo` / `-m plan` / `-m acceptEdits`，支持缩写 `d/a/p/y`
- ⭐ **默认模式**：`--set-default-mode` 设一次，以后免选
- 📦 **参数透传**：`--` 之后的参数原样传给 claude（`ccs glm -- --resume`）
- 🖥️ **跨平台**：Windows / Linux / macOS
- 🔌 **多 app**：也可查看 codex / gemini / opencode 的配置（`-a`）

## 安装

**Linux / macOS 一键安装（推荐，无需克隆仓库）:**

```bash
curl -fsSL https://raw.githubusercontent.com/everdom/cc-selector/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

**Linux / macOS（已克隆仓库）:**

```bash
curl -fsSL https://raw.githubusercontent.com/everdom/cc-selector/main/install.sh | bash
```

安装后重新打开终端即可。依赖：Python 3.8+（`prompt_toolkit` 由安装脚本自动装）。

## 更新

一键安装/脚本安装的 ccs 可自我更新到 GitHub 最新版:

```bash
ccs --update        # 从 GitHub 拉取最新版并覆盖
ccs --version       # 查看当前版本
```

git 克隆安装的会提示改用 `git pull`。

## 用法

```bash
ccs                                  # 交互选择配置和权限模式
ccs deepseek                         # 用名称匹配的配置启动（支持模糊匹配）
ccs deepseek -m yolo                 # yolo = --dangerously-skip-permissions
ccs -m p                             # 交互选配置，plan 模式
ccs deepseek -- --resume             # -- 后的参数原样传给 claude
ccs --list                           # 列出所有配置（* 为 cc-switch 当前项）
ccs --set-default-mode yolo          # 设置默认权限模式（免每次选）
ccs --default-mode                   # 查看当前默认模式
ccs --update                         # 更新 ccs 自身到 GitHub 最新版
ccs --version                        # 查看当前版本
ccs -a codex --list                  # 查看其他 app 类型的配置
ccs --help                           # 完整帮助
```

权限模式对应 Claude Code 权限模式：

| 模式 | 缩写 | 说明 |
|---|---|---|
| `default` | d | 每次操作都询问 |
| `acceptEdits` | a | 自动接受文件编辑 |
| `plan` | p | 只读规划模式 |
| `yolo` | y | `--dangerously-skip-permissions` |

模式优先级：`-m` 临时指定 > 默认模式（初始 default）。`--` 之后全部原样传给 claude。

## 工作原理

1. 只读打开 `~/.cc-switch/cc-switch.db`（SQLite），读取 `providers` 表
2. 把选中配置写入临时文件，注入 `env` 后启动 `claude --settings <临时文件>`
3. claude 退出后删除临时文件

## 文件结构

```
ccs.py        主程序（跨平台）
ccs.cmd       Windows 入口
ccs.sh        Linux/macOS 入口
install.ps1   Windows 安装脚本
install.sh    Linux/macOS 安装脚本
```
