# ccs installer (Windows)
#
# Install (recommended, no clone required):
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/everdom/cc-selector/main/install.ps1 | iex"
#
# Install from a clone:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Keep this file ASCII-only and free of a UTF-8 BOM:
#   - "irm | iex" pipes the raw bytes into the parser. A UTF-8 BOM arrives
#     as U+FEFF, and PowerShell 5.1 then tries to run the first line as a
#     command ("The term 'Windows' is not recognized ...").
#   - "powershell -File" reads the file with the system ANSI code page, so
#     non-ASCII characters turn into mojibake.
# Keeping user-facing messages in English makes both paths behave the same.
$ErrorActionPreference = "Stop"

$RepoRaw = "https://raw.githubusercontent.com/everdom/cc-selector/main"
$RepoPath = "everdom/cc-selector"
$InstallDir = "$env:LOCALAPPDATA\Programs\ccs"

# Detect install source: with -File the script lives on disk and local files
# can be reused; with "irm | iex" $MyInvocation.MyCommand.Path is empty.
$ScriptFile = try { $MyInvocation.MyCommand.Path } catch { $null }
$ProjectDir = if ($ScriptFile) { Split-Path -Parent $ScriptFile } else { $null }

function Invoke-Exe([string]$Exe, [string[]]$ExeArgv) {
    # Run an external program and return its exit code.
    #
    # Two traps this avoids:
    #   - PowerShell 5.1 turns a native command's stderr into a terminating
    #     error (NativeCommandError) when $ErrorActionPreference is Stop, so
    #     the preference is relaxed for the duration of the call.
    #   - cmd /c is not used as a relay: cmd cannot use a UNC path as its
    #     current directory, so every call fails on network paths, and its
    #     quoting rules break on paths containing spaces.
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

# Locate a usable python.
# Prefer the one on PATH; fall back to the "py" launcher with "-3".
# A Microsoft Store alias stub resolves as a command but cannot run, so the
# interpreter is actually executed before it is accepted.
$PyExe = $null
$PyPrefix = @()
try {
    $candidate = (Get-Command python -ErrorAction Stop).Source
    if ((Invoke-Exe $candidate @('--version')) -eq 0) {
        $PyExe = $candidate
    }
} catch {
}
if (-not $PyExe) {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        if ((Invoke-Exe "py" @('-3', '--version')) -eq 0) {
            $PyExe = "py"
            $PyPrefix = @("-3")
        }
    }
}
if (-not $PyExe) {
    Write-Host "[ccs] ERROR: no usable python found. Install Python 3.8+ from https://www.python.org/downloads/" -ForegroundColor Red
    exit 1
}

# Fetch a single file from the repository.
# $FetchIsTemp tells the caller whether the path is a throwaway download
# (delete it) or a file inside the local clone (never delete that).
$FetchIsTemp = $false
function Get-SourceFile([string]$Name) {
    if ($ProjectDir -and (Test-Path (Join-Path $ProjectDir $Name))) {
        $script:FetchIsTemp = $false
        return (Join-Path $ProjectDir $Name)
    }
    $tmp = Join-Path $env:TEMP "$Name.$PID.tmp"
    Write-Host "[ccs] Downloading $Name from GitHub ..."
    # Prefer the contents API: raw.githubusercontent.com is served from a CDN
    # with cache-control: max-age=300, so freshly pushed content is not
    # visible everywhere for up to 5 minutes and some edge nodes 404. The API
    # reads the repository directly.
    try {
        Invoke-WebRequest -Uri "https://api.github.com/repos/$RepoPath/contents/$Name?ref=main" `
            -Headers @{ Accept = "application/vnd.github.raw" } `
            -OutFile $tmp -UseBasicParsing
    } catch {
        # The API allows 60 anonymous requests per hour; fall back to raw.
        try {
            Invoke-WebRequest -Uri "$RepoRaw/$Name" -OutFile $tmp -UseBasicParsing
        } catch {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Write-Host "[ccs] ERROR: failed to download $Name : $_" -ForegroundColor Red
            exit 1
        }
    }
    $script:FetchIsTemp = $true
    return $tmp
}

Write-Host "[ccs] Installing to $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$pySrc = Get-SourceFile "ccs.py"
Copy-Item $pySrc "$InstallDir\ccs.py" -Force
if ($FetchIsTemp) { Remove-Item $pySrc -Force }

$cmdSrc = Get-SourceFile "ccs.cmd"
Copy-Item $cmdSrc "$InstallDir\ccs.cmd" -Force
if ($FetchIsTemp) { Remove-Item $cmdSrc -Force }

# Pin the interpreter in ccs.cmd to the one used here.
# With several Pythons installed, a change in PATH order would otherwise
# leave "the python that installed prompt_toolkit" and "the python that runs
# ccs" as two different interpreters, and the dependency would be wasted.
if ($PyExe -ne "py" -and (Test-Path $PyExe)) {
    $cmdText = Get-Content "$InstallDir\ccs.cmd" -Raw
    $cmdText = $cmdText -replace '(?m)^python\s', "`"$PyExe`" "
    Set-Content "$InstallDir\ccs.cmd" -Value $cmdText -Encoding ASCII -NoNewline
}

# ---------------------------------------------------------------------------
# prompt_toolkit dependency
#
# prompt_toolkit provides the arrow-key + fuzzy-search picker. Without it ccs
# falls back to "type a number", and the user gets no menu and no hint.
# ---------------------------------------------------------------------------

if (Test-PyImport "prompt_toolkit") {
    Write-Host "[ccs] prompt_toolkit is ready"
} else {
    Write-Host "[ccs] Installing prompt_toolkit ..."

    $installed = $false

    # 1) standard pip install
    if ((Invoke-Py @('-m', 'pip', 'install', 'prompt_toolkit')) -eq 0 -and (Test-PyImport "prompt_toolkit")) {
        $installed = $true
    }

    # 2) user site variant (some environments refuse to write to the system
    #    directory by default)
    if (-not $installed) {
        if ((Invoke-Py @('-m', 'pip', 'install', '--user', 'prompt_toolkit')) -eq 0 -and (Test-PyImport "prompt_toolkit")) {
            $installed = $true
        }
    }

    # 3) uv fallback (bundles its own package management, no pip needed)
    if (-not $installed) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            if ((Invoke-Exe "uv" @('pip', 'install', '--python', $PyExe, '--break-system-packages', 'prompt_toolkit')) -eq 0) {
                if (Test-PyImport "prompt_toolkit") { $installed = $true }
            }
        }
    }

    # 4) last resort: download the pure-python wheel and unpack it into the
    #    site-packages directory, bypassing pip entirely
    if (-not $installed) {
        $wheelCode = @'
import io, json, os, sys, urllib.request, zipfile
import site, sysconfig
# A venv (or PYTHONNOUSERSITE / python -s) hides the user site directory, so
# unpack into the interpreter's own site-packages there instead.
if site.ENABLE_USER_SITE:
    dest = site.getusersitepackages()
else:
    dest = sysconfig.get_paths()["purelib"]
os.makedirs(dest, exist_ok=True)
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
    z.extractall(dest)
'@
        $tmpPy = Join-Path $env:TEMP "ccs_wheel_$PID.py"
        Set-Content $tmpPy -Value $wheelCode -Encoding ASCII
        Invoke-Exe $PyExe (@($PyPrefix) + @($tmpPy)) | Out-Null
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        if (Test-PyImport "prompt_toolkit") { $installed = $true }
    }

    if (-not $installed) {
        Write-Host "[ccs] WARNING: prompt_toolkit could not be installed. The picker falls back to numbered input (no arrow-key menu)." -ForegroundColor Yellow
        Write-Host "[ccs]          install it manually with: $PyExe $PyPrefix -m pip install --user prompt_toolkit" -ForegroundColor Yellow
    }
}

# Add to the user PATH (skip if already there)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable(
        "Path", "$userPath;$InstallDir", "User")
    Write-Host "[ccs] Added $InstallDir to the user PATH"
}

Write-Host ""
Write-Host "[ccs] Installed. Reopen your terminal, then:" -ForegroundColor Green
Write-Host "    ccs              # pick a provider interactively"
Write-Host "    ccs --list       # list all providers"
Write-Host "    ccs --update     # update to the latest version on GitHub"
Write-Host "    ccs <name> --args  # use a provider and pass args to claude"
