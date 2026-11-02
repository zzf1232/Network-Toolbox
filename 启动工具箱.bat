@echo off
chcp 936 >nul
title 网络工具箱
setlocal
set "PS1=%~dp0NetworkToolbox.ps1"

if not exist "%PS1%" (
    echo.
    echo 错误：找不到 NetworkToolbox.ps1
    echo 请确认本文件和 NetworkToolbox.ps1 放在同一个文件夹中。
    echo.
    pause
    exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
    echo 正在请求管理员权限，请在弹出的窗口点击"是"...
    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
pause
endlocal
