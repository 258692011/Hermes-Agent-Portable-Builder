param(
    [switch]$KeepProcesses,
    [switch]$UpdatePython,
    [switch]$ShowOfficialPythonVersion
)

# Repair-Portable.ps1 — 便携环境修复（自包含，不依赖其他脚本）
#
# 修复/重建便携 Python 环境：读取官方 scripts\install.ps1 的 PythonVersion
# 选择器，按该版本重建 relocatable venv 并更新 runtime\python\current.txt。
# 已存在且健康的环境会直接通过（重复运行也不会重复重建）。
# 默认保持进程不杀（-KeepProcesses），适合在 Hermes 正在运行时手动修复；
# 传 -UpdatePython 时按官方选择器安装/切换 Python 运行时（供 Update.exe 调用）。

$ErrorActionPreference = 'Stop'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$HermesHome = Join-Path $Root 'data\hermes-home'
$Repo = Join-Path $HermesHome 'hermes-agent'
$Venv = Join-Path $Repo 'venv'
$OldVenv = Join-Path $Repo 'venv.portable-repair-old'
$PythonRoot = Join-Path $Root 'runtime\python'
$Pointer = Join-Path $PythonRoot 'current.txt'
$PythonBackup = Join-Path $PythonRoot '.portable-python-backup'

function Remove-TreeBestEffort([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        $drive = 'V:'
        try {
            subst $drive (Split-Path $Path -Parent) | Out-Null
            cmd.exe /d /c "rd /s /q $drive\$(Split-Path $Path -Leaf)" | Out-Null
        } finally {
            subst $drive /d 2>$null | Out-Null
        }
    }
}

function Invoke-NativeChecked {
    # npm 12+ writes "npm notice" lines to stderr. PowerShell 5.1 under
    # $ErrorActionPreference='Stop' wraps ANY native stderr output as a
    # NativeCommandError and aborts the script even when the command
    # succeeded (exit code 0). Run the command with EAP relaxed and judge
    # success purely by $LASTEXITCODE. With -AllowFailure, a nonzero exit
    # code is returned (as $null output) instead of throwing.
    param(
        [string]$What,
        [scriptblock]$Script,
        [switch]$AllowFailure
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Script
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($code -ne 0 -and -not $AllowFailure) { throw "$What failed with exit code $code" }
    if ($code -ne 0) { return }
    $output
}

# Directory-boundary match: a bare StartsWith($Root) would also kill a
# DIFFERENT install whose path merely begins with this root (e.g.
# "...-Portable-Beta\..." or "...Portable 2\..."). Only stop processes under
# THIS root (or the root itself), excluding Update.exe (self).
function Stop-RootProcesses {
    $rootPrefix = $Root.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.ExecutablePath -and $_.Name -ne 'Update.exe' -and
            ($_.ExecutablePath.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -or
             $_.ExecutablePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

function Set-PortableEnvironment {
    $env:HERMES_HOME = $HermesHome
    $env:HERMES_DESKTOP_USER_DATA_DIR = Join-Path $Root 'data\electron-user-data'
    $env:HERMES_GIT_BASH_PATH = Join-Path $HermesHome 'git\bin\bash.exe'
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $Root 'runtime\python'
    $env:UV_PYTHON_INSTALL_BIN = '0'
    $env:UV_PYTHON_INSTALL_REGISTRY = '0'
    $env:HERMES_PORTABLE_SITE_PACKAGES = Join-Path $Repo 'venv\Lib\site-packages'
    $env:PYTHONPATH = @((Join-Path $Root 'runtime\python-bootstrap'), $Repo, $env:PYTHONPATH) -join ';'
    $env:PATH = @(
        (Join-Path $Repo 'venv\Scripts'),
        (Join-Path $HermesHome 'node'),
        (Join-Path $HermesHome 'git\cmd'),
        (Join-Path $HermesHome 'git\bin'),
        (Join-Path $HermesHome 'git\usr\bin'),
        (Join-Path $Root 'runtime\bin'),
        $env:PATH
    ) -join ';'
}

function Remove-PythonRuntimeEntry($Entry) {
    if (-not $Entry) { return }
    if ($Entry.LinkType -eq 'Junction') {
        cmd.exe /d /c "rd /q `"$($Entry.FullName)`"" | Out-Null
    } else {
        Remove-TreeBestEffort $Entry.FullName
    }
}

function Get-OfficialDefaultPythonVersion {
    $installer = Join-Path $Repo 'scripts\install.ps1'
    if (-not (Test-Path $installer)) { throw 'Official Windows installer script was not found.' }
    $text = [IO.File]::ReadAllText($installer, [Text.Encoding]::UTF8)
    $match = [regex]::Match($text, '(?m)^\$PythonVersion\s*=\s*"(\d+\.\d+)"\s*$')
    if (-not $match.Success) { throw 'Official default PythonVersion declaration was not found.' }
    return $match.Groups[1].Value
}

function Test-PythonRuntime([string]$Path, [string]$ExpectedMinor = '') {
    if (-not (Test-Path $Path)) { return $false }
    try {
        $raw = & $Path -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        if ($ExpectedMinor) {
            $actual = [version]$raw.Trim()
            $expected = [version]$ExpectedMinor
            if ($actual.Major -ne $expected.Major -or $actual.Minor -ne $expected.Minor) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-CurrentPython([string]$ExpectedMinor) {
    $name = if (Test-Path $Pointer) { ([IO.File]::ReadAllText($Pointer, [Text.Encoding]::UTF8)).Trim() } else { '' }
    if ($name -and $name -notmatch '[\\/:*?"<>|]') {
        $candidate = Join-Path (Join-Path $PythonRoot $name) 'python.exe'
        if (Test-PythonRuntime $candidate $ExpectedMinor) { return $candidate }
    }
    $candidate = Get-ChildItem $PythonRoot -Directory -Filter 'cpython-*-windows-x86_64-none' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'python.exe' } |
        Where-Object { Test-PythonRuntime $_ $ExpectedMinor } |
        Select-Object -First 1
    if ($candidate) { return $candidate }
    throw "No bundled Python matching official PythonVersion $ExpectedMinor was found."
}

$OfficialPythonVersion = Get-OfficialDefaultPythonVersion
if ($ShowOfficialPythonVersion) {
    Write-Output $OfficialPythonVersion
    exit 0
}

if (-not $KeepProcesses) {
    Stop-RootProcesses
}

$Uv = Join-Path $HermesHome 'bin\uv.exe'
if (-not (Test-Path $Uv)) { $Uv = Join-Path $Root 'runtime\bin\uv.exe' }
if (-not (Test-Path $Uv)) { throw 'Bundled uv.exe was not found.' }
if (-not (Test-Path (Join-Path $Repo 'pyproject.toml'))) { throw 'Hermes source checkout is incomplete.' }

$env:UV_PYTHON_INSTALL_DIR = $PythonRoot
$env:UV_PYTHON_INSTALL_BIN = '0'
$env:UV_PYTHON_INSTALL_REGISTRY = '0'
# Do NOT set UV_NO_CONFIG here: upstream pyproject.toml [tool.uv] now declares
# override-dependencies and a relative exclude-newer ("14 days"). UV_NO_CONFIG
# strips that entire table, so `uv sync --locked` re-resolves without the
# project's resolution constraints and fails against the shipped uv.lock.
# Project configuration wins over any user uv.toml, so discovery stays safe.
$env:UV_NO_CONFIG = '0'
$PreviousPython = Get-CurrentPython ''
$Python = $PreviousPython

if ($UpdatePython) {
    Write-Host "Checking official default Python $OfficialPythonVersion..."
    Remove-TreeBestEffort $PythonBackup
    $previousPythonDir = Split-Path $PreviousPython -Parent
    Copy-Item $previousPythonDir $PythonBackup -Recurse -Force
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $uvOutput = & $Uv python install $OfficialPythonVersion 2>&1
        $uvExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $uvOutput | ForEach-Object { Write-Host $_ }
    if ($uvExitCode -ne 0) {
        Remove-TreeBestEffort $previousPythonDir
        Move-Item $PythonBackup $previousPythonDir
        throw "uv python install $OfficialPythonVersion failed with exit code $uvExitCode"
    }
    $found = ((& $Uv python find $OfficialPythonVersion --managed-python 2>$null) | Select-Object -First 1).Trim()
    if (-not (Test-PythonRuntime $found $OfficialPythonVersion)) {
        Remove-TreeBestEffort $previousPythonDir
        Move-Item $PythonBackup $previousPythonDir
        throw "The newly installed official Python $OfficialPythonVersion runtime failed validation."
    }
    $foundDir = Get-Item (Split-Path $found -Parent) -Force
    if ($foundDir.LinkType -eq 'Junction' -and $foundDir.Target) {
        $targetDir = [string]@($foundDir.Target)[0]
        $resolved = Join-Path $targetDir 'python.exe'
        if (-not (Test-PythonRuntime $resolved $OfficialPythonVersion)) {
            Remove-TreeBestEffort $previousPythonDir
            Move-Item $PythonBackup $previousPythonDir
            throw "The exact target behind official PythonVersion $OfficialPythonVersion failed validation."
        }
        $found = $resolved
    }
    $Python = $found
}

$VenvPython = Join-Path $Venv 'Scripts\python.exe'
$healthy = $false
if (-not $UpdatePython -and (Test-Path $VenvPython)) {
    try {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        # uv sync --no-install-project never installs the project itself; the
        # runtime resolves hermes_cli from the embedded checkout via PYTHONPATH
        # (see hermes-cli.cmd). The probe must replicate that instead of
        # relying on the caller's ambient PYTHONPATH.
        $oldPythonPath = $env:PYTHONPATH
        try {
            $env:PYTHONPATH = @($Repo, $oldPythonPath) -join ';'
            & $VenvPython -c "import sys, hermes_cli, fastapi, dotenv, yaml; expected=tuple(map(int, '$OfficialPythonVersion'.split('.'))); raise SystemExit(0 if sys.version_info[:2] == expected else 1)" 2>$null
            $healthy = ($LASTEXITCODE -eq 0)
        } finally { $env:PYTHONPATH = $oldPythonPath }
    } catch { $healthy = $false } finally { $ErrorActionPreference = $previousPreference }
}

if (-not $healthy) {
    Write-Host "Repairing relocatable Hermes Python environment for official PythonVersion $OfficialPythonVersion..."
    Remove-TreeBestEffort $OldVenv
    if (Test-Path $Venv) { Rename-Item $Venv (Split-Path $OldVenv -Leaf) }
    try {
        Invoke-NativeChecked 'uv venv recreation' { & $Uv venv $Venv --python $Python --relocatable --clear --seed --no-python-downloads --no-managed-python }
        $env:UV_PROJECT_ENVIRONMENT = $Venv
        $env:VIRTUAL_ENV = $Venv
        $env:PYTHONPATH = ''
        Invoke-NativeChecked 'uv locked dependency sync' { & $Uv sync --project $Repo --extra all --locked --link-mode copy }
        $oldPythonPath = $env:PYTHONPATH
        try {
            $env:PYTHONPATH = @($Repo, $oldPythonPath) -join ';'
            Invoke-NativeChecked 'Rebuilt environment version/import probe' { & $VenvPython -c "import sys, hermes_cli, fastapi, dotenv, yaml; expected=tuple(map(int, '$OfficialPythonVersion'.split('.'))); raise SystemExit(0 if sys.version_info[:2] == expected else 1)" }
        } finally { $env:PYTHONPATH = $oldPythonPath }
        $activeName = Split-Path (Split-Path $Python -Parent) -Leaf
        [IO.File]::WriteAllText($Pointer, $activeName + "`n", [Text.UTF8Encoding]::new($false))
        Remove-TreeBestEffort $OldVenv
        if ($UpdatePython) {
            $activeExactDir = [IO.Path]::GetFullPath((Split-Path $Python -Parent)).TrimEnd('\')
            Get-ChildItem $PythonRoot -Directory -Filter 'cpython-*-windows-x86_64-none' -Force |
                Where-Object {
                    $entryPath = [IO.Path]::GetFullPath($_.FullName).TrimEnd('\')
                    if ($entryPath.Equals($activeExactDir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
                    if ($_.LinkType -eq 'Junction' -and $_.Target) {
                        $targetPath = [IO.Path]::GetFullPath([string]@($_.Target)[0]).TrimEnd('\')
                        if ($targetPath.Equals($activeExactDir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
                    }
                    return $true
                } |
                ForEach-Object { Remove-PythonRuntimeEntry $_ }
            Remove-TreeBestEffort $PythonBackup
        }
    } catch {
        Remove-TreeBestEffort $Venv
        if (Test-Path $OldVenv) { Rename-Item $OldVenv 'venv' }
        $oldName = Split-Path (Split-Path $PreviousPython -Parent) -Leaf
        if ($UpdatePython -and (Test-Path $PythonBackup)) {
            $oldDir = Join-Path $PythonRoot $oldName
            Remove-TreeBestEffort $oldDir
            Move-Item $PythonBackup $oldDir
        }
        [IO.File]::WriteAllText($Pointer, $oldName + "`n", [Text.UTF8Encoding]::new($false))
        throw
    }
} else {
    $activeName = Split-Path (Split-Path $Python -Parent) -Leaf
    [IO.File]::WriteAllText($Pointer, $activeName + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Portable Python environment is healthy for official PythonVersion $OfficialPythonVersion."
}

Set-PortableEnvironment
Write-Host "Portable venv ready: $VenvPython"
Write-Host "Official PythonVersion selector: $OfficialPythonVersion"
Write-Host "Active official Python: $Python"
