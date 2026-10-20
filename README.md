# cc-selector (ccs)

**一个 Claude Code 多配置启动器** —— 从 [cc-switch](https://github.com/farion1231/cc-switch) 读取所有供应商配置，按需选择启动，不同配置可**同时并行**运行，随时在不同模型/供应商之间切换。

**A multi-profile launcher for Claude Code** — reads all provider profiles from [cc-switch](https://github.com/farion1231/cc-switch), lets you pick one to launch, runs multiple profiles **in parallel**, and switches between models/providers at any time.

---

## 中文

### 为什么需要它

cc-switch 通过改写全局 `~/.claude/settings.json` 来切换配置，切换后只有一个配置生效。如果你正在用一个配置跑任务，想同时用另一个模型开个新会话，就得来回切换。

cc-selector 换了一种方式：**不动全局配置**。它把选中的配置写到临时 settings 文件，以 `claude --settings <临时文件>` 启动，因此：

- ✅ 多个不同配置的 Claude Code **同时运行**，互不干扰
- ✅ cc-switch 本身继续正常使用，两边互不影响
- ✅ 内置权限模式选择（yolo / plan / acceptEdits），不用手写参数
- ✅ 选择器光标初始停在 cc-switch 当前使用的配置上

### 特性

- 🔍 **模糊搜索选择**：输入即过滤，↑↓ 选择（缺 prompt_toolkit 时降级为编号列表）
- 🚀 **权限模式**：`-m yolo` / `-m plan` / `-m acceptEdits`，支持缩写 `d/a/p/y`
- ⭐ **默认模式**：`--set-default-mode` 设一次，以后免选
- 📦 **参数透传**：`--` 之后的参数原样传给 claude（`ccs glm -- --resume`）
- 🖥️ **跨平台**：Windows / Linux / macOS，Windows 也支持远程一键安装
- 🔌 **多 app**：也可查看 codex / gemini / opencode 的配置（`-a`）

### 安装

**Linux / macOS 一键安装（推荐，无需克隆仓库）:**

```bash
curl -fsSL https://raw.githubusercontent.com/everdom/cc-selector/main/install.sh | bash
```

**Windows 一键安装（推荐，无需克隆仓库）:**

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/everdom/cc-selector/main/install.ps1 | iex"
```

**已克隆仓库（Linux / macOS）:**

```bash
./install.sh
```

**已克隆仓库（Windows）:**

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

安装后重新打开终端即可。依赖：Python 3.8+（`prompt_toolkit` 由安装脚本自动装）。

### 更新

一键安装/脚本安装的 ccs 可自我更新到 GitHub 最新版:

```bash
ccs --update        # 从 GitHub 拉取最新版并覆盖
ccs --version       # 查看当前版本
```

git 克隆安装的会提示改用 `git pull`。

### 用法

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

### 工作原理

1. 只读打开 `~/.cc-switch/cc-switch.db`（SQLite），读取 `providers` 表
2. 把选中配置写入临时文件，注入 `env` 后启动 `claude --settings <临时文件>`
3. claude 退出后删除临时文件

### 文件结构

```
ccs.py        主程序（跨平台）
ccs.cmd       Windows 入口
ccs.sh        Linux/macOS 入口
install.ps1   Windows 安装脚本
install.sh    Linux/macOS 安装脚本
```

---

## English

### Why

cc-switch switches profiles by rewriting the global `~/.claude/settings.json`, so only one profile is active at a time. If you're running a task with one profile and want to open a new session with another model, you have to switch back and forth.

cc-selector takes a different approach: **it never touches the global config**. It writes the selected profile to a temp settings file and launches `claude --settings <temp file>`, so:

- ✅ Multiple Claude Code instances with **different profiles run in parallel** without interference
- ✅ cc-switch keeps working as usual — the two don't affect each other
- ✅ Built-in permission mode picker (yolo / plan / acceptEdits) — no need to type flags
- ✅ The picker cursor starts on the profile currently in use by cc-switch

### Features

- 🔍 **Fuzzy search picker**: type to filter, ↑↓ to select (falls back to a numbered list without prompt_toolkit)
- 🚀 **Permission modes**: `-m yolo` / `-m plan` / `-m acceptEdits`, with short forms `d/a/p/y`
- ⭐ **Default mode**: set once with `--set-default-mode`
- 📦 **Arg passthrough**: everything after `--` goes straight to claude (`ccs glm -- --resume`)
- 🖥️ **Cross-platform**: Windows / Linux / macOS, with one-line remote install on Windows too
- 🔌 **Multiple apps**: also browse codex / gemini / opencode profiles (`-a`)

### Install

**Linux / macOS one-liner (recommended, no clone needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/everdom/cc-selector/main/install.sh | bash
```

**Windows one-liner (recommended, no clone needed):**

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/everdom/cc-selector/main/install.ps1 | iex"
```

**From a cloned repo (Linux / macOS):**

```bash
./install.sh
```

**From a cloned repo (Windows):**

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Reopen your terminal after install. Requires Python 3.8+ (`prompt_toolkit` is installed automatically).

### Update

```bash
ccs --update        # pull the latest version from GitHub and overwrite
ccs --version       # show current version
```

If installed from a git clone, ccs will suggest `git pull` instead.

### Usage

```bash
ccs                                  # interactive profile & mode picker
ccs deepseek                         # launch with a matching profile (fuzzy)
ccs deepseek -m yolo                 # yolo = --dangerously-skip-permissions
ccs -m p                             # plan mode, pick profile interactively
ccs deepseek -- --resume             # args after -- are passed to claude
ccs --list                           # list all profiles (* = cc-switch current)
ccs --set-default-mode yolo          # set the default permission mode
ccs --default-mode                   # show current default mode
ccs --update                         # update ccs itself to the latest release
ccs --version                        # show current version
ccs -a codex --list                  # browse other app types' profiles
ccs --help                           # full help
```

Permission modes map to Claude Code permission modes:

| Mode | Short | Description |
|---|---|---|
| `default` | d | Ask for every action |
| `acceptEdits` | a | Auto-accept file edits |
| `plan` | p | Read-only plan mode |
| `yolo` | y | `--dangerously-skip-permissions` |

Priority: an explicit `-m` wins over the default mode (initially `default`). Everything after `--` is passed to claude verbatim.

### How it works

1. Opens `~/.cc-switch/cc-switch.db` (SQLite) read-only and reads the `providers` table
2. Writes the selected profile to a temp file, injects `env`, launches `claude --settings <temp file>`
3. Removes the temp file when claude exits

### Files

```
ccs.py        Main program (cross-platform)
ccs.cmd       Windows entry
ccs.sh        Linux/macOS entry
install.ps1   Windows installer
install.sh    Linux/macOS installer
```
