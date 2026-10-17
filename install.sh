#!/usr/bin/env bash
# ccs 安装脚本 (Linux/macOS)
#
# 方式一（推荐，无需克隆仓库）:
#   curl -fsSL https://raw.githubusercontent.com/everdom/ccs/main/install.sh | bash
#
# 方式二（已克隆仓库）:
#   ./install.sh
set -e

REPO_RAW="https://raw.githubusercontent.com/everdom/ccs/main"
INSTALL_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/ccs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

# 获取 ccs.py / ccs.sh 的来源目录；管道安装时自动从 GitHub 下载
fetch_file() {
    local name="$1"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
        echo "$SCRIPT_DIR/$name"
    else
        local tmp
        tmp="$(mktemp)"
        echo "[ccs] 从 GitHub 下载 $name ..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$REPO_RAW/$name" -o "$tmp" || { rm -f "$tmp"; exit 1; }
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$tmp" "$REPO_RAW/$name" || { rm -f "$tmp"; exit 1; }
        else
            echo "[ccs] 错误: 需要 curl 或 wget" >&2
            exit 1
        fi
        echo "$tmp"
    fi
}

echo "[ccs] 安装到 $INSTALL_DIR ..."

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ccs] 错误: 未找到 python3，请先安装 Python 3.8+" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$SHARE_DIR"

PY_SRC="$(fetch_file ccs.py)"
cp "$PY_SRC" "$SHARE_DIR/ccs.py"

# 入口脚本指向共享安装位置
cat > "$INSTALL_DIR/ccs" <<EOF
#!/usr/bin/env bash
exec python3 "$SHARE_DIR/ccs.py" "\$@"
EOF
chmod +x "$INSTALL_DIR/ccs"

# 确保 prompt_toolkit 可用（缺失时交互界面降级，但建议安装）
if ! python3 -c "import prompt_toolkit" >/dev/null 2>&1; then
    echo "[ccs] 安装 prompt_toolkit ..."
    python3 -m pip install --user prompt_toolkit 2>/dev/null \
        || python3 -m pip install --break-system-packages --user prompt_toolkit \
        || echo "[ccs] 提示: prompt_toolkit 安装失败，交互界面将使用降级模式"
fi

# 确保 ~/.local/bin 在 PATH 中
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [ -f "$rc" ] && ! grep -q '.local/bin' "$rc"; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
                echo "[ccs] 已将 $INSTALL_DIR 加入 PATH ($rc)"
            fi
        done
        ;;
esac

echo ""
echo "[ccs] 安装完成！重新打开终端或 source ~/.bashrc 后即可使用:"
echo "    ccs              # 交互式选择配置"
echo "    ccs --list       # 列出所有配置"
echo "    ccs 名称 -- 参数 # 指定配置并把参数传给 claude"
