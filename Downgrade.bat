@echo off
REM ===================================================================
REM  Steam Game Downgrade Helper
REM
REM  DOUBLE-CLICK THIS FILE to run the tool.
REM
REM  This wrapper exists because Windows blocks PowerShell scripts that
REM  arrive from the internet (a zip download or a Git clone). Rather
REM  than asking you to change a machine-wide security setting, it
REM  lifts the restriction for THIS ONE RUN only. Nothing about your
REM  system is changed permanently.
REM ===================================================================

title Steam Game Downgrade Helper

REM %~dp0 is this file's own folder, so the pack works from any location
REM and from any drive - no paths are assumed.
set "PACKDIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PACKDIR%Downgrade.ps1" %*

REM Windows PowerShell 5.1 is used deliberately - it ships with Windows.
REM Nothing needs installing to run this.

if errorlevel 1 (
    echo.
    echo ----------------------------------------------------------------
    echo  The tool stopped early. Any message above explains why.
    echo  Your game files were only changed if it said so explicitly.
    echo ----------------------------------------------------------------
    echo.
    pause
)
