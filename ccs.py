#!/usr/bin/env python3
"""ccs - 用 cc-switch 中的指定配置启动 Claude Code.

从 cc-switch 数据库 (~/.cc-switch/cc-switch.db) 读取供应商配置，
交互式选择后以 `claude --settings <临时文件>` 启动，
不修改全局 ~/.claude/settings.json，因此不同配置可同时并行运行。

用法:
  ccs                     # 交互式选择（模糊搜索 + 上下键）
  ccs <名称> [参数...]    # 用名称匹配的配置启动，其余参数传给 claude
  ccs --                  # 之后的参数全部传给 claude
  ccs --list              # 仅列出所有配置
  ccs -a codex            # 指定 app 类型 (claude/codex/gemini/opencode)

示例:
  ccs deepseek -- --dangerously-skip-permissions
  ccs -- --resume --continue

跨平台: Windows 用 ccs.cmd，Linux/macOS 把 ccs.sh 加入 PATH。
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

CC_SWITCH_DB = Path.home() / ".cc-switch" / "cc-switch.db"
APP_TYPE = "claude"


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

    from prompt_toolkit.layout.containers import VSplit

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

    from prompt_toolkit.styles import Style

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


def launch(provider, extra_args, app_type):
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

    base = find_executable(LAUNCH_COMMANDS.get(app_type, ["claude"])[0])
    if not base:
        sys.exit(f"找不到可执行文件 '{LAUNCH_COMMANDS.get(app_type, ['claude'])[0]}'")

    cmd = [base, "--settings", str(tmp_path)] + extra_args
    print(f"[ccs] 使用配置: {provider['name']}")
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

    list_only = "--list" in argv
    args = [a for a in argv if a != "--list"]

    # ccs 自身参数: ccs [-a app] [配置名] [claude 参数...]
    # 用 -- 显式分隔 claude 参数: ccs 配置名 -- --dangerously-skip-permissions
    if "--" in args:
        sep = args.index("--")
        extra = args[sep + 1:]
        args = args[:sep]
    else:
        extra = []

    app_type = "claude"
    if "-a" in args or "--app" in args:
        flag = "-a" if "-a" in args else "--app"
        i = args.index(flag)
        try:
            app_type = args[i + 1]
            args = args[:i] + args[i + 2:]
        except IndexError:
            sys.exit(f"{flag} 需要一个参数，如 ccs -a claude")

    providers = load_providers(app_type)
    if not providers:
        sys.exit(f"cc-switch 中没有 app_type='{app_type}' 的配置")

    if list_only:
        for p in providers:
            print(f"{'*' if p['current'] else ' '} {p['name']}")
        return

    target = args[0] if args else None
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

    launch(provider, extra, app_type)


if __name__ == "__main__":
    main()
