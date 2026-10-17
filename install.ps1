# ccs 安装脚本 (Windows)
# 用法: 以普通用户运行  powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = "Stop"

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = "$env:LOCALAPPDATA\Programs\ccs"

Write-Host "[ccs] 安装到 $InstallDir ..."

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item "$ProjectDir\ccs.py"  "$InstallDir\ccs.py"  -Force
Copy-Item "$ProjectDir\ccs.cmd" "$InstallDir\ccs.cmd" -Force

# 确保 prompt_toolkit 可用（缺失时交互界面降级，但建议安装）
python -m pip show prompt_toolkit *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ccs] 安装 prompt_toolkit ..."
    python -m pip install prompt_toolkit
}

# 检查 python 是否可用
try { python --version *>$null } catch {
    Write-Host "[ccs] 错误: 未找到 python，请先安装 Python 3.8+" -ForegroundColor Red
    exit 1
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
Write-Host "    ccs 名称 -- 参数 # 指定配置并把参数传给 claude"
