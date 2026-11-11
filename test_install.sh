#!/usr/bin/env bash
# install.sh 的回归测试。
#
# 用隔离的 HOME 和 PATH 桩覆盖四条路径:
#   1. 依赖已就绪          -> 不应重复安装
#   2. 缺 prompt_toolkit 但有 pip -> 应能自动装上
#   3. 完全装不上          -> 必须明确警告，而不是静默降级
#   4. 本地克隆安装        -> 不得删除仓库里的源文件
#
# 用法: ./test_install.sh
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
SKIP=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP+1)); }

# 造一个没有任何配置的隔离 HOME
make_home() {
    local h="$WORK/$1"
    rm -rf "$h"; mkdir -p "$h"
    echo "$h"
}

# 造一个"有 python 但没有 prompt_toolkit / 没有 pip / 没有 venv"的桩。
#
# 同时把 curl / wget / uv 也桩掉: 否则 bootstrap_pip 会真的去连
# bootstrap.pypa.io，测试既依赖网络，又没有真的测到它以为测的东西。
make_stub_bin() {
    local dir="$WORK/$1/bin"
    mkdir -p "$dir"
    cat > "$dir/python3" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *prompt_toolkit*) exit 1;;
esac
case "$1" in
    -m)
        case "$2" in
            pip|venv) exit 1;;
        esac
        ;;
    -c) exit 0;;
    *) exit 1;;   # 执行脚本文件（get-pip.py 等）一律失败
esac
exit 0
STUB
    for tool in curl wget uv; do
        printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/$tool"
    done
    chmod +x "$dir/python3" "$dir/curl" "$dir/wget" "$dir/uv"
    echo "$dir"
}

# 造一个干净的、不含 prompt_toolkit 的 python3 环境（有 pip）。
#
# 直接返回 venv 的 bin 目录而不是做软链: 软链会让 Python 把 prefix 解析回
# 系统 python，venv 的 site-packages 就整个丢了。
# uv venv 默认不装 pip，必须 --seed，否则测到的是 uv 分支而不是 pip 分支。
make_bare_python() {
    local venv="$WORK/$1/venv"
    if command -v uv >/dev/null 2>&1; then
        uv venv --seed "$venv" >/dev/null 2>&1 || return 1
    elif python3 -m venv "$venv" >/dev/null 2>&1; then
        :
    else
        return 1
    fi
    echo "$venv/bin"
}

# 造一个已经装好 prompt_toolkit 的 python3 环境。
# 用独立 venv 而不是系统 python: 系统 python 的 user site 跟着 HOME 走，
# 隔离 HOME 后它就"看不见"已装的包了。
make_ready_python() {
    local venv="$WORK/$1/venv"
    if command -v uv >/dev/null 2>&1; then
        uv venv "$venv" >/dev/null 2>&1 || return 1
        uv pip install --python "$venv/bin/python" prompt_toolkit >/dev/null 2>&1 || return 1
    else
        python3 -m venv "$venv" >/dev/null 2>&1 || return 1
        "$venv/bin/python" -m pip install prompt_toolkit >/dev/null 2>&1 || return 1
    fi
    echo "$venv/bin"
}

# 在隔离环境里跑一次 install.sh，输出存到 $WORK/<name>.log。
#
# 在仓库副本里跑，而不是直接跑 $REPO_DIR/install.sh:
# 安装脚本本来有个 bug —— 从本地克隆安装时会把仓库里的 ccs.py 删掉。
# 让测试直接跑仓库脚本，测试本身就变成了破坏源的工具。
run_install() {
    local home="$1" pathdir="$2" name="$3"
    local sandbox="$WORK/$name-repo"
    rm -rf "$sandbox"; mkdir -p "$sandbox"
    cp "$REPO_DIR/install.sh" "$REPO_DIR/ccs.py" "$sandbox/"
    env -i HOME="$home" PATH="$pathdir:$PATH" TERM=dumb \
        bash "$sandbox/install.sh" >"$WORK/$name.log" 2>&1
    local rc=$?
    if [ -f "$sandbox/ccs.py" ]; then
        echo kept > "$WORK/$name.src"
    else
        echo deleted > "$WORK/$name.src"
    fi
    echo $rc
}

echo "== 用例 1: prompt_toolkit 已就绪 =="
home="$(make_home h1)"
pathdir="$(make_ready_python r1)"
if [ -z "$pathdir" ]; then
    skip "无法创建带 prompt_toolkit 的 python 环境 (需要 uv 或 python3-venv)"
else
    status="$(run_install "$home" "$pathdir" c1)"
    if [ "$status" = 0 ]; then ok "安装脚本退出码为 0"; else bad "安装脚本退出码为 $status"; fi
    if grep -q "安装 prompt_toolkit" "$WORK/c1.log"; then
        bad "依赖已就绪却仍尝试安装"
    else
        ok "依赖已就绪时不重复安装"
    fi
    wrapper="$home/.local/bin/ccs"
    if [ -x "$wrapper" ]; then ok "wrapper 已生成且可执行"; else bad "wrapper 未生成或不可执行"; fi
    if grep -q "prompt_toolkit" "$home/.local/share/ccs/ccs.py"; then
        ok "ccs.py 已安装"
    else
        bad "ccs.py 未安装"
    fi
    if "$wrapper" --version >/dev/null 2>&1; then ok "wrapper 可正常运行"; else bad "wrapper 无法运行"; fi
    # wrapper 必须钉死解释器: 否则用户中途换掉 PATH 里的 python3，
    # 装依赖的 python 和跑 ccs 的 python 就不是同一个，会静默降级
    if grep -qE 'exec "?[^ "]+/python3?"?' "$wrapper"; then
        ok "wrapper 钉死了解释器路径"
    else
        bad "wrapper 没有钉死解释器路径"
    fi
fi

echo "== 用例 2: 缺 prompt_toolkit，但有 pip =="
home="$(make_home h2)"
pathdir="$(make_bare_python b2)"
if [ -z "$pathdir" ]; then
    skip "无法创建带 pip 的裸 python 环境 (需要 uv 或 python3-venv)"
else
    status="$(run_install "$home" "$pathdir" c2)"
    if [ "$status" = 0 ]; then ok "安装脚本退出码为 0"; else bad "安装脚本退出码为 $status"; fi
    if grep -q "安装 prompt_toolkit" "$WORK/c2.log"; then ok "检测到缺失并尝试安装"; else bad "未尝试安装缺失的依赖"; fi
    if "$pathdir/python3" -c "import prompt_toolkit" >/dev/null 2>&1; then
        ok "prompt_toolkit 已安装到该 python 环境"
    else
        bad "prompt_toolkit 未装上"
    fi
    if "$home/.local/bin/ccs" --version >/dev/null 2>&1; then ok "wrapper 可正常运行"; else bad "wrapper 无法运行"; fi
fi

echo "== 用例 3: 依赖完全装不上 =="
home="$(make_home h3)"
pathdir="$(make_stub_bin s3)"
status="$(run_install "$home" "$pathdir" c3)"
if [ "$status" = 0 ]; then ok "安装脚本不因依赖失败而中断"; else bad "安装脚本退出码为 $status"; fi
if grep -q "降级" "$WORK/c3.log"; then ok "明确提示了降级模式"; else bad "依赖失败时没有明确提示"; fi
if grep -q "手动安装" "$WORK/c3.log"; then ok "给出了手动安装命令"; else bad "没有给出手动安装命令"; fi
if [ -x "$home/.local/bin/ccs" ]; then ok "wrapper 仍然生成"; else bad "wrapper 未生成"; fi

echo "== 用例 4: 本地克隆安装不得删除源文件 =="
home="$(make_home h4)"
pathdir="$(make_ready_python r4)"
if [ -z "$pathdir" ]; then
    skip "无法创建带 prompt_toolkit 的 python 环境 (需要 uv 或 python3-venv)"
else
    status="$(run_install "$home" "$pathdir" c4)"
    if [ "$status" = 0 ]; then ok "安装脚本退出码为 0"; else bad "安装脚本退出码为 $status"; fi
    if [ "$(cat "$WORK/c4.src")" = kept ]; then
        ok "本地克隆安装后 ccs.py 仍在（源文件未被删除）"
    else
        bad "安装脚本把仓库里的 ccs.py 删掉了"
    fi
    if [ -f "$REPO_DIR/ccs.py" ]; then
        ok "仓库中的 ccs.py 未受影响"
    else
        bad "仓库中的 ccs.py 丢失"
    fi
fi

echo ""
echo "通过 $PASS 项，失败 $FAIL 项，跳过 $SKIP 项"
[ "$FAIL" = 0 ]
