#!/usr/bin/env bash
# ccs - 用 cc-switch 中的指定配置启动 Claude Code (Linux/macOS 入口)
# Windows 请使用同目录下的 ccs.cmd
exec python3 "$(dirname "$(readlink -f "$0")")/ccs.py" "$@"
