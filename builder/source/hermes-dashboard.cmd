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
  rem Port is taken. Verify the listener is actually the Hermes dashboard
  rem before reusing it (a foreign app could be squatting on 9119). Fingerprint
  rem = the dashboard's root HTML <title>; anything else means a foreign
  rem service, so fall back to an OS-assigned random port (--port 0) instead
  rem of opening a browser at a stranger's page. curl ships with Windows 10
  rem 1803+; if it is somehow missing, treat the listener as foreign (safe).
  set "IS_HERMES="
  where curl >nul 2>&1
  if not errorlevel 1 (
    for /f "delims=" %%t in ('curl -s --max-time 5 "http://!HOST!:!PORT!/" 2^>nul ^| findstr /c:"Hermes Agent - Dashboard"') do set "IS_HERMES=1"
  )
  if defined IS_HERMES (
    start "" "http://!HOST!:!PORT!"
    exit /b 0
  )
  echo WARNING: port !PORT! is occupied by a non-Hermes service; starting on a random port.
  set "PORT=0"
)
:start
rem NOTE: --port !PORT! MUST come AFTER %* — argparse keeps the LAST
rem occurrence of a repeated option, so this guarantees the resolved PORT
rem (possibly rewritten to 0 by the foreign-occupant fallback above) wins
rem over a --port the user may have passed explicitly.
call "%BIN%hermes-cli.cmd" dashboard %* --port !PORT!
exit /b %errorlevel%
