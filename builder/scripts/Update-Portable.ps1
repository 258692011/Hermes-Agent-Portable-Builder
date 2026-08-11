param(
    [Parameter(Mandatory = $true)][ValidateSet('Patch', 'PatchRemove', 'SyncDesktop')][string]$Stage,
    # Patch / PatchRemove stages (RepoPath = build-time mode; PortableRoot = deployed mode)
    [string]$PortableRoot = '',
    [string]$RepoPath = '',
    # SyncDesktop stage
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
if ((Split-Path $Root -Leaf) -eq 'hermes-portable-builder') { $Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Root)) }
$HermesHome = Join-Path $Root 'data\hermes-home'
$Repo = Join-Path $HermesHome 'hermes-agent'

function Remove-TreeBestEffort([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        $drive = 'W:'
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

# =====================================================================
# Stage: Patch / PatchRemove — Portable 桌面源码补丁生命周期
# =====================================================================
function Apply-PortablePatch {
    param([switch]$Remove)

    # Repo resolution mirrors the original standalone script's three modes:
    # 1) -RepoPath (build-time): patch that checkout directly
    # 2) -PortableRoot (deployed): patch <root>\data\hermes-home\hermes-agent
    # 3) neither (manual run from builder\scripts): auto-detect builder\upstream
    #    when present, else fall back to the deployed checkout next to us.
    if ($RepoPath) {
        $patchRepo = [IO.Path]::GetFullPath($RepoPath)
    } elseif ($PortableRoot) {
        $patchRepo = Join-Path ([IO.Path]::GetFullPath($PortableRoot)) 'data\hermes-home\hermes-agent'
    } else {
        $candidate = [IO.Path]::GetFullPath((Join-Path $ToolsDir '..\..'))
        $candidateRepo = Join-Path $candidate 'upstream'
        if (Test-Path (Join-Path $candidateRepo 'apps\desktop\electron\main.ts')) {
            $patchRepo = $candidateRepo
        } else {
            $patchRepo = $Repo
        }
    }
    $Main = Join-Path $patchRepo 'apps\desktop\electron\main.ts'
    $Zoom = Join-Path $patchRepo 'apps\desktop\electron\zoom.ts'
    $ZoomTest = Join-Path $patchRepo 'apps\desktop\electron\zoom.test.ts'
    if (-not (Test-Path $Main) -or -not (Test-Path $Zoom) -or -not (Test-Path $ZoomTest)) {
        if ($Remove) {
            Write-Host 'Portable Desktop source patch is already absent (Desktop source not present).'
            exit 0
        }
        throw "Desktop main.ts not found: $Main"
    }

    $startMarker = '// HERMES_PORTABLE_PATCH_BEGIN'
    $endMarker = '// HERMES_PORTABLE_PATCH_END'
    $zoomOwnershipMarker = '// HERMES_PORTABLE_ZOOM_PATCH_OWNED'
    $backendPatch1Begin = '// HERMES_PORTABLE_BACKEND_1_BEGIN'
    $backendPatch1End = '// HERMES_PORTABLE_BACKEND_1_END'
    $backendPatch2Begin = '// HERMES_PORTABLE_BACKEND_2_BEGIN'
    $backendPatch2End = '// HERMES_PORTABLE_BACKEND_2_END'
    $backendNeedle1 = '  const command = IS_WINDOWS && fileExists(venvPython) ? venvPython : python'
    $backendNeedle2 = '  const command = fileExists(venvPython) ? venvPython : findSystemPython()'
    $backendBlock1 = @"
$backendPatch1Begin
// Portable: the packaged venv trampoline records the builder's build-tree
// python in pyvenv.cfg home, which CPython requires to exist, so it is not
// relocatable. The portable launcher sets HERMES_DESKTOP_PYTHON to the
// bundled runtime python; prefer it over the venv trampoline (wrapper).
const portablePython = process.env.HERMES_DESKTOP_PYTHON && fileExists(process.env.HERMES_DESKTOP_PYTHON) ? process.env.HERMES_DESKTOP_PYTHON : null
const command = portablePython ?? (IS_WINDOWS && fileExists(venvPython) ? venvPython : python)
$backendPatch1End
"@.Trim()
    $backendBlock2 = @"
$backendPatch2Begin
// Portable: same rationale as the createPythonBackend hunk.
const portablePython = process.env.HERMES_DESKTOP_PYTHON && fileExists(process.env.HERMES_DESKTOP_PYTHON) ? process.env.HERMES_DESKTOP_PYTHON : null
const command = portablePython ?? (fileExists(venvPython) ? venvPython : findSystemPython())
$backendPatch2End
"@.Trim()
    function Read-NormalizedText {
        param([string]$Path)
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
        @{ Text = $raw.Replace("`r`n", "`n"); Eol = $eol }
    }

    function Write-TextWithOriginalEol {
        param([string]$Path, [string]$Text, [string]$Eol)
        # Re-normalize defensively so a stray CRLF can never become CRCRLF,
        # then restore the file's original line endings.
        $Text = $Text.Replace("`r`n", "`n")
        if ($Eol -eq "`r`n") { $Text = $Text.Replace("`n", "`r`n") }
        [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
    }

    $mainInfo = Read-NormalizedText $Main
    $text = $mainInfo.Text
    $mainEol = $mainInfo.Eol
    $zoomInfo = Read-NormalizedText $Zoom
    $zoomText = $zoomInfo.Text
    $zoomEol = $zoomInfo.Eol
    $zoomTestInfo = Read-NormalizedText $ZoomTest
    $zoomTestText = $zoomTestInfo.Text
    $zoomTestEol = $zoomTestInfo.Eol
    $officialZoom = 'Math.log(0.9) / Math.log(ZOOM_FACTOR_BASE)'
    $portableZoom = 'Math.log(1.0) / Math.log(ZOOM_FACTOR_BASE)'
    $changesZoomDefault = -not $zoomText.Contains($portableZoom)
    $officialZoomRestore = "win.webContents.on('did-finish-load', () => restorePersistedZoomLevel(win))"
    $portableZoomRestore = @'
win.webContents.on('did-finish-load', () => {
      restorePersistedZoomLevel(win)
      // Chromium can reset zoom to 100% shortly after the first packaged load.
      // Re-read the user's persisted value once after initialization settles.
      setTimeout(() => restorePersistedZoomLevel(win), 250)
    })
'@.Trim()

    function Refresh-PortableGitIndex {
        param([switch]$Skip)
        if ($Skip) { return }
        $repo = $patchRepo
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if (-not $git -or -not (Test-Path (Join-Path $repo '.git'))) { return }

        Invoke-NativeChecked 'git config core.longpaths' { & $git.Source -C $repo config core.longpaths true }
        Invoke-NativeChecked 'git config core.autocrlf' { & $git.Source -C $repo config core.autocrlf false }
        Invoke-NativeChecked 'git config core.eol' { & $git.Source -C $repo config core.eol lf }

        # ZIP extraction on Windows can make every LF-tracked file appear modified
        # only because its working-tree bytes are CRLF. Normalize only when there
        # are no substantive or staged changes, so real user edits are never staged.
        Invoke-NativeChecked 'git diff --cached --quiet' -AllowFailure { & $git.Source -C $repo diff --cached --quiet }
        $cachedClean = ($LASTEXITCODE -eq 0)
        Invoke-NativeChecked 'git diff --ignore-space-at-eol --quiet' -AllowFailure { & $git.Source -C $repo diff --ignore-space-at-eol --quiet }
        $contentClean = ($LASTEXITCODE -eq 0)
        if ($cachedClean -and $contentClean) {
            Invoke-NativeChecked 'git add --renormalize' { & $git.Source -C $repo add --renormalize . }
            Invoke-NativeChecked 'git reset --mixed HEAD' { & $git.Source -C $repo reset --mixed HEAD | Out-Null }
        }
    }

    if ($Remove) {
        $ownsZoomPatch = $text.Contains($zoomOwnershipMarker)
        $start = $text.IndexOf($startMarker, [System.StringComparison]::Ordinal)
        if ($start -ge 0) {
            $end = $text.IndexOf($endMarker, $start, [System.StringComparison]::Ordinal)
            if ($end -lt 0) { throw 'Portable patch end marker was not found.' }
            $end += $endMarker.Length
            while ($end -lt $text.Length -and ($text[$end] -eq "`r" -or $text[$end] -eq "`n")) { $end++ }
            $text = $text.Remove($start, $end - $start)
            if ($text.Contains($backendPatch1Begin)) {
                if (-not $text.Contains($backendBlock1)) { throw 'Portable backend patch 1 block was not found.' }
                $text = $text.Replace($backendBlock1, $backendNeedle1)
            }
            if ($text.Contains($backendPatch2Begin)) {
                if (-not $text.Contains($backendBlock2)) { throw 'Portable backend patch 2 block was not found.' }
                $text = $text.Replace($backendBlock2, $backendNeedle2)
            }
            Write-TextWithOriginalEol $Main $text $mainEol
        }
        if ($ownsZoomPatch -and $zoomText.Contains($portableZoom)) {
            $zoomText = $zoomText.Replace($portableZoom, $officialZoom)
            Write-TextWithOriginalEol $Zoom $zoomText $zoomEol
        }
        if ($text.Contains($portableZoomRestore)) {
            $text = $text.Replace($portableZoomRestore, $officialZoomRestore)
            Write-TextWithOriginalEol $Main $text $mainEol
        }
        $portableTestBlock = @'
test('default zoom matches the Portable Appearance 100% preset', () => {
  assert.equal(ZOOM_STEP, 0.1)
  assert.equal(zoomLevelToPercent(DEFAULT_ZOOM_LEVEL), 100)
  assert.equal(DEFAULT_ZOOM_LEVEL, percentToZoomLevel(100))
})
'@.Trim()
        $officialTestBlock = @'
test('default zoom matches the Appearance 90% preset', () => {
  assert.equal(ZOOM_STEP, 0.1)
  assert.equal(zoomLevelToPercent(DEFAULT_ZOOM_LEVEL), 90)
  assert.equal(DEFAULT_ZOOM_LEVEL, percentToZoomLevel(90))
})
'@.Trim()
        if ($ownsZoomPatch) {
            $zoomTestText = $zoomTestText.Replace($portableTestBlock, $officialTestBlock)
            Write-TextWithOriginalEol $ZoomTest $zoomTestText $zoomTestEol
        }
        Refresh-PortableGitIndex -Skip:(-not $PortableRoot)
        Write-Host "Portable Desktop source patch removed before official update: $Main"
        exit 0
    }

    if ($text.Contains($startMarker) -and $text.Contains($portableZoomRestore) -and $zoomText.Contains($portableZoom)) {
        Write-Host 'Portable Desktop source patch already applied.'
        exit 0
    }

    $needle = "const USER_DATA_OVERRIDE = process.env.HERMES_DESKTOP_USER_DATA_DIR"
    if (-not $text.Contains($needle)) { throw 'Portable patch insertion point was not found.' }

    $block = @'
// HERMES_PORTABLE_PATCH_BEGIN
// A marker beside the packed executable makes direct app\Hermes.exe launches
// portable too. Explicit environment overrides from the root launcher win.
if (process.platform === 'win32') {
  const executableDir = path.dirname(process.execPath)
  const marker = path.join(executableDir, 'portable.marker')

  if (fs.existsSync(marker)) {
    const portableRoot = path.resolve(executableDir, '..')
    const portableHome = path.join(portableRoot, 'data', 'hermes-home')
    const portableGit = path.join(portableHome, 'git')
    const portableConfig = path.join(portableHome, 'config.yaml')
    if (!fs.existsSync(portableConfig)) {
      fs.mkdirSync(portableHome, { recursive: true })
      try {
        fs.writeFileSync(portableConfig, 'display:\n  language: zh\n', { encoding: 'utf8', flag: 'wx' })
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      }
    }
    const portableEntries = [
      path.join(portableHome, 'hermes-agent', 'venv', 'Scripts'),
      path.join(portableHome, 'node'),
      path.join(portableGit, 'cmd'),
      path.join(portableGit, 'bin'),
      path.join(portableGit, 'usr', 'bin'),
      path.join(portableRoot, 'runtime', 'bin')
    ]

    process.env.HERMES_HOME ||= portableHome
    process.env.HERMES_DESKTOP_USER_DATA_DIR ||= path.join(portableRoot, 'data', 'electron-user-data')
    process.env.HERMES_DESKTOP_HERMES ||= path.join(portableRoot, 'runtime', 'bin', 'hermes-cli.cmd')
    process.env.HERMES_DESKTOP_HERMES_ROOT ||= path.join(portableHome, 'hermes-agent')
    process.env.HERMES_GIT_BASH_PATH ||= path.join(portableGit, 'bin', 'bash.exe')
    process.env.UV_PYTHON_INSTALL_DIR ||= path.join(portableRoot, 'runtime', 'python')
    process.env.UV_PYTHON_INSTALL_BIN ||= '0'
    process.env.UV_PYTHON_INSTALL_REGISTRY ||= '0'
    process.env.HERMES_PORTABLE_SITE_PACKAGES ||= path.join(portableHome, 'hermes-agent', 'venv', 'Lib', 'site-packages')
    // Mirror the root launcher (Hermes-Desktop.cs): pin the backend to the
    // bundled runtime python via current.txt so the venv trampoline (whose
    // pyvenv.cfg home records the builder's build tree) is never used.
    try {
      const pythonPointer = path.join(portableRoot, 'runtime', 'python', 'current.txt')
      const pythonDir = fs.readFileSync(pythonPointer, 'utf8').trim()
      if (pythonDir) {
        const pythonExe = path.join(portableRoot, 'runtime', 'python', pythonDir, 'python.exe')
        if (fs.existsSync(pythonExe)) {
          process.env.HERMES_DESKTOP_PYTHON ||= pythonExe
        }
      }
    } catch (error) {}
    process.env.PYTHONPATH = [
      path.join(portableRoot, 'runtime', 'python-bootstrap'),
      path.join(portableHome, 'hermes-agent'),
      process.env.PYTHONPATH
    ].filter(Boolean).join(path.delimiter)
    process.env.PATH = [...portableEntries, process.env.PATH].filter(Boolean).join(path.delimiter)
  }
}
// HERMES_PORTABLE_PATCH_END

'@

    if (-not $text.Contains($startMarker)) {
        if ($changesZoomDefault) {
            if (-not $zoomText.Contains($officialZoom)) {
                throw 'Portable zoom default insertion point was not found.'
            }
            $block = $block.Replace($startMarker, $startMarker + "`n" + $zoomOwnershipMarker)
        }
        $text = $text.Replace($needle, $block + $needle)
        Write-TextWithOriginalEol $Main $text $mainEol
    }
    if (-not $zoomText.Contains($officialZoom) -and -not $zoomText.Contains($portableZoom)) {
        throw 'Portable zoom default insertion point was not found.'
    }
    if (-not $text.Contains($officialZoomRestore) -and -not $text.Contains($portableZoomRestore)) {
        throw 'Portable delayed zoom restore insertion point was not found.'
    }
    $text = $text.Replace($officialZoomRestore, $portableZoomRestore)
    if (-not $text.Contains($backendPatch1Begin)) {
        if (-not $text.Contains($backendNeedle1)) { throw 'Portable backend patch 1 insertion point was not found.' }
        $text = $text.Replace($backendNeedle1, $backendBlock1)
    }
    if (-not $text.Contains($backendPatch2Begin)) {
        if (-not $text.Contains($backendNeedle2)) { throw 'Portable backend patch 2 insertion point was not found.' }
        $text = $text.Replace($backendNeedle2, $backendBlock2)
    }
    Write-TextWithOriginalEol $Main $text $mainEol
    if ($changesZoomDefault) {
        $zoomText = $zoomText.Replace($officialZoom, $portableZoom)
        Write-TextWithOriginalEol $Zoom $zoomText $zoomEol
    }
    $officialTestBlock = @'
test('default zoom matches the Appearance 90% preset', () => {
  assert.equal(ZOOM_STEP, 0.1)
  assert.equal(zoomLevelToPercent(DEFAULT_ZOOM_LEVEL), 90)
  assert.equal(DEFAULT_ZOOM_LEVEL, percentToZoomLevel(90))
})
'@.Trim()
    $portableTestBlock = @'
test('default zoom matches the Portable Appearance 100% preset', () => {
  assert.equal(ZOOM_STEP, 0.1)
  assert.equal(zoomLevelToPercent(DEFAULT_ZOOM_LEVEL), 100)
  assert.equal(DEFAULT_ZOOM_LEVEL, percentToZoomLevel(100))
})
'@.Trim()
    if ($changesZoomDefault) {
        $zoomTestText = $zoomTestText.Replace($officialTestBlock, $portableTestBlock)
        Write-TextWithOriginalEol $ZoomTest $zoomTestText $zoomTestEol
    }
    Write-Host "Portable Desktop source patch applied (default zoom 100%): $Main"
}

# =====================================================================
# Stage: SyncDesktop — 重建 Desktop/TUI/Web 并原子交换 app
# =====================================================================
function Sync-PortableDesktop {
    $Python = Join-Path $Repo 'venv\Scripts\python.exe'
    $BuiltApp = Join-Path $Repo 'apps\desktop\release\win-unpacked'
    $LiveApp = Join-Path $Root 'app'
    $NextApp = Join-Path $Root 'app.portable-next'
    $OldApp = Join-Path $Root 'app.portable-old'

    Stop-RootProcesses

    if (-not $SkipBuild) {
        if (-not (Test-Path $Python)) { throw 'Portable venv is missing. Run scripts\Repair-Portable.ps1 first.' }
        $PatchScript = Join-Path $ToolsDir 'Update-Portable.ps1'
        Invoke-NativeChecked 'Applying the Portable Desktop source patch' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PatchScript -Stage Patch -PortableRoot $Root }
        Set-PortableEnvironment

        Write-Host 'Building the latest official Hermes Desktop...'
        Invoke-NativeChecked 'Desktop build' { & $Python -m hermes_cli.main desktop --build-only --force-build }
        # npm version follows the official floor (repo package.json engines.npm);
        # the node distribution's bundled npm does not track it. Parse the highest
        # ">=" constraint and upgrade when the packaged npm is below that floor.
        $npmCmd = Join-Path $HermesHome 'node\npm.cmd'
        if (Test-Path $npmCmd) {
            $npmReq = $null
            try { $npmReq = (Get-Content (Join-Path $Repo 'package.json') -Raw | ConvertFrom-Json).engines.npm } catch { }
            if ($npmReq) {
                $best = [version]'0.0.0'
                $matches = [regex]::Matches($npmReq, '>=(\d+\.\d+\.\d+)')
                foreach ($m in $matches) {
                    $v = [version]$m.Groups[1].Value
                    if ($v -gt $best) { $best = $v }
                }
                if ($best -ne [version]'0.0.0') {
                    $cur = [version]((& $npmCmd --version 2>$null).Trim())
                    if ($cur -lt $best) {
                        Write-Host "Upgrading packaged npm to match official requirement ($npmReq, floor >=$best)..."
                        Invoke-NativeChecked "Packaged npm upgrade to npm@$($best.Major)" { & $npmCmd install --prefix (Split-Path $npmCmd -Parent) "npm@$($best.Major)" --no-fund --no-audit --progress=false }
                        Write-Host "Packaged npm now $((& $npmCmd --version 2>$null).Trim()) (official requires $npmReq)."
                    }
                }
            }
        }
        # Prebuilt TUI bundle: ship hermes_cli/tui_dist/entry.js so the first
        # TUI launch never runs npm install, and rebuild it after every source
        # update so the bundle always matches the checked-out ui-tui source. On
        # failure, drop any stale bundle so the TUI falls back to a first-launch
        # install from the current source instead of running an old bundle.
        $tuiDistDir = Join-Path $Repo 'hermes_cli\tui_dist'
        try {
            Push-Location $Repo
            try {
                Invoke-NativeChecked 'TUI workspace install' { & npm.cmd install --workspace ui-tui --include=dev --silent --no-fund --no-audit --progress=false }
                Push-Location (Join-Path $Repo 'ui-tui')
                try {
                    Invoke-NativeChecked 'TUI bundle build' { & npm.cmd run build }
                } finally {
                    Pop-Location
                }
            } finally {
                Pop-Location
            }
            New-Item -ItemType Directory -Force $tuiDistDir | Out-Null
            Copy-Item (Join-Path $Repo 'ui-tui\dist\entry.js') (Join-Path $tuiDistDir 'entry.js') -Force
            # npm install --workspace ui-tui can "complete" the committed lockfile
            # (npm >=10 re-resolves scoped peer deps and adds entries). Restore it
            # so the embedded checkout stays clean for the next update gate.
            if (Test-Path (Join-Path $Repo '.git')) {
                & git.exe -C $Repo checkout -- package-lock.json 2>$null | Out-Null
            }
            Write-Host "Prebuilt TUI bundle: $tuiDistDir\entry.js"
        } catch {
            Remove-TreeBestEffort $tuiDistDir
            Write-Warning "TUI bundle build failed ($($_.Exception.Message)); removed stale bundle — first TUI launch will npm install from source."
        }
    }

    # Prebuilt Web bundle (same contract as TUI): ship hermes_cli/web_dist so
    # `hermes dashboard` serves the real browser UI, and rebuild it after every
    # source update so the bundle matches the checked-out web/ source. On
    # failure, drop any stale bundle so the dashboard fails explicitly
    # ("Frontend not built") instead of serving a mismatched old UI.
    $webDistDir = Join-Path $Repo 'hermes_cli\web_dist'
    try {
        Push-Location $Repo
        try {
            Invoke-NativeChecked 'Web workspace install' { & npm.cmd install --workspace web --include=dev --silent --no-fund --no-audit --progress=false }
            Push-Location (Join-Path $Repo 'web')
            try {
                Invoke-NativeChecked 'Web bundle build' { & npm.cmd run build }
            } finally {
                Pop-Location
            }
        } finally {
            Pop-Location
        }
        # npm install --workspace web can "complete" the committed root lockfile
        # (npm >=10 re-resolves scoped peer deps). Restore it so the embedded
        # checkout stays clean for the next update gate.
        if (Test-Path (Join-Path $Repo '.git')) {
            & git.exe -C $Repo checkout -- package-lock.json 2>$null | Out-Null
        }
        Write-Host "Prebuilt Web bundle: $webDistDir\index.html"
        # Write the web UI build stamp so the next dashboard launch skips the
        # runtime npm install + rebuild (offline-first contract, same as TUI).
        # Non-fatal: a missing stamp only costs one rebuild, while deleting the
        # good bundle below would break the dashboard outright.
        try {
            $env:HERMES_HOME = $HermesHome
            $env:PYTHONPATH = "$Repo;$env:PYTHONPATH"
            Invoke-NativeChecked 'Web UI build stamp' { & $Python -c "from pathlib import Path; from hermes_cli.main import _write_web_ui_build_stamp; _write_web_ui_build_stamp(Path(r'$Repo'), Path(r'$Repo\web'))" }
        } catch {
            Write-Warning "Web UI build stamp failed ($($_.Exception.Message)); first dashboard launch after update will rebuild the frontend once."
        }
    } catch {
        Remove-TreeBestEffort $webDistDir
        Write-Warning "Web bundle build failed ($($_.Exception.Message)); removed stale bundle — dashboard will report 'Frontend not built' until the next full build."
    }

    $BuiltExe = Join-Path $BuiltApp 'Hermes.exe'
    if (-not (Test-Path $BuiltExe)) { throw "Built Desktop was not found: $BuiltExe" }
    if ((Get-Item $BuiltExe).Length -lt 50MB) { throw 'Built Hermes.exe is unexpectedly small.' }

    Remove-TreeBestEffort $NextApp
    New-Item -ItemType Directory -Force $NextApp | Out-Null
    robocopy $BuiltApp $NextApp /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying Desktop build failed with robocopy exit code $LASTEXITCODE" }
    New-Item -ItemType File -Force (Join-Path $NextApp 'portable.marker') | Out-Null
    if (-not (Test-Path (Join-Path $NextApp 'Hermes.exe'))) { throw 'Staged Portable Desktop is incomplete.' }

    Remove-TreeBestEffort $OldApp
    if (Test-Path $LiveApp) { Rename-Item $LiveApp (Split-Path $OldApp -Leaf) }
    try {
        Rename-Item $NextApp (Split-Path $LiveApp -Leaf)
        Remove-TreeBestEffort $OldApp
    } catch {
        Remove-TreeBestEffort $LiveApp
        if (Test-Path $OldApp) { Rename-Item $OldApp 'app' }
        throw
    }

    Write-Host "Portable Desktop synchronized: $LiveApp"

    # The live app owns the compiled patch, so restore the embedded checkout to a
    # pristine state: a direct `hermes update` (outside Update.exe) then never hits
    # the "Restore local changes now? [Y/n]" stash prompt. Idempotent — a no-op
    # when the patch is already absent (e.g. under -SkipBuild). Update.exe's own
    # pre-update -Remove stays as a safety net for patches from other sources.
    Invoke-NativeChecked 'Removing the Portable Desktop source patch' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ToolsDir 'Update-Portable.ps1') -Stage PatchRemove -PortableRoot $Root }

    # The live app now owns the build output. Remove source-tree build caches so
    # the next official update does not rebuild Desktop once before this script,
    # and so the Portable directory does not retain gigabytes of temporary files.
    Remove-TreeBestEffort (Join-Path $Repo 'node_modules')
    Remove-TreeBestEffort (Join-Path $Repo 'apps\desktop\release')
    Remove-TreeBestEffort (Join-Path $Repo 'apps\desktop\dist')
    Write-Host 'Temporary Desktop build caches removed.'
}

switch ($Stage) {
    'Patch'       { Apply-PortablePatch }
    'PatchRemove' { Apply-PortablePatch -Remove }
    'SyncDesktop' { Sync-PortableDesktop }
}
