$ErrorActionPreference = 'Stop'
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$HomeDir = Join-Path $Root 'data\hermes-home'
$PythonPointer = Join-Path $Root 'runtime\python\current.txt'
if (-not (Test-Path $PythonPointer)) {
  Write-Error "Portable Python runtime pointer is missing: $PythonPointer"
  exit 1
}
$PythonRuntimeName = [IO.File]::ReadAllText($PythonPointer, [Text.Encoding]::UTF8).Trim()
if (-not $PythonRuntimeName -or $PythonRuntimeName -match '[\\/:*?"<>|]') {
  Write-Error "Portable Python runtime pointer is invalid: $PythonRuntimeName"
  exit 1
}
$Checks = [ordered]@{
  Launcher = Join-Path $Root 'Hermes.exe'
  Updater = Join-Path $Root 'Update.exe'
  Desktop = Join-Path $Root 'app\Hermes.exe'
  PortableMarker = Join-Path $Root 'app\portable.marker'
  Hermes = Join-Path $Root 'runtime\bin\hermes-cli.cmd'
  TuiCli = Join-Path $Root 'runtime\bin\hermes-tui.cmd'
  DashboardCli = Join-Path $Root 'runtime\bin\hermes-dashboard.cmd'
  Python = Join-Path $Root "runtime\python\$PythonRuntimeName\python.exe"
  Node = Join-Path $HomeDir 'node\node.exe'
  Npm = Join-Path $HomeDir 'node\npm.cmd'
  # corepack body + shim: the official Node zip bundles corepack, but the
  # Ensure-OfficialNpm npm upgrade (Hermes.ps1) prunes
  # node_modules\corepack, leaving dead shims (verified 2026-08-14). Gate on
  # the body file so a pruned corepack fails the build.
  Corepack = Join-Path $HomeDir 'node\node_modules\corepack\dist\corepack.js'
  CorepackShim = Join-Path $HomeDir 'node\corepack.cmd'
  Git = Join-Path $HomeDir 'git\cmd\git.exe'
  Bash = Join-Path $HomeDir 'git\bin\bash.exe'
  Uv = Join-Path $Root 'runtime\bin\uv.exe'
  WebDist = Join-Path $HomeDir 'hermes-agent\hermes_cli\web_dist\index.html'
  TuiDist = Join-Path $HomeDir 'hermes-agent\hermes_cli\tui_dist\entry.js'
}

foreach ($legacyName in @('Hermes-Desktop.exe', 'Update-Hermes.exe')) {
  $legacyPath = Join-Path $Root $legacyName
  if (Test-Path $legacyPath) {
    Write-Error "Legacy root executable must not be packaged: $legacyPath"
    exit 1
  }
}

$missing = @($Checks.GetEnumerator() | Where-Object { -not (Test-Path $_.Value) })
if ($missing) {
  $missing | ForEach-Object { Write-Error "Missing $($_.Key): $($_.Value)" }
  exit 1
}

$env:HERMES_HOME = $HomeDir
$env:HERMES_DESKTOP_USER_DATA_DIR = Join-Path $Root 'data\electron-user-data'
$env:HERMES_GIT_BASH_PATH = $Checks.Bash
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Root 'runtime\python'
$env:UV_PYTHON_INSTALL_BIN = '0'
$env:UV_PYTHON_INSTALL_REGISTRY = '0'
$env:HERMES_PORTABLE_SITE_PACKAGES = Join-Path $HomeDir 'hermes-agent\venv\Lib\site-packages'
$env:PYTHONPATH = @(
  (Join-Path $Root 'runtime\python-bootstrap')
  (Join-Path $HomeDir 'hermes-agent')
  $env:PYTHONPATH
) -join ';'
$env:PATH = @(
  (Join-Path $HomeDir 'hermes-agent\venv\Scripts')
  (Join-Path $HomeDir 'node')
  (Join-Path $HomeDir 'git\cmd')
  (Join-Path $HomeDir 'git\bin')
  (Join-Path $HomeDir 'git\usr\bin')
  (Join-Path $Root 'runtime\bin')
  $env:PATH
) -join ';'

$results = [ordered]@{}
function Invoke-Check([string]$File, [string[]]$Arguments) {
  # ProcessStartInfo captures native stderr as plain text. PowerShell 5.1's
  # native pipeline otherwise wraps successful warning output in noisy
  # NativeCommandError records when the script uses Stop semantics.
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $File
  $psi.Arguments = ($Arguments | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
  }) -join ' '
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $process = [Diagnostics.Process]::Start($psi)
  # Read BOTH redirected streams asynchronously: a sequential
  # ReadToEnd() on stdout before stderr can deadlock when the child
  # fills the 4KB stderr pipe buffer while the parent still blocks on
  # stdout's EOF. Parallel async reads drain both pipes concurrently.
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  $exitCode = $process.ExitCode
  $output = ($stderr + $stdout).Trim()
  if ($exitCode -ne 0) { throw "$File failed with exit code $exitCode`n$output" }
  return $output
}

$results.Hermes = Invoke-Check $Checks.Hermes @('--version')
$results.Python = (& $Checks.Python --version 2>&1 | Out-String).Trim()
$results.Node = (& $Checks.Node --version 2>&1 | Out-String).Trim()
$results.Npm = (& $Checks.Npm --version 2>&1 | Out-String).Trim()
$results.Corepack = (& $Checks.CorepackShim --version 2>&1 | Out-String).Trim()
$results.Git = (& $Checks.Git --version 2>&1 | Out-String).Trim()
$results.Bash = ((& $Checks.Bash --version 2>&1) | Select-Object -First 1 | Out-String).Trim()
$results.Uv = (& $Checks.Uv --version 2>&1 | Out-String).Trim()
$results.Imports = (& $Checks.Python -c "import hermes_cli, dotenv, fastapi, yaml; print('ok')" 2>&1 | Out-String).Trim()
$results.McpImports = Invoke-Check $Checks.Python @('-c', "import mcp; print('mcp-ok')")

$results | ConvertTo-Json -Depth 3

