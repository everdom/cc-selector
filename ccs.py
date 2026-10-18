#!/usr/bin/env python3
"""ccs - 用 cc-switch 中的指定配置启动 Claude Code.

从 cc-switch 数据库 (~/.cc-switch/cc-switch.db) 读取供应商配置，
交互式选择后以 `claude --settings <临时文件>` 启动，
不修改全局 ~/.claude/settings.json，因此不同配置可同时并行运行。
"""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

__version__ = "1.0.0"

CC_SWITCH_DB = Path.home() / ".cc-switch" / "cc-switch.db"
CONFIG_FILE = Path.home() / ".ccs" / "config.json"
CCS_RAW_URL = "https://raw.githubusercontent.com/everdom/cc-selector/main/ccs.py"
CCS_TARBALL_URL = "https://codeload.github.com/everdom/cc-selector/tar.gz/refs/heads/main"
APP_TYPE = "claude"

# 权限模式 -> 传给 claude 的参数
PERMISSION_MODES = {
    "default": [],
    "acceptEdits": ["--permission-mode", "acceptEdits"],
    "plan": ["--permission-mode", "plan"],
    "yolo": ["--dangerously-skip-permissions"],
}
MODE_ALIASES = {
    "d": "default", "default": "default",
    "a": "acceptEdits", "accept": "acceptEdits", "acceptEdits": "acceptEdits",
    "p": "plan", "plan": "plan",
    "y": "yolo", "yolo": "yolo",
}


def help_text():
    return """ccs - 用 cc-switch 中的配置启动 Claude Code（可多配置并行）

用法:
  ccs [选项] [配置名] [-- claude参数...]

选项:
  -m, --mode <模式>   权限模式: default | acceptEdits | plan | yolo
                      (缩写: d / a / p / y)
  -l, --list          列出所有配置后退出
  -a, --app <类型>    app 类型: claude(默认) | codex | gemini | opencode
  -h, --help          显示本帮助

模式说明（对应 Claude Code 权限模式）:
  default      每次操作都询问
  acceptEdits  自动接受文件编辑 (a)
  plan         只读规划模式 (p)
  yolo         跳过所有权限确认 = --dangerously-skip-permissions (y)

配置管理:
  ccs --set-default-mode yolo      设置默认权限模式（写 ~/.ccs/config.json）
  ccs --default-mode               查看当前默认模式

自身维护:
  ccs --update                     从 GitHub 更新 ccs 到最新版
  ccs --version                    查看当前版本

示例:
  ccs                              交互选择配置和模式
  ccs deepseek                     用 deepseek 配置启动
  ccs deepseek -m yolo             用 deepseek + yolo 模式
  ccs -m plan                      交互选配置，plan 模式
  ccs glm -- --resume              glm 配置，其余参数原样传给 claude

临时指定一次的模式优先于默认模式；不指定时用默认模式（初始为 default）。
配置名支持模糊匹配，多个匹配时弹出选择菜单。
"""


def load_config():
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_config(cfg):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def resolve_mode(argv):
    """返回 (mode, 剩余argv, 是否显式指定)。别名归一化，非法则退出。"""
    mode = None
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-m", "--mode"):
            if i + 1 >= len(argv):
                sys.exit(f"{a} 需要一个模式参数: default|acceptEdits|plan|yolo")
            mode = argv[i + 1]
            i += 2
        elif a.startswith("--mode="):
            mode = a.split("=", 1)[1]
            i += 1
        else:
            rest.append(a)
            i += 1
    if mode is not None:
        m = MODE_ALIASES.get(mode.lower())
        if m is None:
            sys.exit(
                f"未知模式 '{mode}'。可选: default | acceptEdits | plan | yolo"
                "（缩写 d / a / p / y）"
            )
        return m, rest, True
    return None, rest, False


def pick_mode_interactive(default_mode):
    """交互式选权限模式。prompt_toolkit 可用则带 UI，否则编号输入。"""
    modes = list(PERMISSION_MODES.keys())
    desc = {
        "default": "每次操作都询问",
        "acceptEdits": "自动接受文件编辑",
        "plan": "只读规划模式",
        "yolo": "跳过所有权限确认 (--dangerously-skip-permissions)",
    }
    try:
        from prompt_toolkit.shortcuts import radiolist_dialog

        result = radiolist_dialog(
            title="权限模式",
            text="选择权限模式（回车确认，Esc 取消）:",
            values=[(m, f"{m}  -  {desc[m]}" + ("  [默认]" if m == default_mode else ""))
                    for m in modes],
            default=default_mode,
        ).run()
        return result
    except Exception:
        pass

    print("\n权限模式:")
    for i, m in enumerate(modes, 1):
        mark = " [默认]" if m == default_mode else ""
        print(f"  {i}. {m:<12} {desc[m]}{mark}")
    try:
        raw = input(f"选择 [1-{len(modes)}，回车=default]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        return None
    if not raw:
        return "default"
    if raw.isdigit() and 1 <= int(raw) <= len(modes):
        return modes[int(raw) - 1]
    return MODE_ALIASES.get(raw)


def load_providers(app_type=APP_TYPE):
    if not CC_SWITCH_DB.exists():
        sys.exit(f"未找到 cc-switch 数据库: {CC_SWITCH_DB}")
    conn = sqlite3.connect(f"file:{CC_SWITCH_DB}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT name, settings_config, is_current FROM providers "
            "WHERE app_type = ? ORDER BY sort_index, name",
            (app_type,),
        ).fetchall()
    finally:
        conn.close()

    providers = []
    for name, config, is_current in rows:
        try:
            settings = json.loads(config)
        except json.JSONDecodeError:
            continue
        providers.append(
            {"name": name, "settings": settings, "current": bool(is_current)}
        )
    return providers


def pick_interactive(providers):
    """prompt_toolkit 模糊搜索 + 列表选择；失败则退回简单输入。"""
    try:
        from prompt_toolkit.application import Application
        from prompt_toolkit.buffer import Buffer
        from prompt_toolkit.key_binding import KeyBindings
        from prompt_toolkit.layout import HSplit, Layout, Window
        from prompt_toolkit.layout.containers import VSplit
        from prompt_toolkit.layout.controls import BufferControl, FormattedTextControl
        from prompt_toolkit.styles import Style
        from prompt_toolkit.widgets import SearchToolbar
    except ImportError:
        return pick_simple(providers)

    state = {"index": 0, "filtered": list(providers)}

    def matches(p, query):
        if not query:
            return True
        q = query.lower()
        return q in p["name"].lower()

    def get_menu_fragments():
        frags = []
        for i, p in enumerate(state["filtered"]):
            marker = "● " if p["current"] else "  "
            style = ""
            if i == state["index"]:
                style = "class:selected"
            elif p["current"]:
                style = "class:current"
            suffix = "  (当前)" if p["current"] else ""
            frags.append((style, f"{marker}{p['name']}{suffix}\n"))
        return frags

    kb = KeyBindings()

    @kb.add("up")
    @kb.add("c-p")
    def _(event):
        if state["index"] > 0:
            state["index"] -= 1

    @kb.add("down")
    @kb.add("c-n")
    def _(event):
        if state["index"] < len(state["filtered"]) - 1:
            state["index"] += 1

    # eager=True: 抢在内置 emacs 绑定（单行 buffer 有文本时 enter=accept 输入，
    # 会清空过滤框导致菜单重置、永不退出）之前处理按键
    @kb.add("enter", eager=True)
    def _(event):
        if state["filtered"]:
            event.app.exit(result=state["filtered"][state["index"]]["name"])

    @kb.add("escape", eager=True)
    @kb.add("c-c", eager=True)
    def _(event):
        event.app.exit(result=None)

    @kb.add("pageup")
    def _(event):
        state["index"] = 0

    @kb.add("pagedown")
    def _(event):
        state["index"] = len(state["filtered"]) - 1

    search_toolbar = SearchToolbar()

    def buffer_changed(_buffer):
        query = buffer.text
        state["filtered"] = [p for p in providers if matches(p, query)]
        state["index"] = 0

    buffer = Buffer(on_text_changed=buffer_changed, multiline=False)

    layout = Layout(
        HSplit(
            [
                Window(
                    FormattedTextControl(get_menu_fragments, show_cursor=False),
                    wrap_lines=True,
                ),
                VSplit(
                    [Window(BufferControl(buffer=buffer), height=1), search_toolbar]
                ),
            ]
        )
    )

    app = Application(
        layout=layout,
        key_bindings=kb,
        full_screen=False,
        mouse_support=False,
        style=Style.from_dict(
            {"selected": "reverse bold", "current": "fg:ansicyan"}
        ),
    )
    result = app.run()
    return result


def pick_interactive_safe(providers):
    try:
        return pick_interactive(providers)
    except Exception:
        return pick_simple(providers)


def pick_simple(providers):
    print("\n可用配置:")
    for i, p in enumerate(providers, 1):
        cur = "  [当前]" if p["current"] else ""
        print(f"  {i:>2}. {p['name']}{cur}")
    try:
        raw = input("\n输入编号或名称: ").strip()
    except (EOFError, KeyboardInterrupt):
        return None
    if raw.isdigit():
        idx = int(raw) - 1
        if 0 <= idx < len(providers):
            return providers[idx]["name"]
        return None
    hits = [p for p in providers if raw.lower() in p["name"].lower()]
    return hits[0]["name"] if len(hits) == 1 else (hits[0]["name"] if hits else None)


LAUNCH_COMMANDS = {
    "claude": ["claude"],
    "codex": ["codex"],
    "gemini": ["gemini"],
    "opencode": ["opencode"],
}


def find_executable(name):
    """跨平台查找可执行文件，含 Windows 的 .cmd/.bat/.exe。"""
    exts = [".cmd", ".bat", ".exe"] if os.name == "nt" else []
    path = shutil.which(name)
    if path:
        return path
    for ext in exts:
        path = shutil.which(name + ext)
        if path:
            return path
    return shutil.which(name + ".ps1") if os.name == "nt" else None


def parse_version(text):
    """从 ccs.py 源码中提取 __version__；缺失返回 None。"""
    m = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', text, re.M)
    return m.group(1) if m else None


def fetch_remote_ccs():
    """下载 GitHub 上最新的 ccs.py。

    优先 codeload tarball: 无 CDN 缓存（raw 有数分钟缓存）、无 API 限流
    （匿名 60 次/小时）。失败时依次退回 GitHub API contents 和 raw 地址。
    """
    import io
    import tarfile
    import urllib.request

    ua = {"User-Agent": "ccs-updater"}
    last_err = None

    try:
        req = urllib.request.Request(CCS_TARBALL_URL, headers=ua)
        with urllib.request.urlopen(req, timeout=30) as resp:
            blob = resp.read()
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
            for member in tf.getmembers():
                if member.isfile() and member.name.endswith("/ccs.py"):
                    return tf.extractfile(member).read()
        last_err = OSError("tarball 中未找到 ccs.py")
    except (OSError, tarfile.TarError) as e:
        last_err = e

    for url, headers in [
        (
            "https://api.github.com/repos/everdom/cc-selector/contents/ccs.py",
            {**ua, "Accept": "application/vnd.github.raw+json"},
        ),
        (CCS_RAW_URL, ua),
    ]:
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=20) as resp:
                return resp.read()
        except OSError as e:
            last_err = e
    raise last_err if last_err else OSError("下载失败")


def cmd_update():
    """ccs --update: 从 GitHub 拉取最新 ccs.py 覆盖当前安装的文件。"""
    here = Path(__file__).resolve()
    if (here.parent / ".git").exists():
        sys.exit(
            "当前 ccs.py 位于 git 仓库中，请用 git pull 更新:\n"
            f"  cd {here.parent} && git pull"
        )

    print("[ccs] 检查更新 ...")
    try:
        data = fetch_remote_ccs()
    except OSError as e:
        sys.exit(f"[ccs] 下载失败: {e}")

    text = data.decode("utf-8")
    try:
        compile(text, "ccs.py", "exec")
    except SyntaxError as e:
        sys.exit(f"[ccs] 下载的文件语法异常，放弃更新: {e}")

    remote_ver = parse_version(text)
    if remote_ver is None:
        sys.exit(
            "[ccs] 下载的文件缺少版本信息，放弃更新。\n"
            "若刚发布新版本，可能是 GitHub CDN 缓存延迟，请几分钟后重试。"
        )

    local_ver = __version__
    if remote_ver == local_ver:
        print(f"[ccs] 已是最新版本: {local_ver}")
        return

    # 先写临时文件再原子替换，保证中断后不会留下半截文件
    tmp = here.with_name(here.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, here)
    print(f"[ccs] 已更新: {local_ver} -> {remote_ver}  ({here})")
    print("[ccs] 重新运行 ccs 即可使用新版本。")


def launch(provider, extra_args, app_type, mode_args):
    settings = dict(provider["settings"])

    # 同步把 env 段写入进程环境，保证最可靠（--settings 之外双保险）
    env = os.environ.copy()
    for k, v in settings.get("env", {}).items():
        if isinstance(v, str):
            env[k] = v

    # 写临时 settings 文件
    safe_name = "".join(c for c in provider["name"] if c.isalnum() or c in "-_") or "cfg"
    tmp_path = Path(tempfile.gettempdir()) / f"ccs-{safe_name}-{os.getpid()}.json"
    tmp_path.write_text(
        json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    cmd_name = LAUNCH_COMMANDS.get(app_type, ["claude"])[0]
    base = find_executable(cmd_name)
    if not base:
        sys.exit(f"找不到可执行文件 '{cmd_name}'")

    cmd = [base, "--settings", str(tmp_path)] + mode_args + extra_args
    mode_label = "default" if not mode_args else "自定义"
    print(f"[ccs] 配置: {provider['name']}  模式: {mode_label}")
    try:
        proc = subprocess.run(cmd, env=env)
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass
    sys.exit(proc.returncode if isinstance(proc.returncode, int) else 0)


def main():
    argv = sys.argv[1:]

    if "-h" in argv or "--help" in argv:
        print(help_text())
        return

    if "--update" in argv or "update" in argv:
        cmd_update()
        return
    if "--version" in argv:
        print(__version__)
        return

    cfg = load_config()
    default_mode = cfg.get("default_mode", "default")

    # --set-default-mode / --default-mode
    if "--set-default-mode" in argv:
        i = argv.index("--set-default-mode")
        if i + 1 >= len(argv):
            sys.exit("用法: ccs --set-default-mode <default|acceptEdits|plan|yolo>")
        m = MODE_ALIASES.get(argv[i + 1].lower())
        if m is None:
            sys.exit(f"未知模式 '{argv[i + 1]}'。可选: default | acceptEdits | plan | yolo")
        cfg["default_mode"] = m
        save_config(cfg)
        print(f"[ccs] 默认模式已设为: {m}  (写入 {CONFIG_FILE})")
        return
    if "--default-mode" in argv:
        print(default_mode)
        return

    list_only = "-l" in argv or "--list" in argv
    argv = [a for a in argv if a not in ("-l", "--list")]

    mode, argv, explicit = resolve_mode(argv)

    # ccs 自身参数: ccs [-a app] [配置名] [-- claude参数...]
    if "--" in argv:
        sep = argv.index("--")
        extra = argv[sep + 1:]
        argv = argv[:sep]
    else:
        extra = []

    app_type = "claude"
    if "-a" in argv or "--app" in argv:
        flag = "-a" if "-a" in argv else "--app"
        i = argv.index(flag)
        try:
            app_type = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]
        except IndexError:
            sys.exit(f"{flag} 需要一个参数，如 ccs -a claude")

    providers = load_providers(app_type)
    if not providers:
        sys.exit(f"cc-switch 中没有 app_type='{app_type}' 的配置")

    if list_only:
        for p in providers:
            print(f"{'*' if p['current'] else ' '} {p['name']}")
        return

    target = argv[0] if argv else None
    provider = None
    if target:
        hits = [p for p in providers if target.lower() == p["name"].lower()]
        if not hits:
            hits = [p for p in providers if target.lower() in p["name"].lower()]
        if len(hits) == 1:
            provider = hits[0]
        elif not hits:
            sys.exit(f"未找到匹配 '{target}' 的配置。用 ccs --list 查看所有配置。")
        else:
            print(f"多个配置匹配 '{target}'，请选择:")
            # 注意：选择器只调用一次！原先写在生成器条件里，next() 每跳过一个
            # 不匹配的配置就会重新弹出一次菜单（选择项排第 N 位就弹 N 次）。
            picked = pick_interactive_safe(hits)
            provider = next((p for p in providers if p["name"] == picked), None)
    else:
        name = pick_interactive_safe(providers)
        provider = next((p for p in providers if p["name"] == name), None)

    if provider is None:
        print("已取消。")
        return

    # 模式: 显式指定 > 默认配置；claude 之外的 app 不注入模式参数
    if explicit:
        chosen = mode
    else:
        chosen = default_mode if default_mode in PERMISSION_MODES else "default"
    mode_args = PERMISSION_MODES.get(chosen, []) if app_type == "claude" else []

    launch(provider, extra, app_type, mode_args)


if __name__ == "__main__":
    main()
