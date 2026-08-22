param(
    [Parameter(Mandatory = $true)][ValidateSet('Patch', 'PatchRemove', 'SyncDesktop', 'WriteDesktopStamp')][string]$Stage,
    # Patch / PatchRemove stages (RepoPath = build-time mode; PortableRoot = deployed mode)
    [string]$PortableRoot = '',
    [string]$RepoPath = '',
    # SyncDesktop stage
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$HermesHome = Join-Path $Root 'data\hermes-home'
$Repo = Join-Path $HermesHome 'hermes-agent'

function Remove-TreeBestEffort([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        # Fixed drive letters are dangerous: if W: is already mapped (network
        # drive, subst, USB), cmd rd would land on THAT drive's content.
        # Enumerate free candidates and verify the subst actually took (2026-08-22).
        $parent = Split-Path $Path -Parent
        $leaf = Split-Path $Path -Leaf
        foreach ($letter in 'W','V','T','U','X','Y','Z','R') {
            if (Test-Path "${letter}:\") { continue }
            subst "${letter}:" $parent | Out-Null
            if (-not (Test-Path "${letter}:\")) { continue }
            try {
                cmd.exe /d /c "rd /s /q ${letter}:\$leaf" | Out-Null
            } finally {
                subst "${letter}:" /d | Out-Null
            }
            return
        }
        throw "Could not remove tree (no free drive letter for subst): $Path"
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
    $Translucency = Join-Path $patchRepo 'apps\shared\src\translucency.ts'
    if (-not (Test-Path $Main) -or -not (Test-Path $Zoom) -or -not (Test-Path $ZoomTest) -or -not (Test-Path $Translucency)) {
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
    # 7th portable patch: default translucency OFF, DRIFT-PROOF. The official
    # per-platform default lines in apps/shared/src/translucency.ts wash out
    # the light-theme UI (NousResearch/hermes-agent#92200; the official
    # per-platform macos/windows split landed later, 2026-08). BOTH the macos
    # block (light fade:1 'header' / dark fade:0 'titlebar') and the windows
    # block (light/dark fade:0 'under-window') are matched by STRUCTURE with
    # ANY intensity numbers (upstream may change them — the intent is always
    # "default translucency OFF"), and the ORIGINAL numbers are captured inside
    # the marker block ("was light N / dark M, windows light N / dark M") so
    # PatchRemove can restore them exactly even after upstream drifts.
    # NOTE: apps/shared is OUTSIDE the desktop content hash scope
    # (apps/desktop only, matching the official _compute_desktop_content_hash),
    # so this patch ships via full builds; a deployed SyncDesktop rebuild is
    # only forced when apps/desktop changes.
    $translucencyBegin = '// HERMES_PORTABLE_TRANSLUCENCY_BEGIN'
    $translucencyEnd = '// HERMES_PORTABLE_TRANSLUCENCY_END'
    # macos block: <indent>light: { intensity: <n>, fade: 1, material: 'header', scope: 'window' },
    #              <indent>dark:  { intensity: <n>, fade: 0, material: 'titlebar', scope: 'window' }
    # windows block: light/dark fade:0, material: 'under-window' (both)
    # Apply groups: 1=indentL+prefix, 2=macLightNum, 3=macLightTail+\n,
    #               4=indentD+prefix, 5=macDarkNum, 6=macDarkTail+separator,
    #               7=winIndentL+prefix, 8=winLightNum, 9=winLightTail+\n,
    #               10=winIndentD+prefix, 11=winDarkNum, 12=winDarkTail
    $translucencyPattern = '(?m)^(\s*light: \{ intensity: )(\d+)(, fade: 1, material: ''header'', scope: ''window'' \},\n)(\s*dark: \{ intensity: )(\d+)(, fade: 0, material: ''titlebar'', scope: ''window'' \}\n  \},\n  windows: \{\n)(\s*light: \{ intensity: )(\d+)(, fade: 0, material: ''under-window'', scope: ''window'' \},\n)(\s*dark: \{ intensity: )(\d+)(, fade: 0, material: ''under-window'', scope: ''window'' \})'
    # Full marker block for restore; captures the original numbers from the
    # comment plus the line pieces to rebuild the official four lines exactly.
    # Groups: 1=macLightOrig, 2=macDarkOrig, 3=winLightOrig, 4=winDarkOrig,
    #         5=indentL+prefix, 6=macLightZero, 7=macLightTail("},"),
    #         8=newline, 9=indentD+prefix, 10=macDarkZero,
    #         11=macDarkTail+separator, 12=winIndentL+prefix, 13=winLightZero,
    #         14=winLightTail("},"), 15=newline, 16=winIndentD+prefix,
    #         17=winDarkZero, 18=winDarkTail.
    $translucencyRestorePattern = '(?s)// HERMES_PORTABLE_TRANSLUCENCY_BEGIN.*?was light (\d+) / dark (\d+), windows light (\d+) / dark (\d+)[^\n]*\n(\s*light: \{ intensity: )(\d+)(, fade: 1, material: ''header'', scope: ''window'' \},)(\n)(\s*dark: \{ intensity: )(\d+)(, fade: 0, material: ''titlebar'', scope: ''window'' \}\n  \},\n  windows: \{\n)(\s*light: \{ intensity: )(\d+)(, fade: 0, material: ''under-window'', scope: ''window'' \},)(\n)(\s*dark: \{ intensity: )(\d+)(, fade: 0, material: ''under-window'', scope: ''window'' \})\s*// HERMES_PORTABLE_TRANSLUCENCY_END'
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
    $translucencyInfo = Read-NormalizedText $Translucency
    $translucencyText = $translucencyInfo.Text
    $translucencyEol = $translucencyInfo.Eol
    $officialZoom = 'Math.log(0.9) / Math.log(ZOOM_FACTOR_BASE)'
    $portableZoom = 'Math.log(1.0) / Math.log(ZOOM_FACTOR_BASE)'
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
            $before = $zoomTestText
            $zoomTestText = $zoomTestText.Replace($portableTestBlock, $officialTestBlock)
            # Fail loudly if upstream changed the test block: a silent no-op
            # would ship zoom.ts at 100% while the test still asserts 90%
            # (2026-08-22).
            if ($zoomTestText -eq $before -or $zoomTestText.Contains($portableTestBlock)) {
                throw 'Portable zoom.test.ts block was not found — upstream changed the test; review before patching.'
            }
            Write-TextWithOriginalEol $ZoomTest $zoomTestText $zoomTestEol
        }
        # Restore the official translucency defaults before an official update,
        # using the ORIGINAL numbers captured in the marker block — drift-proof
        # against upstream changing the values (2026-08-22).
        if ($translucencyText.Contains($translucencyBegin)) {
            $rm = [regex]::Match($translucencyText, $translucencyRestorePattern)
            if (-not $rm.Success) { throw 'Portable translucency default restore failed — marker block structure changed.' }
            $official = $rm.Groups[5].Value + $rm.Groups[1].Value + $rm.Groups[7].Value + $rm.Groups[8].Value +
                        $rm.Groups[9].Value + $rm.Groups[2].Value + $rm.Groups[11].Value +
                        $rm.Groups[12].Value + $rm.Groups[3].Value + $rm.Groups[14].Value + $rm.Groups[15].Value +
                        $rm.Groups[16].Value + $rm.Groups[4].Value + $rm.Groups[18].Value
            $translucencyText = $translucencyText.Substring(0, $rm.Index) + $official + $translucencyText.Substring($rm.Index + $rm.Length)
            Write-TextWithOriginalEol $Translucency $translucencyText $translucencyEol
        }
        Refresh-PortableGitIndex -Skip:(-not $PortableRoot)
        Write-Host "Portable Desktop source patch removed before official update: $Main"
        exit 0
    }

    if ($text.Contains($startMarker) -and $text.Contains($portableZoomRestore) -and $zoomText.Contains($portableZoom) -and $translucencyText.Contains($translucencyBegin)) {
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
    // Mirror the root launcher (Hermes.cs): pin the backend to the
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
        # Ownership marker is written ONLY when the official default is 90%
        # and the zoom default is actually rewritten to 100%. When the official
        # default is already 100% the rewrite is a no-op; marking it owned would
        # make PatchRemove wrongly revert 100% -> 90%.
        if ($zoomText.Contains($officialZoom)) {
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
    # Always normalize the zoom default to 100%. When the official default is
    # already 100% (portableZoom present), the Replace is a no-op.
    $zoomText = $zoomText.Replace($officialZoom, $portableZoom)
    Write-TextWithOriginalEol $Zoom $zoomText $zoomEol
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
    $zoomTestText = $zoomTestText.Replace($officialTestBlock, $portableTestBlock)
    Write-TextWithOriginalEol $ZoomTest $zoomTestText $zoomTestEol
    # 7th patch: translucency defaults -> 0/0, drift-proof — matched by
    # structure with ANY official numbers, originals captured in the marker
    # block for exact restore (2026-08-22).
    if (-not $translucencyText.Contains($translucencyBegin)) {
        $st = @{ matched = $false }
        $translucencyText = [regex]::Replace($translucencyText, $translucencyPattern, {
            param($m)
            $st.matched = $true
            return $translucencyBegin + "`n" +
                "// Portable: default translucency OFF (was light " + $m.Groups[2].Value + " / dark " + $m.Groups[5].Value + ", windows light " + $m.Groups[8].Value + " / dark " + $m.Groups[11].Value + ").`n" +
                $m.Groups[1].Value + '0' + $m.Groups[3].Value +
                $m.Groups[4].Value + '0' + $m.Groups[6].Value +
                $m.Groups[7].Value + '0' + $m.Groups[9].Value +
                $m.Groups[10].Value + '0' + $m.Groups[12].Value + "`n" +
                $translucencyEnd
        })
        if (-not $st.matched) { throw 'Portable translucency default block was not found (structure changed).' }
        Write-TextWithOriginalEol $Translucency $translucencyText $translucencyEol
    }
    Write-Host "Portable Desktop source patch applied (default zoom 100%, translucency off): $Main"
}

# =====================================================================
# =====================================================================
# Desktop incremental build support (2026-08-14): a source update that did
# not touch the desktop tree skips the expensive electron-builder rebuild.
# The content hash mirrors the official hermes_cli
# _compute_desktop_content_hash contract: every file under apps/desktop
# (git ls-files honours .gitignore, so node_modules/dist/release are
# excluded exactly like the official pathspec walk) plus the root
# package.json / package-lock.json (workspace dependency resolution).
# Build machine and deployed side both call these helpers, so the hash
# comparison is always apples-to-apples.
# =====================================================================
function Get-DesktopContentHash([string]$RepoDir) {
    $git = Join-Path (Split-Path $RepoDir -Parent) 'git\cmd\git.exe'
    if (-not (Test-Path $git)) { $git = 'git.exe' }
    # git ls-files honours .gitignore (node_modules/dist/release excluded
    # exactly like the official pathspec walk); --others --exclude-standard
    # adds untracked-but-not-ignored files so a stray source file changes the
    # hash just like the official directory walk would.
    $files = @(& $git -C $RepoDir ls-files -- apps/desktop 2>$null) +
             @(& $git -C $RepoDir ls-files --others --exclude-standard -- apps/desktop 2>$null) +
             @('package.json', 'package-lock.json')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sep = [byte[]](0)
    foreach ($rel in $files) {
        if (-not $rel) { continue }
        $bytes = [Text.Encoding]::UTF8.GetBytes($rel)
        $sha.TransformBlock($bytes, 0, $bytes.Length, $null, 0) | Out-Null
        $sha.TransformBlock($sep, 0, 1, $null, 0) | Out-Null
        $path = Join-Path $RepoDir ($rel -replace '/', '\')
        if (Test-Path $path) {
            $content = [IO.File]::ReadAllBytes($path)
            $sha.TransformBlock($content, 0, $content.Length, $null, 0) | Out-Null
        }
        $sha.TransformBlock($sep, 0, 1, $null, 0) | Out-Null
    }
    $sha.TransformFinalBlock([byte[]]@(), 0, 0) | Out-Null
    $hash = ''
    foreach ($b in $sha.Hash) { $hash += $b.ToString('x2') }
    return $hash
}

function Test-DesktopBuildStale([string]$RepoDir, [string]$HomeDir) {
    $stampFile = Join-Path $HomeDir 'desktop-build-stamp.json'
    if (-not (Test-Path $stampFile)) { return $true }
    try {
        $stamp = Get-Content $stampFile -Raw | ConvertFrom-Json
    } catch { return $true }
    if (-not $stamp.contentHash) { return $true }
    return ((Get-DesktopContentHash $RepoDir) -ne $stamp.contentHash)
}

function Write-DesktopBuildStamp([string]$RepoDir, [string]$HomeDir) {
    try {
        $stamp = @{
            contentHash = Get-DesktopContentHash $RepoDir
            sourceMode  = $true
            builtAt     = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json
        Set-Content -Path (Join-Path $HomeDir 'desktop-build-stamp.json') -Value $stamp -Encoding UTF8
    } catch {
        Write-Warning "Failed to write desktop build stamp: $($_.Exception.Message)"
    }
}

# Stage: SyncDesktop — 重建 Desktop/TUI/Web 并原子交换 app
# =====================================================================
function Sync-PortableDesktop {
    $Python = Join-Path $Repo 'venv\Scripts\python.exe'
    $BuiltApp = Join-Path $Repo 'apps\desktop\release\win-unpacked'
    $LiveApp = Join-Path $Root 'app'
    $NextApp = Join-Path $Root 'app.portable-next'
    $OldApp = Join-Path $Root 'app.portable-old'

    Stop-RootProcesses

    $needDesktopBuild = $true
    if (-not $SkipBuild) {
        if (-not (Test-Path $Python)) { throw 'Portable venv is missing. Run scripts\Repair-Portable.ps1 first.' }
        $PatchScript = Join-Path $ToolsDir 'Update-Portable.ps1'
        # Skip the expensive electron-builder rebuild when the source update
        # did not touch the desktop tree (content-hash stamp, see helpers
        # above; the stamp is written after a successful build + PatchRemove,
        # so the comparison always runs against pristine upstream source).
        $needDesktopBuild = Test-DesktopBuildStale $Repo $HermesHome
        if ($needDesktopBuild) {
            Invoke-NativeChecked 'Applying the Portable Desktop source patch' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PatchScript -Stage Patch -PortableRoot $Root }
            Set-PortableEnvironment

            Write-Host 'Building the latest official Hermes Desktop...'
            Invoke-NativeChecked 'Desktop build' { & $Python -m hermes_cli.main desktop --build-only --force-build }
        } else {
            Write-Host 'Desktop source unchanged since the last build; skipping electron-builder rebuild.'
        }
        # KEEP IN SYNC with Hermes.ps1 Ensure-OfficialNpm (same npm floor logic,\n        # deploy-time vs build-time; 2026-08-22 cross-reference).\n        # npm version follows the official floor (repo package.json engines.npm);
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
                    $npmOut = (& $npmCmd --version 2>$null)
                    if (-not $npmOut) {
                        Write-Host "WARNING: packaged npm --version returned nothing; skipping npm floor check (2026-08-22 null-guard)."
                    } else {
                        $cur = [version]$npmOut.Trim()
                        if ($cur -lt $best) {
                            Write-Host "Upgrading packaged npm to match official requirement ($npmReq, floor >=$best)..."
                            # Read the bundled corepack version BEFORE the upgrade:
                            # the npm install --prefix below prunes
                            # node_modules\corepack (verified 2026-08-14, leaving
                            # dead shims that fail with MODULE_NOT_FOUND), so
                            # afterwards reinstall exactly the version the official
                            # Node zip bundled — the version follows the Node
                            # archive automatically, no hardcoding.
                            $nodeDir = Split-Path $npmCmd -Parent
                            $corepackVersion = $null
                            $cpPkg = Join-Path $nodeDir 'node_modules\corepack\package.json'
                            if (Test-Path $cpPkg) { try { $corepackVersion = (Get-Content $cpPkg -Raw | ConvertFrom-Json).version } catch { } }
                            Invoke-NativeChecked "Packaged npm upgrade to npm@$($best.Major)" { & $npmCmd install --prefix $nodeDir "npm@$($best.Major)" --no-fund --no-audit --progress=false }
                            if ($corepackVersion -and -not (Test-Path (Join-Path $nodeDir 'node_modules\corepack\dist\corepack.js'))) {
                                Write-Host "Packaged corepack was pruned by the npm upgrade; reinstalling corepack@$corepackVersion (bundled version)..."
                                Invoke-NativeChecked "Packaged corepack reinstall" { & $npmCmd install --prefix $nodeDir "corepack@$corepackVersion" --no-fund --no-audit --progress=false }
                            }
                            Write-Host "Packaged npm now $((& $npmCmd --version 2>$null).Trim()) (official requires $npmReq)."
                        }
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
        # Align with the official updater: rebuild the TUI bundle only when
        # _tui_need_rebuild says so (dist/entry.js missing or older than its
        # inputs). On any error, rebuild (conservative).
        $tuiNeeded = $true
        try {
            $env:PYTHONPATH = "$Repo;$env:PYTHONPATH"
            $tuiProbe = (& $Python -c "from pathlib import Path; from hermes_cli.main import _tui_need_rebuild; print(_tui_need_rebuild(Path(r'$Repo\ui-tui')))" 2>$null | Select-Object -Last 1)
            # A non-zero native exit is NOT a PS exception under 5.1 — check
            # $LASTEXITCODE so a broken venv rebuilds instead of silently
            # shipping a stale/missing bundle (2026-08-22).
            if ($LASTEXITCODE -ne 0) { $tuiNeeded = $true } else { $tuiNeeded = ($tuiProbe -eq 'True') }
        } catch { $tuiNeeded = $true }
        if ($tuiNeeded) {
            try {
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
        } else {
            Write-Host 'TUI bundle is fresh; skipping TUI rebuild.'
        }
    }

    # Prebuilt Web bundle (same contract as TUI): ship hermes_cli/web_dist so
    # `hermes dashboard` serves the real browser UI, and rebuild it after every
    # source update so the bundle matches the checked-out web/ source. On
    # failure, drop any stale bundle so the dashboard fails explicitly
    # ("Frontend not built") instead of serving a mismatched old UI.
    $webDistDir = Join-Path $Repo 'hermes_cli\web_dist'
    # Align with the official updater: rebuild the web bundle only when
    # _web_ui_build_needed says so (content-hash stamp). On any error,
    # rebuild (conservative).
    $webNeeded = $true
    try {
        $env:HERMES_HOME = $HermesHome
        $env:PYTHONPATH = "$Repo;$env:PYTHONPATH"
        $webProbe = (& $Python -c "from pathlib import Path; from hermes_cli.main import _web_ui_build_needed; print(_web_ui_build_needed(Path(r'$Repo\web')))" 2>$null | Select-Object -Last 1)
        # Non-zero native exit = probe failed -> rebuild (conservative, 2026-08-22).
        if ($LASTEXITCODE -ne 0) { $webNeeded = $true } else { $webNeeded = ($webProbe -eq 'True') }
    } catch { $webNeeded = $true }
    if ($webNeeded) {
        try {
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
    } else {
        Write-Host 'Web UI bundle is fresh; skipping web rebuild.'
    }

    if ($needDesktopBuild) {
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

        # Record the pristine (patch-free) source state so the next update can
        # skip the rebuild when the desktop tree did not change.
        Write-DesktopBuildStamp $Repo $HermesHome
    } else {
        Write-Host "Desktop app unchanged; keeping current app (desktop-build-stamp matches)."
    }

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
    'WriteDesktopStamp' {
        # Build-machine stage: record the pristine desktop source hash of the
        # staged hermes-agent so deployed updates can skip the electron-builder
        # rebuild when the desktop tree did not change.
        $stampRoot = if ($PortableRoot) { $PortableRoot } else { $Root }
        $stampRepo = if ($RepoPath) { $RepoPath } else { Join-Path $stampRoot 'data\hermes-home\hermes-agent' }
        Write-DesktopBuildStamp $stampRepo (Join-Path $stampRoot 'data\hermes-home')
    }
}
