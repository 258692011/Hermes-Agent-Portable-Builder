@echo off
setlocal EnableDelayedExpansion
rem Open the Hermes web dashboard in the default browser.
rem Default port is 9119. For a FIXED custom port, edit PORT below; for a
rem one-off, pass it through, e.g.:  hermes-dashboard.cmd --port 9120
rem If the dashboard server is already listening on the target port, this
rem just opens the browser; otherwise it starts the server (foreground,
rem auto-opens the browser) and closing this window stops the server.
rem Capture %~dp0 BEFORE any shift: cmd's shift overwrites %0 (the script
rem path) with %1, which would make %~dp0 resolve to the current directory.
set "BIN=%~dp0"
set "PORT=9119"
set "HOST=127.0.0.1"

rem Parse --port N / --port=N from the args; everything else is forwarded.
rem NOTE: cmd's `if` does NOT support wildcards, so "--port=*" never matched;
rem compare the first 7 chars ("--port=") instead (verified 2026-08-10).
:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="--port" (
  set "PORT=%~2"
  shift
  goto :parse
)
set "ARG=%~1"
if /i "!ARG:~0,7!"=="--port=" (
  set "PORT=!ARG:~7!"
  shift
  goto :parse
)
shift
goto :parse

:parsed
if "!PORT!"=="0" goto :start
netstat -ano | findstr /c:":!PORT! " | findstr /c:"LISTENING" >nul 2>&1
if %errorlevel%==0 (
  start "" "http://!HOST!:!PORT!"
  exit /b 0
)
:start
call "%BIN%hermes-cli.cmd" dashboard %*
exit /b %errorlevel%
