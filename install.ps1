# ccs 安装脚本 (Windows)
#
# 方式一（推荐，无需克隆仓库，远程一键安装）:
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/everdom/cc-selector/main/install.ps1 | iex"
#
# 方式二（已克隆仓库）:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# 安装后可用 ccs --update 自我更新。
$ErrorActionPreference = "Stop"

$RepoRaw = "https://raw.githubusercontent.com/everdom/cc-selector/main"
$InstallDir = "$env:LOCALAPPDATA\Programs\ccs"

# 检测安装来源: -File 运行时脚本在磁盘上，可直接复制本地文件；
# 通过 irm | iex 管道安装时 $MyInvocation.MyCommand.Path 为空，需从 GitHub 下载。
$ScriptFile = try { $MyInvocation.MyCommand.Path } catch { $null }
$ProjectDir = if ($ScriptFile) { Split-Path -Parent $ScriptFile } else { $null }

function Get-SourceFile([string]$Name) {
    # 仓库里有同名文件就直接用（本地克隆安装），否则从 GitHub 下载临时文件。
    if ($ProjectDir -and (Test-Path (Join-Path $ProjectDir $Name))) {
        return (Join-Path $ProjectDir $Name)
    }
    $tmp = Join-Path $env:TEMP "$Name.$PID.tmp"
    Write-Host "[ccs] 从 GitHub 下载 $Name ..."
    try {
        Invoke-WebRequest -Uri "$RepoRaw/$Name" -OutFile $tmp -UseBasicParsing
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "[ccs] 错误: 下载 $Name 失败: $_" -ForegroundColor Red
        exit 1
    }
    return $tmp
}

# 检查 python 是否可用。
# 优先用 PATH 里的 python；若没有但有 py 启动器，则退回 py -3。
$PyExe = $null
$PyPrefix = @()
try {
    $cmd = Get-Command python -ErrorAction Stop
    $PyExe = $cmd.Source
} catch {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $PyExe = "py"
        $PyPrefix = @("-3")
    }
}
if (-not $PyExe) {
    Write-Host "[ccs] 错误: 未找到 python，请先安装 Python 3.8+ (https://www.python.org/downloads/)" -ForegroundColor Red
    exit 1
}

# 执行外部程序并返回退出码。
#
# 两个坑:
#   - PowerShell 5.1 下 native 命令的 stderr 会被当成终止错误
#     (NativeCommandError)，$ErrorActionPreference="Stop" 时直接中断脚本，
#     所以这里临时放宽成 Continue。
#   - 不走 cmd /c 转发: cmd 不支持 UNC 路径作为当前目录，在网络路径下
#     调用会整条失败，而且 cmd 的引号规则在路径含空格时很容易出错。
function Invoke-Exe([string]$Exe, [string[]]$ExeArgv) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @ExeArgv 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-Py([string[]]$PyArgv) {
    return Invoke-Exe $PyExe (@($PyPrefix) + @($PyArgv))
}

function Test-PyImport([string]$Module) {
    return (Invoke-Py @('-c', "import $Module")) -eq 0
}

Write-Host "[ccs] 安装到 $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$pySrc = Get-SourceFile "ccs.py"
Copy-Item $pySrc "$InstallDir\ccs.py" -Force
if ($pySrc -like "$env:TEMP*") { Remove-Item $pySrc -Force }

$cmdSrc = Get-SourceFile "ccs.cmd"
Copy-Item $cmdSrc "$InstallDir\ccs.cmd" -Force
if ($cmdSrc -like "$env:TEMP*") { Remove-Item $cmdSrc -Force }

# 把 ccs.cmd 里的解释器固定为本次实际使用的那个。
# 机器上装了多个 Python 时，PATH 顺序一变就会导致"装依赖的 python"和
# "跑 ccs 的 python"不是同一个，装好的 prompt_toolkit 就白装了。
if ($PyExe -ne "py" -and (Test-Path $PyExe)) {
    $cmdText = Get-Content "$InstallDir\ccs.cmd" -Raw
    $cmdText = $cmdText -replace '(?m)^python\s', "`"$PyExe`" "
    Set-Content "$InstallDir\ccs.cmd" -Value $cmdText -Encoding ASCII -NoNewline
}

# ---------------------------------------------------------------------------
# prompt_toolkit 依赖安装
#
# prompt_toolkit 提供上下键 + 模糊搜索的交互菜单；缺失时 ccs 会退化成
# "输入编号" 模式，用户看不到上下键菜单却没有任何提示。
# ---------------------------------------------------------------------------

if (Test-PyImport "prompt_toolkit") {
    Write-Host "[ccs] prompt_toolkit 已就绪"
} else {
    Write-Host "[ccs] 安装 prompt_toolkit ..."

    $installed = $false

    # 1) 标准 pip 安装
    if ((Invoke-Py @('-m', 'pip', 'install', 'prompt_toolkit')) -eq 0 -and (Test-PyImport "prompt_toolkit")) {
        $installed = $true
    }

    # 2) user site 变体（个别环境默认写系统目录会失败）
    if (-not $installed) {
        if ((Invoke-Py @('-m', 'pip', 'install', '--user', 'prompt_toolkit')) -eq 0 -and (Test-PyImport "prompt_toolkit")) {
            $installed = $true
        }
    }

    # 3) uv 兜底（自带包管理能力，不需要 pip）
    if (-not $installed) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            if ((Invoke-Exe "uv" @('pip', 'install', '--python', $PyExe, '--break-system-packages', 'prompt_toolkit')) -eq 0) {
                if (Test-PyImport "prompt_toolkit") { $installed = $true }
            }
        }
    }

    # 4) 最后的兜底: 直接下载纯 Python wheel 解压到 user site，绕开 pip
    if (-not $installed) {
        $wheelCode = @'
import io, json, sys, urllib.request, zipfile
site = sys.argv[1]
with urllib.request.urlopen("https://pypi.org/pypi/prompt_toolkit/json", timeout=30) as r:
    data = json.load(r)
wheel = None
for f in data["urls"]:
    if f["filename"].endswith("py3-none-any.whl"):
        wheel = f["url"]
        break
if wheel is None:
    sys.exit(1)
with urllib.request.urlopen(wheel, timeout=60) as r:
    blob = r.read()
with zipfile.ZipFile(io.BytesIO(blob)) as z:
    z.extractall(site)
'@
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $site = (& $PyExe @($PyPrefix) @('-c', 'import site; print(site.getusersitepackages())') 2>$null | Select-Object -First 1)
        $ErrorActionPreference = $prev
        if ($site) {
            $tmpPy = Join-Path $env:TEMP "ccs_wheel_$PID.py"
            Set-Content $tmpPy -Value $wheelCode -Encoding ASCII
            Invoke-Exe $PyExe (@($PyPrefix) + @($tmpPy, "$site")) | Out-Null
            Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
            if (Test-PyImport "prompt_toolkit") { $installed = $true }
        }
    }

    if (-not $installed) {
        Write-Host "[ccs] 警告: prompt_toolkit 安装失败，交互界面将降级为编号输入模式（没有上下键菜单）。" -ForegroundColor Yellow
        Write-Host "[ccs]       手动安装: $PyExe $PyPrefix -m pip install prompt_toolkit" -ForegroundColor Yellow
    }
}

# 加入用户 PATH（已存在则跳过）
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable(
        "Path", "$userPath;$InstallDir", "User")
    Write-Host "[ccs] 已将 $InstallDir 加入用户 PATH"
}

Write-Host ""
Write-Host "[ccs] 安装完成！重新打开终端后即可使用:" -ForegroundColor Green
Write-Host "    ccs              # 交互式选择配置"
Write-Host "    ccs --list       # 列出所有配置"
Write-Host "    ccs --update     # 更新到 GitHub 最新版"
Write-Host "    ccs 名称 -- 参数 # 指定配置并把参数传给 claude"
