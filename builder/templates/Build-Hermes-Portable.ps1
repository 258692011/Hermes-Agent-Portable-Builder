param(
    [string]$BuilderRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch]$SkipArchive
)

$ErrorActionPreference = 'Stop'
$Repo = Join-Path $BuilderRoot 'upstream'
$StageParent = Join-Path $BuilderRoot 'stage'
$Stage = Join-Path $StageParent 'Hermes-Agent-Desktop-Portable'
$Dist = Join-Path $BuilderRoot 'dist'
$Builder = Join-Path $BuilderRoot 'builder'
$Templates = Join-Path $Builder 'templates'
$Scripts = Join-Path $Builder 'scripts'
# Offline cache for build-time runtimes (uv / Git / Node / Python). Priority:
# system install > this cache > network download (downloads are back-filled
# here so the next build is offline). Populate manually by dropping the same
# artifact names the installer functions expect, e.g.:
#   assets\uv\uv-x86_64-pc-windows-msvc.zip
#   assets\git\PortableGit-2.55.0.3-64-bit.7z.exe
#   assets\node\node-v<ver>-win-x64.zip
#   assets\python\cpython-3.11.15-windows-x86_64-none\ (unpacked dir)
$RuntimeCache = Join-Path $Builder 'assets'

# Offline-first npm/Electron caches under assets (same contract as uv/git/node).
# The cache dirs ARE the assets dirs: every npm/electron-builder run both
# consumes and back-fills them, so the first online build seeds them and later
# builds stay offline. --prefer-offline (on each install below) uses the cache
# first and only hits the network for packages not yet cached, back-filling the
# same run. Electron download honors ELECTRON_CACHE / ELECTRON_BUILDER_CACHE.
$env:npm_config_cache = Join-Path $RuntimeCache 'npm-cache'
$env:ELECTRON_CACHE = Join-Path $RuntimeCache 'electron-cache'
$env:ELECTRON_BUILDER_CACHE = Join-Path $RuntimeCache 'electron-builder-cache'

# Sanitize leaked managed-Python environment variables before any uv call.
# A running Portable Hermes Desktop sets UV_PYTHON_INSTALL_DIR/BIN/REGISTRY
# (Hermes-Desktop.cs, the main.ts patch, hermes-cli.cmd) and every agent/user
# terminal spawned from it inherits them, pointing uv at the LIVE portable's
# runtime python whose DLLs are locked by the running backend. Without this,
# any `uv python find <selector> --system` run before Install-ManagedPython
# resolves to that live runtime and the stage python copy fails. Clearing
# here is safe: Install-ManagedPython re-sets all three to the stage's own
# runtime\python before it invokes uv.
foreach ($leakedVar in 'UV_PYTHON_INSTALL_DIR', 'UV_PYTHON_INSTALL_BIN', 'UV_PYTHON_INSTALL_REGISTRY') {
    if (Test-Path "Env:$leakedVar") {
        Write-Host "Sanitizing leaked $leakedVar=$([Environment]::GetEnvironmentVariable($leakedVar))"
        Remove-Item "Env:$leakedVar"
    }
}


function Copy-Tree([string]$Source, [string]$Destination) {
    if (-not (Test-Path $Source)) { throw "Missing source tree: $Source" }
    New-Item -ItemType Directory -Force $Destination | Out-Null
    robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $Source -> $Destination" }
}

function Remove-TreeSafe([string]$Path) {
    # Long-path-safe deletion: plain Remove-Item fails silently on >MAX_PATH
    # trees (e.g. website i18n docs, node_modules), leaving a poisoned stage.
    Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $Path)) { return }
    $parent = Split-Path $Path -Parent
    $leaf = Split-Path $Path -Leaf
    $candidates = 'H','G','F','I','J','K','L','M','N'
    foreach ($letter in $candidates) {
        if (Test-Path "${letter}:\") { continue }
        subst "${letter}:" $parent | Out-Null
        try {
            cmd.exe /d /c "rd /s /q ${letter}:\$leaf" | Out-Null
        } finally {
            subst "${letter}:" /d | Out-Null
        }
        break
    }
}

function Assert-WindowsX64 {
    $archCode = $null
    try { $archCode = [int](Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Architecture) } catch { }
    $isX64 = if ($null -ne $archCode) { $archCode -eq 9 } else { [Environment]::Is64BitOperatingSystem -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'ARM64' }
    if (-not $isX64) { throw 'This Portable Builder currently supports Windows x64 only; ARM64/x86 builds are rejected to prevent mixed-architecture packages.' }
}

Assert-WindowsX64

function Assert-Upstream {
    # The build consumes the official source checkout under upstream/.
    # If the folder is missing or empty, clone it from the official
    # repository (full history: the packaged .git is copied from this
    # checkout, so a shallow clone would ship a shallow .git inside the
    # release archive). Non-empty non-git folders and incomplete snapshots
    # are reported with an English error and are never deleted automatically.
    $officialRepo = 'https://github.com/NousResearch/hermes-agent.git'
    $upstreamExists = Test-Path -LiteralPath $Repo
    $gitDir = Join-Path $Repo '.git'

    if ($upstreamExists -and -not (Test-Path -LiteralPath $gitDir)) {
        $children = @(Get-ChildItem -LiteralPath $Repo -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "upstream ($Repo) exists but is not a git checkout and is not empty. Refusing to delete it automatically; remove it manually or clone the official repository, then re-run the build."
        }
    }

    if (-not $upstreamExists -or ((Test-Path -LiteralPath $Repo) -and -not (Test-Path -LiteralPath $gitDir))) {
        $cloned = $false
        for ($attempt = 1; $attempt -le 3 -and -not $cloned; $attempt++) {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                if (Test-Path -LiteralPath $Repo) {
                    Remove-Item -LiteralPath $Repo -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-Host "Cloning official Hermes source into $Repo (attempt $attempt/3)..."
                & git.exe clone $officialRepo $Repo 2>&1 | Out-Host
                $cloneCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldEap
            }
            if ($cloneCode -eq 0 -and (Test-Path -LiteralPath $gitDir)) {
                $cloned = $true
            } elseif ($attempt -eq 3) {
                throw "Failed to clone the official Hermes source ($officialRepo) after 3 attempts. Check network connectivity and clone manually: git clone $officialRepo `"$Repo`""
            } else {
                Write-Host "Clone attempt $attempt failed (exit code $cloneCode); retrying in 5s..."
                Start-Sleep -Seconds 5
            }
        }
    }

    foreach ($file in @('scripts\install.ps1', 'package.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Repo $file))) {
            throw "upstream checkout at $Repo is incomplete: missing $file. Restore it from the official repository: git -C `"$Repo`" fetch --prune origin && git -C `"$Repo`" reset --hard origin/main"
        }
    }
}

Assert-Upstream

function Read-OfficialPythonSelector {
    $text = [IO.File]::ReadAllText((Join-Path $Repo 'scripts\install.ps1'), [Text.Encoding]::UTF8)
    $match = [regex]::Match($text, '(?m)^\$PythonVersion\s*=\s*"(\d+\.\d+)"\s*$')
    if (-not $match.Success) { throw 'Official scripts\install.ps1 PythonVersion was not found.' }
    $match.Groups[1].Value
}

function Read-OfficialNodeSelector {
    $text = [IO.File]::ReadAllText((Join-Path $Repo 'scripts\install.ps1'), [Text.Encoding]::UTF8)
    $match = [regex]::Match($text, '(?m)^\$NodeVersion\s*=\s*"(\d+)"\s*$')
    if (-not $match.Success) { throw 'Official scripts\install.ps1 NodeVersion was not found.' }
    $match.Groups[1].Value
}

# Downloads can be flaky (GitHub releases, nodejs.org); retry up to 3 times
# with a 5s pause, matching the retry contract of the git clone /
# PortableGit / 7-Zip download sites in this script. With -ReturnContent the
# response body is returned instead of writing a file.
function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$OutFile,
        [string]$Label,
        [switch]$ReturnContent
    )
    $downloaded = $false
    for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
        try {
            $iwrArgs = @{ Uri = $Uri; UseBasicParsing = $true }
            if ($OutFile) { $iwrArgs['OutFile'] = $OutFile }
            $response = Invoke-WebRequest @iwrArgs
            $downloaded = $true
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Host "$Label download attempt $attempt failed; retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }
    if ($ReturnContent) { return $response.Content }
}


function Install-ManagedUv([string]$Root) {
    $uvVersion = '0.12.3'
    $asset = 'uv-x86_64-pc-windows-msvc.zip'
    $bin = Join-Path $Root 'runtime\bin'
    $uv = Join-Path $bin 'uv.exe'
    New-Item -ItemType Directory -Force $bin | Out-Null
    $zip = Join-Path $env:TEMP $asset
    $extract = Join-Path $env:TEMP 'hermes-portable-uv-bootstrap'
    $base = "https://github.com/astral-sh/uv/releases/download/$uvVersion"
    # Prefer the offline cache under assets; otherwise download and back-fill.
    # No separate SHA256 verification: the archive's own CRC makes any corrupt
    # download fail at extraction below, and the HTTPS download plus the 3x
    # retry covers transient failures (decided 2026-08-09: hash check removed).
    $cacheZip = Join-Path $RuntimeCache "uv\$asset"
    if (Test-Path $cacheZip) {
        Write-Host "Using cached uv from assets: $cacheZip"
        Copy-Item $cacheZip $zip -Force
    } else {
        # The download can be flaky; retry up to 3 times.
        Invoke-DownloadWithRetry -Uri "$base/$asset" -OutFile $zip -Label 'uv'
        try {
            New-Item -ItemType Directory -Force (Split-Path $cacheZip -Parent) | Out-Null
            Copy-Item $zip $cacheZip -Force
            Write-Host "Cached uv to assets: $cacheZip"
        } catch { Write-Host "WARNING: could not cache uv to assets: $_" }
    }
    try {
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $zip $extract -Force
        Copy-Item (Join-Path $extract 'uv.exe') $uv -Force
        if (-not (Test-Path $uv)) { throw 'Managed uv bootstrap failed.' }
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
    $uv
}

function Install-ManagedPython([string]$Root, [string]$Uv, [string]$Selector) {
    $pythonRoot = Join-Path $Root 'runtime\python'
    New-Item -ItemType Directory -Force $pythonRoot | Out-Null
    # Prefer an unpacked CPython directory cached under assets (name pattern
    # cpython-<major>.<minor>*). This keeps the build fully offline once the
    # cache is populated; otherwise uv downloads and we back-fill the cache.
    $cacheDir = Get-ChildItem (Join-Path $RuntimeCache 'python') -Directory -Filter "cpython-$Selector.*" -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'python.exe') } | Select-Object -First 1
    if ($cacheDir) {
        $runtimeName = $cacheDir.Name
        $dest = Join-Path $pythonRoot $runtimeName
        Write-Host "Using cached Python from assets: $($cacheDir.FullName)"
        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Tree $cacheDir.FullName $dest
        [IO.File]::WriteAllText((Join-Path $pythonRoot 'current.txt'), $runtimeName + "`n", [Text.UTF8Encoding]::new($false))
        return @{ Python = (Join-Path $dest 'python.exe'); RuntimeName = $runtimeName }
    }
    $env:UV_PYTHON_INSTALL_DIR = $pythonRoot
    $env:UV_PYTHON_INSTALL_BIN = '0'
    $env:UV_PYTHON_INSTALL_REGISTRY = '0'
    Invoke-NativeChecked "Managed Python $Selector bootstrap" { & $Uv python install $Selector | Out-Host }
    $python = (Invoke-NativeChecked "Managed Python $Selector find" { (& $Uv python find $Selector --managed-python) | Select-Object -First 1 }).Trim()
    if (-not (Test-Path $python)) { throw "Managed Python $Selector was not found after installation." }
    $dir = Split-Path $python -Parent
    $item = Get-Item $dir -Force
    if ($item.LinkType -eq 'Junction' -and $item.Target) { $dir = [string]@($item.Target)[0] }
    $runtimeName = Split-Path $dir -Leaf
    [IO.File]::WriteAllText((Join-Path $pythonRoot 'current.txt'), $runtimeName + "`n", [Text.UTF8Encoding]::new($false))
    # Back-fill the cache so the next build is offline.
    try {
        $cacheDest = Join-Path $RuntimeCache "python\$runtimeName"
        if (-not (Test-Path (Join-Path $cacheDest 'python.exe'))) {
            Copy-Tree $dir $cacheDest
            Write-Host "Cached Python to assets: $cacheDest"
        }
    } catch { Write-Host "WARNING: could not cache Python to assets: $_" }
    @{ Python = (Join-Path $dir 'python.exe'); RuntimeName = $runtimeName }
}

function Install-PortableNode([string]$Root, [string]$Major) {
    $arch = 'x64'
    $index = "https://nodejs.org/dist/latest-v$Major.x/"
    # Prefer a cached Node archive under assets (node-v<major>.*-win-x64.zip);
    # otherwise resolve the latest version and back-fill the cache.
    $cacheZip = Get-ChildItem (Join-Path $RuntimeCache 'node') -File -Filter "node-v$Major.*-win-$arch.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cacheZip) {
        Write-Host "Using cached Node from assets: $($cacheZip.FullName)"
        $zip = $cacheZip.FullName
        $match = [regex]::Match($cacheZip.Name, "node-v$Major\.\d+\.\d+-win-$arch\.zip")
        if (-not $match.Success) { throw "Cached Node archive name does not match expected pattern: $($cacheZip.Name)" }
    } else {
        $page = Invoke-DownloadWithRetry -Uri $index -ReturnContent -Label 'Node.js version index'
        $match = [regex]::Match($page, "node-v$Major\.\d+\.\d+-win-$arch\.zip")
        if (-not $match.Success) { throw "Could not resolve portable Node.js $Major for $arch." }
        $zip = Join-Path $env:TEMP $match.Value
        # The ~30 MB nodejs.org download can be flaky; retry up to 3 times.
        Invoke-DownloadWithRetry -Uri ($index + $match.Value) -OutFile $zip -Label 'Node.js'
        try {
            New-Item -ItemType Directory -Force (Join-Path $RuntimeCache 'node') | Out-Null
            Copy-Item $zip (Join-Path $RuntimeCache "node\$($match.Value)") -Force
            Write-Host "Cached Node to assets: $($match.Value)"
        } catch { Write-Host "WARNING: could not cache Node to assets: $_" }
    }
    $extract = Join-Path $env:TEMP 'hermes-portable-node-bootstrap'
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $source = Get-ChildItem $extract -Directory | Select-Object -First 1
    if (-not $source) { throw 'Portable Node.js archive was empty.' }
    Copy-Tree $source.FullName (Join-Path $Root 'data\hermes-home\node')
    if (-not $cacheZip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-PortableGit([string]$Root) {
    $gitTag = 'v2.55.0.windows.3'
    $gitVer = '2.55.0.3'
    $arch = '64-bit'
    $asset = "PortableGit-$gitVer-$arch.7z.exe"
    $gitRoot = Join-Path $Root 'data\hermes-home\git'
    # Prefer a cached PortableGit archive under assets; otherwise download and
    # back-fill the cache. The ~60 MB GitHub release download can be flaky;
    # retry up to 3 times when we have to download.
    $cacheArchive = Join-Path $RuntimeCache "git\$asset"
    if (Test-Path $cacheArchive) {
        Write-Host "Using cached PortableGit from assets: $cacheArchive"
        $archive = $cacheArchive
    } else {
        $archive = Join-Path $env:TEMP $asset
        $downloadArgs = @{
            Uri = "https://github.com/git-for-windows/git/releases/download/$gitTag/$asset"
            OutFile = $archive
            UseBasicParsing = $true
        }
        $downloaded = $false
        for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
            try {
                Invoke-WebRequest @downloadArgs
                $downloaded = $true
            }
            catch {
                if ($attempt -eq 3) { throw }
                Write-Host "PortableGit download attempt $attempt failed; retrying in 5s..."
                Start-Sleep -Seconds 5
            }
        }
        try {
            New-Item -ItemType Directory -Force (Join-Path $RuntimeCache 'git') | Out-Null
            Copy-Item $archive (Join-Path $RuntimeCache "git\$asset") -Force
            Write-Host "Cached PortableGit to assets: $asset"
        } catch { Write-Host "WARNING: could not cache PortableGit to assets: $_" }
    }
    Remove-Item $gitRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $gitRoot | Out-Null
    $proc = Start-Process -FilePath $archive -ArgumentList "-o`"$gitRoot`"", '-y' -NoNewWindow -Wait -PassThru
    if (-not (Test-Path (Join-Path $RuntimeCache "git\$asset"))) { Remove-Item $archive -Force -ErrorAction SilentlyContinue }
    if ($proc.ExitCode -ne 0 -or -not (Test-Path (Join-Path $gitRoot 'cmd\git.exe')) -or -not (Test-Path (Join-Path $gitRoot 'bin\bash.exe'))) {
        throw 'PortableGit bootstrap failed.'
    }
}

function Install-PortableVenv([string]$Root, [string]$Uv, [string]$Python) {
    $checkout = Join-Path $Root 'data\hermes-home\hermes-agent'
    $venv = Join-Path $checkout 'venv'
    Invoke-NativeChecked 'Portable venv creation' { & $Uv venv $venv --python $Python --relocatable | Out-Host }
    $oldProjectEnvironment = $env:UV_PROJECT_ENVIRONMENT
    $oldPython = $env:UV_PYTHON
    try {
        $env:UV_PROJECT_ENVIRONMENT = $venv
        $env:UV_PYTHON = Join-Path $venv 'Scripts\python.exe'
        Push-Location $checkout
        try {
            Invoke-NativeChecked 'Locked Portable dependency sync' { & $Uv sync --extra all --locked --no-install-project --link-mode copy | Out-Host }
        } finally { Pop-Location }
    } finally {
        $env:UV_PROJECT_ENVIRONMENT = $oldProjectEnvironment
        $env:UV_PYTHON = $oldPython
    }
    Get-ChildItem (Join-Path $venv 'Lib\site-packages') -File | Where-Object { $_.Name -like '__editable__*' -or $_.Name -like '*.egg-link' } | Remove-Item -Force
    $probe = Join-Path $venv 'Scripts\python.exe'
    # uv sync --no-install-project never installs the project itself; the
    # runtime resolves hermes_cli from the embedded checkout via PYTHONPATH
    # (see hermes-cli.cmd). The probe must replicate that, not assume the
    # build machine's ambient PYTHONPATH (which may leak a different
    # checkout's site-packages and falsely pass or fail).
    $oldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = @($checkout, $oldPythonPath) -join ';'
        Invoke-NativeChecked 'First-build venv imports' { & $probe -c "import hermes_cli, mcp, win32api, pywintypes" }
    } finally {
        $env:PYTHONPATH = $oldPythonPath
    }
}

function Resolve-OrInstallUv([string]$Root) {
    # Self-contained: never read the system. Install-ManagedUv prefers the
    # assets cache and only downloads when the cache is missing, back-filling
    # it so the next build is offline (corruption is caught by archive CRC at
    # extraction; no separate hash check).
    Install-ManagedUv $Root
}

function Resolve-OrInstallPython([string]$Root, [string]$Uv, [string]$Selector) {
    # Self-contained: never read the system. Install-ManagedPython prefers an
    # unpacked CPython directory under assets; only falls back to uv install
    # (then back-fills the cache) when the cache is missing.
    Install-ManagedPython $Root $Uv $Selector
}

function Resolve-OrInstallNode([string]$Root, [string]$Major) {
    # Self-contained: never read the system. Install-PortableNode prefers a
    # cached node-v<major>.*-win-x64.zip under assets; only resolves and
    # downloads from nodejs.org (then back-fills) when the cache is missing.
    Install-PortableNode $Root $Major
}

function Ensure-OfficialNpm([string]$NodeDir) {
    # The official npm floor lives in the repo root package.json engines.npm
    # (e.g. "<11.10.0 || >=11.17.0"). Parse the highest ">=" constraint and
    # upgrade the packaged npm when the bundled version is below that floor.
    # Called from the build (after Resolve-OrInstallNode) and from the update
    # script (before the TUI rebuild) so a floor bump never bricks either path.
    if (-not (Test-Path $NodeDir)) { return }
    $npmCmd = Join-Path $NodeDir 'npm.cmd'
    if (-not (Test-Path $npmCmd)) { return }
    $pkgPath = Join-Path $Repo 'package.json'
    if (-not (Test-Path $pkgPath)) { return }
    $npmReq = $null
    try { $npmReq = (Get-Content $pkgPath -Raw | ConvertFrom-Json).engines.npm } catch { }
    if (-not $npmReq) { return }
    # Find the highest ">=" constraint: e.g. ">=11.17.0" -> "11.17.0"
    $best = [version]'0.0.0'
    $matches = [regex]::Matches($npmReq, '>=(\d+\.\d+\.\d+)')
    foreach ($m in $matches) {
        $v = [version]$m.Groups[1].Value
        if ($v -gt $best) { $best = $v }
    }
    if ($best -eq [version]'0.0.0') { return }
    $current = (& $npmCmd --version 2>$null).Trim()
    if (-not $current) { return }
    $cur = [version]$current
    if ($cur -ge $best) { return }
    $targetMajor = $best.Major
    Write-Host "Official npm requirement ($npmReq, floor >=$best) exceeds packaged npm ($current); upgrading packaged npm to npm@$targetMajor..."
    Invoke-NativeChecked "Packaged npm upgrade to npm@$targetMajor" { & $npmCmd install --prefix $NodeDir "npm@$targetMajor" --no-fund --no-audit --progress=false }
    $after = (& $npmCmd --version 2>$null).Trim()
    Write-Host "Packaged npm now $after (official requires $npmReq)."
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

# Release gate (merged into the build script 2026-08-10): the staged venv
# must be relocatable — no `__editable__*` / `*.egg-link` metadata
# (editable installs embed the builder's absolute paths) and no build-root
# absolute path inside any retained .pth. Both would break a moved Portable.
function Test-PortableNoEditableInstall([string]$Root) {
    $Site = Join-Path $Root 'data\hermes-home\hermes-agent\venv\Lib\site-packages'
    $Repo = Join-Path $Root 'data\hermes-home\hermes-agent'
    $offenders = Get-ChildItem $Site -File -ErrorAction Stop | Where-Object {
        $_.Name -like '__editable__*' -or $_.Name -like '*.egg-link'
    }
    if ($offenders) { throw "Non-relocatable editable metadata found: $($offenders.Name -join ', ')" }
    $absolute = Get-ChildItem $Site -File -Filter '*.pth' -ErrorAction Stop | Where-Object {
        [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8).Contains($Repo)
    }
    if ($absolute) { throw "Build-root absolute path found in .pth: $($absolute.Name -join ', ')" }
    [ordered]@{ EditableMetadataPresent = $false; BuildRootInPth = $false } | ConvertTo-Json
}

# Release gate (merged into the build script 2026-08-10): a broad
# contract check of the assembled stage — Python follows the official
# selector via current.txt (no hard-coded runtime dir), the CLI launcher wires
# the bootstrap + site-packages, the verifier enforces the MCP import probe,
# no build-only overlay / user config / credentials / obsolete executables /
# stale README path leak into the release.
function Test-PortablePythonContract([string]$Root) {
    $Repo = Join-Path $Root 'data\hermes-home\hermes-agent'
    $Installer = Join-Path $Repo 'scripts\install.ps1'
    $Pointer = Join-Path $Root 'runtime\python\current.txt'
    $Launcher = Join-Path $Root 'runtime\bin\hermes-cli.cmd'
    $Bootstrap = Join-Path $Root 'runtime\python-bootstrap\sitecustomize.py'
    $Readme = Join-Path $Root 'README.txt'
    $Verifier = Join-Path $Root 'scripts\Verify-Portable.ps1'
    $UserConfig = Join-Path $Root 'data\hermes-home\config.yaml'
    $ForbiddenUserState = @('.env', 'auth.json', 'state.db', 'state.db-wal', 'state.db-shm')

    if (-not (Test-Path $Installer)) { throw "Official installer missing: $Installer" }
    $text = [IO.File]::ReadAllText($Installer, [Text.Encoding]::UTF8)
    $match = [regex]::Match($text, '(?m)^\$PythonVersion\s*=\s*"(\d+\.\d+)"\s*$')
    if (-not $match.Success) { throw 'Official scripts\install.ps1 PythonVersion was not found.' }
    $selector = $match.Groups[1].Value

    if (-not (Test-Path $Pointer)) { throw "Runtime pointer missing: $Pointer" }
    $runtimeName = [IO.File]::ReadAllText($Pointer, [Text.Encoding]::UTF8).Trim()
    if (-not $runtimeName -or $runtimeName -match '[\\/:*?"<>|]') { throw "Invalid runtime pointer: $runtimeName" }
    $python = Join-Path (Join-Path $Root 'runtime\python') (Join-Path $runtimeName 'python.exe')
    if (-not (Test-Path $python)) { throw "Pointed Python missing: $python" }
    $actual = (& $python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')").Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Bundled Python version probe failed.' }
    $actualVersion = [version]$actual
    $selectorVersion = [version]$selector
    if ($actualVersion.Major -ne $selectorVersion.Major -or $actualVersion.Minor -ne $selectorVersion.Minor) {
        throw "Bundled Python $actual does not follow official PythonVersion $selector."
    }

    if (-not (Test-Path $Launcher)) { throw "CLI launcher missing: $Launcher" }
    $launcherText = [IO.File]::ReadAllText($Launcher, [Text.Encoding]::UTF8)
    if ($launcherText -match 'cpython-\d+\.\d+(?:\.\d+)?-windows') {
        throw 'hermes-cli.cmd contains a hard-coded CPython runtime directory.'
    }
    if (-not $launcherText.Contains('runtime\python\current.txt')) {
        throw 'hermes-cli.cmd does not read runtime\python\current.txt.'
    }
    if (-not $launcherText.Contains('runtime\python-bootstrap')) {
        throw 'hermes-cli.cmd does not enable the Portable Python bootstrap.'
    }
    if (-not $launcherText.Contains('HERMES_PORTABLE_SITE_PACKAGES')) {
        throw 'hermes-cli.cmd does not expose the retained site-packages path to the Portable Python bootstrap.'
    }
    if (-not (Test-Path $Bootstrap)) { throw "Portable Python bootstrap missing: $Bootstrap" }
    if (-not (Test-Path $Verifier)) { throw "Portable verifier missing: $Verifier" }
    $verifierText = [IO.File]::ReadAllText($Verifier, [Text.Encoding]::UTF8)
    if (-not $verifierText.Contains("import mcp; print('mcp-ok')")) {
        throw 'Portable verifier does not enforce the MCP import regression probe.'
    }
    if (-not $verifierText.Contains('runtime\python\current.txt')) {
        throw 'Portable verifier does not select Python through runtime\python\current.txt.'
    }
    if ($verifierText.Contains("Get-ChildItem (Join-Path `$Root 'runtime\python') -Filter python.exe -Recurse")) {
        throw 'Portable verifier still selects an arbitrary recursively discovered Python runtime.'
    }
    if (Test-Path (Join-Path $Root 'portable')) { throw 'Build-only portable overlay was packaged in the release.' }
    if (Test-Path $UserConfig) { throw "Release contains user-owned config.yaml: $UserConfig" }
    foreach ($name in $ForbiddenUserState) {
        if (Test-Path (Join-Path $Root "data\hermes-home\$name")) { throw "Release contains forbidden user state: $name" }
    }
    $toolNames = @('Update-Portable.ps1', 'Repair-Portable.ps1', 'Verify-Portable.ps1')
    foreach ($toolName in $toolNames) {
        $toolPath = Join-Path $Root "scripts\$toolName"
        if (-not (Test-Path $toolPath)) { throw "Required runtime tool is missing: $toolName" }
        $duplicates = Get-ChildItem $Root -Recurse -File -Filter $toolName | Where-Object { $_.FullName -ne $toolPath }
        if ($duplicates) { throw "Runtime tool has duplicate packaged copies: $toolName" }
    }
    $trackedOverlay = & git.exe -C $Repo ls-files 'skills/software-development/hermes-portable-builder/*'
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the embedded official checkout.' }
    if ($trackedOverlay) { throw 'Portable overlay is still tracked inside the embedded official checkout.' }

    if (Test-Path (Join-Path $Root 'Hermes-CLI.exe')) { throw 'Obsolete root Hermes-CLI.exe is present.' }
    if (-not (Test-Path $Readme)) { throw "README missing: $Readme" }
    $readmeText = [IO.File]::ReadAllText($Readme, [Text.Encoding]::UTF8)
    if ($readmeText.Contains('Hermes-CLI.exe')) { throw 'README still points to obsolete Hermes-CLI.exe.' }
    if (-not $readmeText.Contains('runtime\bin\hermes-cli.cmd')) { throw 'README does not point to runtime\bin\hermes-cli.cmd.' }

    [ordered]@{
        OfficialPythonVersion = $selector
        BundledPythonVersion = $actual
        RuntimePointer = $runtimeName
        RootHermesCliExePresent = $false
        LauncherUsesPointer = $true
        PortablePythonBootstrap = $true
        ExternalOverlayPackaged = $false
        RuntimeToolsUnique = $true
        BuildOnlyFilesPackaged = $false
        UserConfigPackaged = $false
        FirstRunLanguage = 'zh'
        ExistingConfigPreserved = $true
        CredentialsOrStatePackaged = $false
        EmbeddedCheckoutIsOfficialOnly = $true
        ReadmeCliPath = 'runtime\bin\hermes-cli.cmd'
    } | ConvertTo-Json
}

function Resolve-OrInstallGit([string]$Root) {
    # Self-contained: never read the system (a system Git is neither required
    # nor consulted; the cached PortableGit under assets is the source).
    # Install-PortableGit prefers the cache and only downloads (then
    # back-fills) when it is missing.
    Install-PortableGit $Root
}

$selector = Read-OfficialPythonSelector
$nodeSelector = Read-OfficialNodeSelector

Invoke-NativeChecked 'Portable source patch' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Scripts 'Update-Portable.ps1') -Stage Patch -RepoPath $Repo }
# Sync the Desktop workspace dependencies against the committed lockfile before
# typecheck/build (mirrors the TUI/web install steps). The Desktop stage has no
# install of its own upstream, so a stale build-machine node_modules breaks the
# build whenever upstream adds a dependency (verified 2026-08-09: get-windows@9.3.0
# from the read_window_below tool failed typecheck with TS2307 until installed).
# npm workspace installs hoist packages to the root node_modules; the later
# package-lock.json restore (after the TUI/web steps) keeps the checkout clean.
# The install must live INSIDE the try whose finally removes the patch — a
# failure here must still restore the checkout (fixed 2026-08-09: a failing
# install outside the try left the patch behind and broke the next build gate).
Push-Location (Join-Path $Repo 'apps\desktop')
try {
    Push-Location $Repo
    try {
        Invoke-NativeChecked 'Desktop workspace install' { & npm.cmd install --workspace apps/desktop --include=dev --silent --no-fund --no-audit --progress=false --prefer-offline }
    } finally {
        Pop-Location
    }
    Invoke-NativeChecked 'Desktop typecheck' { & npm.cmd run typecheck }
    Invoke-NativeChecked 'Desktop build' { & npm.cmd run build }
    Invoke-NativeChecked 'Desktop packaging' { & npm.cmd run builder -- --win --x64 --dir }
} finally {
    Pop-Location
    Invoke-NativeChecked 'Portable source patch cleanup' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Scripts 'Update-Portable.ps1') -Stage PatchRemove -RepoPath $Repo }
}
# Prebuilt TUI bundle: stage hermes_cli/tui_dist/entry.js so the packaged
# Portable never runs npm install on the first TUI launch.
Push-Location $Repo
try {
    Invoke-NativeChecked 'TUI workspace install' { & npm.cmd install --workspace ui-tui --include=dev --silent --no-fund --no-audit --progress=false --prefer-offline }
    Push-Location (Join-Path $Repo 'ui-tui')
    try {
        Invoke-NativeChecked 'TUI bundle build' { & npm.cmd run build }
    } finally {
        Pop-Location
    }
} finally {
    Pop-Location
}
$tuiDistDir = Join-Path $Repo 'hermes_cli\tui_dist'
New-Item -ItemType Directory -Force $tuiDistDir | Out-Null
Copy-Item (Join-Path $Repo 'ui-tui\dist\entry.js') (Join-Path $tuiDistDir 'entry.js') -Force
# Prebuilt Web bundle: stage hermes_cli/web_dist so `hermes dashboard` serves
# the real browser UI (vite outDir targets ../hermes_cli/web_dist) instead of
# the Electron desktop bundle, which needs the desktop IPC bridge and breaks in
# a plain browser ("Desktop IPC bridge is unavailable").
Push-Location $Repo
try {
    Invoke-NativeChecked 'Web workspace install' { & npm.cmd install --workspace web --include=dev --silent --no-fund --no-audit --progress=false --prefer-offline }
    Push-Location (Join-Path $Repo 'web')
    try {
        Invoke-NativeChecked 'Web bundle build' { & npm.cmd run build }
    } finally {
        Pop-Location
    }
} finally {
    Pop-Location
}
# npm install --workspace ui-tui / --workspace web can "complete" the committed
# lockfile (npm >=10 re-resolves scoped peer deps and adds entries). Restore it
# so the staged checkout stays clean for the next update gate.
if (Test-Path (Join-Path $Repo '.git')) {
    & git.exe -C $Repo checkout -- package-lock.json 2>$null | Out-Null
}
$BuiltApp = Join-Path $Repo 'apps\desktop\release\win-unpacked'
if (-not (Test-Path (Join-Path $BuiltApp 'Hermes.exe'))) { throw 'Built Desktop is missing.' }

Remove-TreeSafe $StageParent
if (Test-Path $Stage) {
    throw "Staging tree could not be fully removed: $Stage (a process is holding files, e.g. a portable launched from it). Close such processes and retry — a partial stage poisons the fresh build."
}
New-Item -ItemType Directory -Force $Stage | Out-Null
Copy-Tree $BuiltApp (Join-Path $Stage 'app')
New-Item -ItemType File -Force (Join-Path $Stage 'app\portable.marker') | Out-Null
Copy-Tree (Join-Path $Repo '.git') (Join-Path $Stage 'data\hermes-home\hermes-agent\.git')
Copy-Tree $Repo (Join-Path $Stage 'data\hermes-home\hermes-agent')
Remove-TreeSafe (Join-Path $Stage 'data\hermes-home\hermes-agent\node_modules')
Remove-TreeSafe (Join-Path $Stage 'data\hermes-home\hermes-agent\apps\desktop\release')
Remove-TreeSafe (Join-Path $Stage 'data\hermes-home\hermes-agent\apps\desktop\dist')
Write-Host 'Preparing a fresh Portable runtime directly in build (system-first, download missing components)...'
$uv = Resolve-OrInstallUv $Stage
$pythonInfo = Resolve-OrInstallPython $Stage $uv $selector
$resolvedPython = $pythonInfo.Python
$runtimeName = $pythonInfo.RuntimeName
$resolvedDir = Split-Path $resolvedPython -Parent
$pythonVersion = (Invoke-NativeChecked 'Resolve python version' { & $resolvedPython -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" }).Trim()
Resolve-OrInstallNode $Stage $nodeSelector
Ensure-OfficialNpm (Join-Path $Stage 'data\hermes-home\node')
Resolve-OrInstallGit $Stage
Install-PortableVenv $Stage $uv $resolvedPython
New-Item -ItemType Directory -Force (Join-Path $Stage 'data\electron-user-data') | Out-Null
Copy-Item (Join-Path $Templates 'hermes-cli.cmd') (Join-Path $Stage 'runtime\bin\hermes-cli.cmd') -Force
Copy-Item (Join-Path $Templates 'hermes-tui.cmd') (Join-Path $Stage 'runtime\bin\hermes-tui.cmd') -Force
Copy-Item (Join-Path $Templates 'hermes-dashboard.cmd') (Join-Path $Stage 'runtime\bin\hermes-dashboard.cmd') -Force
Copy-Tree (Join-Path $Templates 'python-bootstrap') (Join-Path $Stage 'runtime\python-bootstrap')
New-Item -ItemType Directory -Force (Join-Path $Stage 'scripts') | Out-Null
Copy-Item (Join-Path $Scripts 'Update-Portable.ps1') (Join-Path $Stage 'scripts\Update-Portable.ps1') -Force
Copy-Item (Join-Path $Scripts 'Repair-Portable.ps1') (Join-Path $Stage 'scripts\Repair-Portable.ps1') -Force
Copy-Item (Join-Path $Scripts 'Verify-Portable.ps1') (Join-Path $Stage 'scripts\Verify-Portable.ps1') -Force

$ConfigPath = Join-Path $Stage 'data\hermes-home\config.yaml'
# User-owned settings must never be shipped or overwritten by an overlay ZIP.
# First-run launchers create the Chinese language seed only when this file does
# not already exist; upstream otherwise loads DEFAULT_CONFIG normally.
Remove-Item $ConfigPath -Force -ErrorAction SilentlyContinue
if (Test-Path $ConfigPath) { throw "Release must not contain user config: $ConfigPath" }

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$officialIcon = Join-Path $Repo 'apps\desktop\assets\icon.ico'
if (-not (Test-Path $officialIcon)) { throw "Official Hermes Desktop icon is missing: $officialIcon" }
Invoke-NativeChecked 'Hermes launcher compilation' { & $csc /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$officialIcon" "/out:$Stage\Hermes.exe" /reference:System.Windows.Forms.dll (Join-Path $Templates 'Hermes-Desktop.cs') }
Invoke-NativeChecked 'Update launcher compilation' { & $csc /nologo /target:exe /platform:anycpu /optimize+ "/win32icon:$officialIcon" "/out:$Stage\Update.exe" /reference:System.Windows.Forms.dll (Join-Path $Templates 'Update-Hermes.cs') }

$package = Get-Content (Join-Path $Repo 'pyproject.toml') -Raw
$hermesVersion = [regex]::Match($package, '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
$commit = (Invoke-NativeChecked 'Resolve source commit' { & git.exe -C $Repo rev-parse HEAD }).Trim()
# electron may be hoisted to the root node_modules or stay in the desktop
# workspace node_modules depending on npm hoisting/version behavior (root
# package.json no longer declares electron as of 2026-08-10; it lives in
# apps/desktop). Resolve either location.
$electronPkg = Join-Path $Repo 'node_modules\electron\package.json'
if (-not (Test-Path $electronPkg)) { $electronPkg = Join-Path $Repo 'apps\desktop\node_modules\electron\package.json' }
if (-not (Test-Path $electronPkg)) { throw "Electron package.json not found in root or apps/desktop node_modules." }
$electronVersion = (Get-Content $electronPkg -Raw | ConvertFrom-Json).version
$nodeVersion = (Invoke-NativeChecked 'Resolve node version' { & (Join-Path $Stage 'data\hermes-home\node\node.exe') --version }).Trim().TrimStart('v')
$gitVersion = ((Invoke-NativeChecked 'Resolve git version' { & (Join-Path $Stage 'data\hermes-home\git\cmd\git.exe') --version }) -replace '^git version ','').Trim()
$uvVersion = ((Invoke-NativeChecked 'Resolve uv version' { & (Join-Path $Stage 'runtime\bin\uv.exe') --version }) -replace '^uv ','').Split(' ')[0]
$readme = [IO.File]::ReadAllText((Join-Path $Templates 'README.txt'), [Text.Encoding]::UTF8)
$readme = $readme.Replace('{{HERMES_VERSION}}', $hermesVersion).Replace('{{SOURCE_COMMIT}}', $commit).Replace('{{ELECTRON_VERSION}}', $electronVersion).Replace('{{PYTHON_VERSION}}', $pythonVersion).Replace('{{NODE_VERSION}}', $nodeVersion).Replace('{{GIT_VERSION}}', $gitVersion).Replace('{{UV_VERSION}}', $uvVersion)
[IO.File]::WriteAllText((Join-Path $Stage 'README.txt'), $readme, [Text.UTF8Encoding]::new($false))

$Checkout = Join-Path $Stage 'data\hermes-home\hermes-agent'
$oldOrigin = (Invoke-NativeChecked 'Resolve staged origin' -AllowFailure { (& git.exe -C $Checkout remote get-url origin 2>$null) | Select-Object -First 1 })
if ($oldOrigin) { Invoke-NativeChecked 'Restore staged origin' { & git.exe -C $Checkout remote set-url origin $oldOrigin.Trim() } }
Invoke-NativeChecked 'Staged git config longpaths' { & git.exe -C $Checkout config core.longpaths true }
Invoke-NativeChecked 'Staged git config autocrlf' { & git.exe -C $Checkout config core.autocrlf false }
Invoke-NativeChecked 'Staged git config eol' { & git.exe -C $Checkout config core.eol lf }
Invoke-NativeChecked 'Staged git reset' { & git.exe -C $Checkout reset --hard $commit | Out-Null }
Invoke-NativeChecked 'Staged git clean' { & git.exe -C $Checkout clean -fdx -e venv/ -e hermes_cli/tui_dist/ -e hermes_cli/web_dist/ | Out-Null }
if (Invoke-NativeChecked 'Staged git status' { & git.exe -C $Checkout status --porcelain }) { throw 'Embedded checkout is dirty before release.' }
if (Invoke-NativeChecked 'Staged git stash list' { & git.exe -C $Checkout stash list }) { throw 'Embedded checkout has stale stashes before release.' }

# Bundle every builder-managed data seed. builder\data mirrors the deployed
# data layout (hermes-home\memories\USER.md, hermes-home\skills\...), so the
# whole tree is copied as-is — adding any file under builder\data is enough
# for it to ship in the next release.
$BuilderData = Join-Path $Builder 'data'
if (Test-Path $BuilderData) {
    Copy-Tree $BuilderData (Join-Path $Stage 'data')
}

# Import probes create bytecode in the bootstrap directory. Release inputs are
# source-only; remove generated caches before verification/archive inventory.
Get-ChildItem (Join-Path $Stage 'runtime\python-bootstrap') -Directory -Filter '__pycache__' -Recurse -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
# Clear __pycache__ across the whole packaged data tree. builder\data mirrors
# the shipped data layout (memories, skills, ...), so any seed that carries a
# .py script could have generated bytecode — clean the entire data root rather
# than enumerating seed subdirectories (adding a seed never needs a new cleanup
# line). The hermes-agent checkout is cleaned again after the web UI build stamp
# step below, which re-imports hermes_cli and regenerates __pycache__ there.
$PackagedDataRoot = Join-Path $Stage 'data'
if (Test-Path $PackagedDataRoot) {
    Get-ChildItem $PackagedDataRoot -Directory -Filter '__pycache__' -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force
}

Invoke-NativeChecked 'Portable Python contract test' { Test-PortablePythonContract $Stage | Out-Host }
Invoke-NativeChecked 'Portable non-editable install contract test' { Test-PortableNoEditableInstall $Stage | Out-Host }
Invoke-NativeChecked 'Verify-Portable' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Stage 'scripts\Verify-Portable.ps1') | Out-Host }

# The Verify probes run `hermes-cli --version`, whose update check runs
# `git fetch origin main` inside the packaged checkout — on a working network
# this drags hundreds of MB of new history into the packaged .git (and an
# interrupted fetch leaves a tmp_pack_*). Reset the packaged .git to the
# pristine upstream copy so the release ships the frozen state, then restore
# the repository-local config the build relies on.
$PackedGit = Join-Path $Stage 'data\hermes-home\hermes-agent\.git'
Remove-TreeSafe $PackedGit
Copy-Tree (Join-Path $Repo '.git') $PackedGit
Invoke-NativeChecked 'Packed git config longpaths' { & git.exe -C $Checkout config core.longpaths true }
Invoke-NativeChecked 'Packed git config autocrlf' { & git.exe -C $Checkout config core.autocrlf false }
Invoke-NativeChecked 'Packed git config eol' { & git.exe -C $Checkout config core.eol lf }
# The staged working tree was robocopy-copied from upstream and may carry
# CRLF bytes while the index (with autocrlf=false above) expects LF. git's
# stat cache then hides the mismatch until the ZIP is extracted on another
# machine (mtime changes -> full re-hash -> thousands of "M" entries, which
# trips the update's "local changes detected" stash prompt). It also carries
# a stale index: build-time patches were git-add'ed into upstream's index, so
# copying .git brings that dirt along. Rebuild index + working tree from HEAD
# (rm --cached forces reset to rewrite every file, bypassing the stat cache).
Invoke-NativeChecked 'Packaged checkout git rm --cached' { & git.exe -C $Checkout rm -r --cached --quiet . }
Invoke-NativeChecked 'Packaged checkout reset --hard' { & git.exe -C $Checkout reset --hard --quiet }
$packagedStatus = Invoke-NativeChecked 'Packaged checkout status' { & git.exe -C $Checkout status --porcelain }
if ($packagedStatus) {
    throw "Packaged checkout is not clean (line-ending or stale-index mismatch?): $packagedStatus"
}
# Probe-generated caches must not ship either.
Remove-Item (Join-Path $Stage 'data\hermes-home\models_dev_cache.json') -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $Stage 'data\hermes-home\models_dev_cache.json')) {
    throw 'Probe cache could not be removed from the release.'
}
Get-ChildItem (Join-Path $Stage 'runtime\python-bootstrap') -Directory -Filter '__pycache__' -Recurse -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force

# Remove interrupted git repack leftovers (tmp_pack_*) from the packaged .git:
# a git maintenance/repack started in the staged checkout can be killed by the
# build environment, leaving a tmp_pack_* that inflates the archive by hundreds
# of MB of garbage. Git treats tmp packs as safe to delete — the objects they
# carry are already in the object store (the originals are only removed after
# a repack finalizes).
Get-ChildItem (Join-Path $Stage 'data\hermes-home\hermes-agent\.git\objects\pack\tmp_pack_*') -ErrorAction SilentlyContinue | Remove-Item -Force



# Write the web UI build stamp (content hash of web/ source) so a packaged
# `hermes dashboard` skips the runtime npm install + rebuild on first launch
# — same offline-first contract as the TUI bundle. MUST be the LAST step that
# can change the hashed inputs (web/ + package.json + package-lock.json):
# the first staged `git reset`/`clean` keeps robocopy-copied CRLF bytes (git's
# stat cache skips the rewrite), and only the later `git rm --cached` +
# `reset --hard` (line-ending fix above) rewrites tracked files to LF — the
# stamp written before that point hashes CRLF content and mismatches on the
# user's first launch (triggering a runtime npm install + rebuild). The stamp
# must be produced by the same code that reads it
# (hermes_cli.main._write_web_ui_build_stamp), so run it through the staged
# venv against the final staged checkout.
$StageHome = Join-Path $Stage 'data\hermes-home'
$StageVenvPython = Join-Path $Checkout 'venv\Scripts\python.exe'
$oldHermesHome = $env:HERMES_HOME
$oldPythonPath = $env:PYTHONPATH
try {
    $env:HERMES_HOME = $StageHome
    $env:PYTHONPATH = "$Checkout;$env:PYTHONPATH"
    Invoke-NativeChecked 'Web UI build stamp' { & $StageVenvPython -c "from pathlib import Path; from hermes_cli.main import _write_web_ui_build_stamp; _write_web_ui_build_stamp(Path(r'$Checkout'), Path(r'$Checkout\web'))" }
} finally {
    $env:HERMES_HOME = $oldHermesHome
    $env:PYTHONPATH = $oldPythonPath
}

# Remove any __pycache__ directories generated by the verification probes
# inside the hermes-agent source tree — they are regenerated on first launch.
# This MUST run AFTER the web UI build stamp step: that step imports
# hermes_cli through the staged venv (PYTHONPATH points at the checkout) and
# re-creates __pycache__ under the source tree, so a cleanup placed before it
# would let fresh .pyc files slip into the archive (observed 2026-08-05:
# archive shipped hermes-agent/.../__pycache__/*.pyc stamped right before ZIP
# creation).
Get-ChildItem $Checkout -Directory -Filter '__pycache__' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

if ($SkipArchive) {
    Write-Host "Portable directory built (archive skipped): $Stage"
} else {
    New-Item -ItemType Directory -Force $Dist | Out-Null
    $buildTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zip = Join-Path $Dist "Hermes-Agent-Desktop-Portable-$hermesVersion-win-x64-$buildTimestamp.zip"
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    # 7za.exe normally ships inside the repo (assets\7zip). If it is
    # missing (cloned without the asset, deleted, ...), restore it from the
    # official 7-Zip site instead of failing: download the "extra" package
    # (7z format) plus the standalone 7zr.exe (which can read 7z), unpack
    # x64\7za.exe, and back-fill the cache.
    $sevenZip = Join-Path $Builder 'assets\7zip\7za.exe'
    if (-not (Test-Path $sevenZip)) {
        Write-Host "7za.exe missing from assets; downloading 7-Zip extra package to restore it..."
        $extraUrl = 'https://www.7-zip.org/a/7z2602-extra.7z'
        $sevenZrUrl = 'https://www.7-zip.org/a/7zr.exe'
        $extra = Join-Path $env:TEMP '7z2602-extra.7z'
        $sevenZr = Join-Path $env:TEMP '7zr.exe'
        $sevenZipDir = Split-Path $sevenZip -Parent
        New-Item -ItemType Directory -Force $sevenZipDir | Out-Null
        try {
            # Both downloads can be flaky; retry up to 3 times each.
            $downloaded = $false
            for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
                try {
                    Invoke-WebRequest -Uri $extraUrl -OutFile $extra -UseBasicParsing -TimeoutSec 300
                    Invoke-WebRequest -Uri $sevenZrUrl -OutFile $sevenZr -UseBasicParsing -TimeoutSec 300
                    if ((Get-Item $extra).Length -ge 1000000 -and (Get-Item $sevenZr).Length -ge 100000) { $downloaded = $true }
                    else { throw '7-Zip downloads too small.' }
                } catch {
                    if ($attempt -eq 3) { throw }
                    Write-Host "7-Zip download attempt $attempt failed; retrying in 5s..."
                    Start-Sleep -Seconds 5
                }
            }
            $extract = Join-Path $env:TEMP 'hermes-portable-7zip-bootstrap'
            Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force $extract | Out-Null
            & $sevenZr x $extra "-o$extract" -y | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $extract 'x64\7za.exe'))) { throw '7-Zip extra package extraction failed.' }
            Copy-Item (Join-Path $extract 'x64\7za.exe') $sevenZip -Force
            Write-Host "Restored 7za.exe to assets: $sevenZip"
        } finally {
            Remove-Item $extra,$sevenZr -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $env:TEMP 'hermes-portable-7zip-bootstrap') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path $sevenZip)) { throw "7za.exe is required for long-path-safe ZIP creation: $sevenZip" }
    Push-Location $StageParent
    try {
        # -tzip with no -mx uses 7-Zip's default compression level (5, Normal);
        # deliberately not -mx=7 (Maximum) — 32k+ files compress at near-default
        # speed with only marginally larger output, and default is faster.
        Invoke-NativeChecked 'ZIP creation' { & $sevenZip a -tzip $zip 'Hermes-Agent-Desktop-Portable' }
    } finally { Pop-Location }
    if (-not (Test-Path $zip)) { throw 'ZIP creation failed.' }
    Write-Host "Portable release built: $zip"
}
