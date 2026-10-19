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
    # 返回 repo 内文件的本地路径；本地不可用时从 GitHub 下载临时文件
    if ($ProjectDir -and (Test-Path (Join-Path $ProjectDir $Name))) {
        return Join-Path $ProjectDir $Name
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

if (-not $ProjectDir) {
    Write-Host "[ccs] 管道安装模式（从 GitHub 下载最新版）..."
}

# 检查 python 是否可用
try { python --version *>$null } catch {
    Write-Host "[ccs] 错误: 未找到 python，请先安装 Python 3.8+ (https://www.python.org/downloads/)" -ForegroundColor Red
    exit 1
}

Write-Host "[ccs] 安装到 $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$pySrc = Get-SourceFile "ccs.py"
Copy-Item $pySrc "$InstallDir\ccs.py" -Force
if ($pySrc -like "$env:TEMP*") { Remove-Item $pySrc -Force }

$cmdSrc = Get-SourceFile "ccs.cmd"
Copy-Item $cmdSrc "$InstallDir\ccs.cmd" -Force
if ($cmdSrc -like "$env:TEMP*") { Remove-Item $cmdSrc -Force }

# 确保 prompt_toolkit 可用（缺失时交互界面降级，但建议安装）。
# 注意: pip show 查不到包时会向 stderr 输出 WARNING 并返回非零，
# 在 $ErrorActionPreference = "Stop" 下会变成终止错误，故这里临时放宽。
$ErrorActionPreference = "Continue"
python -m pip show prompt_toolkit *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ccs] 安装 prompt_toolkit ..."
    python -m pip install prompt_toolkit
}
$ErrorActionPreference = "Stop"

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
