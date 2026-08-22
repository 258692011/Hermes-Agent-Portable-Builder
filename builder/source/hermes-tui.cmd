@echo off
rem Skip the early CSI mouse-mode reset that main.py emits before the TUI
rem starts: legacy cmd/conhost renders those bytes as literal garbage while
rem VT-capable terminals swallow them. (Upstream escape hatch:
rem HERMES_TUI_NO_EARLY_DISABLE=1)
set "HERMES_TUI_NO_EARLY_DISABLE=1"
call "%~dp0hermes-cli.cmd" --tui %*
exit /b %errorlevel%
