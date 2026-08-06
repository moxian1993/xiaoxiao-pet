@echo off
cd /d "%~dp0"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File ".\CorgiPet.ps1"
echo.
echo 如果上方显示错误，请截图发给开发者。
pause
