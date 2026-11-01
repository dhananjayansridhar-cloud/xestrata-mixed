@echo off
rem Start Strata in multi-vendor mode (RX 7900 XTX + RTX 4070 Ti SUPER in one process, port 8097).
rem Checks for a newer XeStrata release first; if there is one it builds it, tests it, and keeps it only if it runs.
rem If the new version does not run, it goes back to the last working version and shows a popup.
rem Options: -NoUpdate (skip the check), -CheckOnly (only report whether a newer release exists), -Rebuild (rebuild
rem against newer installed toolkits), -Sessions N (serve N conversations in parallel instead of one pipelined session).
title XeStrata multi-vendor launcher
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strata-multi.ps1" %*
if errorlevel 1 ( echo. & pause ) else ( timeout /t 15 )
