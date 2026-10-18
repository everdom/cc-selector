# ccs

用 [cc-switch](https://github.com/farion1231/cc-switch) 中的配置启动 Claude Code —— 随时用不同配置，且可多个并行。

cc-switch 切换后全局只生效一个配置；`ccs` 读取 cc-switch 数据库，把选中的配置写到临时 settings 文件后以 `claude --settings <临时文件>` 启动，**不改全局 `~/.claude/settings.json`**，因此不同配置的 Claude Code 可以同时运行。

## 安装

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

**Linux / macOS:**

```bash
chmod +x install.sh && ./install.sh
```

安装后重新打开终端即可。依赖：Python 3.8+（`prompt_toolkit` 由安装脚本自动装，缺失时交互界面降级为编号列表）。

## 用法

```bash
ccs                                  # 交互选择配置和权限模式
ccs deepseek                         # 用名称匹配的配置启动
ccs deepseek -m yolo                 # yolo = --dangerously-skip-permissions
ccs -m p                             # 交互选配置，plan 模式（缩写 d/a/p/y）
ccs deepseek -- --resume             # -- 后的参数原样传给 claude
ccs --list                           # 列出所有配置（* 为 cc-switch 当前项）
ccs --set-default-mode yolo          # 设置默认权限模式（免每次选）
ccs --default-mode                   # 查看当前默认模式
ccs -a codex --list                  # 查看其他 app 类型的配置
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
