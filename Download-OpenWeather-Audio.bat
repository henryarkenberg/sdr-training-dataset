@echo off
rem ============================================================
rem  Open Weather Archive - audio downloader
rem  Made in Pakistan - https://github.com/henryarkenberg/sdr-training-dataset
rem
rem  Drag archive.csv onto this file (or just double click it if
rem  the CSV sits in the same folder).
rem ============================================================
setlocal
title Made in Pakistan - Open Weather Archive audio downloader
pushd "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenWeather-Audio-Downloader.ps1" %*

set "RC=%ERRORLEVEL%"

popd
echo.
pause
exit /b %RC%
