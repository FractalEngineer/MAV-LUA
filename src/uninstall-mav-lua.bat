@echo off
setlocal EnableExtensions
rem SPDX-License-Identifier: GPL-3.0-or-later
rem
rem Remove every MAV-LUA file from this SD card, ready for a fresh copy.
rem
rem Keep this file at the top level of the card, next to SCRIPTS and WIDGETS, and it
rem cleans the card it is run from. No path is needed or asked for.
rem
rem   uninstall-mav-lua.bat         confirm, then remove
rem   uninstall-mav-lua.bat /y      remove without asking
rem
rem Only MAV-LUA files are deleted. Nothing else on the card is touched, and the card is
rem never formatted. Run it with the card in a reader on the PC, not in the radio.

rem The script's own folder is the card root, because it sits beside SCRIPTS.
set "CARD=%~dp0"
if "%CARD:~-1%"=="\" set "CARD=%CARD:~0,-1%"

set "ASSUME_YES="
if /I "%~1"=="/y" set "ASSUME_YES=1"

echo.
echo Removing MAV-LUA from:
echo   %CARD%
echo.

if not exist "%CARD%\SCRIPTS" (
  echo Could not find a SCRIPTS folder next to this script, so this does not look like
  echo your SD card. Copy this file to the card's top level, beside SCRIPTS and WIDGETS,
  echo then run it again. Nothing deleted.
  echo.
  if not defined ASSUME_YES pause
  exit /b 1
)

echo   SCRIPTS\MAV\                  all parameter modules and any built index
echo   SCRIPTS\TELEMETRY\MAV.lua
echo   SCRIPTS\TELEMETRY\MAV.luac
echo   SCRIPTS\TOOLS\MAV.lua
echo   SCRIPTS\TOOLS\MAV.luac
echo   SCRIPTS\TOOLS\MAVLUA_BUILD_INDEX.lua
echo   SCRIPTS\TOOLS\MAVLUA_BUILD_INDEX.luac
echo   WIDGETS\MAV\
echo.
echo The parameter index is removed with the rest, so the next run reads the vehicle's
echo parameters again. That is deliberate: a stale index must never shadow a new one.
echo.

if defined ASSUME_YES goto confirmed

rem Answered with goto rather than a parenthesised block: batch expands %CONFIRM% when it
rem parses a whole block, which happens before set /p runs, so a block would always see an
rem empty value and cancel. Only the first character is compared, because redirected input
rem such as "echo y | script" arrives as "y " with a trailing space.
set /p CONFIRM="Remove these files? [y/N] "
if /I "%CONFIRM:~0,1%"=="y" goto confirmed

echo.
echo Cancelled. Nothing deleted.
echo.
if not defined ASSUME_YES pause
exit /b 0

:confirmed

echo.

rem A read-only file would otherwise survive and leave its folder behind, so clear the
rem attribute on anything being removed first.
if exist "%CARD%\SCRIPTS\MAV" (
  attrib -R /S /D "%CARD%\SCRIPTS\MAV\*" >nul 2>&1
  rd /s /q "%CARD%\SCRIPTS\MAV"
)
if exist "%CARD%\WIDGETS\MAV" (
  attrib -R /S /D "%CARD%\WIDGETS\MAV\*" >nul 2>&1
  rd /s /q "%CARD%\WIDGETS\MAV"
)

for %%F in (
  "%CARD%\SCRIPTS\TELEMETRY\MAV.luac"
  "%CARD%\SCRIPTS\TELEMETRY\MAV.lua"
  "%CARD%\SCRIPTS\TOOLS\MAV.luac"
  "%CARD%\SCRIPTS\TOOLS\MAV.lua"
  "%CARD%\SCRIPTS\TOOLS\MAVLUA_BUILD_INDEX.luac"
  "%CARD%\SCRIPTS\TOOLS\MAVLUA_BUILD_INDEX.lua"
) do (
  if exist %%F (
    attrib -R %%F >nul 2>&1
    del /f /q %%F >nul 2>&1
  )
)

rem Verify rather than assume, so a locked or protected card is reported honestly.
set "LEFTOVER="
if exist "%CARD%\SCRIPTS\MAV" set "LEFTOVER=1"
if exist "%CARD%\WIDGETS\MAV" set "LEFTOVER=1"
for %%F in (
  "%CARD%\SCRIPTS\TELEMETRY\MAV.lua"
  "%CARD%\SCRIPTS\TELEMETRY\MAV.luac"
  "%CARD%\SCRIPTS\TOOLS\MAV.lua"
  "%CARD%\SCRIPTS\TOOLS\MAV.luac"
  "%CARD%\SCRIPTS\TOOLS\MAVLUA_BUILD_INDEX.lua"
  "%CARD%\SCRIPTS\TOOLS\MAVLUA_BUILD_INDEX.luac"
) do if exist %%F set "LEFTOVER=1"

if defined LEFTOVER (
  echo Some files could not be removed. Another program may be using the card, or the card
  echo is write-protected. Close any Explorer window showing it and run this again.
  echo.
  if not defined ASSUME_YES pause
  exit /b 1
)

echo MAV-LUA removed. Now copy the new package's SCRIPTS folder here, then restart the
echo radio so EdgeTX rebuilds its script caches.
echo.
if not defined ASSUME_YES pause
exit /b 0

