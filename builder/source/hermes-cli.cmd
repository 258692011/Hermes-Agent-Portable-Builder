@echo off
setlocal
set "ROOT=%~dp0..\.."
set "HERMES_HOME=%ROOT%\data\hermes-home"
set "AGENT_ROOT=%HERMES_HOME%\hermes-agent"
if not defined HERMES_PORTABLE_SITE_PACKAGES set "HERMES_PORTABLE_SITE_PACKAGES=%AGENT_ROOT%\venv\Lib\site-packages"
set "PYTHONPATH=%ROOT%\runtime\python-bootstrap;%AGENT_ROOT%;%PYTHONPATH%"
set "HERMES_GIT_BASH_PATH=%HERMES_HOME%\git\bin\bash.exe"
set "UV_PYTHON_INSTALL_DIR=%ROOT%\runtime\python"
set "UV_PYTHON_INSTALL_BIN=0"
set "UV_PYTHON_INSTALL_REGISTRY=0"
set "PATH=%HERMES_HOME%\node;%HERMES_HOME%\git\cmd;%HERMES_HOME%\git\bin;%HERMES_HOME%\git\usr\bin;%ROOT%\runtime\bin;%PATH%"
rem The desktop app sets HERMES_WEB_DIST to its own Electron bundle for its
rem embedded dashboard. Clear it here so a standalone `hermes dashboard` serves
rem the shipped hermes_cli\web_dist browser UI instead of the desktop bundle
rem (which needs the desktop IPC bridge and breaks in a plain browser).
set "HERMES_WEB_DIST="

set "PYTHON_DIR="
if exist "%ROOT%\runtime\python\current.txt" set /p "PYTHON_DIR="<"%ROOT%\runtime\python\current.txt"
if not defined PYTHON_DIR (
  echo Portable Python runtime pointer is missing: %ROOT%\runtime\python\current.txt 1>&2
  echo Run scripts\Repair-Portable.ps1 to repair it from the official scripts\install.ps1 PythonVersion. 1>&2
  exit /b 1
)
set "PYTHON=%ROOT%\runtime\python\%PYTHON_DIR%\python.exe"
if not exist "%PYTHON%" (
  echo Bundled Python runtime not found: %PYTHON% 1>&2
  echo Run scripts\Repair-Portable.ps1 to repair the runtime pointer. 1>&2
  exit /b 1
)
"%PYTHON%" -m hermes_cli.main %*
