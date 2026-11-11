#!/usr/bin/env bash
# ccs 安装脚本 (Linux/macOS)
#
# 方式一（推荐，无需克隆仓库）:
#   curl -fsSL https://raw.githubusercontent.com/everdom/cc-selector/main/install.sh | bash
#
# 方式二（已克隆仓库）:
#   ./install.sh
#
# 安装后可用 ccs --update 自我更新。
set -e

REPO_RAW="https://raw.githubusercontent.com/everdom/cc-selector/main"
REPO_PATH="everdom/cc-selector"
INSTALL_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/ccs"

# 检测安装来源: 管道安装（curl | bash 等）时脚本经 stdin 传入，
# $0 是 "bash"、BASH_SOURCE 未指向真实文件，此时必须从 GitHub 下载。
PIPE_INSTALL=0
case "${BASH_SOURCE[0]:-$0}" in
    "bash"|"/dev/stdin"|"-"|*"/dev/stdin")
        PIPE_INSTALL=1
        SCRIPT_DIR=""
        ;;
    *)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
        ;;
esac

# 从 GitHub 取单个文件。
#
# raw.githubusercontent.com 走 CDN 缓存（cache-control: max-age=300），刚 push
# 的内容最多 5 分钟才对所有人可见，而且不同边缘节点状态不一致: 有的返回
# 404，有的返回旧版。所以优先用 contents API（直接读仓库，不吃 raw 的
# 缓存），raw 只作兜底。API 匿名调用有 60 次/小时限制，超了正好回退 raw。
download_from_github() {
    local name="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL -H "Accept: application/vnd.github.raw" \
            "https://api.github.com/repos/$REPO_PATH/contents/$name?ref=main" \
            -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
        if curl -fsSL "$REPO_RAW/$name" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -qO "$dest" \
            --header="Accept: application/vnd.github.raw" \
            "https://api.github.com/repos/$REPO_PATH/contents/$name?ref=main" 2>/dev/null \
            && [ -s "$dest" ]; then
            return 0
        fi
        if wget -qO "$dest" "$REPO_RAW/$name" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
    else
        echo "[ccs] 错误: 需要 curl 或 wget" >&2
    fi
    return 1
}

# 取得 repo 内文件的路径；repo 不可用时从 GitHub 下载。
# 结果放在 FETCH_PATH，FETCH_TEMP 标明它是不是需要清理的临时文件。
# 不用 $(...) 取值是因为在子 shell 里设置的变量传不回来。
# 注意: 提示信息必须走 stderr，否则会被命令替换捕获污染返回的路径。
FETCH_PATH=""
FETCH_TEMP=0
fetch_file() {
    local name="$1" tmp
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
        FETCH_PATH="$SCRIPT_DIR/$name"
        FETCH_TEMP=0
        return
    fi
    tmp="$(mktemp)"
    echo "[ccs] 从 GitHub 下载 $name ..." >&2
    if ! download_from_github "$name" "$tmp"; then
        rm -f "$tmp"
        echo "[ccs] 错误: 下载 $name 失败" >&2
        exit 1
    fi
    FETCH_PATH="$tmp"
    FETCH_TEMP=1
}

if [ "$PIPE_INSTALL" = 1 ]; then
    echo "[ccs] 管道安装模式（从 GitHub 下载最新版）..."
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ccs] 错误: 未找到 python3，请先安装 Python 3.8+" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$SHARE_DIR"

# ---------------------------------------------------------------------------
# prompt_toolkit 依赖安装
#
# prompt_toolkit 提供上下键 + 模糊搜索的交互菜单；缺失时 ccs 会退化成
# "输入编号" 模式，用户看不到上下键菜单却没有任何提示。
#
# PEP 668 之后，发行版自带的系统 Python 常常既不带 pip（ensurepip 被拆成
# 独立包），又被标记为 externally-managed，直接 pip install 会被拒绝。
# 因此这里按可用性逐级回退，并且每一级都以"能否 import"为成功判据。
# ---------------------------------------------------------------------------

# 用 pip 装 prompt_toolkit。依次尝试 user site -> user site + 允许装进
# 受管环境 -> 系统 site-packages（后两级用于 externally-managed 发行版）。
install_prompt_toolkit_with_pip() {
    local py="$1"
    if try_pip_install "$py" --user prompt_toolkit; then return 0; fi
    if try_pip_install "$py" --user --break-system-packages prompt_toolkit; then return 0; fi
    if try_pip_install "$py" --break-system-packages prompt_toolkit; then return 0; fi
    return 1
}

# 执行一次 pip install，并在安装后确认 prompt_toolkit 真的能 import。
try_pip_install() {
    local py="$1"; shift
    "$py" -m pip install "$@" >/dev/null 2>&1 || return 1
    "$py" -c "import prompt_toolkit" >/dev/null 2>&1
}

# 系统没有 pip 时，用官方 get-pip.py 引导一个用户级 pip。
bootstrap_pip() {
    local py="$1" tmp rc
    tmp="$(mktemp)" || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$tmp" || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" https://bootstrap.pypa.io/get-pip.py || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"; return 1
    fi
    "$py" "$tmp" --user --break-system-packages >/dev/null 2>&1
    rc=$?
    rm -f "$tmp"
    return $rc
}

# 最后的兜底: 直接下载纯 Python wheel 解压到 user site，完全绕开 pip。
install_prompt_toolkit_from_wheel() {
    local py="$1"
    "$py" - <<'PYEOF' >/dev/null 2>&1
import io, json, os, sys, urllib.request, zipfile
import site, sysconfig

# venv (or PYTHONNOUSERSITE / python -s) hides the user site directory, so
# unpack into the interpreter's own site-packages there instead. Otherwise the
# package lands somewhere the interpreter cannot see and the install looks
# like it failed while leaving a stray copy behind.
if site.ENABLE_USER_SITE:
    dest = site.getusersitepackages()
else:
    dest = sysconfig.get_paths()["purelib"]
os.makedirs(dest, exist_ok=True)

def pure_python_wheel(name):
    with urllib.request.urlopen("https://pypi.org/pypi/%s/json" % name, timeout=30) as r:
        data = json.load(r)
    for f in data["urls"]:
        if f["filename"].endswith("py3-none-any.whl"):
            return f["url"]
    return None

def requirements(blob):
    """Package names listed in the wheel's Requires-Dist metadata."""
    names = []
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        for info in z.infolist():
            if not info.filename.endswith(".dist-info/METADATA"):
                continue
            text = z.read(info).decode("utf-8", "replace")
            for line in text.splitlines():
                if not line.startswith("Requires-Dist:"):
                    continue
                spec = line.split(":", 1)[1].strip().split(";")[0].strip()
                name = spec.split("[")[0]
                for sep in ("==", ">=", "<=", "~=", "!=", ">", "<"):
                    name = name.split(sep)[0]
                name = name.strip()
                if name:
                    names.append(name)
            break
    return names

def unpack(name, seen):
    # Dependencies have to come along. prompt_toolkit imports wcwidth
    # unguarded, so a lone prompt_toolkit wheel can never be imported, and
    # unpacking it alone leaves a broken package behind.
    if name.lower() in seen:
        return
    seen.add(name.lower())
    url = pure_python_wheel(name)
    if url is None:
        return
    with urllib.request.urlopen(url, timeout=60) as r:
        blob = r.read()
    for dep in requirements(blob):
        unpack(dep, seen)
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        z.extractall(dest)

unpack("prompt_toolkit", set())
PYEOF
    "$py" -c "import prompt_toolkit" >/dev/null 2>&1
}

# 自救命令里该带哪些 pip 选项:
#   - venv 里 pip 不允许 --user（"User site-packages are not visible in this
#     virtualenv"），只能装进 venv 自己
#   - 受管环境 (PEP 668) 会拒绝 --user 安装，得加 --break-system-packages
# 两种情况都可能撞上，所以按解释器实际情况给。
pip_hint_flags() {
    local py="$1"
    if "$py" -c 'import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)' >/dev/null 2>&1; then
        echo "--break-system-packages"
    else
        echo "--user --break-system-packages"
    fi
}

# 安装 prompt_toolkit 并输出运行 ccs.py 的解释器。
# 成功时 stdout 只有解释器路径；所有提示信息走 stderr，
# 避免污染 $(...) 捕获到的路径。
ensure_prompt_toolkit() {
    local py="$1"

    if "$py" -c "import prompt_toolkit" >/dev/null 2>&1; then
        echo "$py"
        return 0
    fi

    echo "[ccs] 安装 prompt_toolkit ..." >&2

    # 1) 已有 pip
    if "$py" -m pip --version >/dev/null 2>&1; then
        if install_prompt_toolkit_with_pip "$py"; then
            echo "$py"; return 0
        fi
    fi

    # 2) 没有 pip: 用 get-pip.py 引导一个用户级 pip 后重试
    if bootstrap_pip "$py"; then
        if install_prompt_toolkit_with_pip "$py"; then
            echo "$py"; return 0
        fi
    fi

    # 3) uv（自带包管理能力，且不需要 pip）
    if command -v uv >/dev/null 2>&1; then
        if uv pip install --python "$py" --break-system-packages prompt_toolkit >/dev/null 2>&1; then
            if "$py" -c "import prompt_toolkit" >/dev/null 2>&1; then
                echo "$py"; return 0
            fi
        fi
    fi

    # 4) 最后的兜底: 直接解压 wheel 到 user site
    if install_prompt_toolkit_from_wheel "$py"; then
        echo "$py"; return 0
    fi

    echo "[ccs] 警告: prompt_toolkit 安装失败，交互界面将降级为编号输入模式（没有上下键菜单）。" >&2
    echo "[ccs]       手动安装: $py -m pip install $(pip_hint_flags "$py") prompt_toolkit" >&2
    echo "$py"
    return 1
}

fetch_file ccs.py
cp "$FETCH_PATH" "$SHARE_DIR/ccs.py"
# 只清理下载出来的临时文件。用本地克隆安装时，FETCH_PATH 指向仓库里的
# 源文件，删掉它就等于把用户 clone 下来的 ccs.py 删了。
if [ "$FETCH_TEMP" = 1 ]; then
    rm -f "$FETCH_PATH"
fi

# 安装依赖并确定用于运行 ccs.py 的解释器。
#
# 用绝对路径钉死: 装依赖时用的是安装那一刻 PATH 里的 python3，而 wrapper
# 若在运行时按 PATH 重新解析，用户中途换了解释器就会静默降级成编号输入
# —— 正是这次要修的问题。install.ps1 把解释器写死进 ccs.cmd 也是同一理由。
#
# command -v 在 PATH 含相对目录时返回相对路径，而 wrapper 里的相对路径按
# 运行时的 cwd 解析，用户换个目录 ccs 就崩了，所以先规范化成绝对路径。
PY_RAW="$(command -v python3)"
CCS_PY="$(cd "$(dirname "$PY_RAW")" && pwd)/$(basename "$PY_RAW")"
CCS_PY="$(ensure_prompt_toolkit "$CCS_PY")" || true

# 入口脚本指向共享安装位置
cat > "$INSTALL_DIR/ccs" <<EOF
#!/usr/bin/env bash
exec "$CCS_PY" "$SHARE_DIR/ccs.py" "\$@"
EOF
chmod +x "$INSTALL_DIR/ccs"

# 确保 ~/.local/bin 持久化在 PATH 中（即使当前 shell 已临时启用，也写入 rc 防重启丢失）
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && ! grep -qs '\.local/bin' "$rc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        echo "[ccs] 已将 $INSTALL_DIR 加入 PATH ($rc)"
    fi
done

echo ""
echo "[ccs] 安装完成！重新打开终端或 source ~/.bashrc 后即可使用:"
echo "    ccs              # 交互式选择配置"
echo "    ccs --list       # 列出所有配置"
echo "    ccs --update     # 更新到 GitHub 最新版"
echo "    ccs 名称 -- 参数 # 指定配置并把参数传给 claude"
